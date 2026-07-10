<#
.SYNOPSIS
    GeoMathmatical v0 -- PowerShell 5.1 build entry point (D26).

.DESCRIPTION
    Behavior-compatible mirror of `python -m geomathmatical`: load/bootstrap the
    config, walk the Block Storage REST capture map (Phase A/B/C incl. the Phase C
    replication discovery, D35), sanitize on-site (D20/D29/D31/D37), run the
    pre-export survivor audit (plan 9), and emit a byte-identical JSON capture
    (D27) plus the on-site mapping and a redacted audit report. Offline replay
    (`-Replay <dir>`) serves fixtures instead of HTTP.

.PARAMETER Replay   Offline: serve fixtures from a capture folder (D32).
.PARAMETER NoSanitize  Emit REAL values (D30); gated + loud; conflicts with -RawNeverWritten.
.PARAMETER User     REST username (password is NEVER a CLI arg; prompted no-echo).
.PARAMETER Config   cfg path (default ./geomathmatical.cfg).
.PARAMETER Out      capture.json output path.
.PARAMETER Phases   a | ab | abc (default from cfg).
.PARAMETER CapturedAt  Override capturedAtUtc (for reproducible baselines).
.PARAMETER LdevOption  Which LDEVs GET ldevs returns (D40): defined (default) | undefined | dpVolume | luMapped | luUnmapped | externalVolume | mappedNamespace | all (no filter, faithful dump, D31).
.PARAMETER Seed     Deterministic sanitizer PRNG seed for reproducible mappings (within the PS build; .NET Random differs from Python's, so not a cross-build match -- D26); omit for OS entropy.
.PARAMETER DryRun   Walk + audit; do not write.
#>
[CmdletBinding()]
param(
    [string] $Replay,
    [string] $RawDir,
    [switch] $NoSanitize,
    [switch] $RawNeverWritten,
    [string] $User,
    [string] $Config = 'geomathmatical.cfg',
    [string] $Out = 'capture.json',
    [string] $Phases,
    [string] $CapturedAt,
    [ValidateSet('defined', 'undefined', 'dpVolume', 'luMapped', 'luUnmapped', 'externalVolume', 'mappedNamespace', 'all')]
    [string] $LdevOption,
    [Nullable[int]] $Seed,
    [string] $LogDir,
    [switch] $DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleDir = Join-Path $here 'modules'
foreach ($mod in 'GmJsonWriter','GmArrayModels','GmEndpoints','GmRestClient','GmTreeWalker','GmEmit','GmSanitize','GmAudit','GmConfig') {
    Import-Module (Join-Path $moduleDir ($mod + '.psm1')) -Force -DisableNameChecking
}

# Optional per-run log FILE (new file per run; durable breadcrumb, syncs cleanly).
$script:LogFile = $null
if ($LogDir) {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $script:LogFile = Join-Path $LogDir ("capture_" + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + ".log")
}
# Write via [Console]::Out + Flush so lines STREAM when output is captured (not a
# live console); otherwise a long live walk shows nothing until it exits (reads as a hang).
$log = {
    param($s, $l, $m)
    $ts = (Get-Date).ToString('HH:mm:ss')
    if ($l) { $line = "{0}  {1,-6} {2,-28} {3}" -f $ts, $s, $l, $m } else { $line = "{0}  ---- {1}" -f $ts, $m }
    [Console]::Out.WriteLine($line); [Console]::Out.Flush()
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

if ($NoSanitize -and $RawNeverWritten) { & $log 'FATAL' '' '--NoSanitize conflicts with -RawNeverWritten (plan 7.1)'; exit 2 }

# Curated common-flags table -- printed on first run (the orientation moment), mirroring
# the Python build's COMMON_FLAGS. Get-Help on this script has the full parameter list.
# {0} is filled with the running script's own name (so the single-file build self-names
# as geomathmatical.ps1 and the dev build as geomathmatical_dev.ps1).
$commonFlags = @'
GeoMathmatical v0 (PowerShell) -- common flags (Get-Help .\{0} for the full list)
  flag                what it does                                    default
  ------------------  ----------------------------------------------  -------------
  -LdevOption OPT     which LDEVs to pull. OPT is one of:             defined
                        defined | undefined | dpVolume | luMapped |
                        luUnmapped | externalVolume | mappedNamespace
                        | all  (all = no filter, faithful dump, D31)
  -RawDir DIR         lab-safe: write each endpoint as fetched,       (off)
                        resumable; transform later with -Replay
  -Replay DIR         offline: serve fixtures from a capture dir      (off)
  -NoSanitize         emit REAL identifiers (gated, loud)             (off)
  -DryRun             walk + report counts; write nothing             (off)
  -Out PATH           where the sanitized capture.json is written     capture.json
'@

$cfg = Import-GmConfig $Config
if ($null -eq $cfg) { Write-Host ("`n" + ($commonFlags -f $MyInvocation.MyCommand.Name)); exit 0 }   # template written; operator edits and re-runs

$phasesSel = if ($Phases) { $Phases } else { (Get-GmCfg $cfg 'capture' 'phases' 'all') }
$pageCount = [int](Get-GmCfg $cfg 'capture' 'page_count' '16384')
# LDEV filter (D40): CLI wins, else cfg, else 'defined'. 'all' -> no ldevOption sent.
$ldevOption = if ($LdevOption) { $LdevOption } else { (Get-GmCfg $cfg 'capture' 'ldev_option' 'defined') }

if ($Replay) {
    & $log '----' '' "REPLAY mode -- fixtures from $Replay (no array)"
    $client = New-GmReplayClient $Replay
} else {
    $username = if ($User) { $User } else { (Get-GmCfg $cfg 'auth' 'username' '') }
    if (-not $username) { & $log 'FATAL' '' 'no username: set [auth] username or pass -User'; exit 2 }
    $targetHost = (Get-GmCfg $cfg 'target' 'host' '')
    # Banner BEFORE the password step so a prompt (or a set-but-wrong GEOM_PASSWORD)
    # is not a silent wait.
    & $log '----' '' "LIVE mode -- https://$targetHost/ConfigurationManager"
    # HIDDEN testing/automation path (D28 note): mirror the Python build -- if
    # GEOM_PASSWORD is set, use it instead of the no-echo prompt (lab sim / CI).
    # Undocumented in -help; loud when used; not for production (env vars leak to
    # process listings). Unset it to force the prompt.
    if ($env:GEOM_PASSWORD) {
        $pw = $env:GEOM_PASSWORD
        & $log '----' '' 'password taken from GEOM_PASSWORD env (hidden testing/automation path)'
    } else {
        & $log '----' '' 'resolving credentials (prompting; set GEOM_PASSWORD to run hands-free)'
        $sec = Read-Host -AsSecureString "Password for $username@$targetHost"
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    $client = New-GmLiveClient $targetHost $username $pw ([int](Get-GmCfg $cfg 'tuneables' 'http_timeout_s' '30')) ([int](Get-GmCfg $cfg 'tuneables' 'retries' '3'))
    $client.Log = $log
}
if ($RawDir) {
    $client = New-GmCachingClient $client $RawDir
    $client.Log = $log
    & $log '----' '' "RAW COLLECTION -> $RawDir (incremental + resumable; transform later with -Replay $RawDir)"
}

if ($NoSanitize) { & $log '----' '' '*** REAL-VALUES MODE (-NoSanitize): output carries REAL identifiers ***' }

try {
    & $log '----' '' 'opening session (login + token) ...'
    if (-not (Open-GmSession $client)) { & $log 'FATAL' '' 'could not open a session'; exit 2 }
    & $log '----' '' "Walk -- Phase A/B/C ($phasesSel); ldevOption=$ldevOption"
    $tree = Invoke-GmWalk $client $phasesSel $pageCount $log $ldevOption
    $entry = @($tree['storages'])[0]
    $sdid = if ($entry) { [string]$entry.storageDeviceId } else { '' }
    $ident = Resolve-GmIdentity $tree['components_instance'] $sdid $entry (Get-GmCfg $cfg 'target' 'prefix_override' '') (Get-GmCfg $cfg 'target' 'model_override' '')
    $apiVer = if ($tree['api_version']) { $tree['api_version'].apiVersion } else { $null }
    & $log 'OK' 'identity' ("{0} ({1}); serial in on-site mapping" -f $ident.model, $ident.confidence)
} finally {
    Close-GmSession $client
    & $log '----' '' 'Session closed (teardown)'
}

# Raw collection stops here: files are already on disk (incrementally). Transform is a
# separate offline step -- survives lab timeouts.
if ($RawDir) {
    & $log '----' '' "raw collection done: $($client.Fetched) fetched, $($client.Hits) served from cache -> $RawDir"
    & $log '----' '' "transform offline: .\$($MyInvocation.MyCommand.Name) -Replay $RawDir -Out capture.json"
    exit 0
}

$realSerial = $ident.serial
$applied = -not $NoSanitize
# These post-walk transforms are silent AND slow at scale (sanitize/serialize tens of
# thousands of LDEVs), so banner each -- otherwise the run looks hung here.
& $log '----' '' $(if ($applied) { 'normalize + sanitize ...' } else { 'REAL-VALUES (no sanitize) ...' })
if ($applied) {
    $m = Invoke-GmSanitize $tree $Seed
    $ident.serial = Gm-SerialBare $m $ident.serial
} else { $m = $null }

if (-not $CapturedAt) { $CapturedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
& $log '----' '' 'assembling capture object ...'
$cap = New-GmCapture $tree $ident $apiVer $CapturedAt $applied $null

& $log '----' '' 'audit (pre-export survivor scan) ...'
$audit = Invoke-GmAudit $cap $m -Skip:(-not $applied)
$outDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($Out))
if (-not $audit.passed) {
    & $log 'FATAL' 'audit' "$($audit.survivors) survivor(s) -- refusing to write the capture (plan 9); see audit_report"
    if (-not $DryRun) { Write-GmJsonFile (New-GmAuditReport $audit) (Join-Path $outDir 'audit_report.json') }
    exit 3
}
if ($applied) { $cap['sanitization']['audit'] = [ordered]@{ patternsScanned = $audit.patterns_scanned; survivors = $audit.survivors } }

$auditLine = if ($audit.skipped) { 'audit skipped (real-values)' } else { "audit $($audit.patterns_scanned) patterns, $($audit.survivors) survivors" }
& $log '----' '' "outOfModel $(@($cap.outOfModel).Count); $auditLine"

if ($DryRun) { & $log '----' '' '--DryRun: capture + mapping NOT written'; exit 0 }

& $log '----' '' "serializing + writing capture to $Out ..."
Write-GmJsonFile $cap $Out
& $log '----' '' "Wrote $Out"

if ($applied) {
    $mapDir = (Get-GmCfg $cfg 'output' 'mapping_dir' ''); if (-not $mapDir) { $mapDir = $outDir }
    $mapPath = Join-Path $mapDir ("mapping.{0}.json" -f $(if ($realSerial) { $realSerial } else { 'unknown' }))
    Write-GmJsonFile (New-GmMappingDict $m) $mapPath
    & $log '----' '' "Wrote on-site mapping $mapPath -- KEEP ON-SITE, never export"
    $reportPath = Join-Path $outDir 'audit_report.json'
    Write-GmJsonFile (New-GmAuditReport $audit) $reportPath
    & $log '----' '' "Wrote audit report $reportPath ($($audit.survivors) survivors)"
}
