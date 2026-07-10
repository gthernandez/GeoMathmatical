<#
GmEndpoints.psm1 -- the ordered capture map (plan section 4).
PowerShell mirror of Scripts/geomathmatical/endpoints.py. Keep in sync with it.
#>
Set-StrictMode -Version Latest

$script:KnownConditional = @(
    'nvm_subsystems','host_nqns','namespaces','namespace_paths',
    'external_storage_ports','external_storage_luns',
    'local_clone_copypairs','snapshots','remote_copypairs',
    'remote_replications','journals','remote_replica_options','channel_boards'
)

function Test-GmKnownConditional([string]$label) { return ($script:KnownConditional -contains $label) }

function _ep {
    param([string]$label, [string]$path, [string]$kind = 'simple', [string]$phase = 'B',
          $params = $null, $discovery = $null, $replicationTypes = $null,
          $pageKey = $null, $pageSize = $null)
    $e = [ordered]@{ label = $label; path = $path; kind = $kind; phase = $phase
                     params = $(if ($params) { $params } else { [ordered]@{} }) }
    if ($discovery) { $e.discovery = $discovery }
    if ($replicationTypes) { $e.replication_types = $replicationTypes }
    if ($pageKey) { $e.page_key = $pageKey }
    if ($pageSize) { $e.page_size = $pageSize }
    return $e
}

function Get-GmEndpoints([string]$phases = 'all') {
    $A = @(
        (_ep 'api_version' '/configuration/version' 'simple' 'A')
        (_ep 'components_instance' '/v1/objects/components/instance' 'simple' 'A')
        (_ep 'storages' '/v1/objects/storages' 'simple' 'A')
        (_ep 'channel_boards' '/v1/objects/channel-boards' 'simple' 'A')
    )
    $B = @(
        (_ep 'parity_groups' '/v1/objects/parity-groups')
        (_ep 'drives' '/v1/objects/drives')
        (_ep 'pools' '/v1/objects/pools')
        (_ep 'mps' '/v1/objects/mps')
        (_ep 'ports' '/v1/objects/ports')
        (_ep 'resource_groups' '/v1/objects/resource-groups')
        (_ep 'virtual_storages' '/v1/objects/virtual-storages')
        (_ep 'nvm_subsystems' '/v1/objects/nvm-subsystems')
        (_ep 'host_nqns' '/v1/objects/host-nqns')
        (_ep 'namespaces' '/v1/objects/namespaces')
        (_ep 'namespace_paths' '/v1/objects/namespace-paths')
        (_ep 'external_storage_ports' '/v1/objects/external-storage-ports')
        (_ep 'external_storage_luns' '/v1/objects/external-storage-luns')
        (_ep 'external_parity_groups' '/v1/objects/external-parity-groups')
        (_ep 'ldevs' '/v1/objects/ldevs' 'paginated')
        (_ep 'host_groups' '/v1/objects/host-groups')
        (_ep 'host_wwns' '/v1/objects/host-wwns' 'per_hg')
        (_ep 'luns' '/v1/objects/luns' 'per_hg')
        (_ep 'host_iscsis' '/v1/objects/host-iscsis' 'per_hg')
        (_ep 'chap_users' '/v1/objects/chap-users' 'per_hg')
    )
    $C = @(
        (_ep 'local_clone_copygroups' '/v1/objects/local-clone-copygroups' 'discovery' 'C' $null ([ordered]@{
            parent_key = 'localCloneCopygroupId'; results_key = 'local_clone_copypairs'
            child_label = 'local_clone_copypairs'; mode = 'query'
            child_path = '/v1/objects/local-clone-copypairs'; child_param = 'localCloneCopyGroupId' }))
        (_ep 'snapshot_groups' '/v1/objects/snapshot-groups' 'discovery' 'C' $null ([ordered]@{
            parent_key = 'snapshotGroupName'; results_key = 'snapshot_group_detail'
            child_label = 'snapshot_group'; mode = 'path'; child_path = '/v1/objects/snapshot-groups'
            fallback = [ordered]@{ when = 'special_chars'; child_label = 'snapshots'
                                   child_path = '/v1/objects/snapshots'; child_param = 'snapshotGroupName' } }))
        (_ep 'remote_mirror_copygroups' '/v1/objects/remote-mirror-copygroups' 'discovery' 'C' $null ([ordered]@{
            parent_key = 'remoteMirrorCopyGroupId'; results_key = 'remote_mirror_copygroup_detail'
            child_label = 'remote_mirror_copygroup'; mode = 'path'
            child_path = '/v1/objects/remote-mirror-copygroups' }))
        (_ep 'remote_copypairs' '/v1/objects/remote-copypairs' 'replication_pairs' 'C' $null $null @('TC','UR','GAD') 'pvolLdevId' 500)
        (_ep 'quorum_disks' '/v1/objects/quorum-disks' 'simple' 'C')
        (_ep 'remote_storages' '/v1/objects/remote-storages' 'simple' 'C')
        (_ep 'remotepath_groups' '/v1/objects/remotepath-groups' 'simple' 'C')
        (_ep 'remote_iscsi_ports' '/v1/objects/remote-iscsi-ports' 'simple' 'C')
        (_ep 'journals' '/v1/objects/journals' 'simple' 'C' ([ordered]@{ journalInfo = 'basic' }))
        (_ep 'remote_replica_options' '/v1/objects/remote-replica-options' 'simple' 'C')
    )
    $ph = ($phases + '').ToLower()
    if ($ph -eq 'all') { $order = @('A','B','C') } else {
        $order = @(); foreach ($c in $ph.ToCharArray()) { if ('abc'.Contains($c)) { $order += $c.ToString().ToUpper() } }
    }
    $out = @()
    foreach ($p in $order) { if ($p -eq 'A') { $out += $A } elseif ($p -eq 'B') { $out += $B } else { $out += $C } }
    return $out
}

Export-ModuleMember -Function Get-GmEndpoints, Test-GmKnownConditional
