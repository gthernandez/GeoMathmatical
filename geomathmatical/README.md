# GeoMathmatical v0 -- Python reference build

Reads a live Hitachi VSP array over its **Block Storage REST API** and emits a
sanitized, portable **geometry file** (`capture.json`) -- provisioning *and*
replication. The sanitize step runs **on-site**: real serials / WWNs / names /
IPs are replaced with referential-integrity-preserving pseudonyms before anything
is written, and the real->pseudonym key stays on-site. v1 scope is **GRAB ONLY**
(no diorama ingest). Concept: `pm/GEOMETRY_CAPTURE_CONCEPT.md`; plan:
`Docs/v0_capture_plan.md`; rulings: `pm/DECISIONS.md`.

The PowerShell 5.1 parity build is `Scripts/geomathmatical_ps/` (D26).

## To run it

```
python geomathmatical.py --help          # from inside this folder
```

`geomathmatical.py` is the entry point -- run that. It is a thin wrapper, exactly
equivalent to `python -m geomathmatical` (which also works); every flag is the same.

## Requirements

**Stock Python 3, zero install.** Stdlib only (`urllib`/`ssl`/`json`/`configparser`/
`getpass`) so it runs unchanged on a locked-down jump box. Nothing to `pip install`.

## Read-only by construction

The live client's request choke point (`LiveRestClient._urlopen`) refuses any request
that is not a `GET` -- the only writes it will issue are to manage its **own** session
(`POST`/`DELETE .../v1/objects/sessions`). It cannot modify the array (grab-only, D19),
so it is safe to point at production or a borrowed lab.

## Quick start

```
# 1. First run writes a cfg template and prints the common-flags table, then exits.
python geomathmatical.py

# 2. Edit geomathmatical.cfg -> set [target] host and [auth] username.
#    (The password is prompted no-echo at run time; never stored, never a CLI arg.)

# 3. Capture. Password is prompted unless GEOM_PASSWORD is set.
python geomathmatical.py --out capture.json
```

Outputs (a sanitizing run writes three files):

| File | What | Leaves site? |
|---|---|---|
| `capture.json` | the sanitized geometry -- the shareable artifact | yes |
| `mapping.<serial>.json` | the real->pseudonym key | **never** (keep on-site) |
| `audit_report.json` | redacted pre-export survivor-scan report | yes |

On a real array, prefer the **lab-safe** path: `--raw-dir DIR` writes each endpoint
as it is fetched (atomic, **resumable** -- a re-run continues, a timeout only loses the
in-flight request), then transform offline with `--replay DIR`.

## Common flags

The first run (and `--help`) print this table; the full list is in `--help`.

| Flag | What it does | Default |
|---|---|---|
| `--ldev-option OPT` | which LDEVs `GET ldevs` returns (see below) | `defined` |
| `--raw-dir DIR` | lab-safe incremental+resumable raw collection; transform later with `--replay` | (off) |
| `--replay DIR` | offline: serve fixtures from a capture folder instead of HTTP (D32) | (off) |
| `--no-sanitize` | emit REAL identifiers (gated, loud) -- output must NOT leave the site | (off) |
| `--seed N` | deterministic sanitizer PRNG (reproducible baselines, plan 13) | OS entropy |
| `--captured-at TS` | pin `capturedAtUtc` (reproducible baselines) | now (UTC) |
| `--phases a\|ab\|abc` | which top-level phases to walk | from cfg (`all`) |
| `--dry-run` | walk + report counts; write nothing | (off) |
| `--out PATH` | where `capture.json` is written | `./capture.json` |

## `--ldev-option` (D40)

By default `GET ldevs` returns a row for **every LDEV slot in the address space**,
defined or not -- on the E1090 sim, 65280 rows of which ~99.7% are `NOT DEFINED`
empty stubs (~40MB of JSON that is almost all non-geometry, and bigger/slower on a
large production array). `--ldev-option` filters that at the source:

| Value | Returns |
|---|---|
| `defined` (default) | only defined LDEVs -- the real volumes; skips the empty slots |
| `undefined` | only the undefined slots |
| `dpVolume` | only DP (thin) volumes |
| `luMapped` / `luUnmapped` | only LDEVs that are / are not mapped to a LU path |
| `externalVolume` | only external (UVM) volumes |
| `mappedNamespace` | only NVMe-namespace-mapped LDEVs (VSP One B85/B20, VSP 5000, E1090) |
| `all` | **no filter** -- the faithful full dump, undefined slots included (D31) |

Set once in the cfg (`[capture] ldev_option`) or override per run (`--ldev-option`).
It sends the REST `ldevOption` query (BS p509/p511) and combines with the `headLdevId`/
`count` paging. `--replay` ignores it (fixtures are keyed by endpoint+page, not query).

## Config (`geomathmatical.cfg`)

INI-style; git-ignored; **must never leave the site** (it names the array). Written as
a template on first run. Password is never stored here. Key fields: `[target] host`,
`[auth] username`, `[capture] page_count / phases / ldev_option`, `[output] capture_dir
/ mapping_dir`. See the template's inline comments.

`GEOM_PASSWORD` (env) is a hidden hands-free path for the sim/CI -- loud when used,
undocumented in `--help`, not for production (an env var shows in process listings).

## Testing

Offline regression suite: `Scripts/tests/` (`run_fixtures.py`, plan 13). Runs the full
pipeline against committed fixtures via `--replay` at a fixed seed and diffs a
byte-reproducible baseline. See `Scripts/tests/README.md`.

## Module layout (plan 2.4)

`config.py` (cfg + bootstrap) | `rest_client.py` (live/replay/caching + token recovery,
D36) | `endpoints.py` (the capture map) | `array_models.py` (identity ladder, D25) |
`tree_walker.py` (simple/paginated/per-hg/discovery/replication-pairs) | `normalize.py`
(M5, pass-through stub) | `sanitize.py` (pseudonymizer, D20/D29/D31/D37) | `audit.py`
(pre-export survivor scan, plan 9) | `emit.py` + `json_writer.py` (assemble + hand-rolled
serializer, D27) | `main.py` (CLI + orchestration) | `geomathmatical.py` (the run-me wrapper
-> `main.run()`; equals `python -m geomathmatical`) | `__main__.py` (the `-m` entry).
