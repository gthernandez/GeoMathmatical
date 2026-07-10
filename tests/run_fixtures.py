"""run_fixtures.py -- offline regression suite over the committed fixtures (plan 13, D32).

Runs the FULL GeoMathmatical pipeline (walk -> normalize -> sanitize -> audit ->
emit) against each committed fixture case via `--replay`, with a FIXED sanitizer
seed and a FIXED capturedAt, so the emitted capture.json is byte-for-byte
reproducible. Diffing that against the committed baseline catches any unintended
change to walk/normalize/sanitize/emit.

Determinism (why this is stable):
  - --seed <SEED> pins the sanitizer PRNG (random.Random(SEED), Mersenne Twister --
    stable across Python versions/platforms), so pseudonyms are reproducible.
  - --captured-at <PINNED> pins the only wall-clock field in the header.
  - fixtures are static; json_writer emits 2-space/LF/no-BOM deterministically.

Modes:
  --check   (default) regenerate each case into a temp dir and DIFF against
            baselines/<case>.capture.json. Exit 1 if any case drifts or a
            baseline is missing. This is the CI/regression gate.
  --update  regenerate and OVERWRITE the baselines (use after an intended change;
            review the diff before committing).

The temp working dir keeps the on-site mapping.<serial>.json and audit_report.json
OUT of the repo -- only capture.json is harvested. Cross-build (PowerShell) parity
is a separate check (D26, --no-sanitize byte-identity); seeded-sanitize baselines
are Python-only because the two builds' PRNGs differ by design.

Usage:
  python Scripts/tests/run_fixtures.py            # check (regression gate)
  python Scripts/tests/run_fixtures.py --update   # refresh baselines
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.abspath(os.path.join(HERE, ".."))   # parent of the geomathmatical package
FIXTURES = os.path.join(HERE, "fixtures")
BASELINES = os.path.join(HERE, "baselines")
REPLAY_CFG = os.path.join(HERE, "replay.cfg")

SEED = 0
CAPTURED_AT = "2020-01-01T00:00:00Z"   # pinned, obviously-synthetic

CASES = ["e1090_base", "e1090_ti", "e1090_si"]


def _generate(case, out_dir):
    """Run the pipeline for one case; return the emitted capture.json text."""
    fixture_dir = os.path.join(FIXTURES, case)
    if not os.path.isdir(fixture_dir):
        raise SystemExit("missing fixture: {0} (run build_fixtures.py)".format(fixture_dir))
    out_path = os.path.join(out_dir, "capture.json")
    cfg_path = os.path.join(out_dir, "replay.cfg")
    shutil.copyfile(REPLAY_CFG, cfg_path)   # a writable copy; keeps tests/ clean
    cmd = [sys.executable, "-m", "geomathmatical",
           "--replay", fixture_dir,
           "--config", cfg_path,
           "--seed", str(SEED),
           "--captured-at", CAPTURED_AT,
           "--phases", "all",
           "--out", out_path]
    proc = subprocess.run(cmd, cwd=SCRIPTS, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, universal_newlines=True)
    if proc.returncode != 0 or not os.path.exists(out_path):
        sys.stdout.write(proc.stdout or "")
        raise SystemExit("pipeline failed for case '{0}' (exit {1})".format(case, proc.returncode))
    with open(out_path, "r", encoding="utf-8") as fh:
        return fh.read()


def _baseline_path(case):
    return os.path.join(BASELINES, "{0}.capture.json".format(case))


def cmd_update():
    if not os.path.isdir(BASELINES):
        os.makedirs(BASELINES)
    for case in CASES:
        tmp = tempfile.mkdtemp(prefix="gmm_fx_")
        try:
            text = _generate(case, tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        with open(_baseline_path(case), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        print("  updated  {0}  ({1} bytes)".format(case, len(text.encode("utf-8"))))
    print("Baselines written to {0}".format(BASELINES))
    return 0


def cmd_check():
    failures = []
    for case in CASES:
        bpath = _baseline_path(case)
        if not os.path.exists(bpath):
            print("  MISSING  {0}  (no baseline -- run --update)".format(case))
            failures.append(case)
            continue
        tmp = tempfile.mkdtemp(prefix="gmm_fx_")
        try:
            got = _generate(case, tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        with open(bpath, "r", encoding="utf-8") as fh:
            want = fh.read()
        if got == want:
            print("  PASS     {0}".format(case))
        else:
            print("  DRIFT    {0}  (output != baseline; see diff below)".format(case))
            _print_diff(want, got, case)
            failures.append(case)
    if failures:
        print("\nFAIL: {0} case(s) drifted/missing: {1}".format(len(failures), ", ".join(failures)))
        return 1
    print("\nOK: {0} case(s) match baseline.".format(len(CASES)))
    return 0


def _print_diff(want, got, case, max_lines=40):
    import difflib
    diff = list(difflib.unified_diff(
        want.splitlines(), got.splitlines(),
        fromfile="baseline/{0}".format(case), tofile="generated/{0}".format(case), lineterm=""))
    for line in diff[:max_lines]:
        print("    " + line)
    if len(diff) > max_lines:
        print("    ... ({0} more diff lines)".format(len(diff) - max_lines))


def main():
    ap = argparse.ArgumentParser(description="Offline fixture regression suite (plan 13)")
    ap.add_argument("--update", action="store_true",
                    help="overwrite baselines (after an intended change)")
    args = ap.parse_args()
    return cmd_update() if args.update else cmd_check()


if __name__ == "__main__":
    sys.exit(main())
