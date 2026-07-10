"""config.py -- load geomathmatical.cfg; first-run bootstrap (plan 2.3, D28).

Milestone 0. Pure-local, no network. INI-style so both builds parse it natively
(Python configparser here; Windows PowerShell 5.1 Get-Content+parse in the mirror
build). First run (no cfg): print usage, write a template with a warning header,
then EXIT without capturing so the operator fills it in.

Credentials: the cfg holds host/username/tuneables but the *password is never
stored plaintext* here and never accepted on the CLI (plan 2.3). If username or
secret is missing it is prompted at run time, no-echo (getpass). The cfg is
git-ignored (plan 12) and must never leave the site.
"""

import configparser
import getpass
import os
import stat
import sys

DEFAULT_CFG_NAME = "geomathmatical.cfg"

# HIDDEN testing/automation path (D28 note): if this env var is set, the password
# is taken from it instead of the no-echo prompt, so a full live capture can run
# hands-free (lab sim, CI). Deliberately UNDOCUMENTED in --help and the cfg
# template, and NOT for production: an env var is visible in process listings, the
# same exposure D28 forbids the password on the CLI for. It is loud when used
# (main.py banners it + the forensic log records it). Unset it to force the prompt.
ENV_PASSWORD = "GEOM_PASSWORD"

# Template written on first run. Mirrors the schema in plan 2.3. The warning
# header is deliberately loud -- this file carries site-identifying inputs.
_TEMPLATE = """\
# ============================================================================
# geomathmatical.cfg -- GeoMathmatical v0 operator inputs
# ----------------------------------------------------------------------------
# WARNING: this file names a customer array. It is git-ignored and MUST NEVER
# leave the customer site. The password is NOT stored here -- you are prompted
# for it at run time (no-echo). Fill in the blanks below and re-run.
# ============================================================================

[target]
host            =            ; array / CM REST host or IP (no scheme, no path)
prefix_override =            ; 6-digit model-designator prefix, if identity read fails (D25)
model_override  =            ; exact model string, last-resort override (D25)

[auth]
username        =            ; REST user; may also be given with -u on the CLI
                             ; NOTE: no 'secret' key -- password is prompted, never stored (plan 2.3)

[capture]
page_count      = 16384      ; LDEV page size (1-16384, the API max; plan 4.1)
phases          = all        ; all | a | ab | abc  (which top-level phases to run)
ldev_option     = defined    ; which LDEVs to pull (D40): defined | undefined | dpVolume | luMapped | luUnmapped | externalVolume | mappedNamespace | all
                             ; 'defined' (default) skips the ~99% NOT-DEFINED slots; 'all' = no filter, the faithful full dump (D31). --ldev-option overrides.
raw_never_written = false    ; true keeps even the intermediate in memory (D27)

[output]
capture_dir     =            ; where capture.json + audit_report.json are written
mapping_dir     =            ; real->pseudonym map (D20); STAYS ON-SITE, never exported

[tuneables]
http_timeout_s  = 30
retries         = 3
concurrency     = 1          ; serialize LDEV paging on VSP E/G/F (plan 4.1)
"""


class Config:
    """Parsed, validated operator inputs. Password is resolved separately."""

    def __init__(self, parser, path):
        self._p = parser
        self.path = path

    def get(self, section, key, fallback=None):
        return self._p.get(section, key, fallback=fallback)

    def getint(self, section, key, fallback=None):
        return self._p.getint(section, key, fallback=fallback)

    def getbool(self, section, key, fallback=False):
        return self._p.getboolean(section, key, fallback=fallback)

    # -- convenience accessors for the fields the walk actually needs --
    @property
    def host(self):
        return (self.get("target", "host") or "").strip()

    @property
    def username(self):
        return (self.get("auth", "username") or "").strip()

    @property
    def page_count(self):
        return self.getint("capture", "page_count", 16384)

    @property
    def phases(self):
        return (self.get("capture", "phases", "all") or "all").strip().lower()

    @property
    def ldev_option(self):
        return (self.get("capture", "ldev_option", "defined") or "defined").strip()

    @property
    def raw_never_written(self):
        return self.getbool("capture", "raw_never_written", False)

    @property
    def http_timeout_s(self):
        return self.getint("tuneables", "http_timeout_s", 30)

    @property
    def retries(self):
        return self.getint("tuneables", "retries", 3)


def _write_template(path):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(_TEMPLATE)
    # Restrictive perms where the OS honors them (plan 2.3 / 12).
    try:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)  # 0600
    except OSError:
        pass  # best-effort on Windows/FAT


def load_or_bootstrap(path=None, stream=sys.stderr):
    """Return a Config, or None if this was a first-run bootstrap.

    None means: no cfg existed, a template was written, and the caller should
    print nothing further and exit 0 -- the operator now edits the template.
    """
    path = path or DEFAULT_CFG_NAME
    if not os.path.exists(path):
        _write_template(path)
        stream.write(
            "No config found. Wrote a template to '{0}'.\n"
            "Edit it (set target.host and auth.username), then re-run.\n"
            "The password is prompted at run time -- do not put it in the file.\n"
            .format(path)
        )
        return None

    # inline ';' comments so the template can annotate each key on its own line;
    # the PS 5.1 mirror build strips ';...' the same way when it parses the cfg.
    parser = configparser.ConfigParser(inline_comment_prefixes=(";",))
    parser.read(path, encoding="utf-8")
    return Config(parser, path)


def resolve_password(cfg, cli_username=None, prompt=getpass.getpass):
    """Resolve (username, password). Username may come from CLI (plan 2.3).

    Password is ALWAYS prompted no-echo -- never read from cfg or CLI. Returns
    (username, password). Raises ValueError if no username can be determined.
    """
    username = (cli_username or cfg.username or "").strip()
    if not username:
        raise ValueError("no username: set [auth] username in the cfg or pass -u/--user")
    env_pw = os.environ.get(ENV_PASSWORD)      # hidden automation path (see ENV_PASSWORD)
    if env_pw:
        return username, env_pw
    password = prompt("Password for {0}@{1}: ".format(username, cfg.host))
    return username, password


def password_from_env():
    """True if the hidden env password path is active (for the loud banner)."""
    return bool(os.environ.get(ENV_PASSWORD))
