"""endpoints.py -- the ordered capture map (plan section 4) as data.

One registry drives both the live walk and the --replay fixture walk, and its
`label` doubles as the replay filename stem (matching the labels the lab
collector wrote: Reference/Captures/capture_*/<label>.json). Keep this in sync
with Docs/v0_capture_plan.md section 4 and Scripts/collect_lab_json.ps1.

Kinds:
  "simple"     GET the path once.
  "paginated"  page by headLdevId until a short/empty page (plan 4.1). Replay
               serves <label>_page000.json, _page001.json, ... in order.
  "per_hg"     fan out per host-group, keyed on (portId, hostGroupNumber). Replay
               file is <label>__<portId>_<hgNumber>.json.
  "discovery"  list a parent collection, then GET a CHILD per parent, using the
               required id/name/param the child endpoint demands (so no bare GET
               that 400s). Driven by the `discovery` spec (see Phase C). Replay
               child file is <child_label>__<key>.json -- the exact names the lab
               collector wrote, so a collector capture replays 1:1 (D35).
  "replication_pairs"  the flat remote-copypairs read, iterated over
               replicationType (TC|UR|GAD), each paginated by pvolLdevId at
               `page_size`. Replay file is remote_copypairs_<TYPE>_page000.json.
"""

# Endpoints whose bare GET the E1090 sim rejected (need a required param / object
# id / precondition). Recorded so the walk logs them as "expected skip", not loss
# (no-silent-truncation, D20). See _capture_log.txt in the reference capture.
KNOWN_CONDITIONAL = {
    "nvm_subsystems", "host_nqns", "namespaces", "namespace_paths",
    "external_storage_ports", "external_storage_luns",
    "local_clone_copypairs", "snapshots", "remote_copypairs",
    "remote_replications", "journals", "remote_replica_options",
    "channel_boards",
}


def _ep(label, path, kind="simple", phase="B", page_ref="", note="", params=None, **extra):
    ep = {
        "label": label, "path": path, "kind": kind, "phase": phase,
        "page_ref": page_ref, "note": note, "params": params or {},
    }
    ep.update(extra)   # discovery spec, replication_types, page_key, page_size, ...
    return ep


# --- Phase A: connect + identify (plan 4 Phase A) ---------------------------
PHASE_A = [
    _ep("api_version", "/configuration/version", phase="A", page_ref="BS p68",
        note="source.restApiVersion"),
    _ep("components_instance", "/v1/objects/components/instance", phase="A",
        page_ref="BS p1519", note="model + microcode for source header"),
    _ep("storages", "/v1/objects/storages", phase="A",
        note="storageDeviceId + exact model + bare serial (D25 step 1/2)"),
    _ep("channel_boards", "/v1/objects/channel-boards", phase="A",
        page_ref="BS p1561", note="VSP 5000 only; 404 elsewhere"),
]

# --- Phase B: provisioning geometry (plan 4 Phase B, B1-B15) ----------------
PHASE_B = [
    _ep("parity_groups", "/v1/objects/parity-groups", page_ref="BS p466",
        note="RAID geometry -- kept real (D20)"),
    _ep("drives", "/v1/objects/drives", page_ref="BS p478"),
    _ep("pools", "/v1/objects/pools", page_ref="BS p736", note="DP + TI pools"),
    _ep("mps", "/v1/objects/mps", page_ref="BS p671"),
    _ep("ports", "/v1/objects/ports", page_ref="BS p578", note="transport identity; wwn -> sanitizer"),
    _ep("resource_groups", "/v1/objects/resource-groups", page_ref="BS p83"),
    _ep("virtual_storages", "/v1/objects/virtual-storages", page_ref="BS p1566",
        note="VSM; underpins GAD virtual-LDEV mapping"),
    # NVMe-oF (B12) -- out-of-model, flag in outOfModel (D20).
    _ep("nvm_subsystems", "/v1/objects/nvm-subsystems", page_ref="BS p695"),
    _ep("host_nqns", "/v1/objects/host-nqns", page_ref="BS p695"),
    _ep("namespaces", "/v1/objects/namespaces", page_ref="BS p695"),
    _ep("namespace_paths", "/v1/objects/namespace-paths", page_ref="BS p695"),
    # External / UVM (B13) -- out-of-model (diorama Phase 4), flag in outOfModel.
    _ep("external_storage_ports", "/v1/objects/external-storage-ports", page_ref="BS p1302"),
    _ep("external_storage_luns", "/v1/objects/external-storage-luns", page_ref="BS p1302"),
    _ep("external_parity_groups", "/v1/objects/external-parity-groups", page_ref="BS p1302"),
    # LDEVs (B4) -- the one non-trivial read (plan 4.1).
    _ep("ldevs", "/v1/objects/ldevs", kind="paginated", page_ref="BS p507",
        note="master inventory; page by headLdevId (plan 4.1)"),
    # Host groups (B7) + per-HG fan-out (B8-B11).
    _ep("host_groups", "/v1/objects/host-groups", page_ref="BS p605",
        note="FULL host-group names here (not the <=16 truncated copy, RC5)"),
    _ep("host_wwns", "/v1/objects/host-wwns", kind="per_hg", page_ref="BS p627",
        note="sanitizer WWN source"),
    _ep("luns", "/v1/objects/luns", kind="per_hg", page_ref="BS p654",
        note="LDEV-to-LUN-to-HG access map"),
    _ep("host_iscsis", "/v1/objects/host-iscsis", kind="per_hg", page_ref="BS p636",
        note="out-of-model (diorama Phase 2b); flag"),
    _ep("chap_users", "/v1/objects/chap-users", kind="per_hg", page_ref="BS p645",
        note="names sanitized"),
]

# --- Phase C: replication geometry (plan 4 Phase C, C1-C7; D23/D35) ----------
# The pair/snapshot reads reject a bare GET -- they need an object id / name /
# replicationType. So Phase C is a DISCOVERY walk (enumerate parents, then fetch
# children with the required key), not flat GETs (D35). Ported from the reference
# walk in Scripts/collect_lab_json.ps1; the child labels match that collector's
# output filenames so a collector capture replays 1:1.
PHASE_C = [
    # C1 ShadowImage: copygroups -> per group, local-clone-copypairs?localCloneCopyGroupId=<id>.
    _ep("local_clone_copygroups", "/v1/objects/local-clone-copygroups",
        kind="discovery", phase="C", page_ref="BS p862", note="ShadowImage: groups -> copypairs",
        discovery={
            "parent_key": "localCloneCopygroupId",
            "results_key": "local_clone_copypairs",
            "child_label": "local_clone_copypairs",
            "mode": "query",
            "child_path": "/v1/objects/local-clone-copypairs",
            "child_param": "localCloneCopyGroupId",
        }),
    # C2 Thin Image: snapshot-groups -> per group, snapshot-groups/<name>; names with
    # / \ or a lone '.' can't sit in the path -> fall back to snapshots?snapshotGroupName=.
    _ep("snapshot_groups", "/v1/objects/snapshot-groups", kind="discovery",
        phase="C", page_ref="BS p954", note="Thin Image: groups -> per-group detail",
        discovery={
            "parent_key": "snapshotGroupName",
            "results_key": "snapshot_group_detail",
            "child_label": "snapshot_group",
            "mode": "path",
            "child_path": "/v1/objects/snapshot-groups",
            "fallback": {
                "when": "special_chars",
                "child_label": "snapshots",
                "child_path": "/v1/objects/snapshots",
                "child_param": "snapshotGroupName",
            },
        }),
    # C3 TC/UR/GAD: remote-mirror-copygroups (local-only, no Remote-Authorization) ->
    # per-group detail remote-mirror-copygroups/<id>. Full remote-side detail would
    # need a Remote-Authorization session on the partner (out of v0, D35).
    _ep("remote_mirror_copygroups", "/v1/objects/remote-mirror-copygroups",
        kind="discovery", phase="C", page_ref="BS p1092", note="TC/UR/GAD: copygroups -> detail",
        discovery={
            "parent_key": "remoteMirrorCopyGroupId",
            "results_key": "remote_mirror_copygroup_detail",
            "child_label": "remote_mirror_copygroup",
            "mode": "path",
            "child_path": "/v1/objects/remote-mirror-copygroups",
        }),
    # C3 (flat): remote-copypairs?replicationType=<TC|UR|GAD>, paginated by pvolLdevId
    # (500/page). remote-replications?replicationType=<..> is a VSP 5000-only flat view
    # (412 elsewhere) fetched best-effort alongside.
    _ep("remote_copypairs", "/v1/objects/remote-copypairs", kind="replication_pairs",
        phase="C", page_ref="BS p1122", note="TC/UR/GAD pair topology (MCU/RCU pairs)",
        replication_types=["TC", "UR", "GAD"], page_key="pvolLdevId", page_size=500),
    # RCU topology + UR journals -- simple reads (no discovery needed).
    _ep("quorum_disks", "/v1/objects/quorum-disks", phase="C", page_ref="BS p1074",
        note="GAD quorum; remoteSerialNumber -> sanitizer"),
    _ep("remote_storages", "/v1/objects/remote-storages", phase="C", page_ref="BS p1002",
        note="RCU topology; remote serials + IPs -> sanitizer"),
    _ep("remotepath_groups", "/v1/objects/remotepath-groups", phase="C",
        page_ref="BS p1002", note="remote path groups"),
    _ep("remote_iscsi_ports", "/v1/objects/remote-iscsi-ports", phase="C", page_ref="BS p1002"),
    # journals: journalInfo is REQUIRED (basic|timer|detail); bare GET = 400.
    _ep("journals", "/v1/objects/journals", phase="C", page_ref="BS p1052",
        params={"journalInfo": "basic"}, note="UR journal state"),
    _ep("remote_replica_options", "/v1/objects/remote-replica-options", phase="C",
        page_ref="BS p1002", note="VSP 5000-flavored; 404 elsewhere"),
]

ALL_PHASES = {"A": PHASE_A, "B": PHASE_B, "C": PHASE_C}


def selected(phases="all"):
    """Yield endpoint dicts for the requested phases in walk order.

    phases: "all" | any subset string of {a,b,c} e.g. "ab".
    """
    phases = (phases or "all").lower()
    order = ["A", "B", "C"] if phases == "all" else [p.upper() for p in phases if p in "abc"]
    for ph in order:
        for ep in ALL_PHASES.get(ph, []):
            yield ep
