#!/usr/bin/env python3
"""build_prod.py -- collapse the PowerShell module build into ONE self-contained
`geomathmatical.ps1` (the production deliverable) from `geomathmatical_dev.ps1` + modules/.

WHY: a locked-down Citrix / air-gapped lab may allow no file transfer and no installs.
PowerShell 5.1 ships on every Windows box, so a single pasteable .ps1 that needs nothing
installed is the most transferable form of the capture tool. Re-run this after editing
any .psm1 or geomathmatical_dev.ps1.

HOW: geomathmatical_dev.ps1 already has param() first; this inlines the modules AT the point of its
`Import-Module` block (so param() stays first and functions are defined before the body
uses them), stripping each module's `Export-ModuleMember` (which is illegal outside a
module). The modules use only distinct Gm-prefixed names and script-scope `$script:` vars,
both of which behave identically in one script scope -- so the single file is the same
code, verified byte-identical to the modular build on a --replay --no-sanitize run.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
# Same load order as geomathmatical_dev.ps1's Import-Module foreach (dependency order).
ORDER = ['GmJsonWriter', 'GmArrayModels', 'GmEndpoints', 'GmRestClient',
         'GmTreeWalker', 'GmEmit', 'GmSanitize', 'GmAudit', 'GmConfig']


def strip_exports(text):
    """Drop Export-ModuleMember statements (single- or multi-line: a trailing comma
    continues the statement onto the next line)."""
    out, skip = [], False
    for line in text.splitlines():
        s = line.strip()
        if not skip and s.startswith('Export-ModuleMember'):
            skip = True
        if skip:
            if not s.endswith(','):   # last line of the statement
                skip = False
            continue
        out.append(line)
    return out


def main():
    cap = open(os.path.join(HERE, 'geomathmatical_dev.ps1'), encoding='utf-8').read().splitlines()
    single, in_import = [], False
    for line in cap:
        if '$here = Split-Path -Parent' in line:
            single += ['',
                       '# ==================== INLINED MODULES (auto-built by build_prod.py) ====================',
                       '# Do NOT edit here -- edit the .psm1 modules + geomathmatical_dev.ps1, then re-run build_prod.py.']
            for mod in ORDER:
                mtext = open(os.path.join(HERE, 'modules', mod + '.psm1'), encoding='utf-8').read()
                single += ['', '# ----- {0}.psm1 -----'.format(mod)] + strip_exports(mtext)
            single += ['# ==================== END INLINED MODULES ====================', '']
            in_import = True
            continue
        if in_import:                 # swallow the foreach { Import-Module } block
            if line.strip() == '}':
                in_import = False
            continue
        single.append(line)

    out_path = os.path.join(HERE, 'geomathmatical.ps1')
    with open(out_path, 'w', encoding='utf-8', newline='\r\n') as fh:
        fh.write('\n'.join(single) + '\n')
    print('wrote {0} ({1} lines, {2} KB)'.format(
        out_path, len(single), round(os.path.getsize(out_path) / 1024, 1)))


if __name__ == '__main__':
    main()
