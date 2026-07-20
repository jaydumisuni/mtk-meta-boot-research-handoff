$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "tools\mtk_meta\RUN_D5_META_INVESTIGATION_LOOP.ps1"
if (!(Test-Path $runner)) { throw "Missing D5 runner: $runner" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner @args
exit $LASTEXITCODE
