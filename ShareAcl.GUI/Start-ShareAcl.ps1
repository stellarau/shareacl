$here = Split-Path -Parent $PSCommandPath
& pwsh -NoProfile -File (Join-Path $here 'Start-ShareAclGui.ps1') @args