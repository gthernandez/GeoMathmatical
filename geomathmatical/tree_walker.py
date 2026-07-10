"""tree_walker.py -- drive the capture map into an in-memory raw tree (plan 2.2).

Phase 1 of the two-phase shape (plan 2.2): a pure read that pulls the REST object
tree (endpoints.py) into a plain dict mirror. NOTHING is normalized or sanitized
here -- normalize/sanitize/emit consume this tree next (plan 2.4 design rule).

Handles the endpoint kinds:
  simple             -> tree[label] = data (list for collections; object otherwise)
  paginated          -> tree[label] = concatenated pages (plan 4.1 headLdevId loop)
  per_hg             -> tree[label] = { "<port>_<num>": [...] } over host_groups
  discovery          -> tree[label] = parent list, AND tree[results_key] =
                        { "<parentKey>": <child> } fetched per parent (D35)
  replication_pairs  -> tree["remote_copypairs"] = { "TC": [...], "UR": [...], "GAD": [...] }
                        and tree["remote_replications"] likewise (D35)

Every endpoint hit, count, and skip is handed to `log` (D20 no-silent-truncation).
"""

import urllib.parse

from . import endpoints


def _data_of(obj):
    """Collection responses wrap rows in .data; singletons are the object itself."""
    if obj is None:
        return None
    if isinstance(obj, dict) and "data" in obj:
        return obj["data"]
    return obj


def _count(x):
    return len(x) if isinstance(x, list) else (0 if x is None else 1)


def walk(client, phases="all", page_count=16384, ldev_option="defined", log=None):
    """Return the raw in-memory tree. `client` is Live or Replay (same interface).

    ldev_option (D40): the REST ldevOption filter for the paginated `ldevs` walk --
    "defined" (skip NOT-DEFINED slots), any other enum value, or "all" (no filter,
    the faithful full dump, D31)."""
    log = log or (lambda *a, **k: None)
    tree = {}

    for ep in endpoints.selected(phases):
        label, kind = ep["label"], ep["kind"]

        if kind == "simple":
            obj = client.fetch(label, ep["path"], params=ep["params"])
            data = _data_of(obj)
            tree[label] = data
            _log_hit(log, ep, data)

        elif kind == "paginated":
            tree[label] = _walk_paginated(client, ep, page_count, log,
                                          ldev_option=ldev_option)

        elif kind == "per_hg":
            tree[label] = _walk_per_hg(client, ep, tree.get("host_groups"), log)

        elif kind == "discovery":
            parent, children = _walk_discovery(client, ep, log)
            tree[label] = parent
            tree[ep["discovery"]["results_key"]] = children

        elif kind == "replication_pairs":
            pairs, repl = _walk_replication_pairs(client, ep, log)
            tree["remote_copypairs"] = pairs
            tree["remote_replications"] = repl

    return tree


def _walk_paginated(client, ep, page_count, log, ldev_option="defined"):
    """LDEV-style paging: headLdevId=max(id)+1 until a short/empty page (plan 4.1).

    ldev_option (D40): when set and not "all", sent as the REST `ldevOption` query so
    the array returns only that class of LDEV (default "defined" skips the ~99% of
    NOT-DEFINED address slots). "all" omits it -> the faithful full dump (D31). It
    combines with headLdevId/count (BS p511)."""
    rows = []
    head, page = 0, 0
    while True:
        params = dict(ep["params"])
        params["headLdevId"] = head
        params["count"] = page_count
        if ldev_option and ldev_option != "all":
            params["ldevOption"] = ldev_option
        # Pre-log: this read is the slow one on a live array (a full count=16384
        # page can take a while); log BEFORE the call so it is not silent.
        log("...", ep["label"], "fetching page {0} (headLdevId={1}, count={2}) ...".format(
            page, head, page_count))
        obj = client.fetch(ep["label"], ep["path"], params=params, page=page)
        data = _data_of(obj)
        if not data:
            break
        rows.extend(data)
        if len(data) < page_count:
            break  # last (short) page
        # ascending by id; advance past the max seen this page
        ids = [r.get("ldevId") for r in data if isinstance(r, dict) and r.get("ldevId") is not None]
        if not ids:
            break
        head, page = max(ids) + 1, page + 1
        if page > 64:
            log("WARN", ep["label"], "page ceiling hit; stopping")
            break
    log("OK", ep["label"], "{0} rows over {1} page(s)".format(len(rows), page + 1))
    return rows


def _walk_per_hg(client, ep, host_groups, log):
    """Fan out per host-group, keyed on (portId, hostGroupNumber) (RC5-safe key)."""
    out = {}
    if not host_groups:
        log("SKIP", ep["label"], "no host_groups captured; nothing to fan out")
        return out
    for hg in host_groups:
        port = hg.get("portId")
        num = hg.get("hostGroupNumber")
        if not port or num is None:
            continue
        obj = client.fetch(ep["label"], ep["path"], hg=(port, num))
        data = _data_of(obj) or []
        out["{0}_{1}".format(port, num)] = data
    total = sum(_count(v) for v in out.values())
    log("OK", ep["label"], "{0} rows over {1} host-group(s)".format(total, len(out)))
    return out


def _needs_query(name):
    """A snapshot-group name with / \\ or a lone '.' can't sit in the URL path;
    such names must use the ?snapshotGroupName= query form (D35 / collector)."""
    return "/" in name or "\\" in name or name == "."


def _fetch_child(client, child, mode, key):
    """Fetch one discovery child. Label = <child_label>__<key> so a replay serves
    the exact file the collector wrote; live builds the query or path form."""
    label = "{0}__{1}".format(child["child_label"], key)
    if mode == "query":
        return _data_of(client.fetch(label, child["child_path"],
                                     params={child["child_param"]: key}))
    # path mode: append the (url-encoded) key -- returns the detail object as-is.
    path = child["child_path"] + "/" + urllib.parse.quote(str(key), safe="")
    return client.fetch(label, path)


def _walk_discovery(client, ep, log):
    """Enumerate the parent collection, then fetch a child per parent with the
    required key (D35). Never a bare GET that 400s -- the child always carries its
    id/name/param. Returns (parent_list, flat_child_list).

    Children are collected into a FLAT LIST, not a dict keyed by the parent key:
    the parent key can be a sensitive copy-group / snapshot name, and the sanitizer
    walks dict VALUES not keys, so a sensitive value must never become a key. Each
    child record carries its own identifying fields (copyGroupName, etc.), which the
    sanitizer handles by field name, so the grouping is preserved without leaking."""
    disc = ep["discovery"]
    parent = _data_of(client.fetch(ep["label"], ep["path"], params=ep["params"]))
    _log_hit(log, ep, parent)
    results = []
    for item in (parent or []):
        if not isinstance(item, dict):
            continue
        key = item.get(disc["parent_key"])
        if key in (None, ""):
            continue
        # Thin Image: names with / \ or a lone '.' fall back to the query form.
        fb = disc.get("fallback")
        if fb and fb.get("when") == "special_chars" and _needs_query(str(key)):
            child = _fetch_child(client, fb, "query", key)
        else:
            child = _fetch_child(client, disc, disc["mode"], key)
        if child is None:
            continue
        if isinstance(child, list):
            results.extend(child)        # query form returned a .data list
        else:
            results.append(child)        # path form returned a detail object
    log("OK", disc["results_key"],
        "{0} parent(s) -> {1} child row(s)".format(len(parent or []), len(results)))
    return parent, results


def _walk_replication_pairs(client, ep, log):
    """Flat remote-copypairs per replicationType (TC/UR/GAD), paginated by
    pvolLdevId at page_size; plus the VSP-5000-only remote-replications view,
    best-effort (D35). Returns ({type: [pairs]}, {type: replications})."""
    pairs, repl = {}, {}
    size = ep["page_size"]
    for rt in ep["replication_types"]:
        rows = []
        head, page = 0, 0
        while True:
            params = {"replicationType": rt, "headLdevId": head, "count": size}
            data = _data_of(client.fetch("remote_copypairs_{0}".format(rt), ep["path"],
                                         params=params, page=page))
            if not data:
                break
            rows.extend(data)
            if len(data) < size:
                break
            ids = [r.get(ep["page_key"]) for r in data
                   if isinstance(r, dict) and r.get(ep["page_key"]) is not None]
            if not ids:
                break
            head, page = max(ids) + 1, page + 1
            if page > 200:
                log("WARN", "remote_copypairs_{0}".format(rt), "page ceiling hit; stopping")
                break
        pairs[rt] = rows
        # remote-replications: VSP 5000-only flat view; 412/404 elsewhere -> None.
        rr = _data_of(client.fetch("remote_replications_{0}".format(rt),
                                   "/v1/objects/remote-replications",
                                   params={"replicationType": rt}))
        if rr is not None:
            repl[rt] = rr
    total = sum(len(v) for v in pairs.values())
    log("OK", "remote_copypairs", "{0} pair row(s) over {1}".format(
        total, ",".join(ep["replication_types"])))
    return pairs, repl


def _log_hit(log, ep, data):
    if data is None:
        tag = "SKIP*" if ep["label"] in endpoints.KNOWN_CONDITIONAL else "SKIP"
        log(tag, ep["label"], "no data (conditional / not present on this array)")
    else:
        log("OK", ep["label"], "{0} object(s)".format(_count(data)))
