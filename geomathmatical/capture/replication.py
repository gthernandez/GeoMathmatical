"""capture/replication.py -- Phase C domain seam (plan 4 Phase C, D23/D35). STUB.

Placeholder for the discovery-driven replication fan-out that the generic walker
does not yet do (milestone 4): per-copygroup local-clone-copypairs, per-snapshot-
group snapshots, and remote-copypairs by replicationType (TC|UR|GAD). The
reference walk for all of these already exists in Scripts/collect_lab_json.ps1
(Phase C, C1-C3); port it here against the tree_walker "discovery" kind.

Pair natural key to preserve for diorama (plan 4 / its D32):
  (p_vol_sn, p_vol_ldev, family, p_vol_mu)
The sanitizer must map p_vol_sn / s_vol_sn through the SAME serial map as the
owning LDEV and both RCU sides so the pair graph stays coherent (plan 7).
"""
