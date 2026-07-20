param(
  [string]$ProjectRoot = "",
  [ValidateRange(1,10)][int]$BootAttempts = 5,
  [ValidateRange(10,300)][int]$BootCommandTimeoutSeconds = 120,
  [ValidateRange(5,120)][int]$MetaWaitSeconds = 25,
  [ValidateRange(10,300)][int]$ProbeTimeoutSeconds = 60,
  [ValidateRange(20,900)][int]$RunTimeoutSeconds = 180,
  [switch]$BootIfNeeded,
  [switch]$Publish,
  [switch]$OpenPullRequest,
  [switch]$PrepareOnly,
  [switch]$SkipHelperUpdate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Support = Join-Path $PSScriptRoot "D5_META_SUPPORT.ps1"
$Builder = Join-Path $PSScriptRoot "BUILD_D5_EXPERIMENT_RUNNER.ps1"
if (!(Test-Path $Support)) { throw "Missing D5 support module: $Support" }
if (!(Test-Path $Builder)) { throw "Missing D5 runner builder: $Builder" }
. $Support
. $Builder

function Invoke-D5Experiment {
  param(
    [string]$ResolvedProjectRoot,
    [string]$GeneratedRunner,
    [string]$CampaignRoot,
    [int]$Index,
    [hashtable]$Experiment
  )
  $runId = "{0:D2}" -f $Index
  $runRoot = Join-Path $CampaignRoot ("runs\${runId}_$($Experiment.Label)")
  New-Item -ItemType Directory -Force $runRoot | Out-Null
  $before = @(Get-MtkPnpSnapshot)
  $metaBefore = Wait-ForMetaPort 3
  if (!$metaBefore) {
    throw "Stable PID_2007 disappeared before run $runId. Rerun with -BootIfNeeded."
  }

  $stdout = Join-Path $runRoot "stdout.txt"
  $stderr = Join-Path $runRoot "stderr.txt"
  Write-Step "RUN $runId/05 - $($Experiment.Label)"
  $arguments = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $GeneratedRunner,
    "-VendorRead", "None",
    "-NativeRead", $Experiment.NativeRead,
    "-DiagnosticRead", $Experiment.Diagnostic,
    "-BridgeRequestSource", $Experiment.BridgeSource,
    "-ProbeTimeoutSeconds", [string]$ProbeTimeoutSeconds
  )
  $result = Invoke-CapturedProcess -FilePath "powershell.exe" `
    -ArgumentList $arguments -WorkingDirectory $ResolvedProjectRoot `
    -StdoutPath $stdout -StderrPath $stderr -TimeoutSeconds $RunTimeoutSeconds
  $after = @(Get-MtkPnpSnapshot)
  $metaAfter = Wait-ForMetaPort 3
  if ($result.ExitCode -eq 0) {
    Write-Ok "Run $runId completed."
  } else {
    Write-Warn "Run $runId exit=$($result.ExitCode) timeout=$($result.TimedOut)"
  }

  return [pscustomobject]@{
    run_id = $runId
    label = $Experiment.Label
    bridge_source = $Experiment.BridgeSource
    native_read = $Experiment.NativeRead
    diagnostic = $Experiment.Diagnostic
    exit_code = $result.ExitCode
    timed_out = $result.TimedOut
    duration_seconds = $result.DurationSeconds
    started_at = $result.StartedAt
    ended_at = $result.EndedAt
    stdout = $stdout
    stderr = $stderr
    port_before = [pscustomobject]@{
      pid_2007 = [bool]$metaBefore
      com_port = $(if ($metaBefore) { $metaBefore.ComPort } else { $null })
      observations = $before
    }
    port_after = [pscustomobject]@{
      pid_2007 = [bool]$metaAfter
      com_port = $(if ($metaAfter) { $metaAfter.ComPort } else { $null })
      observations = $after
    }
  }
}

$ResearchRepoRoot = Resolve-ResearchRepoRoot
$ResolvedProjectRoot = Resolve-ProjectRoot $ProjectRoot
$D4Runner = Join-Path $ResearchRepoRoot "scripts\RUN_D4_NATIVE_METACORE_EXISTING_META.ps1"
$Analyzer = Join-Path $ResearchRepoRoot "tools\mtk_meta\meta_investigator.py"
$Publisher = Join-Path $ResearchRepoRoot "tools\mtk_meta\PUBLISH_D5_FINDINGS.ps1"
if (!(Test-Path $D4Runner)) { throw "Missing D4 runner: $D4Runner" }
if (!(Test-Path $Analyzer)) { throw "Missing campaign analyzer: $Analyzer" }

$Stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
$CampaignId = "D5-$Stamp"
$CampaignRoot = Join-Path $ResolvedProjectRoot "audit_shared_runtime\$CampaignId"
$GeneratedRoot = Join-Path $CampaignRoot "generated"
$SanitizedRoot = Join-Path $CampaignRoot "sanitized"
New-Item -ItemType Directory -Force $GeneratedRoot | Out-Null
$GeneratedRunner = Join-Path $GeneratedRoot "RUN_D5_NATIVE_METACORE_EXPERIMENT.ps1"
New-D5ExperimentRunner -D4Runner $D4Runner -OutputPath $GeneratedRunner

Write-Step "D5 META INVESTIGATION CAMPAIGN"
Write-Ok "Campaign=$CampaignId"
Write-Ok "ProjectRoot=$ResolvedProjectRoot"
Write-Ok "ResearchRepo=$ResearchRepoRoot"
Write-Warn "READ-ONLY: no write/reset/format/FRP/unlock/shell/reboot function is called."

if ($PrepareOnly) {
  Write-Ok "PrepareOnly complete. No device command was run."
  exit 0
}

$Boot = Start-MetaBootCampaign -ResolvedProjectRoot $ResolvedProjectRoot -CampaignRoot $CampaignRoot
$Boot | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $CampaignRoot "boot_result.json") -Encoding UTF8

if (!$Boot.success) {
  $failureManifest = [ordered]@{
    schema_version = "ttg.mtk-meta.raw-campaign.v1"
    campaign_id = $CampaignId
    created_at = (Get-Date).ToUniversalTime().ToString("o")
    research_mode = "read_only"
    write_allowed = $false
    project_root = $ResolvedProjectRoot
    research_repo_root = $ResearchRepoRoot
    boot = $Boot
    runs = @()
  }
  $failureManifest | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $CampaignRoot "campaign_manifest.json") -Encoding UTF8
  $Python = Resolve-Python
  $pythonArguments = @($Python.Prefix) + @(
    $Analyzer, "analyze", "--campaign", $CampaignRoot, "--output", $SanitizedRoot
  )
  & $Python.File @pythonArguments
  if ($Publish -and (Test-Path $Publisher)) {
    $publishArguments = @(
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Publisher,
      "-CampaignRoot", $CampaignRoot,
      "-ResearchRepoRoot", $ResearchRepoRoot
    )
    if ($OpenPullRequest) { $publishArguments += "-OpenPullRequest" }
    & powershell.exe @publishArguments
  }
  throw "META boot was not certified; findings were still analyzed."
}

$Experiments = @(
  @{ Label="fixed2_baseline"; BridgeSource="Fixed2"; NativeRead="BridgeOnly"; Diagnostic="None" },
  @{ Label="current_modem"; BridgeSource="CurrentModem"; NativeRead="BridgeOnly"; Diagnostic="ModemVersion" },
  @{ Label="connection_info0_db_inventory"; BridgeSource="ConnectionInfo0"; NativeRead="BridgeOnly"; Diagnostic="DatabaseFileInventory" },
  @{ Label="connection_info1_db_init"; BridgeSource="ConnectionInfo1"; NativeRead="Barcode"; Diagnostic="DatabaseAcquireInit" },
  @{ Label="current_modem_type_identifier"; BridgeSource="CurrentModemType"; NativeRead="IMEI1"; Diagnostic="None" }
)

$Runs = @()
for ($index = 1; $index -le $Experiments.Count; $index++) {
  $experiment = $Experiments[$index - 1]
  $Runs += Invoke-D5Experiment -ResolvedProjectRoot $ResolvedProjectRoot `
    -GeneratedRunner $GeneratedRunner -CampaignRoot $CampaignRoot `
    -Index $index -Experiment $experiment
}

$Manifest = [ordered]@{
  schema_version = "ttg.mtk-meta.raw-campaign.v1"
  campaign_id = $CampaignId
  created_at = (Get-Date).ToUniversalTime().ToString("o")
  research_mode = "read_only"
  write_allowed = $false
  project_root = $ResolvedProjectRoot
  research_repo_root = $ResearchRepoRoot
  d4_runner = $D4Runner
  generated_runner = $GeneratedRunner
  boot = $Boot
  runs = $Runs
}
$Manifest | ConvertTo-Json -Depth 14 | Set-Content (Join-Path $CampaignRoot "campaign_manifest.json") -Encoding UTF8

Write-Step "NORMALIZE - CHALLENGE - CERTIFY"
$Python = Resolve-Python
$pythonArguments = @($Python.Prefix) + @(
  $Analyzer, "analyze", "--campaign", $CampaignRoot, "--output", $SanitizedRoot
)
& $Python.File @pythonArguments
if ($LASTEXITCODE -ne 0) { throw "META campaign analysis failed." }

if ($Publish) {
  if (!(Test-Path $Publisher)) { throw "Missing publisher: $Publisher" }
  $publishArguments = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Publisher,
    "-CampaignRoot", $CampaignRoot,
    "-ResearchRepoRoot", $ResearchRepoRoot
  )
  if ($OpenPullRequest) { $publishArguments += "-OpenPullRequest" }
  & powershell.exe @publishArguments
  if ($LASTEXITCODE -ne 0) { throw "Publishing sanitized findings failed." }
}

Write-Step "DONE"
Write-Ok "Raw local audit: $CampaignRoot"
Write-Ok "Sanitized findings: $SanitizedRoot"
if ($Publish) { Write-Ok "Evidence pushed to the evidence/auto branch." }
