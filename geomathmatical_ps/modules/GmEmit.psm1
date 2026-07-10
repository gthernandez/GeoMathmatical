<#
GmEmit.psm1 -- assemble the interim geometry object (plan section 5).
PowerShell mirror of Scripts/geomathmatical/emit.py. Key order matches the Python
emit EXACTLY so the serialized capture is byte-identical (D26).
#>
Set-StrictMode -Version Latest

function _Gm_EmitN($x) {
    if ($x -is [System.Collections.IDictionary]) {
        $n = 0; foreach ($v in $x.Values) { $n += _Gm_EmitN $v }; return $n
    }
    if ($x -is [string]) { return 0 }
    if ($x -is [System.Collections.IEnumerable]) { return @($x).Count }
    return 0
}

function _Gm_OutOfModel($tree) {
    $ledger = New-Object System.Collections.ArrayList
    $ext = (_Gm_EmitN $tree['external_parity_groups']) + (_Gm_EmitN $tree['external_storage_luns'])
    if ($ext) { [void]$ledger.Add([ordered]@{ family = 'external'; count = $ext; reason = 'UVM / diorama Phase 4'; captured = $true }) }
    $iscsi = _Gm_EmitN $tree['host_iscsis']
    if ($iscsi) { [void]$ledger.Add([ordered]@{ family = 'iscsi'; count = $iscsi; reason = 'diorama Phase 2b'; captured = $true }) }
    $nvme = (_Gm_EmitN $tree['nvm_subsystems']) + (_Gm_EmitN $tree['namespaces'])
    if ($nvme) { [void]$ledger.Add([ordered]@{ family = 'nvme'; count = $nvme; reason = 'NVMe-oF not yet modeled'; captured = $true }) }
    return , @($ledger.ToArray())
}

# $auditResult is $null or a hashtable with .patterns_scanned / .survivors.
function New-GmCapture($tree, $identity, [string]$apiVersion, [string]$capturedAtUtc,
                      [bool]$sanitizeApplied, $auditResult) {
    $source = New-GmSourceFields $identity
    $source['restApiVersion'] = $apiVersion
    $source['capturedAtUtc'] = $capturedAtUtc
    $source['tool'] = 'GeoMathmatical v0'

    $san = [ordered]@{
        applied            = $sanitizeApplied
        mode               = $(if ($sanitizeApplied) { 'sanitized' } else { 'real-values' })
        mapping_kept_onsite = $sanitizeApplied
    }
    if ($sanitizeApplied -and $auditResult) {
        $san['audit'] = [ordered]@{ patternsScanned = $auditResult.patterns_scanned; survivors = $auditResult.survivors }
    }

    return [ordered]@{
        schema_version = '0'
        source         = $source
        sanitization   = $san
        provisioning   = [ordered]@{
            parityGroups    = $tree['parity_groups']
            drives          = $tree['drives']
            pools           = $tree['pools']
            mps             = $tree['mps']
            ldevs           = $tree['ldevs']
            ports           = $tree['ports']
            hostGroups      = $tree['host_groups']
            hostWwns        = $tree['host_wwns']
            luns            = $tree['luns']
            hostIscsis      = $tree['host_iscsis']
            chapUsers       = $tree['chap_users']
            resourceGroups  = $tree['resource_groups']
            virtualStorages = $tree['virtual_storages']
        }
        replication    = [ordered]@{
            shadowImage       = [ordered]@{ copyGroups = $tree['local_clone_copygroups']; copyPairs = $tree['local_clone_copypairs'] }
            thinImage         = [ordered]@{ snapshotGroups = $tree['snapshot_groups']; snapshotGroupDetail = $tree['snapshot_group_detail'] }
            remoteCopy        = [ordered]@{
                copyGroups      = $tree['remote_mirror_copygroups']
                copyGroupDetail = $tree['remote_mirror_copygroup_detail']
                copyPairs       = $tree['remote_copypairs']
                replications    = $tree['remote_replications']
            }
            journals          = $tree['journals']
            quorum            = $tree['quorum_disks']
            remoteConnections = [ordered]@{
                remoteStorages   = $tree['remote_storages']
                remotepathGroups = $tree['remotepath_groups']
                remoteIscsiPorts = $tree['remote_iscsi_ports']
            }
        }
        outOfModel     = _Gm_OutOfModel $tree
    }
}

Export-ModuleMember -Function New-GmCapture
