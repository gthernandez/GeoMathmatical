#!/usr/bin/env python3
"""geomathmatical.py -- the obvious way to run this tool.

If you just opened this folder and want to RUN it, run THIS file:

    python geomathmatical.py --replay <capture-dir> --out capture.json
    python geomathmatical.py            (first run writes a config template + a help table)

It is a thin wrapper: identical to `python -m geomathmatical ...` (which also works).
Every flag is the same -- pass `--help` to see them. All the real code lives in the
sibling modules (main.py, rest_client.py, sanitize.py, ...); this file just launches it.

Why a wrapper exists: `python -m geomathmatical` is the Pythonic entry point but is not
obvious to someone new to the folder, so this gives the package one clearly-named script
to call -- the same idea as geomathmatical.ps1 in the PowerShell build.
"""
import os
import sys

# Make the package importable no matter where this is invoked from: put the package's
# PARENT dir (…/Scripts) on sys.path so `geomathmatical` resolves as a package, then its
# relative imports (from . import config, ...) work exactly as under `python -m`.
_PARENT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT not in sys.path:
    sys.path.insert(0, _PARENT)

from geomathmatical.main import run  # noqa: E402  (import after the sys.path fix, by design)

if __name__ == "__main__":
    sys.exit(run())
