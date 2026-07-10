# GeoMathmatical v0 -- PowerShell 5.1 build

The Windows PowerShell 5.1 alternate release (D26). Behavior-compatible mirror of the
Python reference build (`Scripts/geomathmatical/`): same endpoint walk (incl. the Phase C
replication discovery, D35), same sanitizer (D20/D29/D31/D37), same pre-export audit
(plan 9), and a hand-rolled JSON serializer that is **byte-identical** to the Python emit.

Runs on a stock Windows jump box with **zero install** -- `Invoke-WebRequest` is native to
5.1, and no `ConvertTo-Json` is used (it truncates at depth 2; we hand-roll instead, D27).

## To run it

```powershell
.\geomathmatical.ps1                 # first run writes a cfg template + a help table
.\geomathmatical.ps1 -Replay <dir> -Out capture.json
Get-Help .\geomathmatical.ps1        # all flags
```

Two entry points, identical flags: **`geomathmatical.ps1`** is the shippable single-file
deliverable (run this / hand this out), and **`geomathmatical_dev.ps1`** is the dev form that
imports `modules/` (edit this). See Layout below. The Python build's equivalent entry point is
`python geomathmatical.py` (`Scripts/geomathmatical/`).

## Layout

The folder root holds only the entry points + tooling:

- **`geomathmatical.ps1`** -- the **deliverable**: one self-contained file (all modules
  inlined), nothing to install. This is what you hand to someone / carry into a locked-down
  box. Generated -- do NOT hand-edit it.
- **`geomathmatical_dev.ps1`** -- the **dev form**: identical behavior, but it imports
  the nine `.psm1` modules from `modules/` (so it needs that folder alongside it). Edit here.
- **`build_prod.py`** -- regenerates `geomathmatical.ps1` from `geomathmatical_dev.ps1`
  + `modules/`. Re-run after editing any module or the modular script.

The nine `.psm1` modules live in the **`modules/`** subfolder.

## Modules (in `modules/`; mirror the Python module-for-module, plan 2.4)

| Module (`modules/`) | Mirrors | Role |
|---|---|---|
| `GmJsonWriter.psm1` | `json_writer.py` | hand-rolled serializer; byte contract for parity |
| `GmArrayModels.psm1` | `array_models.py` | prefix->family map + D25 identity ladder |
| `GmEndpoints.psm1` | `endpoints.py` | the ordered capture map (plan 4) |
| `GmRestClient.psm1` | `rest_client.py` | replay + live GET + token-expiry recovery (D36) |
| `GmTreeWalker.psm1` | `tree_walker.py` | simple/paginated/per-hg/discovery/replication-pairs |
| `GmSanitize.psm1` | `sanitize.py` | referential-integrity pseudonymizer |
| `GmAudit.psm1` | `audit.py` | survivor scan (ground-truth, type-aware, D37) |
| `GmEmit.psm1` | `emit.py` | assemble the interim `schema_version:"0"` object |
| `GmConfig.psm1` | `config.py` | first-run bootstrap + INI cfg load (D28) |
| `geomathmatical_dev.ps1` (root) | `main.py` | CLI + orchestration entry point |

## Run

Both scripts take identical arguments; use `geomathmatical.ps1` (the deliverable) unless you
are developing the modules, in which case run `geomathmatical_dev.ps1`.

```powershell
# first run writes an annotated geomathmatical.cfg template, then exits
.\geomathmatical.ps1

# offline replay against a captured fixture folder (no array)
.\geomathmatical.ps1 -Replay C:\caps\capture_20260706_162304 -Out capture.json

# real-values mode (gated; output carries real identifiers)
.\geomathmatical.ps1 -Replay <dir> -NoSanitize -Out capture.json

# pull only defined LDEVs (default); -LdevOption all = faithful full dump (D40)
.\geomathmatical.ps1 -LdevOption defined -Out capture.json
```

The first run prints a **common-flags table** (mirrors the Python build) that self-names
whichever script you ran; `Get-Help` on the script has the full parameter list. Two flags mirror the Python `--ldev-option` / `--seed` (D40):

- **`-LdevOption`** { defined (default) | undefined | dpVolume | luMapped | luUnmapped |
  externalVolume | mappedNamespace | all } -- which LDEVs `GET ldevs` returns; `defined` skips the
  ~99% NOT-DEFINED slots, `all` sends no filter (the faithful full dump, D31). Also a cfg key
  (`[capture] ldev_option`).
- **`-Seed <int>`** -- deterministic sanitizer PRNG for reproducible mappings *within* the PS build.
  It does NOT match Python's seeded output (.NET `Random` != Mersenne Twister), so it is for PS-side
  reproducibility, not a cross-build byte match (see Parity below).

Live mode reads host/username from the cfg (password prompted no-echo, never on the CLI),
opens one session with 401 recovery, walks, sanitizes on-site, audits, and writes
`capture.json` + the on-site `mapping.<serial>.json` + a redacted `audit_report.json`.

## Parity with the Python reference (D26)

- **Read + emit: proven byte-identical.** Same `--replay` fixtures + `-NoSanitize` produce a
  capture with the **same SHA256** as the Python build (validated on the E1090 capture,
  10,192,582 bytes). This is the byte contract that keeps the two builds in lockstep.
- **Sanitize: proven by properties, not bytes.** The sanitized output is NOT byte-identical
  across builds because .NET `System.Random` and Python's Mersenne Twister differ. Parity is
  instead validated by the invariants both must hold: length/format-preserving pseudonyms,
  injective maps, referential integrity (a serial/WWN/name maps consistently everywhere), and
  a clean audit (0 survivors), with the audit catching injected leaks.
- The PS 5.1 gotchas handled for parity: ordered hashtables to preserve key order; the
  `, @(...)` return idiom so empty / single-element arrays are not collapsed to `$null` or
  unwrapped to a scalar.

Keep this build in sync with the Python reference; that reference and
`Docs/v0_capture_plan.md` are the spec.
