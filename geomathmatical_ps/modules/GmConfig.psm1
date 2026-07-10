<#
GmConfig.psm1 -- load geomathmatical.cfg; first-run bootstrap (plan 2.3, D28).
PowerShell mirror of Scripts/geomathmatical/config.py. INI-style, inline ';'
comments stripped. First run (no cfg): write an annotated template, return $null.
#>
Set-StrictMode -Version Latest

function Get-GmConfigTemplate {
    return @'
# ============================================================================
# geomathmatical.cfg -- GeoMathmatical v0 operator inputs
# ----------------------------------------------------------------------------
# WARNING: this file names a customer array. It is git-ignored and MUST NEVER
# leave the customer site. The password is NOT stored here -- you are prompted
# for it at run time (no-echo). Fill in the blanks below and re-run.
# ============================================================================

[target]
host            =            ; array / CM REST host or IP (no scheme, no path)
prefix_override =            ; 6-digit model-designator prefix, if identity read fails (D25)
model_override  =            ; exact model string, last-resort override (D25)

[auth]
username        =            ; REST user; may also be given with -User on the CLI
                             ; NOTE: no 'secret' key -- password is prompted, never stored (plan 2.3)

[capture]
page_count      = 16384      ; LDEV page size (1-16384, the API max; plan 4.1)
phases          = all        ; all | a | ab | abc  (which top-level phases to run)
ldev_option     = defined    ; which LDEVs to pull (D40): defined | undefined | dpVolume | luMapped | luUnmapped | externalVolume | mappedNamespace | all
                             ; 'defined' (default) skips the ~99% NOT-DEFINED slots; 'all' = no filter, the faithful full dump (D31). -LdevOption overrides.
raw_never_written = false    ; true keeps even the intermediate in memory (D27)

[output]
capture_dir     =            ; where capture.json + audit_report.json are written
mapping_dir     =            ; real->pseudonym map (D20); STAYS ON-SITE, never exported

[tuneables]
http_timeout_s  = 30
retries         = 3
concurrency     = 1          ; serialize LDEV paging on VSP E/G/F (plan 4.1)
'@
}

function Import-GmConfig([string]$Path) {
    if (-not (Test-Path $Path)) {
        [System.IO.File]::WriteAllText($Path, (Get-GmConfigTemplate), ([System.Text.UTF8Encoding]::new($false)))
        Write-Host "No config found. Wrote a template to '$Path'."
        Write-Host "Edit it (set target.host and auth.username), then re-run."
        Write-Host "The password is prompted at run time -- do not put it in the file."
        return $null
    }
    $sections = [ordered]@{}; $cur = $null
    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') { $cur = $Matches[1]; $sections[$cur] = [ordered]@{}; continue }
        $eq = $line.IndexOf('=')
        if ($eq -ge 0 -and $cur) {
            $key = $line.Substring(0, $eq).Trim()
            $val = $line.Substring($eq + 1)
            $sc = $val.IndexOf(';'); if ($sc -ge 0) { $val = $val.Substring(0, $sc) }
            $sections[$cur][$key] = $val.Trim()
        }
    }
    return $sections
}

function Get-GmCfg($cfg, [string]$section, [string]$key, $default = $null) {
    if ($cfg.Contains($section) -and $cfg[$section].Contains($key)) {
        $v = $cfg[$section][$key]
        if ($v -ne '') { return $v }
    }
    return $default
}

Export-ModuleMember -Function Get-GmConfigTemplate, Import-GmConfig, Get-GmCfg
