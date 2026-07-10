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


# ==================== INLINED MODULES (auto-built by build_prod.py) ====================
# Do NOT edit here -- edit the .psm1 modules + geomathmatical_dev.ps1, then re-run build_prod.py.

# ----- GmJsonWriter.psm1 -----
<#
GmJsonWriter.psm1 -- hand-rolled JSON serializer (plan 2.2, D26/D27).

The PowerShell mirror of Scripts/geomathmatical/json_writer.py. Deliberately NOT
ConvertTo-Json (5.1 truncates at depth 2). This emitter reproduces the Python
reference's byte contract EXACTLY so the two builds produce byte-identical output
on the same input (D26):
  - 2-space indent, "key": value, LF newlines, UTF-8 no BOM
  - keys in INSERTION order (ordered hashtables / PSCustomObject property order)
  - ASCII-safe: non-ASCII escaped as \uXXXX
  - ints as-is, bools true/false, null; empty {} / []

Accepts ordered hashtables (what the walker/emit build) and PSCustomObject (what
ConvertFrom-Json returns for fixture data) uniformly.
#>

Set-StrictMode -Version Latest

$script:INDENT = '  '

function ConvertTo-GmJsonString {
    param([Parameter(Mandatory = $true)] [AllowNull()] $Value)
    $sb = [System.Text.StringBuilder]::new()
    _Gm_Write $Value 0 $sb
    return $sb.ToString()
}

function Write-GmJsonFile {
    param([Parameter(Mandatory = $true)] [AllowNull()] $Value,
          [Parameter(Mandatory = $true)] [string] $Path)
    $text = (ConvertTo-GmJsonString $Value) + "`n"
    # UTF-8 without BOM, LF preserved (plan 2.1).
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $text, $enc)
}

function _Gm_IsDictionary($v) { return ($v -is [System.Collections.IDictionary]) }
function _Gm_IsPSObject($v) {
    return ($v -is [System.Management.Automation.PSCustomObject])
}
function _Gm_IsList($v) {
    if ($v -is [string]) { return $false }
    if (_Gm_IsDictionary $v) { return $false }
    if (_Gm_IsPSObject $v) { return $false }
    return ($v -is [System.Collections.IEnumerable])
}

function _Gm_Write($v, [int]$depth, $sb) {
    if ($null -eq $v) { [void]$sb.Append('null'); return }

    if ($v -is [bool]) { [void]$sb.Append($(if ($v) { 'true' } else { 'false' })); return }

    if ($v -is [string]) { _Gm_WriteString $v $sb; return }

    if ($v -is [ValueType] -and -not ($v -is [bool])) {
        # number -- invariant culture so no locale decimal comma / grouping.
        [void]$sb.Append(([System.Convert]::ToString($v, [System.Globalization.CultureInfo]::InvariantCulture)))
        return
    }

    if (_Gm_IsDictionary $v) { _Gm_WriteDict $v.Keys $v $depth $sb 'dict'; return }
    if (_Gm_IsPSObject $v) {
        $keys = @($v.PSObject.Properties | ForEach-Object { $_.Name })
        _Gm_WriteDict $keys $v $depth $sb 'pso'; return
    }
    if (_Gm_IsList $v) { _Gm_WriteList $v $depth $sb; return }

    # Fallback: stringify unknowns.
    _Gm_WriteString ([string]$v) $sb
}

function _Gm_WriteDict($keys, $obj, [int]$depth, $sb, [string]$kind) {
    $keyArr = @($keys)
    if ($keyArr.Count -eq 0) { [void]$sb.Append('{}'); return }
    $pad = $script:INDENT * ($depth + 1)
    $cpad = $script:INDENT * $depth
    [void]$sb.Append("{`n")
    for ($i = 0; $i -lt $keyArr.Count; $i++) {
        $k = $keyArr[$i]
        [void]$sb.Append($pad)
        _Gm_WriteString ([string]$k) $sb
        [void]$sb.Append(': ')
        if ($kind -eq 'dict') { $val = $obj[$k] } else { $val = $obj.$k }
        _Gm_Write $val ($depth + 1) $sb
        [void]$sb.Append($(if ($i -lt $keyArr.Count - 1) { ",`n" } else { "`n" }))
    }
    [void]$sb.Append($cpad + '}')
}

function _Gm_WriteList($lst, [int]$depth, $sb) {
    $arr = @($lst)
    if ($arr.Count -eq 0) { [void]$sb.Append('[]'); return }
    $pad = $script:INDENT * ($depth + 1)
    $cpad = $script:INDENT * $depth
    [void]$sb.Append("[`n")
    for ($i = 0; $i -lt $arr.Count; $i++) {
        [void]$sb.Append($pad)
        _Gm_Write $arr[$i] ($depth + 1) $sb
        [void]$sb.Append($(if ($i -lt $arr.Count - 1) { ",`n" } else { "`n" }))
    }
    [void]$sb.Append($cpad + ']')
}

function _Gm_WriteString([string]$s, $sb) {
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $code = [int][char]$ch
        switch ($ch) {
            '"'  { [void]$sb.Append('\"'); continue }
            '\'  { [void]$sb.Append('\\'); continue }
            "`n" { [void]$sb.Append('\n'); continue }
            "`t" { [void]$sb.Append('\t'); continue }
            "`r" { [void]$sb.Append('\r'); continue }
            default {
                if ($code -lt 0x20 -or $code -gt 0x7E) {
                    [void]$sb.Append('\u' + $code.ToString('x4'))
                } else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
}


# ----- GmArrayModels.psm1 -----
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


# ----- GmEndpoints.psm1 -----
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


# ----- GmRestClient.psm1 -----
<#
GmRestClient.psm1 -- session lifecycle, labeled GET, --replay + token recovery.
PowerShell mirror of Scripts/geomathmatical/rest_client.py (plan 2.1, D32/D36).

A client is a hashtable; Invoke-GmFetch dispatches on .Mode ('replay'|'live').
Replay serves <label...>.json from the capture dir (the exact names the collector
wrote). Live keeps one session and recovers from a 401 by re-logging in and
re-issuing the same GET (D36); status is classified (401 re-auth / 403 skip /
400-404-412-417 conditional / 5xx+network transient) and an unrecoverable read
throws GmRestError so a partial capture cannot pass for complete (D20).
#>
Set-StrictMode -Version Latest

function Get-GmSafeName([string]$name) { return ($name -replace '[\\/:*?"<>|,&=]', '_') }

function Get-GmReplayFilename([string]$label, $page, $hg) {
    $stem = $label
    if ($null -ne $hg) { $stem = '{0}__{1}_{2}' -f $label, $hg[0], $hg[1] }
    if ($null -ne $page) { $stem = '{0}_page{1:D3}' -f $label, [int]$page }
    return (Get-GmSafeName $stem) + '.json'
}

function New-GmReplayClient([string]$CaptureDir) {
    return @{ Mode = 'replay'; Dir = $CaptureDir }
}

# Write-through / read-through cache around another client (the lab-safe pull):
# each fetch is written to <Dir>/<replay-name>.json the moment it lands (atomic), and
# an already-present file is served from disk. INCREMENTAL + RESUMABLE, so a timeout
# only loses the in-flight request; transform offline later with -Replay <Dir>.
function New-GmCachingClient($Inner, [string]$CacheDir) {
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    return @{ Mode = 'caching'; Inner = $Inner; Dir = $CacheDir; Hits = 0; Fetched = 0; Log = $null }
}

# Live client. Password is a plain string here (resolved no-echo by the caller).
function New-GmLiveClient([string]$TargetHost, [string]$Username, [string]$Password,
                         [int]$TimeoutSec = 30, [int]$Retries = 3, [int]$ReauthMax = 3,
                         [int]$AliveTime = 300) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($s,$c,$ch,$e) $true }
    $pair = '{0}:{1}' -f $Username, $Password
    $basic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return @{ Mode = 'live'; BaseUrl = "https://$TargetHost/ConfigurationManager"
              Basic = $basic; TimeoutSec = $TimeoutSec; Retries = $Retries
              ReauthMax = $ReauthMax; AliveTime = $AliveTime; Token = $null; SessionId = $null
              Log = $null; ReauthCount = 0; ConnResetCount = 0 }
}

function Open-GmSession($client) {
    if ($client.Mode -eq 'caching') { return (Open-GmSession $client.Inner) }
    if ($client.Mode -eq 'replay') { return $true }
    $uri = $client.BaseUrl + '/v1/objects/sessions/'
    $body = (@{ aliveTime = $client.AliveTime } | ConvertTo-Json -Compress)
    _Gm_GuardReadOnly 'POST' $uri
    $attempt = 0
    while ($true) {
        try {
            $r = Invoke-WebRequest -Uri $uri -Method Post -Body $body -UseBasicParsing -TimeoutSec $client.TimeoutSec `
                    -Headers @{ 'Accept'='application/json'; 'Content-Type'='application/json'; 'Authorization'=$client.Basic }
            $o = $r.Content | ConvertFrom-Json
            $client.Token = $o.token; $client.SessionId = $o.sessionId
            return [bool]$client.Token
        } catch {
            $code = _Gm_HttpCode $_
            if ($code -eq 503 -and $attempt -lt $client.Retries) { _Gm_Backoff $client $attempt 'login 503; retrying'; $attempt++; continue }
            throw (New-GmRestError 'session' "login failed (HTTP $code)")
        }
    }
}

function Close-GmSession($client) {
    if ($client.Mode -eq 'caching') { Close-GmSession $client.Inner; return }
    if ($client.Mode -eq 'replay' -or -not $client.SessionId) { return }
    try {
        $duri = "{0}/v1/objects/sessions/{1}" -f $client.BaseUrl, $client.SessionId
        _Gm_GuardReadOnly 'DELETE' $duri
        Invoke-WebRequest -Uri $duri -Method Delete `
            -UseBasicParsing -TimeoutSec $client.TimeoutSec `
            -Headers @{ 'Accept'='application/json'; 'Authorization'=("Session {0}" -f $client.Token) } | Out-Null
    } catch { }
    $client.Token = $null; $client.SessionId = $null
}

function New-GmRestError([string]$label, [string]$message) {
    $e = [System.Exception]::new("${label}: $message")
    $e.Data['GmRest'] = $true; $e.Data['label'] = $label
    return $e
}

function _Gm_GuardReadOnly([string]$method, [string]$uri) {
    # READ-ONLY GUARANTEE (grab-only, D19): the walk only GETs config; the ONLY writes are
    # managing our OWN session (POST/DELETE .../v1/objects/sessions). Refuse anything else so
    # the tool is provably incapable of writing to a shared array.
    $ownSession = $uri -like '*/v1/objects/sessions*'
    if ($method -eq 'GET' -or (($method -eq 'POST' -or $method -eq 'DELETE') -and $ownSession)) { return }
    throw (New-GmRestError 'readonly-guard' "refusing non-read-only request $method $uri (grab-only, D19)")
}

function _Gm_HttpCode($err) {
    $resp = $null
    try { $resp = $err.Exception.Response } catch { }
    if ($null -eq $resp) { return $null }
    $code = $null
    try { $code = [int]$resp.StatusCode } catch { }
    # PS 5.1 / .NET footgun: Invoke-WebRequest throws on a 4xx, and if the error
    # response BODY is left undrained it wedges the KeepAlive connection -- the NEXT
    # request reusing it then dies at the socket level (status $null, looks transient).
    # DRAIN + close the body so a clean connection returns to the pool. Reproduced
    # live: external_storage_luns (a 400) failed on the connection reused right after
    # external_storage_ports (also a 400) until this drain was added. urllib (Python)
    # drains cleanly, which is why the Python live walk never hit this.
    try {
        $stream = $resp.GetResponseStream()
        if ($stream) { $sr = New-Object System.IO.StreamReader($stream); [void]$sr.ReadToEnd(); $sr.Close() }
    } catch { }
    try { $resp.Close() } catch { }
    try { $resp.Dispose() } catch { }
    return $code
}

function _Gm_Backoff($client, [int]$attempt, [string]$msg) {
    $delay = [Math]::Min(1.0 * [Math]::Pow(2, $attempt), 15.0)
    if ($client.Log) { & $client.Log 'RETRY' '' ("$msg (waiting {0:N1}s)" -f $delay) }
    Start-Sleep -Seconds $delay
}

# Recover a wedged keep-alive connection. This sim, after some responses (a 4xx, or
# a large/slow 200), leaves the reused connection in a state where the NEXT send
# fails at the socket level ("underlying connection was closed ... on a send") with
# no HTTP response (null status). Re-issuing on the SAME connection never recovers,
# so we drop the pooled socket and re-establish the session -- a fresh POST login
# dials + warms a new connection, which the retried GET then rides. (Proven live:
# same-connection retry fails every time; a fresh session yields a clean response.)
function _Gm_ResetConnection($client) {
    try { [System.Net.ServicePointManager]::FindServicePoint((New-Object System.Uri $client.BaseUrl)).CloseConnectionGroup('') | Out-Null } catch { }
    Close-GmSession $client
    Open-GmSession $client | Out-Null
    $client.ConnResetCount++
}

# Returns parsed JSON (PSCustomObject) or $null for an expected empty read; throws
# GmRestError when recovery is exhausted (D36).
function Invoke-GmFetch($client, [string]$label, [string]$path, $params, $page, $hg) {
    if ($client.Mode -eq 'caching') {
        $fpath = Join-Path $client.Dir (Get-GmReplayFilename $label $page $hg)
        if (Test-Path $fpath) { $client.Hits++; return ([System.IO.File]::ReadAllText($fpath) | ConvertFrom-Json) }
        $obj = Invoke-GmFetch $client.Inner $label $path $params $page $hg
        if ($null -ne $obj) {
            $tmp = "$fpath.tmp"   # atomic: a killed write never leaves a half file
            [System.IO.File]::WriteAllText($tmp, (ConvertTo-GmJsonString $obj), ([System.Text.UTF8Encoding]::new($false)))
            Move-Item -Force -LiteralPath $tmp -Destination $fpath
            $client.Fetched++
        }
        return $obj
    }
    if ($client.Mode -eq 'replay') {
        $fpath = Join-Path $client.Dir (Get-GmReplayFilename $label $page $hg)
        if (-not (Test-Path $fpath)) { return $null }
        return ([System.IO.File]::ReadAllText($fpath) | ConvertFrom-Json)
    }
    # live
    $query = @{}
    if ($params) { foreach ($k in $params.Keys) { $query[$k] = $params[$k] } }
    if ($null -ne $hg) { $query['portId'] = $hg[0]; $query['hostGroupNumber'] = $hg[1] }
    if ($null -ne $page) { if (-not $query.ContainsKey('count')) { $query['count'] = 16384 } }
    $url = $client.BaseUrl + $path
    if ($query.Count -gt 0) {
        $qs = ($query.GetEnumerator() | ForEach-Object { '{0}={1}' -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value) }) -join '&'
        $url = $url + '?' + $qs
    }
    _Gm_GuardReadOnly 'GET' $url
    $reauthLeft = $client.ReauthMax; $transientLeft = $client.Retries; $tAttempt = 0
    while ($true) {
        $status = $null; $content = $null
        try {
            $r = Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -TimeoutSec $client.TimeoutSec `
                    -Headers @{ 'Accept'='application/json'; 'Content-Type'='application/json'; 'Authorization'=("Session {0}" -f $client.Token) }
            $status = [int]$r.StatusCode; $content = $r.Content
        } catch { $status = _Gm_HttpCode $_ }

        if ($status -ge 200 -and $status -lt 300 -and $null -ne $content) { return ($content | ConvertFrom-Json) }
        if ($status -in @(400,404,412,417)) { return $null }
        if ($status -eq 401) {
            if ($reauthLeft -le 0) { throw (New-GmRestError $label "401 persisted after $($client.ReauthMax) re-login(s)") }
            $reauthLeft--; $client.ReauthCount++
            Close-GmSession $client; Open-GmSession $client | Out-Null
            if ($client.Log) { & $client.Log 'AUTH' $label ("token expired (401); re-authenticated (#{0})" -f $client.ReauthCount) }
            continue
        }
        if ($status -eq 403) {
            if ($client.Log) { & $client.Log 'SKIP' $label '403 permission denied (account lacks rights)' }
            return $null
        }
        # Transport-level failure (null status = no HTTP response): the reused
        # keep-alive connection is wedged. Retrying on it is hopeless -- reset the
        # connection/session so the retry dials fresh (see _Gm_ResetConnection).
        if ($null -eq $status) {
            if ($transientLeft -le 0) { throw (New-GmRestError $label "unrecoverable after $($client.Retries) retr(ies), last error: transport/connection failure (no HTTP response)") }
            $transientLeft--
            if ($client.Log) { & $client.Log 'RESET' $label 'transport error (connection wedged); resetting session + retrying' }
            _Gm_ResetConnection $client
            _Gm_Backoff $client $tAttempt ("{0}: connection reset; retrying" -f $label); $tAttempt++
            continue
        }
        # HTTP-level transient (5xx etc.): the connection is fine; retry on it.
        if ($transientLeft -le 0) { throw (New-GmRestError $label "unrecoverable after $($client.Retries) retr(ies), last status $status") }
        $transientLeft--; _Gm_Backoff $client $tAttempt ("{0}: status {1}; retrying" -f $label, $status); $tAttempt++
    }
}


# ----- GmTreeWalker.psm1 -----
<#
GmTreeWalker.psm1 -- drive the capture map into an in-memory tree (plan 2.2).
PowerShell mirror of Scripts/geomathmatical/tree_walker.py. Tree is an ordered
hashtable so key order is preserved for byte-identical emit (D26). Requires
GmRestClient, GmEndpoints, GmArrayModels imported in the session.
#>
Set-StrictMode -Version Latest

function Get-GmData($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Management.Automation.PSCustomObject] -and $obj.PSObject.Properties['data']) {
        # unary comma so a 1-element data array is NOT unwrapped to a scalar on
        # return (that would emit an object instead of a 1-element array).
        return , @($obj.data)
    }
    return $obj
}

function Get-GmCount($x) {
    if ($null -eq $x) { return 0 }
    if ($x -is [string]) { return 1 }
    if ($x -is [System.Collections.IDictionary]) { return 1 }
    if ($x -is [System.Collections.IEnumerable]) { return @($x).Count }
    return 1
}

function _Gm_IsArray($v) {
    if ($v -is [string]) { return $false }
    if ($v -is [System.Collections.IDictionary]) { return $false }
    if ($v -is [System.Management.Automation.PSCustomObject]) { return $false }
    return ($v -is [System.Collections.IEnumerable])
}

# Return an array that survives PS's empty-array-return collapse (an empty @()
# returned bare becomes $null). The unary comma keeps it an array for the caller.
function _Gm_AsArray($v) { if ($null -eq $v) { return , @() } return , @($v) }

function Invoke-GmWalk($client, [string]$phases = 'all', [int]$pageCount = 16384, $log = $null, [string]$ldevOption = 'defined') {
    if (-not $log) { $log = { param($s, $l, $m) } }
    $tree = [ordered]@{}
    foreach ($ep in (Get-GmEndpoints $phases)) {
        switch ($ep.kind) {
            'simple' {
                $data = Get-GmData (Invoke-GmFetch $client $ep.label $ep.path $ep.params $null $null)
                $tree[$ep.label] = $data
                _Gm_LogHit $log $ep $data
            }
            'paginated' { $tree[$ep.label] = _Gm_WalkPaginated $client $ep $pageCount $log $ldevOption }
            'per_hg'    { $tree[$ep.label] = _Gm_WalkPerHg $client $ep $tree['host_groups'] $log }
            'discovery' {
                $res = _Gm_WalkDiscovery $client $ep $log
                $tree[$ep.label] = $res.Parent
                $tree[$ep.discovery.results_key] = $res.Children
            }
            'replication_pairs' {
                $res = _Gm_WalkReplicationPairs $client $ep $log
                $tree['remote_copypairs'] = $res.Pairs
                $tree['remote_replications'] = $res.Repl
            }
        }
    }
    return $tree
}

function _Gm_WalkPaginated($client, $ep, [int]$pageCount, $log, [string]$ldevOption = 'defined') {
    # ldevOption (D40): mirror tree_walker.py -- send the REST ldevOption filter on the
    # ldevs walk unless 'all' (which omits it = the faithful full dump, D31).
    $rows = New-Object System.Collections.ArrayList
    $head = 0; $page = 0
    while ($true) {
        $params = [ordered]@{}
        foreach ($k in $ep.params.Keys) { $params[$k] = $ep.params[$k] }
        $params['headLdevId'] = $head; $params['count'] = $pageCount
        if ($ldevOption -and $ldevOption -ne 'all') { $params['ldevOption'] = $ldevOption }
        # Pre-log the slow live read so it is not silent (see Python tree_walker).
        & $log '...' $ep.label ("fetching page {0} (headLdevId={1}, count={2}) ..." -f $page, $head, $pageCount)
        $data = Get-GmData (Invoke-GmFetch $client $ep.label $ep.path $params $page $null)
        if ($null -eq $data -or @($data).Count -eq 0) { break }
        foreach ($r in @($data)) { [void]$rows.Add($r) }
        if (@($data).Count -lt $pageCount) { break }
        $ids = @($data | ForEach-Object { $_.ldevId } | Where-Object { $null -ne $_ })
        if ($ids.Count -eq 0) { break }
        $head = ([int]($ids | Measure-Object -Maximum).Maximum) + 1; $page++
        if ($page -gt 64) { & $log 'WARN' $ep.label 'page ceiling hit; stopping'; break }
    }
    & $log 'OK' $ep.label ("{0} rows over {1} page(s)" -f $rows.Count, ($page + 1))
    return , @($rows.ToArray())
}

function _Gm_WalkPerHg($client, $ep, $hostGroups, $log) {
    $out = [ordered]@{}
    if ($null -eq $hostGroups -or @($hostGroups).Count -eq 0) {
        & $log 'SKIP' $ep.label 'no host_groups captured; nothing to fan out'; return $out
    }
    foreach ($hg in @($hostGroups)) {
        $port = $hg.portId; $num = $hg.hostGroupNumber
        if (-not $port -or $null -eq $num) { continue }
        $data = Get-GmData (Invoke-GmFetch $client $ep.label $ep.path $null $null @($port, $num))
        if ($null -eq $data) { $data = @() }
        $out[('{0}_{1}' -f $port, $num)] = @($data)
    }
    $total = 0; foreach ($v in $out.Values) { $total += @($v).Count }
    & $log 'OK' $ep.label ("{0} rows over {1} host-group(s)" -f $total, $out.Count)
    return $out
}

function _Gm_WalkDiscovery($client, $ep, $log) {
    $disc = $ep.discovery
    $parent = Get-GmData (Invoke-GmFetch $client $ep.label $ep.path $ep.params $null $null)
    _Gm_LogHit $log $ep $parent
    $parentArr = _Gm_AsArray $parent
    $results = New-Object System.Collections.ArrayList
    foreach ($item in $parentArr) {
        if (-not ($item -is [System.Management.Automation.PSCustomObject])) { continue }
        $key = Get-GmProp $item $disc.parent_key
        if ($null -eq $key -or $key -eq '') { continue }
        $fb = $null; if ($disc.Contains('fallback')) { $fb = $disc.fallback }
        if ($fb -and $fb.when -eq 'special_chars' -and (_Gm_NeedsQuery ([string]$key))) {
            $child = _Gm_FetchChild $client $fb 'query' $key
        } else {
            $child = _Gm_FetchChild $client $disc $disc.mode $key
        }
        if ($null -eq $child) { continue }
        if (_Gm_IsArray $child) { foreach ($c in @($child)) { [void]$results.Add($c) } }
        else { [void]$results.Add($child) }
    }
    & $log 'OK' $disc.results_key ("{0} parent(s) -> {1} child row(s)" -f @($parentArr).Count, $results.Count)
    return @{ Parent = $parent; Children = @($results.ToArray()) }
}

function _Gm_NeedsQuery([string]$name) {
    return ($name.Contains('/') -or $name.Contains('\') -or $name -eq '.')
}

function _Gm_FetchChild($client, $child, [string]$mode, $key) {
    $label = '{0}__{1}' -f $child.child_label, $key
    if ($mode -eq 'query') {
        $p = [ordered]@{}; $p[$child.child_param] = $key
        return (Get-GmData (Invoke-GmFetch $client $label $child.child_path $p $null $null))
    }
    $path = $child.child_path + '/' + [uri]::EscapeDataString([string]$key)
    return (Invoke-GmFetch $client $label $path $null $null $null)
}

function _Gm_WalkReplicationPairs($client, $ep, $log) {
    $pairs = [ordered]@{}; $repl = [ordered]@{}
    $size = $ep.page_size
    foreach ($rt in $ep.replication_types) {
        $rows = New-Object System.Collections.ArrayList
        $head = 0; $page = 0
        while ($true) {
            $params = [ordered]@{ replicationType = $rt; headLdevId = $head; count = $size }
            $data = Get-GmData (Invoke-GmFetch $client ("remote_copypairs_{0}" -f $rt) $ep.path $params $page $null)
            if ($null -eq $data -or @($data).Count -eq 0) { break }
            foreach ($r in @($data)) { [void]$rows.Add($r) }
            if (@($data).Count -lt $size) { break }
            $ids = @($data | ForEach-Object { $_.($ep.page_key) } | Where-Object { $null -ne $_ })
            if ($ids.Count -eq 0) { break }
            $head = ([int]($ids | Measure-Object -Maximum).Maximum) + 1; $page++
            if ($page -gt 200) { & $log 'WARN' ("remote_copypairs_{0}" -f $rt) 'page ceiling hit; stopping'; break }
        }
        $pairs[$rt] = @($rows.ToArray())
        $rr = Get-GmData (Invoke-GmFetch $client ("remote_replications_{0}" -f $rt) '/v1/objects/remote-replications' ([ordered]@{ replicationType = $rt }) $null $null)
        if ($null -ne $rr) { $repl[$rt] = $rr }
    }
    $total = 0; foreach ($v in $pairs.Values) { $total += @($v).Count }
    & $log 'OK' 'remote_copypairs' ("{0} pair row(s) over {1}" -f $total, ($ep.replication_types -join ','))
    return @{ Pairs = $pairs; Repl = $repl }
}

function _Gm_LogHit($log, $ep, $data) {
    if ($null -eq $data) {
        $tag = if (Test-GmKnownConditional $ep.label) { 'SKIP*' } else { 'SKIP' }
        & $log $tag $ep.label 'no data (conditional / not present on this array)'
    } else {
        & $log 'OK' $ep.label ("{0} object(s)" -f (Get-GmCount $data))
    }
}


# ----- GmEmit.psm1 -----
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


# ----- GmSanitize.psm1 -----
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


# ----- GmAudit.psm1 -----
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


# ----- GmConfig.psm1 -----
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

# ==================== END INLINED MODULES ====================


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
