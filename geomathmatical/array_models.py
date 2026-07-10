"""array_models.py -- model-designator prefix -> family map + identity fallback.

The Phase A identity ladder (plan section 4 / D25). The `source` header needs a
model, and generation-specific field sets are gated on it. Resolve, first hit:

  1. GET components/instance -> exact model + microcode          (confidence "exact")
  2. storageDeviceId[:6] prefix -> model FAMILY via the table     (confidence "family")
  3. operator-supplied prefix_override / model_override            (confidence "override")

Never switch on a bare serial: the model lives in the 6-digit prefix, not the
serial, and a bare serial is reused across families (a VSP G400 and a VSP 5500
can share serial 123456). Record the confidence so downstream (and the D24 schema
generation gating) knows how much to trust the model.

Mirrors as Scripts array_models.psm1 in the PowerShell build.
"""

# Prefix -> family. Block Storage bs_overview p31; Config Manager
# cm_storage_registration p97-98 (plan section 4).
PREFIX_TO_FAMILY = {
    "A00000": "VSP One B85",
    "A34000": "VSP One B24, B26, B28",
    "900000": "VSP 5100/5500/5100H/5500H/5200/5600/5200H/5600H",
    "938000": "VSP E1090, E1090H",
    "936000": "VSP E990",
    "934000": "VSP E590, E790, E590H, E790H",
    "886000": "VSP G370/G700/G900, F370/F700/F900",
    "882000": "VSP G350, F350",
    "880000": "VSP G130",
    "836000": "VSP G800, F800, N800",
    "834000": "VSP G400/G600, F400/F600, N400/N600",
    "832000": "VSP G200",
    "800000": "VSP G1000, G1500, F1500",
}


class Identity(object):
    """Resolved array identity for the capture `source` header (plan 5)."""

    def __init__(self, serial, model, microcode, prefix, confidence):
        self.serial = serial            # bare serial, un-prefixed (D22)
        self.model = model              # exact or family string
        self.microcode = microcode      # None when only a family was resolved
        self.prefix = prefix            # 6-digit model designator
        self.confidence = confidence    # "exact" | "family" | "override"

    def as_source_fields(self):
        return {
            "serial": self.serial,      # sanitizer replaces this (section 7)
            "model": self.model,
            "microcode": self.microcode,
            "modelConfidence": self.confidence,
        }


def family_from_prefix(prefix):
    """Map a 6-digit prefix to a family string, or None if unknown."""
    return PREFIX_TO_FAMILY.get((prefix or "").strip())


def split_storage_device_id(storage_device_id):
    """12-digit storageDeviceId -> (prefix6, serial6). ('', '') if malformed."""
    s = (storage_device_id or "").strip()
    if len(s) != 12 or not s.isdigit():
        return "", ""
    return s[:6], s[6:]


def resolve_identity(components_instance=None, storage_device_id=None,
                     storages_entry=None, prefix_override=None,
                     model_override=None):
    """Run the D25 ladder against whatever Phase A returned. Returns Identity.

    components_instance : parsed GET components/instance (step 1), or None
    storages_entry      : one entry from GET storages (has model/serialNumber)
    storage_device_id   : the 12-digit id, source of the prefix (step 2)
    *_override          : operator last-resort (step 3)
    """
    prefix, serial6 = split_storage_device_id(storage_device_id)

    # Bare serial preferred from storages/, else the padded tail of the id.
    serial = None
    if storages_entry:
        sn = storages_entry.get("serialNumber")
        serial = str(sn) if sn is not None else None
    if serial is None and serial6:
        serial = serial6.lstrip("0") or "0"

    # Step 1: exact model from components/instance (or the storages model line).
    # NOTE: on this E1090 capture the exact model surfaces via GET storages
    # ("VSP E1090"); components/instance carries health, not the model string --
    # so the storages entry is the practical "exact" source. Confirm the field
    # home per array generation before trusting only one. (plan 4, A3)
    exact_model = None
    microcode = None
    if components_instance:
        # microcode/model home varies by generation; wire the real key here once
        # confirmed against more captures. Left None-safe for the skeleton.
        exact_model = components_instance.get("model")
        microcode = components_instance.get("microcode") or components_instance.get("svpMicroVersion")
    if not exact_model and storages_entry:
        exact_model = storages_entry.get("model")

    if exact_model:
        return Identity(serial, exact_model, microcode, prefix, "exact")

    # Step 2: family from the prefix.
    fam = family_from_prefix(prefix)
    if fam:
        return Identity(serial, fam, None, prefix, "family")

    # Step 3: operator override (prefix takes precedence over a bare model).
    if prefix_override:
        return Identity(serial, family_from_prefix(prefix_override) or model_override,
                        None, prefix_override, "override")
    if model_override:
        return Identity(serial, model_override, None, prefix, "override")

    return Identity(serial, None, None, prefix, "family")
