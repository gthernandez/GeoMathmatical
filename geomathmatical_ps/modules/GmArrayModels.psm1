<#
GmArrayModels.psm1 -- prefix->family map + identity ladder (D25).
PowerShell mirror of Scripts/geomathmatical/array_models.py.
#>
Set-StrictMode -Version Latest

$script:PrefixToFamily = [ordered]@{
    'A00000' = 'VSP One B85'
    'A34000' = 'VSP One B24, B26, B28'
    '900000' = 'VSP 5100/5500/5100H/5500H/5200/5600/5200H/5600H'
    '938000' = 'VSP E1090, E1090H'
    '936000' = 'VSP E990'
    '934000' = 'VSP E590, E790, E590H, E790H'
    '886000' = 'VSP G370/G700/G900, F370/F700/F900'
    '882000' = 'VSP G350, F350'
    '880000' = 'VSP G130'
    '836000' = 'VSP G800, F800, N800'
    '834000' = 'VSP G400/G600, F400/F600, N400/N600'
    '832000' = 'VSP G200'
    '800000' = 'VSP G1000, G1500, F1500'
}

function Get-GmProp($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $p = $obj.PSObject.Properties[$name]
        if ($p) { return $p.Value } else { return $null }
    }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) { return $obj[$name] } else { return $null }
    }
    return $null
}

function Get-GmFamilyFromPrefix([string]$prefix) {
    $p = ($prefix + '').Trim()
    if ($script:PrefixToFamily.Contains($p)) { return $script:PrefixToFamily[$p] }
    return $null
}

function Split-GmStorageDeviceId([string]$sdid) {
    $s = ($sdid + '').Trim()
    if ($s.Length -ne 12 -or ($s -notmatch '^\d{12}$')) { return @('', '') }
    return @($s.Substring(0, 6), $s.Substring(6))
}

# Returns an ordered hashtable identity: serial, model, microcode, prefix, confidence.
function Resolve-GmIdentity {
    param($ComponentsInstance, [string]$StorageDeviceId, $StoragesEntry,
          [string]$PrefixOverride, [string]$ModelOverride)

    $split = Split-GmStorageDeviceId $StorageDeviceId
    $prefix = $split[0]; $serial6 = $split[1]

    $serial = $null
    if ($StoragesEntry) {
        $sn = Get-GmProp $StoragesEntry 'serialNumber'
        if ($null -ne $sn) { $serial = [string]$sn }
    }
    if ($null -eq $serial -and $serial6) {
        $t = $serial6.TrimStart('0'); if ($t -eq '') { $t = '0' }; $serial = $t
    }

    $exactModel = $null; $microcode = $null
    if ($ComponentsInstance) {
        $exactModel = Get-GmProp $ComponentsInstance 'model'
        $microcode = Get-GmProp $ComponentsInstance 'microcode'
        if ($null -eq $microcode) { $microcode = Get-GmProp $ComponentsInstance 'svpMicroVersion' }
    }
    if (-not $exactModel -and $StoragesEntry) { $exactModel = Get-GmProp $StoragesEntry 'model' }

    if ($exactModel) { return (New-GmIdentity $serial $exactModel $microcode $prefix 'exact') }

    $fam = Get-GmFamilyFromPrefix $prefix
    if ($fam) { return (New-GmIdentity $serial $fam $null $prefix 'family') }

    if ($PrefixOverride) {
        $m = Get-GmFamilyFromPrefix $PrefixOverride; if (-not $m) { $m = $ModelOverride }
        return (New-GmIdentity $serial $m $null $PrefixOverride 'override')
    }
    if ($ModelOverride) { return (New-GmIdentity $serial $ModelOverride $null $prefix 'override') }
    return (New-GmIdentity $serial $null $null $prefix 'family')
}

function New-GmIdentity($serial, $model, $microcode, $prefix, $confidence) {
    return [ordered]@{ serial = $serial; model = $model; microcode = $microcode
                       prefix = $prefix; confidence = $confidence }
}

# source header fields, in the Python emit order: serial, model, microcode, modelConfidence.
function New-GmSourceFields($identity) {
    return [ordered]@{
        serial          = $identity.serial
        model           = $identity.model
        microcode       = $identity.microcode
        modelConfidence = $identity.confidence
    }
}

Export-ModuleMember -Function Get-GmProp, Get-GmFamilyFromPrefix, Split-GmStorageDeviceId,
    Resolve-GmIdentity, New-GmIdentity, New-GmSourceFields
