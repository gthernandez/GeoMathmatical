"""emit.py -- assemble the interim geometry object (plan section 5).

Milestone 7. Maps the (normalized, sanitized) tree into the single self-describing
capture object: schema_version "0", source header, sanitization block, provisioning
+ replication sections, and the outOfModel no-silent-truncation ledger (D20).

Explicitly INTERIM (D24): sections mirror REST object families now; the D24 schema
later remaps them field-by-field onto diorama tables. Written via json_writer
(never json.dumps) so the PS mirror can match it byte-for-byte (D27).
"""

from . import __version__, TOOL_NAME


def _n(x):
    """Count rows in a tree node (list, per-hg dict-of-lists, or scalar)."""
    if isinstance(x, list):
        return len(x)
    if isinstance(x, dict):
        return sum(_n(v) for v in x.values())
    return 0 if x is None else 1


def _out_of_model(tree):
    """Families captured but outside diorama's modeled scope (D20). Never dropped."""
    ledger = []
    ext = _n(tree.get("external_parity_groups")) + _n(tree.get("external_storage_luns"))
    if ext:
        ledger.append({"family": "external", "count": ext,
                       "reason": "UVM / diorama Phase 4", "captured": True})
    iscsi = _n(tree.get("host_iscsis"))
    if iscsi:
        ledger.append({"family": "iscsi", "count": iscsi,
                       "reason": "diorama Phase 2b", "captured": True})
    nvme = _n(tree.get("nvm_subsystems")) + _n(tree.get("namespaces"))
    if nvme:
        ledger.append({"family": "nvme", "count": nvme,
                       "reason": "NVMe-oF not yet modeled", "captured": True})
    return ledger


def assemble(tree, identity, api_version, captured_at_utc,
             sanitize_applied=True, audit_result=None):
    """Build the interim capture dict (plan 5). captured_at_utc supplied by caller."""
    source = dict(identity.as_source_fields()) if identity else {}
    source.update({"restApiVersion": api_version, "capturedAtUtc": captured_at_utc,
                   "tool": TOOL_NAME})

    sanitization = {
        "applied": sanitize_applied,
        "mode": "sanitized" if sanitize_applied else "real-values",
        "mapping_kept_onsite": sanitize_applied,
    }
    if sanitize_applied and audit_result is not None:
        sanitization["audit"] = {"patternsScanned": audit_result.patterns_scanned,
                                 "survivors": audit_result.survivors}

    return {
        "schema_version": __version__,
        "source": source,
        "sanitization": sanitization,
        "provisioning": {
            "parityGroups": tree.get("parity_groups"),
            "drives": tree.get("drives"),
            "pools": tree.get("pools"),
            "mps": tree.get("mps"),
            "ldevs": tree.get("ldevs"),
            "ports": tree.get("ports"),
            "hostGroups": tree.get("host_groups"),
            "hostWwns": tree.get("host_wwns"),
            "luns": tree.get("luns"),
            "hostIscsis": tree.get("host_iscsis"),
            "chapUsers": tree.get("chap_users"),
            "resourceGroups": tree.get("resource_groups"),
            "virtualStorages": tree.get("virtual_storages"),
        },
        "replication": {
            "shadowImage": {
                "copyGroups": tree.get("local_clone_copygroups"),
                "copyPairs": tree.get("local_clone_copypairs"),      # {groupId: [pairs]}
            },
            "thinImage": {
                "snapshotGroups": tree.get("snapshot_groups"),
                "snapshotGroupDetail": tree.get("snapshot_group_detail"),  # {name: detail}
            },
            "remoteCopy": {  # TC / UR / GAD (MCU/RCU pairs)
                "copyGroups": tree.get("remote_mirror_copygroups"),
                "copyGroupDetail": tree.get("remote_mirror_copygroup_detail"),  # {id: detail}
                "copyPairs": tree.get("remote_copypairs"),           # {TC|UR|GAD: [pairs]}
                "replications": tree.get("remote_replications"),     # {TC|UR|GAD: ...}
            },
            "journals": tree.get("journals"),
            "quorum": tree.get("quorum_disks"),
            "remoteConnections": {
                "remoteStorages": tree.get("remote_storages"),
                "remotepathGroups": tree.get("remotepath_groups"),
                "remoteIscsiPorts": tree.get("remote_iscsi_ports"),
            },
        },
        "outOfModel": _out_of_model(tree),
    }
