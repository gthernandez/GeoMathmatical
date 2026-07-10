<#
GmAudit.psm1 -- pre-export survivor scan (plan 7/9, D20/D37).
PowerShell mirror of Scripts/geomathmatical/audit.py. Scans the assembled
sanitized capture for surviving REAL identifiers using the mapping as ground
truth; type-aware (int serials matched by exact equality, strings by substring),
D37 kept-real exclusion, redacted report. Requires GmSanitize imported
(Test-GmAuditSkip). Fails the export on any survivor.
#>
Set-StrictMode -Version Latest

function _Gm_Redact($v) {
    $s = [string]$v
    if ($s.Length -le 4) { return ('*' * $s.Length) }
    return $s.Substring(0, 2) + ('*' * ($s.Length - 4)) + $s.Substring($s.Length - 2)
}

function _Gm_IsContainer($v) {
    return ($v -is [System.Collections.IDictionary]) -or ($v -is [System.Management.Automation.PSCustomObject]) -or `
           (($v -isnot [string]) -and ($v -is [System.Collections.IEnumerable]))
}

function _Gm_CollectReals($m) {
    $realToTable = @{}; $intSerials = @{}
    foreach ($t in $m.Tables.Keys) {
        foreach ($real in @($m.Tables[$t].Keys)) {
            $rs = [string]$real
            $realToTable[$rs] = $t
            if ($t -eq 'serials' -and $rs -match '^\d+$') { $intSerials[[int64]$rs] = $true }
        }
    }
    $distinctive = @($realToTable.Keys | Where-Object { $_.Length -ge 5 })
    $short = @{}; foreach ($r in $realToTable.Keys) { if ($r.Length -lt 5) { $short[$r] = $true } }
    $rx = $null
    if ($distinctive.Count -gt 0) {
        $pat = (($distinctive | ForEach-Object { [regex]::Escape($_) }) -join '|')
        $rx = [regex]::new($pat, [System.Text.RegularExpressions.RegexOptions]::Compiled)
    }
    return @{ Rx = $rx; Short = $short; IntSerials = $intSerials; Table = $realToTable; Count = $realToTable.Count }
}

function _Gm_AuditCheck($path, $key, $value, $reals, $survivors) {
    if ($null -ne $key -and (Test-GmAuditSkip $key $value)) { return }
    if ($value -is [bool]) { return }
    if ($value -is [System.ValueType]) {
        if ($reals.IntSerials.Contains([int64]$value)) {
            [void]$survivors.Add([ordered]@{ path = $path; field = $key; table = 'serials'; hint = (_Gm_Redact $value) })
        }
        return
    }
    if (-not ($value -is [string])) { return }
    $hit = $null
    if ($reals.Rx) { $mm = $reals.Rx.Match($value); if ($mm.Success) { $hit = $mm.Value } }
    if ($null -eq $hit -and $reals.Short.Contains($value)) { $hit = $value }
    if ($hit) {
        $tbl = if ($reals.Table.ContainsKey($hit)) { $reals.Table[$hit] } else { '?' }
        [void]$survivors.Add([ordered]@{ path = $path; field = $key; table = $tbl; hint = (_Gm_Redact $hit) })
    }
}

function _Gm_AuditScan($node, $path, $reals, $survivors) {
    if ($node -is [System.Collections.IDictionary]) {
        foreach ($k in @($node.Keys)) {
            $v = $node[$k]; $p = "$path.$k"
            if (_Gm_IsContainer $v) { _Gm_AuditScan $v $p $reals $survivors } else { _Gm_AuditCheck $p $k $v $reals $survivors }
        }
    } elseif ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($k in @($node.PSObject.Properties | ForEach-Object Name)) {
            $v = $node.$k; $p = "$path.$k"
            if (_Gm_IsContainer $v) { _Gm_AuditScan $v $p $reals $survivors } else { _Gm_AuditCheck $p $k $v $reals $survivors }
        }
    } elseif (($node -isnot [string]) -and ($node -is [System.Collections.IEnumerable])) {
        $i = 0
        foreach ($item in @($node)) {
            $p = "$path[$i]"
            if (_Gm_IsContainer $item) { _Gm_AuditScan $item $p $reals $survivors } else { _Gm_AuditCheck $p $null $item $reals $survivors }
            $i++
        }
    }
}

function Invoke-GmAudit($capture, $m, [switch]$Skip) {
    if ($Skip -or $null -eq $m) {
        return @{ patterns_scanned = 0; survivors = 0; details = @(); skipped = $true; passed = $true }
    }
    $reals = _Gm_CollectReals $m
    $survivors = New-Object System.Collections.ArrayList
    _Gm_AuditScan $capture 'root' $reals $survivors
    return @{ patterns_scanned = $reals.Count; survivors = $survivors.Count
              details = @($survivors.ToArray()); skipped = $false; passed = ($survivors.Count -eq 0) }
}

function New-GmAuditReport($r) {
    $det = @($r.details); if ($det.Count -gt 100) { $det = $det[0..99] }
    return [ordered]@{
        mode            = $(if ($r.skipped) { 'skipped (real-values)' } else { 'sanitized' })
        patternsScanned = $r.patterns_scanned
        survivors       = $r.survivors
        pass            = $r.passed
        details         = , @($det)
    }
}

Export-ModuleMember -Function Invoke-GmAudit, New-GmAuditReport
