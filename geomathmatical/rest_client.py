"""rest_client.py -- session lifecycle, labeled GET, and --replay (plan 2.1, D32).

Two interchangeable clients behind one interface so the whole pipeline
(walk -> normalize -> sanitize -> audit -> emit) runs identically live or offline:

  LiveRestClient    real HTTP to https://<host>/ConfigurationManager (Block
                    Storage REST). Session login/logout, self-signed cert accept,
                    TLS 1.2, and TOKEN-EXPIRY RECOVERY (see below).
  ReplayRestClient  serves canned JSON from a capture folder (D32). The lab
                    collector's file names ARE the labels, so a real capture
                    (Reference/Captures/capture_*/) is a ready-made fixture set.

Both expose:  fetch(label, path, params=None, page=None, hg=None) -> dict | None
  dict  = the parsed response.
  None  = an EXPECTED empty read: a conditional endpoint the array rejects with a
          param/precondition error (400/404/412/417), or a resource the account
          lacks permission for (403). Logged, never fatal (D20).
  raise RestError = recovery was exhausted (a 401 that re-login could not clear, or
          a transient 5xx/network error past the retry budget). Raised on purpose
          so the walk fails LOUDLY rather than emit a capture that silently dropped
          an endpoint (no-silent-truncation, D20 / plan 9).

Token-expiry recovery (why this exists):
  A Block Storage session times out after `aliveTime` seconds (default/max 300),
  and the lab simulator was observed dropping tokens unpredictably mid-collection.
  The stock collector (collect_lab_json.ps1) dodged this by opening one session
  PER collection (D34) -- brute force. Here we keep a single session for the whole
  walk and, on a 401, discard the dead token, log in again, and re-issue the exact
  same GET before continuing (GETs are idempotent, so retry is safe).
  Grounding: bs_auth_sessions.md (session timeout, p40-41, p73; 401 = auth failed,
  p46-47), bs_errors_status.md (status table; 503 retry, p26).
"""

import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

# Mirrors ConvertTo-SafeName in collect_lab_json.ps1 (same char class -> '_').
_UNSAFE = re.compile(r'[\\/:*?"<>|,&=]')

# Status classification (bs_errors_status.md status table).
_TOKEN_EXPIRED = 401           # auth failed -> re-login and retry
_PERMISSION = 403              # no permission -> logged skip, NOT re-auth-able
_CONDITIONAL_SKIP = {400, 404, 412, 417}   # param/precondition -> expected empty
# Everything else (503, other 5xx) and network errors are treated as transient.


class RestError(Exception):
    """Unrecoverable REST read failure -- raised so a partial capture can't pass
    for a complete one (D20). Carries the endpoint label + last status seen."""

    def __init__(self, label, message, status=None):
        self.label = label
        self.status = status
        super().__init__("{0}: {1}".format(label, message))


def safe_name(name):
    return _UNSAFE.sub("_", name)


def _replay_filename(label, page=None, hg=None):
    """Resolve the fixture stem the lab collector would have written."""
    stem = label
    if hg is not None:
        port, num = hg
        stem = "{0}__{1}_{2}".format(label, port, num)
    if page is not None:
        stem = "{0}_page{1:03d}".format(label, page)
    return safe_name(stem) + ".json"


class ReplayRestClient(object):
    """Offline client: reads <capture_dir>/<label...>.json. No network (D32)."""

    def __init__(self, capture_dir, log=None):
        self.capture_dir = capture_dir
        self.mode = "replay"
        self._log = log or (lambda *a, **k: None)

    def open_session(self):
        return True  # no-op offline

    def close_session(self):
        pass

    def fetch(self, label, path, params=None, page=None, hg=None):
        fname = _replay_filename(label, page=page, hg=hg)
        fpath = os.path.join(self.capture_dir, fname)
        if not os.path.exists(fpath):
            return None  # missing fixture == an endpoint the array skipped
        with open(fpath, "r", encoding="utf-8-sig") as fh:
            return json.load(fh)


class CachingRestClient(object):
    """Write-through / read-through cache around another client (the lab-safe pull).

    Every fetch is written to <cache_dir>/<replay-name>.json the MOMENT it returns
    (atomic tmp+rename), and any file already present is served from disk instead of
    re-fetching. So a live pull becomes:
      - INCREMENTAL: each endpoint/page/host-group/child is on disk as soon as it
        lands, so a timeout / kill only loses the in-flight request -- not the run.
      - RESUMABLE: re-running skips what is already on disk and continues where it
        stopped (endpoint- AND page-level, since every fetch is keyed by its file).
    The cache dir IS a --replay fixture folder (same names the collector writes), so
    the slow transform (normalize/sanitize/audit/emit) runs OFFLINE later via
    `--replay <cache_dir>`. This is why a lab session that times out no longer loses
    everything the way an all-in-memory run does (it only writes at the very end).
    """

    def __init__(self, inner, cache_dir, log=None):
        self.inner = inner
        self.cache_dir = cache_dir
        self.mode = "caching"
        self._log = log or (lambda *a, **k: None)
        self.hits = 0
        self.fetched = 0
        if not os.path.isdir(cache_dir):
            os.makedirs(cache_dir)

    def open_session(self):
        return self.inner.open_session()

    def close_session(self):
        self.inner.close_session()

    def fetch(self, label, path, params=None, page=None, hg=None):
        fpath = os.path.join(self.cache_dir, _replay_filename(label, page=page, hg=hg))
        if os.path.exists(fpath):
            self.hits += 1
            with open(fpath, "r", encoding="utf-8-sig") as fh:
                return json.load(fh)
        obj = self.inner.fetch(label, path, params=params, page=page, hg=hg)
        if obj is not None:
            tmp = fpath + ".tmp"      # atomic: a killed write never leaves a half file
            with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
                json.dump(obj, fh)
            os.replace(tmp, fpath)
            self.fetched += 1
        return obj


class LiveRestClient(object):
    """Block Storage REST over HTTP (plan 2.1) with token-expiry recovery.

    Keeps one session for the whole walk; on a 401 it re-authenticates and retries
    the same GET (see module docstring). `reauth_max` bounds re-login attempts per
    request; `retries` bounds transient (5xx/network) backoff attempts per request.
    """

    def __init__(self, host, username, password, timeout_s=30, retries=3,
                 reauth_max=3, backoff_base_s=1.0, alive_time_s=300, verify=False,
                 log=None):
        self.base_url = "https://{0}/ConfigurationManager".format(host)
        self.username = username
        self._password = password
        self.timeout_s = timeout_s
        self.retries = retries              # transient (503/5xx/network) budget
        self.reauth_max = reauth_max        # 401 re-login budget
        self.backoff_base_s = backoff_base_s
        self.alive_time_s = alive_time_s    # request the max (300) to reduce expiry
        self.mode = "live"
        self._token = None
        self._session_id = None
        self._log = log or (lambda *a, **k: None)
        self._reauth_count = 0              # forensic: total re-logins this run
        # Self-signed array certs: accept without verification (plan 2.1).
        self._ctx = ssl.create_default_context()
        if not verify:
            self._ctx.check_hostname = False
            self._ctx.verify_mode = ssl.CERT_NONE

    # -- session lifecycle (plan A1 / G) ------------------------------------
    def _urlopen(self, req):
        """READ-ONLY CHOKE POINT -- every HTTP request the live client makes goes through
        here. The capture path only GETs configuration; the ONLY writes are managing our
        OWN session (POST/DELETE .../v1/objects/sessions). Any other method/endpoint is a
        bug that must never touch a shared array, so refuse it loudly (grab-only, D19)."""
        method = req.get_method()
        url = req.get_full_url()
        own_session = "/v1/objects/sessions" in url
        if method == "GET" or (method in ("POST", "DELETE") and own_session):
            return urllib.request.urlopen(req, timeout=self.timeout_s, context=self._ctx)
        raise RestError("readonly-guard",
                        "refusing non-read-only request {0} {1} (grab-only, D19)".format(method, url))

    def open_session(self):
        """Log in, storing the token. Retries HTTP 503 (64-session cap / maint)."""
        import base64
        pair = "{0}:{1}".format(self.username, self._password)
        basic = "Basic " + base64.b64encode(pair.encode("ascii")).decode("ascii")
        body = json.dumps({"aliveTime": self.alive_time_s}).encode("ascii")
        attempt = 0
        while True:
            req = urllib.request.Request(
                self.base_url + "/v1/objects/sessions/", data=body, method="POST",
                headers={"Accept": "application/json", "Content-Type": "application/json",
                         "Authorization": basic})
            try:
                with self._urlopen(req) as r:
                    obj = json.loads(r.read().decode("utf-8"))
                self._token = obj.get("token")
                self._session_id = obj.get("sessionId")
                return bool(self._token)
            except urllib.error.HTTPError as e:
                # 503 = all 64 session slots busy, or maintenance -> back off, retry.
                if e.code == 503 and attempt < self.retries:
                    self._backoff(attempt, "login 503 (sessions busy); retrying")
                    attempt += 1
                    continue
                raise RestError("session", "login failed (HTTP {0})".format(e.code), e.code)
            except urllib.error.URLError as e:
                if attempt < self.retries:
                    self._backoff(attempt, "login network error ({0}); retrying".format(e.reason))
                    attempt += 1
                    continue
                raise RestError("session", "login unreachable ({0})".format(e.reason))

    def close_session(self):
        """DELETE the session to free its slot (plan G). Best-effort, never raises."""
        if not self._session_id:
            return
        try:
            req = urllib.request.Request(
                "{0}/v1/objects/sessions/{1}".format(self.base_url, self._session_id),
                method="DELETE",
                headers={"Accept": "application/json",
                         "Authorization": "Session {0}".format(self._token)})
            self._urlopen(req).read()
        except Exception:
            pass  # a dead token can't discard itself; the slot times out on its own
        finally:
            self._token = self._session_id = None

    def _reauthenticate(self, label):
        """Drop the dead token and log in again (the recovery core)."""
        self._reauth_count += 1
        self.close_session()          # best-effort discard of the expired session
        self.open_session()           # may raise RestError if the array is truly down
        self._log("AUTH", label, "token expired (401); re-authenticated (#{0})".format(
            self._reauth_count))

    # -- the one GET the walk uses, with recovery ---------------------------
    def fetch(self, label, path, params=None, page=None, hg=None):
        url = self._build_url(path, params, page, hg)
        reauth_left = self.reauth_max
        transient_left = self.retries
        transient_attempt = 0
        last_status = None

        while True:
            status, body = self._raw_get(url)

            if status is not None and 200 <= status < 300:
                return json.loads(body)

            last_status = status

            if status in _CONDITIONAL_SKIP:
                return None  # expected: conditional endpoint / bad param (logged by walker)

            if status == _TOKEN_EXPIRED:
                if reauth_left <= 0:
                    raise RestError(label, "401 persisted after {0} re-login(s)".format(
                        self.reauth_max), status)
                reauth_left -= 1
                self._reauthenticate(label)   # get a fresh token, then loop to retry
                continue

            if status == _PERMISSION:
                # Not a token problem; re-auth won't help. Record and skip (D20).
                self._log("SKIP", label, "403 permission denied (account lacks rights)")
                return None

            # Transient: 503, other 5xx, or network error (status is None).
            if transient_left <= 0:
                raise RestError(label, "unrecoverable after {0} retr(ies), last status {1}".format(
                    self.retries, status), status)
            transient_left -= 1
            self._backoff(transient_attempt, "{0}: status {1}; retrying".format(label, status))
            transient_attempt += 1

    def _raw_get(self, url):
        """Issue the GET. Returns (status, body_str). status None == network error."""
        req = urllib.request.Request(
            url, method="GET",
            headers={"Accept": "application/json", "Content-Type": "application/json",
                     "Authorization": "Session {0}".format(self._token)})
        try:
            with self._urlopen(req) as r:
                return int(r.status), r.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            return int(e.code), None
        except urllib.error.URLError:
            return None, None      # timeout / connection reset -> transient

    def _build_url(self, path, params, page, hg):
        query = dict(params or {})
        if hg is not None:
            query["portId"], query["hostGroupNumber"] = hg
        if page is not None:
            query.setdefault("count", 16384)   # walker also sets headLdevId in params
        url = self.base_url + path
        if query:
            url = url + "?" + urllib.parse.urlencode(query)
        return url

    def _backoff(self, attempt, message):
        """Exponential backoff with a modest ceiling; logged for the forensic trail."""
        delay = min(self.backoff_base_s * (2 ** attempt), 15.0)
        self._log("RETRY", "", "{0} (waiting {1:.1f}s)".format(message, delay))
        time.sleep(delay)
