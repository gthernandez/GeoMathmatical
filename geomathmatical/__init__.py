"""GeoMathmatical v0 -- REST array-geometry capture tool (producer side).

Reads a live Hitachi VSP array over its Block Storage REST API, walks every
geometry-bearing object, normalizes + sanitizes on-site, and emits a single
self-describing JSON capture (schema_version "0", interim). GRAB ONLY (D19):
no ingest into diorama.

Spec / build plan: Docs/v0_capture_plan.md. Rulings: pm/DECISIONS.md D18-D35.
This is the Python reference build (D26); a Windows PowerShell 5.1 build mirrors
it module-for-module once behavior is pinned by the replay fixtures.
"""

__version__ = "0"          # emitted as source.tool / schema_version "0" (plan 5)
TOOL_NAME = "GeoMathmatical v0"
