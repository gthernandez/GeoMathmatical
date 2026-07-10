"""build_fixtures.py -- one-time extraction of committable --replay fixtures (plan 13, D32/D33).

Turns the full-scale lab-sim captures under Reference/Captures/ into small,
COMMITTABLE fixture folders under Scripts/tests/fixtures/<case>/. The sim carries
only lab-canned identifiers (no customer data, D33), so these are safe to commit --
unlike a real-silicon raw capture, which is PRE-SCRUB and must never enter git
(pm/TODO.md fixture-extraction rule; D20).

What it does per case:
  - copies every endpoint file VERBATIM (they are small: pools, ports, snapshot /
    clone groups, copypairs, etc.) -- real field sets, real empty-vs-populated
    collections, so the sanitizer/walk see real shapes;
  - TRIMS the LDEV set: the sim returns the whole 65280-row LDEV space (~5.7 MB of
    JSON per capture, 4 pages of 16384). A committable fixture does not need 65280
    rows to exercise the walk, so we keep the first LDEV_TRIM rows and re-split them
    into pages of PAGE_COUNT. This preserves the multi-page paging loop (plan 4.1)
    and keeps the low-numbered LDEVs the replication pairs reference (pvol/svol
    150-155), while dropping the surface from ~6 MB to a few hundred KB per case.

This is a ONE-TIME build run from a machine that has Reference/Captures/ (which is
git-ignored). It is NOT part of the regression run -- run_fixtures.py works only
from the committed fixtures. Re-run this only to refresh/extend the fixture set.

Usage:  python Scripts/tests/build_fixtures.py
"""

import json
import os
import re
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CAPTURES = os.path.join(REPO, "Reference", "Captures")
FIXTURES = os.path.join(HERE, "fixtures")

# LDEV trim: keep a representative slice, re-paginated at PAGE_COUNT so the walk
# still reads multiple pages then stops on a short last page. Must match the
# page_count in tests/replay.cfg.
LDEV_TRIM = 190
PAGE_COUNT = 64

# case name (fixture dir) -> source capture under Reference/Captures/
CASES = {
    # provisioning + 4 empty snapshot-group shells, 0 pairs (empty-child discovery state)
    "e1090_base": "capture_20260706_162304",
    # + Thin Image local snapshots (10 snapshot pairs across the 4 groups)
    "e1090_ti":   "capture_20260707_105306",
    # superset of TI + ShadowImage local clone (3 clone pairs, copy group SEEDSICG)
    "e1090_si":   "capture_20260707_205522_si_seeded",
}

_LDEV_PAGE = re.compile(r"^ldevs_page\d+\.json$")


def _load(path):
    with open(path, "r", encoding="utf-8-sig") as fh:
        return json.load(fh)


def _dump(obj, path):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(obj, fh, ensure_ascii=False)


def _collect_referenced_ldev_ids(dst_dir):
    """Scan the already-copied (non-ldev) fixture files for LDEV ids referenced by
    other objects -- replication pairs (pvolLdevId/svolLdevId), LU paths (ldevId),
    etc. Any key ending in 'ldevid' counts. So the trimmed LDEV table still contains
    every LDEV its own replication/host objects point at (fidelity: no pair referencing
    an absent LDEV)."""
    ids = set()

    def _scan(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k.lower().endswith("ldevid") and isinstance(v, int):
                    ids.add(v)
                else:
                    _scan(v)
        elif isinstance(node, list):
            for item in node:
                _scan(item)

    for name in os.listdir(dst_dir):
        if _LDEV_PAGE.match(name) or not name.endswith(".json"):
            continue
        try:
            _scan(_load(os.path.join(dst_dir, name)))
        except (ValueError, OSError):
            pass
    return ids


def _trim_ldevs(src_dir, dst_dir):
    """Keep the first LDEV_TRIM rows PLUS any LDEV referenced by other objects
    (replication pairs, LU paths), then re-split into pages of PAGE_COUNT."""
    pages = sorted(f for f in os.listdir(src_dir) if _LDEV_PAGE.match(f))
    rows = []
    for p in pages:
        rows.extend(_load(os.path.join(src_dir, p)).get("data", []))

    referenced = _collect_referenced_ldev_ids(dst_dir)
    kept_ids = set(r.get("ldevId") for r in rows[:LDEV_TRIM])
    kept_ids |= referenced
    # Preserve source (ascending ldevId) order; the walk advances by max id seen.
    kept = [r for r in rows if r.get("ldevId") in kept_ids]
    extra = len([i for i in referenced if i not in
                 set(r.get("ldevId") for r in rows[:LDEV_TRIM])])

    n_pages = 0
    for i in range(0, len(kept), PAGE_COUNT):
        chunk = kept[i:i + PAGE_COUNT]
        _dump({"data": chunk}, os.path.join(dst_dir, "ldevs_page{0:03d}.json".format(n_pages)))
        n_pages += 1
    return len(rows), len(kept), n_pages, extra


def build_case(case, capname):
    src = os.path.join(CAPTURES, capname)
    dst = os.path.join(FIXTURES, case)
    if not os.path.isdir(src):
        raise SystemExit("missing source capture: {0}".format(src))
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(dst)

    copied = 0
    for name in sorted(os.listdir(src)):
        if name == "_capture_log.txt" or _LDEV_PAGE.match(name):
            continue  # log is provenance not a fixture; ldevs handled by _trim_ldevs
        spath = os.path.join(src, name)
        if os.path.isfile(spath):
            shutil.copyfile(spath, os.path.join(dst, name))
            copied += 1

    total, kept, n_pages, extra = _trim_ldevs(src, dst)

    with open(os.path.join(dst, "_source.txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(
            "Fixture case: {0}\n"
            "Source (lab sim, committable per D33): Reference/Captures/{1}\n"
            "Endpoint files copied verbatim: {2}\n"
            "LDEVs: kept {3} of {4} rows (first {5} + {6} referenced by "
            "replication/LU-path objects), re-split into {7} page(s) of {8} "
            "(deliberate trim; see build_fixtures.py). Full-scale set stays in "
            "Reference/Captures/.\n".format(
                case, capname, copied, kept, total, LDEV_TRIM, extra, n_pages, PAGE_COUNT))
    print("  {0:12s} <- {1}: {2} files verbatim, ldevs {3}->{4} (+{5} referenced) "
          "over {6} page(s)".format(case, capname, copied, total, kept, extra, n_pages))


def main():
    print("Building committable fixtures under {0}".format(FIXTURES))
    if not os.path.isdir(FIXTURES):
        os.makedirs(FIXTURES)
    for case, capname in CASES.items():
        build_case(case, capname)
    print("Done. Regenerate baselines: python Scripts/tests/run_fixtures.py --update")


if __name__ == "__main__":
    main()
