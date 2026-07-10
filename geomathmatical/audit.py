"""audit.py -- pre-export survivor scan (plan 7 / 9, D20/D37).

Milestone 7. The backstop for the sanitizer: scan the assembled, SANITIZED capture
for any surviving REAL identifier before it is written. survivors MUST be 0 to pass;
nonzero FAILS the export -- main refuses to write the capture (plan 9 acceptance #2).
Inapplicable + skipped in real-values mode (--no-sanitize, plan 7.1).

Why it exists: the sanitizer's field classifier can have gaps (the
quorumStorageSerialNumber leak was one). This pass uses the mapping as GROUND TRUTH
-- it scans for the actual real values that were replaced -- so a real identifier that
slipped through an unclassified field is still caught here. It is not heuristic
pattern-matching; it looks for the exact reals in `mapping`.

Precision rules (learned building M6):
  - Type-aware: a real serial is matched in an INT field by exact equality (so a
    6-digit serial that merely appears as digits inside a kept-real capacity integer
    is NOT a false survivor), and in a STRING field by substring (so a serial embedded
    in a composite ID would be caught). Short reals (< 5 chars) match strings by
    exact equality only, to avoid noise.
  - Kept-real exclusion (D37): fields sanitize.audit_skip() flags -- drive serials --
    are not scanned, so a lab capture (whose fake drive serials embed the array serial)
    does not false-fail. Unclassified fields ARE scanned (classifier-gap backstop).
  - Redacted report: audit_report.json can leave site (plan 12), so survivors are
    reported by path/field/table with a REDACTED hint, never the literal real value.
"""

import re

from . import sanitize


def _redact(v):
    s = str(v)
    if len(s) <= 4:
        return "*" * len(s)
    return s[:2] + "*" * (len(s) - 4) + s[-2:]


class AuditResult(object):
    def __init__(self, patterns_scanned=0, survivors=0, details=None, skipped=False):
        self.patterns_scanned = patterns_scanned
        self.survivors = survivors
        self.details = details or []
        self.skipped = skipped

    @property
    def passed(self):
        return self.skipped or self.survivors == 0

    def report(self):
        """The audit_report.json body (redacted -- safe to leave site)."""
        return {
            "mode": "skipped (real-values)" if self.skipped else "sanitized",
            "patternsScanned": self.patterns_scanned,
            "survivors": self.survivors,
            "pass": self.passed,
            "details": self.details[:100],   # cap; details are already redacted
        }


def _collect_reals(mapping):
    """Index the mapping's real values for scanning."""
    real_to_table = {}
    int_serials = set()
    for table, d in mapping.tables.items():
        for real in d:
            real_to_table[str(real)] = table
            if table == "serials" and str(real).isdigit():
                int_serials.add(int(real))
    distinctive = sorted((r for r in real_to_table if len(r) >= 5), key=len, reverse=True)
    short = {r for r in real_to_table if len(r) < 5}
    pattern = re.compile("|".join(re.escape(r) for r in distinctive)) if distinctive else None
    return {"pattern": pattern, "short": short, "int_serials": int_serials,
            "table": real_to_table, "count": len(real_to_table)}


def _check(path, key, value, reals, survivors):
    if key is not None and sanitize.audit_skip(key, value):
        return                                   # kept-real (D37) -- not a survivor
    if isinstance(value, bool):
        return
    if isinstance(value, int):
        if value in reals["int_serials"]:
            survivors.append({"path": path, "field": key, "table": "serials",
                              "hint": _redact(value)})
        return
    if not isinstance(value, str):
        return
    hit = None
    if reals["pattern"] is not None:
        m = reals["pattern"].search(value)
        if m:
            hit = m.group(0)
    if hit is None and value in reals["short"]:
        hit = value
    if hit is not None:
        survivors.append({"path": path, "field": key,
                          "table": reals["table"].get(hit, "?"), "hint": _redact(hit)})


def _scan(node, path, reals, survivors):
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(v, (dict, list)):
                _scan(v, path + "." + k, reals, survivors)
            else:
                _check(path + "." + k, k, v, reals, survivors)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            p = "{0}[{1}]".format(path, i)
            if isinstance(v, (dict, list)):
                _scan(v, p, reals, survivors)
            else:
                _check(p, None, v, reals, survivors)


def audit(capture, mapping, skip=False):
    """Scan the assembled sanitized `capture` for surviving reals. Returns AuditResult."""
    if skip or mapping is None:
        return AuditResult(skipped=True)
    reals = _collect_reals(mapping)
    survivors = []
    _scan(capture, "root", reals, survivors)
    return AuditResult(patterns_scanned=reals["count"],
                       survivors=len(survivors), details=survivors)
