# GeoMathmatical

Capture the full **geometry** of a Hitachi VSP storage array over its REST API --
provisioning **and** replication -- and emit it as a single sanitized, portable JSON
file. Sanitization runs **on-site**: real serials, WWNs, host-group names, and IPs are
replaced with referential-integrity-preserving pseudonyms *before anything is written*,
and the real-to-pseudonym key never leaves your environment.

Two behavior-identical builds, both **zero-install** (stdlib / stock PowerShell only):

| Build | Run it | Folder |
|---|---|---|
| **Python 3** | `python geomathmatical.py --help` | [`geomathmatical/`](geomathmatical/) |
| **PowerShell 5.1** | `.\geomathmatical.ps1` | [`geomathmatical_ps/`](geomathmatical_ps/) |

The PowerShell build ships as one self-contained file (`geomathmatical.ps1`) so it drops
onto a locked-down Windows jump box with nothing to install.

## Read-only by construction

The live client only ever issues `GET` requests (plus `POST`/`DELETE` to manage its own
REST session). It **cannot modify the array** -- there is a hard guard that refuses any
other method. Safe to point at production.

## What it does

1. **Identify** the array (model / generation from the REST identity ladder).
2. **Walk** every geometry-bearing object: pools, parity groups, drives, ports, LDEVs,
   host groups / LUNs / WWNs, and replication (ShadowImage, Thin Image, TrueCopy,
   Universal Replicator, GAD -- discovered, not hard-coded).
3. **Sanitize** identifiers with stable, length/format-preserving pseudonyms (a serial
   maps to the same pseudonym everywhere it appears, so the geometry stays coherent).
4. **Audit** the emitted file for any surviving real identifier and **fail the export**
   if one is found (no silent leaks).
5. **Emit** `capture.json` (shareable) + an on-site `mapping.<serial>.json` key (never
   leaves your site) + a redacted `audit_report.json`.

## Quick start

```
# Python
python geomathmatical.py                       # first run writes a config template + help
python geomathmatical.py --out capture.json    # capture (prompts for the REST password)

# PowerShell
.\geomathmatical.ps1
.\geomathmatical.ps1 -Out capture.json
```

Offline, no array needed: point either build at a captured folder with
`--replay <dir>` / `-Replay <dir>`.

`--ldev-option` (default `defined`) controls which LDEVs are pulled; `defined` skips the
mostly-empty address slots. Pass `--help` for the full flag list; both builds print a
common-flags table on first run.

## Tests

`tests/` has an offline regression suite that runs the whole pipeline against committed
fixtures and diffs a byte-reproducible baseline:

```
python tests/run_fixtures.py          # from the repo root
```

## License

Apache License 2.0 -- see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Not affiliated with or endorsed by Hitachi; "Hitachi" and "VSP" are their trademarks.
See NOTICE for details.
