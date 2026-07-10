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

Export-ModuleMember -Function Invoke-GmWalk, Get-GmData, Get-GmCount
