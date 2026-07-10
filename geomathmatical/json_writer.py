"""json_writer.py -- hand-rolled JSON serializer (plan 2.2, D27).

Deliberately NOT ConvertTo-Json / json.dumps: the PowerShell 5.1 build cannot use
ConvertTo-Json (depth-2 truncation), so both builds share ONE serializer spec to
guarantee byte-identical output (D26). The Python reference pins the exact byte
layout the PS mirror must reproduce; the replay baselines (plan 13) diff against it.

Byte contract (keep the PS mirror in lockstep with any change here):
  - 2-space indent, "key": value, LF newlines, UTF-8 no BOM
  - keys in INSERTION order (do not sort)
  - ASCII-safe: non-ASCII escaped as \\uXXXX
"""

INDENT = "  "


def dumps(obj):
    """Serialize obj to the project's canonical JSON text (see byte contract)."""
    out = []
    _write(obj, 0, out)
    return "".join(out)


def dump(obj, path):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(dumps(obj))
        fh.write("\n")


def _write(obj, depth, out):
    if isinstance(obj, dict):
        _write_dict(obj, depth, out)
    elif isinstance(obj, (list, tuple)):
        _write_list(obj, depth, out)
    elif obj is True:
        out.append("true")
    elif obj is False:
        out.append("false")
    elif obj is None:
        out.append("null")
    elif isinstance(obj, (int, float)):
        out.append(repr(obj) if isinstance(obj, float) else str(obj))
    else:
        _write_str(str(obj), out)


def _write_dict(d, depth, out):
    if not d:
        out.append("{}")
        return
    pad, cpad = INDENT * (depth + 1), INDENT * depth
    out.append("{\n")
    items = list(d.items())
    for i, (k, v) in enumerate(items):
        out.append(pad)
        _write_str(str(k), out)
        out.append(": ")
        _write(v, depth + 1, out)
        out.append(",\n" if i < len(items) - 1 else "\n")
    out.append(cpad + "}")


def _write_list(lst, depth, out):
    if not lst:
        out.append("[]")
        return
    pad, cpad = INDENT * (depth + 1), INDENT * depth
    out.append("[\n")
    for i, v in enumerate(lst):
        out.append(pad)
        _write(v, depth + 1, out)
        out.append(",\n" if i < len(lst) - 1 else "\n")
    out.append(cpad + "]")


def _write_str(s, out):
    out.append('"')
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 0x20 or ord(ch) > 0x7E:
            out.append("\\u{0:04x}".format(ord(ch)))
        else:
            out.append(ch)
    out.append('"')
