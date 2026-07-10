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

Export-ModuleMember -Function Get-GmSafeName, Get-GmReplayFilename, New-GmReplayClient, New-GmLiveClient,
    New-GmCachingClient, Open-GmSession, Close-GmSession, Invoke-GmFetch, New-GmRestError
