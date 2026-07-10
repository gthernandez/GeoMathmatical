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

Export-ModuleMember -Function ConvertTo-GmJsonString, Write-GmJsonFile
