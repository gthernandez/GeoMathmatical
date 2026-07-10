<#
GmSanitize.psm1 -- referential-integrity-preserving pseudonymizer (plan 7, D20/D29/D31/D37).
PowerShell mirror of Scripts/geomathmatical/sanitize.py.

Behavior-compatible with the Python reference: same per-type memoized maps, same
length/format-preserving generators, same field classification (explicit NAME
allowlist + serial/deviceid/wwn suffix rules), same composite-ID handlers, same
drive-serials-kept-real rule (D37). NOT byte-identical to Python's *sanitized*
output -- .NET System.Random and Python's Mersenne Twister differ -- so parity is
proven by PROPERTIES (format-preserving, injective, referential, 0 survivors).
#>
Set-StrictMode -Version Latest

$script:Sentinels = @('','-','n/a','none','unknown','not available','notavailable',
                      'not installed','notinstalled','not supported','notsupported')
$script:Tables = @('serials','wwns','hostGroupNames','ips','nicknames',
                   'journalNames','copyGroupNames','iscsiNames','chapUsers')

# field name -> @(kind, table). Serials/deviceids/wwns are ALSO matched by suffix
# in Gm-Classify; NAME fields are explicit-only (keep driveTypeName/productName real).
$script:Simple = @{
    'ctl1Ip' = @('ip', $null); 'ctl2Ip' = @('ip', $null)
    'restServerIp' = @('ip', $null); 'ipAddress' = @('ip', $null)
    'hostGroupName' = @('freeform', 'hostGroupNames')
    'wwnNickname' = @('freeform', 'nicknames'); 'label' = @('freeform', 'nicknames')
    'poolName' = @('freeform', 'nicknames'); 'resourceGroupName' = @('freeform', 'nicknames')
    'snapshotGroupName' = @('freeform', 'copyGroupNames'); 'snapshotGroupId' = @('freeform', 'copyGroupNames')
    'copyGroupName' = @('freeform', 'copyGroupNames')
    'pvolDeviceGroupName' = @('freeform', 'copyGroupNames'); 'svolDeviceGroupName' = @('freeform', 'copyGroupNames')
    'copyPairName' = @('freeform', 'copyGroupNames')
    'journalName' = @('freeform', 'journalNames'); 'iscsiName' = @('freeform', 'iscsiNames')
    'chapUserName' = @('freeform', 'chapUsers')
    'serialNumber' = @('serial_auto', $null)
}
$script:CompositeKeys = @('hostWwnId','remotepathGroupId','localCloneCopygroupId','localCloneCopypairId','remoteMirrorCopyGroupId','remoteMirrorCopyPairId')

function New-GmMapping($Seed) {
    if ($null -ne $Seed) { $rng = [System.Random]::new([int]$Seed) } else { $rng = [System.Random]::new() }
    $tables = [ordered]@{}; $used = @{}
    foreach ($t in $script:Tables) { $tables[$t] = [ordered]@{}; $used[$t] = @{} }
    return @{ Rng = $rng; Tables = $tables; Used = $used }
}

function _Gm_Sanitizable($v) {
    if ($null -eq $v) { return $false }
    if ($v -is [string] -and ($script:Sentinels -contains $v.Trim().ToLower())) { return $false }
    return $true
}

function _Gm_IsNumeric($v) { return ($v -is [System.ValueType] -and $v -isnot [bool]) }

function _Gm_IsArr($v) {
    if ($v -is [string]) { return $false }
    if ($v -is [System.Collections.IDictionary]) { return $false }
    if ($v -is [System.Management.Automation.PSCustomObject]) { return $false }
    return ($v -is [System.Collections.IEnumerable])
}

function _Gm_Store($m, [string]$table, $real, $cand) {
    $m.Tables[$table][$real] = $cand; $m.Used[$table][$cand] = $true; return $cand
}

# -- generators ---------------------------------------------------------------
function Gm-Wwn($m, $value) {
    if (-not ($value -is [string]) -or -not (_Gm_Sanitizable $value)) { return $value }
    $real = $value.Trim().ToLower()
    if ($m.Tables['wwns'].Contains($real)) { return $m.Tables['wwns'][$real] }
    $n = $real.Length
    for ($i = 0; $i -lt 1000; $i++) {
        $sb = [System.Text.StringBuilder]::new()
        for ($j = 0; $j -lt $n; $j++) { [void]$sb.Append('0123456789abcdef'[$m.Rng.Next(0, 16)]) }
        $cand = $sb.ToString()
        if (-not $m.Used['wwns'].Contains($cand)) { return (_Gm_Store $m 'wwns' $real $cand) }
    }
    throw "pseudonym space exhausted for wwns"
}

function _Gm_Serial6($m, [string]$real6) {
    if ($m.Tables['serials'].Contains($real6)) { return $m.Tables['serials'][$real6] }
    $lead = $real6.Length - $real6.TrimStart('0').Length
    $body = 6 - $lead
    if ($body -le 0) { return (_Gm_Store $m 'serials' $real6 $real6) }
    for ($i = 0; $i -lt 1000; $i++) {
        $s = ('0' * $lead) + [char](49 + $m.Rng.Next(0, 9))
        for ($j = 1; $j -lt $body; $j++) { $s += [char](48 + $m.Rng.Next(0, 10)) }
        if (-not $m.Used['serials'].Contains($s)) { return (_Gm_Store $m 'serials' $real6 $s) }
    }
    throw "pseudonym space exhausted for serials"
}

function Gm-SerialBare($m, $value) {
    if ($null -eq $value) { return $value }
    $s = [string]$value
    if ($s -notmatch '^\d+$') { return $value }
    $pseud6 = _Gm_Serial6 $m ($s.PadLeft(6, '0'))
    if (_Gm_IsNumeric $value) { return [int64]$pseud6 }
    if ($s.Length -le 6) { return $pseud6.Substring(6 - $s.Length) }
    return $pseud6
}

function Gm-SerialSdid($m, $value) {
    $s = [string]$value
    if ($s.Length -ne 12 -or $s -notmatch '^\d{12}$') { return (Gm-SerialBare $m $value) }
    return $s.Substring(0, 6) + (_Gm_Serial6 $m $s.Substring(6))
}

function Gm-Ip($m, $value) {
    if (-not ($value -is [string]) -or -not (_Gm_Sanitizable $value)) { return $value }
    $addr = $null
    if (-not [System.Net.IPAddress]::TryParse($value.Trim(), [ref]$addr)) { return $value }
    if ($addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $value }
    if ($m.Tables['ips'].Contains($value)) { return $m.Tables['ips'][$value] }
    for ($i = 0; $i -lt 1000; $i++) {
        $cand = '{0}.{1}.{2}.{3}' -f $m.Rng.Next(1, 255), $m.Rng.Next(1, 255), $m.Rng.Next(1, 255), $m.Rng.Next(1, 255)
        if (-not $m.Used['ips'].Contains($cand)) { return (_Gm_Store $m 'ips' $value $cand) }
    }
    throw "pseudonym space exhausted for ips"
}

function _Gm_GenFreeform($m, [string]$s) {
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $s.ToCharArray()) {
        $c = [int][char]$ch
        if ($c -ge 48 -and $c -le 57) { [void]$sb.Append([char](48 + $m.Rng.Next(0, 10))) }
        elseif ($c -ge 97 -and $c -le 122) { [void]$sb.Append([char](97 + $m.Rng.Next(0, 26))) }
        elseif ($c -ge 65 -and $c -le 90) { [void]$sb.Append([char](65 + $m.Rng.Next(0, 26))) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Gm-Freeform($m, [string]$table, $value) {
    if (-not ($value -is [string]) -or -not (_Gm_Sanitizable $value)) { return $value }
    if ($m.Tables[$table].Contains($value)) { return $m.Tables[$table][$value] }
    for ($i = 0; $i -lt 1000; $i++) {
        $cand = _Gm_GenFreeform $m $value
        if (-not $m.Used[$table].Contains($cand)) { return (_Gm_Store $m $table $value $cand) }
    }
    throw "pseudonym space exhausted for $table"
}

# -- classification -----------------------------------------------------------
function Gm-Classify([string]$key) {
    if ($script:Simple.ContainsKey($key)) { return $script:Simple[$key] }
    $kl = $key.ToLower()
    if ($kl.EndsWith('serialnumber')) { return @('serial_auto', $null) }
    if ($kl.EndsWith('deviceid')) { return @('serial_sdid', $null) }
    if ($kl -eq 'wwn' -or $kl.EndsWith('wwn')) { return @('wwn', $null) }
    return $null
}

function Test-GmAuditSkip([string]$key, $value) {
    $cls = Gm-Classify $key
    if ($cls -and $cls[0] -eq 'serial_auto') {
        return -not ((_Gm_IsNumeric $value) -or ($value -is [string] -and $value -match '^\d+$'))
    }
    return $false
}

function _Gm_Apply($m, [string]$kind, $table, $v) {
    switch ($kind) {
        'wwn'         { return (Gm-Wwn $m $v) }
        'serial_sdid' { return (Gm-SerialSdid $m $v) }
        'serial_bare' { return (Gm-SerialBare $m $v) }
        'serial_auto' {
            if ((_Gm_IsNumeric $v) -or ($v -is [string] -and $v -match '^\d+$')) { return (Gm-SerialBare $m $v) }
            return $v   # drive/hardware serial kept real (D37)
        }
        'ip'          { return (Gm-Ip $m $v) }
        'freeform'    { return (Gm-Freeform $m $table $v) }
        default       { return $v }
    }
}

# -- composite IDs (rebuilt from sanitized parts) -----------------------------
function _Gm_ApplyComposite([string]$key, [string]$value, $m) {
    switch ($key) {
        'hostWwnId' {
            $p = $value.Split(','); if ($p.Count -eq 3) { $p[2] = Gm-Wwn $m $p[2] }; return ($p -join ',')
        }
        'remotepathGroupId' {
            $p = $value.Split(','); if ($p.Count -ge 1 -and $p[0] -match '^\d+$') { $p[0] = [string](Gm-SerialBare $m $p[0]) }; return ($p -join ',')
        }
        'localCloneCopygroupId' {
            return (($value.Split(',') | ForEach-Object { Gm-Freeform $m 'copyGroupNames' $_ }) -join ',')
        }
        'localCloneCopypairId' {   # 4-part (adds copyPairName); same all-names rebuild
            return (($value.Split(',') | ForEach-Object { Gm-Freeform $m 'copyGroupNames' $_ }) -join ',')
        }
        'remoteMirrorCopyGroupId' {
            $p = $value.Split(','); $out = @()
            for ($i = 0; $i -lt $p.Count; $i++) {
                if ($i -eq 0 -and $p[$i] -match '^\d+$') {
                    if ($p[$i].Length -eq 12) { $out += (Gm-SerialSdid $m $p[$i]) } else { $out += [string](Gm-SerialBare $m $p[$i]) }
                } else { $out += (Gm-Freeform $m 'copyGroupNames' $p[$i]) }
            }
            return ($out -join ',')
        }
        'remoteMirrorCopyPairId' {   # serial,names,pairName -- unverified (no remote fixture yet)
            $p = $value.Split(','); $out = @()
            for ($i = 0; $i -lt $p.Count; $i++) {
                if ($i -eq 0 -and $p[$i] -match '^\d+$') {
                    if ($p[$i].Length -eq 12) { $out += (Gm-SerialSdid $m $p[$i]) } else { $out += [string](Gm-SerialBare $m $p[$i]) }
                } else { $out += (Gm-Freeform $m 'copyGroupNames' $p[$i]) }
            }
            return ($out -join ',')
        }
        default { return $value }
    }
}

# -- the walk (mutates in place) ---------------------------------------------
function _Gm_SanSet($node, $k, $v, [string]$kind) {
    if ($kind -eq 'dict') { $node[$k] = $v } else { $node.$k = $v }
}

function _Gm_SanField($node, $k, $v, $m, [string]$kind) {
    if (($script:CompositeKeys -contains $k) -and ($v -is [string])) {
        _Gm_SanSet $node $k (_Gm_ApplyComposite $k $v $m) $kind; return
    }
    $isContainer = ($v -is [System.Collections.IDictionary]) -or ($v -is [System.Management.Automation.PSCustomObject]) -or (_Gm_IsArr $v)
    if (-not $isContainer) {
        $cls = Gm-Classify $k
        if ($cls) { _Gm_SanSet $node $k (_Gm_Apply $m $cls[0] $cls[1] $v) $kind; return }
    }
    _Gm_SanWalk $v $m
}

function _Gm_SanWalk($node, $m) {
    if ($node -is [System.Collections.IDictionary]) {
        foreach ($k in @($node.Keys)) { _Gm_SanField $node $k $node[$k] $m 'dict' }
    } elseif ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($k in @($node.PSObject.Properties | ForEach-Object Name)) { _Gm_SanField $node $k $node.$k $m 'pso' }
    } elseif (_Gm_IsArr $node) {
        foreach ($item in @($node)) { _Gm_SanWalk $item $m }
    }
}

function Invoke-GmSanitize($tree, $Seed) {
    $m = New-GmMapping $Seed
    _Gm_SanWalk $tree $m
    return $m
}

function New-GmMappingDict($m) {
    return [ordered]@{
        _note  = 'ON-SITE ONLY -- the real->pseudonym key. Never leaves the site (plan 7 / D20). The emitted capture carries pseudonyms only.'
        tables = $m.Tables
    }
}

Export-ModuleMember -Function New-GmMapping, Invoke-GmSanitize, New-GmMappingDict,
    Gm-Wwn, Gm-SerialBare, Gm-SerialSdid, Gm-Ip, Gm-Freeform, Gm-Classify, Test-GmAuditSkip
