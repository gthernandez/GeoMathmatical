# GeoMathmatical

Capture the full **geometry** of a Hitachi VSP storage array over its REST API --
provisioning **and** replication -- and emit it as a single sanitized, portable JSON
file. Sanitization runs **on-site**: real serials, WWNs, host-group names, and IPs are
replaced with referential-integrity-preserving pseudonyms *before anything is written*,
and the real-to-pseudonym key never leaves your environment.

*Apache-2.0 &middot; Python + PowerShell &middot; zero-install &middot; read-only.*

Two behavior-identical builds, both **zero-install** (Python standard library / stock
PowerShell only):

| Build | Run it | Folder |
|---|---|---|
| **Python 3** | `python geomathmatical.py --help` | [`geomathmatical/`](geomathmatical/) |
| **PowerShell 5.1** | `.\geomathmatical.ps1` | [`geomathmatical_ps/`](geomathmatical_ps/) |

The PowerShell build ships as one self-contained file (`geomathmatical.ps1`), so it drops
onto a locked-down Windows jump box with nothing to install.

## Requirements

- **Python build:** Python 3 (standard library only -- no `pip install`). Any modern 3.x.
- **PowerShell build:** Windows PowerShell 5.1+ (ships on every current Windows box);
  `Invoke-WebRequest` is native and no modules are required.
- **Array:** a Hitachi VSP exposing the **Block Storage REST API** (the Configuration
  Manager REST API), either embedded on the array or fronted by Ops Center. The tool
  connects to `https://<host>/ConfigurationManager` and accepts the array's self-signed
  certificate.
- **Recognized models** (identity is resolved from the array; unknown models still
  capture, just with a less specific label): VSP 5000 series, VSP E series, VSP One B
  series, VSP G/F/N series, and VSP G1000/G1500/F1500.

## Read-only by construction

The live client issues only `GET` requests, plus `POST`/`DELETE` to manage its **own**
REST session. A hard guard refuses any other method, so the tool **cannot modify the
array**. It is safe to point at production.

## How it works

1. **Identify** the array -- model / generation, from a REST identity ladder.
2. **Walk** every geometry-bearing object: pools, parity groups, drives, ports, LDEVs,
   host groups / LUNs / WWNs.
3. **Discover** replication -- ShadowImage, Thin Image, TrueCopy, Universal Replicator,
   and GAD are found by walking the array's own copy groups, not hard-coded.
4. **Sanitize** identifiers on-site (see below), then **audit** the result and **fail the
   export** if any real identifier survives.
5. **Emit** the geometry file plus the on-site key and a redacted audit report.

## Quick start

```
# Python
python geomathmatical.py                       # first run writes a config template + help
python geomathmatical.py --out capture.json    # capture (prompts for the REST password)

# PowerShell
.\geomathmatical.ps1
.\geomathmatical.ps1 -Out capture.json
```

On first run the tool writes a `geomathmatical.cfg` template and prints a common-flags
table, then exits so you can fill in the array host + username. The REST password is
always prompted (never stored in the config, never passed on the command line).

### Offline / no array

`--replay <dir>` (`-Replay <dir>`) runs the whole pipeline against a previously
**captured folder** instead of a live array. You produce such a folder from a live array
with a `--raw-dir <dir>` (`-RawDir <dir>`) capture run -- it writes each endpoint to disk
as it is fetched and is resumable -- then transform it offline later with `--replay`.

No array handy? The repo ships ready-made capture folders under `tests/fixtures/`. The
simplest way to exercise the full pipeline with no array is the bundled offline suite
(it also sets the right page size for the trimmed fixtures):

```
python tests/run_fixtures.py
```

## Output

A sanitizing run writes three files:

| File | What | Safe to share? |
|---|---|---|
| `capture.json` | the sanitized geometry file -- the portable artifact | **yes** |
| `mapping.<serial>.json` | the real-to-pseudonym key | **no -- keep on-site** |
| `audit_report.json` | redacted pre-export survivor-scan report | yes |

`capture.json` is a single self-describing document: a `source` header (model, microcode,
REST version, capture time, schema version), a `sanitization` block (including the audit
result), then the geometry under `provisioning` and `replication`. Illustrative excerpt
(values are synthetic):

```json
{
  "schema_version": "0",
  "source": {
    "serial": "600042",
    "model": "VSP E1090",
    "modelConfidence": "exact",
    "restApiVersion": "1.32.0",
    "capturedAtUtc": "2026-01-01T00:00:00Z",
    "tool": "GeoMathmatical v0"
  },
  "sanitization": { "applied": true, "audit": { "patternsScanned": 201, "survivors": 0 } },
  "provisioning": {
    "parityGroups": [
      { "parityGroupId": "1-1", "raidLevel": "RAID6", "raidType": "14D+2P",
        "driveTypeName": "SSD", "totalCapacity": 26600 }
    ]
  }
}
```

`schema_version` is `"0"` -- an interim format; expect it to evolve.

## Sanitization

The reason this is safe to run and safe to share. It is **not** a blind find/replace -- it
is referential-integrity-preserving pseudonymization:

- **Replaced** (sensitive): array + remote-array serials, WWPNs/WWNs, host-group names,
  IP addresses, volume nicknames/labels, journal and copy-group names.
- **Kept real** (this is what makes the capture a *useful* model): capacities, RAID
  geometry, drive types, object counts, pool layouts, and the pair/replication topology.
- **Consistent everywhere:** a given real value maps to the **same** pseudonym every place
  it appears -- an LDEV's owning serial, both sides of every pair, every LU path -- so the
  geometry stays coherent. Pseudonyms are length- and format-preserving (a 16-hex WWN
  stays 16 hex; a serial keeps its width).
- **The key stays on-site:** the real-to-pseudonym table is written to
  `mapping.<serial>.json`, which you keep. The emitted `capture.json` carries only
  pseudonyms.
- **Pre-export audit gate:** before writing, the tool scans the assembled file for
  surviving real-identifier patterns and **refuses to export** (non-zero exit) if it finds
  any -- so a leak fails loudly instead of shipping.

`--no-sanitize` emits real values (for local, on-site use only -- that output must never
leave your environment).

## Flags and configuration

Python uses `--flag`; PowerShell uses the same names as `-Flag`. Both print a common-flags
table on first run; `--help` / `Get-Help` lists them all.

| Flag | Purpose |
|---|---|
| `--out <path>` | where `capture.json` is written (default `./capture.json`) |
| `--replay <dir>` | transform a captured folder offline; no array |
| `--raw-dir <dir>` | live capture that writes each endpoint as fetched; resumable |
| `--ldev-option <opt>` | which LDEVs to pull (see below); default `defined` |
| `--no-sanitize` | emit REAL identifiers (gated; output must not leave site) |
| `--seed <int>` | deterministic sanitizer PRNG (reproducible output) |
| `--captured-at <ts>` | pin the capture timestamp (reproducible output) |
| `--phases a\|ab\|abc` | which capture phases to run (default: all) |
| `--dry-run` | walk and report counts; write nothing |
| `--config <path>` | config-file location (default `./geomathmatical.cfg`) |

`--ldev-option` values: `defined` (default -- only real volumes; skips the large,
mostly-empty LDEV address space), `undefined`, `dpVolume`, `luMapped`, `luUnmapped`,
`externalVolume`, `mappedNamespace`, or `all` (no filter -- the faithful full dump).

**Config file** (`geomathmatical.cfg`, INI-style, written on first run, git-ignored):
`[target] host`, `[auth] username`, `[capture] page_count / phases / ldev_option`,
`[output] capture_dir / mapping_dir`, `[tuneables] http_timeout_s / retries`. The password
is never stored here.

## Examples

```
# Live capture, sanitized (the normal case)
python geomathmatical.py --out capture.json

# Lab-safe: pull raw endpoints (resumable), then transform offline later
python geomathmatical.py --raw-dir ./raw
python geomathmatical.py --replay ./raw --out capture.json

# Reproducible output (fixed pseudonyms + timestamp) -- handy for diffing
python geomathmatical.py --replay ./raw --seed 0 --captured-at 2026-01-01T00:00:00Z --out capture.json

# Real values, on-site only (never share this output)
python geomathmatical.py --replay ./raw --no-sanitize --out real.json
```

## Scope and limitations

- **v0, GRAB ONLY.** It captures, sanitizes, and emits. It does not import into anything.
- **Schema `"0"` is interim** and may change.
- **Not captured:** the HORCM/host-side lens (that lives in on-site config files, not the
  array), and external / UVM volumes and iSCSI details are out of the current model
  (anything skipped is logged -- a partial capture never reads as complete).
- **Validation:** exercised end-to-end against a Hitachi VSP simulator; wider real-hardware
  coverage is ongoing. Treat first runs against a new array as validation.

## Development

- `geomathmatical_dev.ps1` is the modular PowerShell source (imports `modules/`);
  `geomathmatical.ps1` is the single-file build generated from it by
  `geomathmatical_ps/build_prod.py`. Edit the dev form + modules, then rebuild.
- The Python and PowerShell builds are kept **byte-identical** on read+emit (same input,
  same output bytes) -- verified by the offline suite.
- Tests: `python tests/run_fixtures.py` runs the whole pipeline against committed fixtures
  and diffs a byte-reproducible baseline.

## Troubleshooting

- **TLS / certificate:** arrays use self-signed certs; the client accepts them by design.
- **Looks stuck at startup:** it is prompting for the REST password (no echo). Set the
  `GEOM_PASSWORD` environment variable for hands-free runs (visible in process listings --
  not for production).
- **Session timeout / 401 mid-walk:** the client keeps one session and transparently
  re-authenticates on expiry; a run that can't recover fails loudly rather than emit a
  partial capture.
- **Only a handful of LDEVs captured:** with a trimmed/`--replay` fixture, match the
  `page_count` the fixture was built with (the bundled suite does this for you).

## License

Apache License 2.0 -- see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Not affiliated with or endorsed by Hitachi; "Hitachi" and "VSP" are trademarks of Hitachi,
Ltd. and/or its affiliates. See [NOTICE](NOTICE).
