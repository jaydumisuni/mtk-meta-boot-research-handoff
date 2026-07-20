param(
  [string]$ProjectRoot = "",
  [ValidateRange(1,10)][int]$BootAttempts = 5,
  [switch]$OpenPullRequest,
  [switch]$PrepareOnly,
  [switch]$NoPublish,
  [switch]$NoBoot,
  [switch]$SkipHelperUpdate
)

$ErrorActionPreference = "Stop"
$Runner = Join-Path $PSScriptRoot "tools\mtk_meta\RUN_D5_META_FIVE_RUN_CAMPAIGN.ps1"
if (!(Test-Path $Runner)) { throw "Missing D5 runner: $Runner" }

$arguments = @(
  "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Runner,
  "-BootAttempts", [string]$BootAttempts
)
if ($ProjectRoot) { $arguments += @("-ProjectRoot", $ProjectRoot) }
if (!$NoBoot) { $arguments += "-BootIfNeeded" }
if (!$NoPublish) { $arguments += "-Publish" }
if ($OpenPullRequest) { $arguments += "-OpenPullRequest" }
if ($PrepareOnly) { $arguments += "-PrepareOnly" }
if ($SkipHelperUpdate) { $arguments += "-SkipHelperUpdate" }

& powershell.exe @arguments
exit $LASTEXITCODE
