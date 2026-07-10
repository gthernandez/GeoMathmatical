"""capture/identity.py -- Phase A identity read (plan 4 Phase A, D25). STUB seam.

Runs the D25 ladder over the Phase A reads already in the tree (api_version,
components_instance, storages) and returns an array_models.Identity for the
`source` header. The ladder logic lives in ../array_models.py; this is the seam
that feeds it the right tree nodes.
"""

from .. import array_models


def resolve(tree, prefix_override=None, model_override=None):
    """Build Identity from Phase A tree nodes (plan 4 / D25)."""
    storages = tree.get("storages") or []
    storages_entry = storages[0] if isinstance(storages, list) and storages else None
    sdid = storages_entry.get("storageDeviceId") if storages_entry else None
    return array_models.resolve_identity(
        components_instance=tree.get("components_instance"),
        storage_device_id=sdid,
        storages_entry=storages_entry,
        prefix_override=prefix_override,
        model_override=model_override,
    )


def api_version(tree):
    v = tree.get("api_version")
    return v.get("apiVersion") if isinstance(v, dict) else None
