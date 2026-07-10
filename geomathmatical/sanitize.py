"""sanitize.py -- referential-integrity-preserving pseudonymizer (plan 7, D20/D29/D31).

Milestone 6, the standout feature. Replaces sensitive identifiers with length- AND
format-preserving pseudonyms (D29) drawn from per-type memoized dictionaries kept
ON-SITE only. Because each dictionary keys on the REAL value, every occurrence of a
value maps to the SAME pseudonym -- a serial is identical across its owning LDEV,
both sides of every pair, and every RCU relation; a WWN is identical across its port
and every LU path; a host-group name is identical everywhere -- so the geometry
stays coherent (D20). Blind find/replace would desync these; the memoized map is
what makes it referential-integrity-preserving.

Format preservation (D29), so the fake stays structurally valid for diorama/raidcom:
  - WWN            16 hex -> 16 random hex (case preserved)
  - Array serial   keep the 6-digit model-designator PREFIX real; randomize only the
                   6-digit serial, keyed on the serial so the bare `serialNumber` and
                   the tail of every 12-digit `storageDeviceId` stay coherent (D31)
  - IP             valid IPv4 -> valid IPv4, per octet
  - Freeform name  host-group / nickname / label / journal / copy-group / iSCSI /
                   CHAP -> same length, per-char character class preserved
The map is INJECTIVE (collision-checked on generation) so two reals never collapse.

KEEP REAL (what makes it a useful bench, D20): capacities, RAID geometry, counts,
pool layouts, pair topology, emulation types, LDEV attributes, model/type designators,
and DRIVE / HARDWARE serials (D31 capture-faithfully; they are not network/site/customer
identifiers, are referenced nowhere else, and -- on real arrays -- do not embed the
array serial). Only array/remote serials (always numeric) are scrubbed; a non-numeric
drive serial is left verbatim. NOTE: a lab simulator's fake drive serials may embed
the array serial (e.g. "DUMMY<serial>000000"), so a *lab* capture can show the array
serial inside drives[].serialNumber -- a fixture artifact, not a real-array leak.

Determinism: pass `seed=<int>` for a reproducible mapping (regression baselines,
plan 13); omit it for an unpredictable, OS-entropy-seeded mapping in the field.
NOTE: the mapping table itself is the secret kept on-site, so field pseudonyms need
not be reproducible run-to-run -- each run writes its own mapping.<serial>.json.

This module MUTATES the tree in place (the raw tree is not persisted, D27) and
returns (tree, Mapping). --no-sanitize (D30) skips this module entirely.
"""

import ipaddress
import random
import string

_HEX = "0123456789abcdef"

# "No value" sentinels REST uses in place of a real identifier -- an absent drive
# serial, an unset field, etc. These are NOT identifiers, so they are left verbatim
# (pseudonymizing "N/A" would invent a fake serial and lose the "none present"
# signal). Matched case-insensitively after strip(). Real arrays vary the spelling,
# hence more than just "-"/"" (the lab's only forms). Tune here if a capture shows
# another marker.
_SENTINELS = {"", "-", "n/a", "none", "unknown", "not available", "notavailable",
              "not installed", "notinstalled", "not supported", "notsupported"}

# Per-type dictionaries (plan 7).
_TABLES = ("serials", "wwns", "hostGroupNames", "ips", "nicknames",
           "journalNames", "copyGroupNames", "iscsiNames", "chapUsers")


def _is_sanitizable(v):
    """False for None and 'no value' sentinels -- those pass through untouched."""
    if v is None:
        return False
    if isinstance(v, str) and v.strip().lower() in _SENTINELS:
        return False
    return True


class Mapping(object):
    """On-site-only real->pseudonym dictionaries (plan 7). Never exported.

    Written to mapping.<serial>.json the customer retains; the emitted capture
    carries pseudonyms only. Injective per table (collision-checked).
    """

    def __init__(self, rng=None):
        self.rng = rng or random.Random()
        self.tables = {t: {} for t in _TABLES}
        self._used = {t: set() for t in _TABLES}   # reverse set -> injectivity

    # -- generic memoize-with-collision-check ------------------------------
    def _memo(self, table, real, gen):
        d = self.tables[table]
        if real in d:
            return d[real]
        used = self._used[table]
        for _ in range(1000):
            cand = gen()
            if cand not in used:
                d[real] = cand
                used.add(cand)
                return cand
        raise RuntimeError("pseudonym space exhausted for table '{0}'".format(table))

    # -- WWN: 16-hex -> 16 random hex (length preserved) --------------------
    def wwn(self, value):
        if not isinstance(value, str) or not _is_sanitizable(value):
            return value
        real = value.strip().lower()
        n = len(real)
        return self._memo("wwns", real, lambda: "".join(self.rng.choice(_HEX) for _ in range(n)))

    # -- Array serial: prefix kept real, 6-digit serial randomized (D31) ----
    def _serial6(self, real6):
        """Map a 6-digit serial string -> 6-digit pseudonym, leading zeros kept."""
        return self._memo("serials", real6, lambda: self._gen_serial6(real6))

    def _gen_serial6(self, real6):
        lead = len(real6) - len(real6.lstrip("0"))
        body = 6 - lead
        if body <= 0:
            return real6  # all-zero degenerate serial; leave it
        first = self.rng.choice("123456789")   # keep exactly `lead` leading zeros
        rest = "".join(self.rng.choice(string.digits) for _ in range(body - 1))
        return "0" * lead + first + rest

    def serial_bare(self, value):
        """Bare serialNumber (int or all-digit string) -> pseudonym, same form."""
        if value is None:
            return value
        s = str(value)
        if not s.isdigit():
            return value
        pseud6 = self._serial6(s.zfill(6))
        if isinstance(value, int):
            return int(pseud6)
        return pseud6[-len(s):] if len(s) <= 6 else pseud6

    def serial_sdid(self, value):
        """12-digit storageDeviceId -> prefix (real) + pseudonym serial (D31)."""
        s = str(value)
        if len(s) != 12 or not s.isdigit():
            return self.serial_bare(value)
        return s[:6] + self._serial6(s[6:])

    # -- IP: valid IPv4 -> valid IPv4 per octet -----------------------------
    def ip(self, value):
        if not isinstance(value, str) or not _is_sanitizable(value):
            return value
        try:
            addr = ipaddress.ip_address(value.strip())
        except ValueError:
            return value
        if addr.version != 4:
            return value  # TODO: IPv6 (none in current captures)
        return self._memo("ips", value,
                          lambda: ".".join(str(self.rng.randint(1, 254)) for _ in range(4)))

    # -- Freeform names: length + per-char class preserved ------------------
    def freeform(self, table, value):
        if not isinstance(value, str) or not _is_sanitizable(value):
            return value
        return self._memo(table, value, lambda: self._gen_freeform(value))

    def _gen_freeform(self, s):
        out = []
        for ch in s:
            if ch.isdigit():
                out.append(self.rng.choice(string.digits))
            elif ch.islower():
                out.append(self.rng.choice(string.ascii_lowercase))
            elif ch.isupper():
                out.append(self.rng.choice(string.ascii_uppercase))
            else:
                out.append(ch)  # keep structural chars ('-', '_', '.', etc.)
        return "".join(out)

    # -- serialization for mapping.<serial>.json ----------------------------
    def to_dict(self):
        return {
            "_note": "ON-SITE ONLY -- the real->pseudonym key. Never leaves the site "
                     "(plan 7 / D20). The emitted capture carries pseudonyms only.",
            "tables": self.tables,
        }


# ---------------------------------------------------------------------------
# Field classification (grounded in the E1090 capture field names).
# ---------------------------------------------------------------------------
# Explicit field map, keyed by field name, applied wherever the name appears at any
# depth. Serials / WWNs / device-IDs are ALSO matched by suffix in _classify() so a
# field this list forgets (e.g. quorumStorageSerialNumber, or a replication field not
# in the E1090 capture) is still caught. NAME fields, by contrast, are EXPLICIT-ONLY:
# name suffixes are too ambiguous to sweep (driveTypeName, productName are not
# sensitive), so only the names listed here are pseudonymized.
#   (kind, table)  -- table used only by the "freeform" kind.
_SIMPLE = {
    # IPs (name-agnostic; enumerated).
    "ctl1Ip": ("ip", None),
    "ctl2Ip": ("ip", None),
    "restServerIp": ("ip", None),
    "ipAddress": ("ip", None),
    # Freeform NAME fields -- explicit allowlist (keep driveTypeName/productName real).
    "hostGroupName": ("freeform", "hostGroupNames"),
    "wwnNickname": ("freeform", "nicknames"),
    "label": ("freeform", "nicknames"),
    "poolName": ("freeform", "nicknames"),
    "resourceGroupName": ("freeform", "nicknames"),
    "snapshotGroupName": ("freeform", "copyGroupNames"),
    "snapshotGroupId": ("freeform", "copyGroupNames"),   # id == name here
    "copyGroupName": ("freeform", "copyGroupNames"),      # SI / TC / UR / GAD pair groups
    "pvolDeviceGroupName": ("freeform", "copyGroupNames"),  # SI/TC/UR device groups (name family)
    "svolDeviceGroupName": ("freeform", "copyGroupNames"),
    "copyPairName": ("freeform", "copyGroupNames"),         # SI/TC/UR/GAD pair name
    # localCloneCopygroupId / localCloneCopypairId / remoteMirrorCopyGroupId are COMPOSITE
    # (name[,name...] and serial,name[,name...]) -- handled by _COMPOSITE below, not here.
    # Replication name fields -- best-known names; confirm against a replication
    # capture and adjust (those endpoints were empty on the E1090 sim).
    "journalName": ("freeform", "journalNames"),
    "iscsiName": ("freeform", "iscsiNames"),
    "chapUserName": ("freeform", "chapUsers"),
    # Serials / device-IDs / WWNs below are also covered by suffix rules in
    # _classify(); listed here for clarity and to pin serialNumber's auto-dispatch.
    "serialNumber": ("serial_auto", None),               # numeric -> array serial; else (drive) kept real
}


def _apply(m, kind, table, v):
    if kind == "wwn":
        return m.wwn(v)
    if kind == "serial_sdid":
        return m.serial_sdid(v)
    if kind == "serial_bare":
        return m.serial_bare(v)
    if kind == "serial_auto":
        # Array/remote serials are numeric -> scrub. A non-numeric serialNumber is a
        # drive/hardware serial -> kept real (D31; user decision). This split relies
        # on array serials always being numeric and drive serials being alphanumeric.
        if isinstance(v, int) or (isinstance(v, str) and v.isdigit()):
            return m.serial_bare(v)
        return v
    if kind == "ip":
        return m.ip(v)
    if kind == "freeform":
        return m.freeform(table, v)
    return v


# Composite IDs: rebuilt from sanitized parts so they stay consistent with the
# standalone fields (e.g. hostWwnId's WWN == the hostWwn field's pseudonym).
def _rebuild_host_wwn_id(value, m):
    # "CL1-A,0,13570bb24e000000" -> port,hgNumber,hostWwn
    parts = value.split(",")
    if len(parts) == 3:
        parts[2] = m.wwn(parts[2])
    return ",".join(parts)


def _rebuild_remotepath_group_id(value, m):
    # "447788,M8,0" -> remoteSerial,storageType,pathGroup
    parts = value.split(",")
    if parts and parts[0].isdigit():
        parts[0] = str(m.serial_bare(parts[0]))
    return ",".join(parts)


def _rebuild_local_clone_copygroup_id(value, m):
    # localCloneCopygroupId "copyGroupName,pvolDeviceGroupName,svolDeviceGroupName" (BS p867)
    # AND localCloneCopypairId "...,copyPairName" (4 parts) -- all names. Each part maps
    # through the SAME copyGroupNames table as its standalone field, so the composites stay
    # consistent with copyGroupName / [pvol|svol]DeviceGroupName / copyPairName.
    return ",".join(m.freeform("copyGroupNames", p) for p in value.split(","))


def _rebuild_remote_mirror_copygroup_id(value, m):
    # "<12-digit remoteStorageDeviceId>,copyGroupName,pvolDGN,svolDGN" (BS p198/291).
    # First part is a partner serial (prefix kept, serial scrubbed, D31); rest names.
    parts = value.split(",")
    out = []
    for i, p in enumerate(parts):
        if i == 0 and p.isdigit():
            out.append(m.serial_sdid(p) if len(p) == 12 else str(m.serial_bare(p)))
        else:
            out.append(m.freeform("copyGroupNames", p))
    return ",".join(out)


_COMPOSITE = {
    "hostWwnId": _rebuild_host_wwn_id,
    "remotepathGroupId": _rebuild_remotepath_group_id,
    "localCloneCopygroupId": _rebuild_local_clone_copygroup_id,
    "localCloneCopypairId": _rebuild_local_clone_copygroup_id,   # 4-part (adds copyPairName); same all-names rebuild
    "remoteMirrorCopyGroupId": _rebuild_remote_mirror_copygroup_id,
    "remoteMirrorCopyPairId": _rebuild_remote_mirror_copygroup_id,  # serial,names,pairName -- unverified (no remote fixture yet)
}


def _classify(key):
    """Return (kind, table) for a field name, or None to leave it real.

    Explicit map wins; then suffix rules catch serial/device-id/WWN fields the
    map forgot (name fields are deliberately NOT suffix-swept -- too ambiguous)."""
    if key in _SIMPLE:
        return _SIMPLE[key]
    kl = key.lower()
    if kl.endswith("serialnumber"):
        return ("serial_auto", None)     # e.g. quorumStorageSerialNumber, pvolSerialNumber
    if kl.endswith("deviceid"):
        return ("serial_sdid", None)     # e.g. remoteStorageDeviceId
    if kl == "wwn" or kl.endswith("wwn"):
        return ("wwn", None)             # e.g. hostWwn, initiatorWwn
    return None


def audit_skip(key, value):
    """True for a field the survivor scan must NOT flag: an intentionally kept-real
    value that can legitimately contain a mapped real identifier (D37 -- a lab drive
    serial embeds the array serial). Deliberately NARROW: only non-numeric serial_auto
    (drive serials) qualify. Unclassified fields are NOT skipped, so the audit still
    backstops classifier gaps (e.g. the quorumStorageSerialNumber leak)."""
    cls = _classify(key)
    if cls and cls[0] == "serial_auto":
        return not (isinstance(value, int) or (isinstance(value, str) and value.isdigit()))
    return False


def _walk(node, m):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in _COMPOSITE and isinstance(v, str):
                node[k] = _COMPOSITE[k](v, m)
                continue
            if not isinstance(v, (dict, list)):
                cls = _classify(k)
                if cls:
                    node[k] = _apply(m, cls[0], cls[1], v)
                    continue
            _walk(v, m)
    elif isinstance(node, list):
        for item in node:
            _walk(item, m)


def sanitize(normalized_tree, mapping=None, seed=None):
    """Pseudonymize the tree IN PLACE (plan 7). Returns (tree, mapping).

    seed: pass an int for a reproducible mapping (baselines); omit for OS-entropy.
    """
    if mapping is None:
        rng = random.Random(seed) if seed is not None else random.Random()
        mapping = Mapping(rng=rng)
    _walk(normalized_tree, mapping)
    return normalized_tree, mapping
