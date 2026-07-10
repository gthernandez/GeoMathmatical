# GeoMathmatical offline fixture regression suite (plan 13, D32/D33)

A committable, offline test surface for the v0 capture pipeline. Runs the full
spine -- walk -> normalize -> sanitize -> audit -> emit -- against canned REST
fixtures via `--replay`, with a fixed sanitizer seed and a fixed capturedAt, so the
emitted `capture.json` is byte-for-byte reproducible. Diffing it against a committed
baseline catches any unintended change to the walk, normalize, sanitize, audit, or
emit logic.

No array, no network, no secrets. This covers **provisioning + Thin Image +
ShadowImage** today; remote replication (TC/UR/GAD) is a future case (needs the
incoming VSP 5000s -- see `pm/TODO.md`).

## Layout

```
Scripts/tests/
  build_fixtures.py            one-time fixture builder (needs Reference/Captures/)
  run_fixtures.py              the regression runner (--check / --update)
  replay.cfg                   secret-free replay config (page_count matches the trim)
  fixtures/<case>/             INPUT fixtures: per-endpoint canned REST bodies
  baselines/<case>.capture.json   EXPECTED sanitized output for each case
```

## Cases

| Case | Content | Source capture (lab sim) |
|---|---|---|
| `e1090_base` | provisioning + 4 empty snapshot-group shells (0 pairs) -- exercises the empty-child discovery path | `capture_20260706_162304` |
| `e1090_ti` | + Thin Image local snapshots (10 snapshot pairs) | `capture_20260707_105306` |
| `e1090_si` | superset of TI + ShadowImage local clone (3 pairs, copy group `SEEDSICG`) | `capture_20260707_205522_si_seeded` |

## Running

```
python Scripts/tests/run_fixtures.py            # regression gate: regenerate + diff vs baselines
python Scripts/tests/run_fixtures.py --update   # refresh baselines after an INTENDED change
```

`--check` (default) regenerates each case into a temp dir and diffs against the
baseline; exit 1 on any drift. `--update` overwrites the baselines -- review the diff
before committing. Both run at a fixed `--seed 0` and `--captured-at
2020-01-01T00:00:00Z`; the on-site `mapping.<serial>.json` and `audit_report.json`
are written to the temp dir and discarded (never the repo).

## Rebuilding fixtures

`build_fixtures.py` is a one-time extraction from the full-scale sim captures under
`Reference/Captures/` (git-ignored). Re-run it only to refresh or extend the fixture
set, then regenerate baselines:

```
python Scripts/tests/build_fixtures.py
python Scripts/tests/run_fixtures.py --update
```

It copies every endpoint file verbatim (small: pools, ports, snapshot/clone groups,
copypairs, ...) and TRIMS the LDEV table: the sim returns the whole 65280-row LDEV
space (~5.7 MB/capture, 4 pages of 16384). The fixtures keep the first 190 LDEVs
**plus** every LDEV referenced by a replication pair or LU path, re-split into pages
of 64 -- so the multi-page paging loop (plan 4.1) still runs and no pair references
an absent LDEV, while the surface drops to a few hundred KB per case. This trim is
deliberate and documented; it is not silent truncation (each case's `_source.txt`
records what was kept vs dropped).

## Committability -- READ THIS

These fixtures are safe to commit **only because they come from the lab simulator**,
which carries no customer data (lab-canned serials/WWNs/names, D33). A raw capture
taken from **real silicon is PRE-SCRUB and must NEVER enter git** -- it can expose
customer identifiers before the sanitizer runs (see the hard rule in `pm/TODO.md`
and D20). When extending this suite, fixtures must come from the sim, the public
MK-manual example payloads, or synthesized data -- never a real-array raw capture.

## Determinism

The sanitizer PRNG is `random.Random(0)` (Mersenne Twister -- stable across Python
versions and platforms), pseudonyms are drawn in deterministic dict-insertion order,
`capturedAtUtc` is pinned, and `json_writer` emits 2-space / LF / no-BOM. Same
fixtures + same seed => byte-identical `capture.json`. (Cross-build Python-vs-
PowerShell byte-identity is a separate check, D26, done with `--no-sanitize`, because
the two builds' PRNGs differ by design -- a seeded sanitize baseline is Python-only.)
