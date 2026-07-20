param(
  [ValidateRange(1,5)]
  [int]$MaxRuns = 5,

  [ValidateRange(10,300)]
  [int]$ProbeTimeoutSeconds = 60,

  [ValidateRange(20,900)]
  [int]$ModeTimeoutSeconds = 150,

  [ValidateRange(20,600)]
  [int]$BootTimeoutSeconds = 120,

  [switch]$SkipBoot,
  [switch]$IncludeVendorReads,

  [ValidateSet("None","Branch","PullRequest")]
  [string]$PublishMode = "PullRequest",

  [string]$HandoffRepoPath = "",
  [string]$RemoteName = "origin",
  [string]$BaseBranch = "main",
  [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$RepoSlug = "jaydumisuni/mtk-meta-boot-research-handoff"
$RepoUrl = "https://github.com/$RepoSlug.git"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Analyzer = Join-Path $ScriptRoot "d5_meta_investigator.py"

function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host $Text -ForegroundColor Red }
function Quote-Arg([string]$Value) { '"' + ($Value -replace '"','\"') + '"' }

function Invoke-CapturedProcess {
  param(
    [Parameter(Mandatory=$true)][string]$FileName,
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [Parameter(Mandatory=$true)][string]$WorkingDirectory,
    [Parameter(Mandatory=$true)][int]$TimeoutSeconds,
    [Parameter(Mandatory=$true)][string]$StdoutPath,
    [Parameter(Mandatory=$true)][string]$StderrPath
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.Arguments = (($Arguments | ForEach-Object { Quote-Arg ([string]$_) }) -join " ")
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $started = Get-Date
  $process = [System.Diagnostics.Process]::Start($psi)
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $timedOut = !$process.WaitForExit($TimeoutSeconds * 1000)
  if ($timedOut) {
    try { $process.Kill() } catch {}
    try { $process.WaitForExit(5000) | Out-Null } catch {}
  }

  $stdout = $stdoutTask.Result
  $stderr = $stderrTask.Result
  if ($timedOut) { $stderr += "`n[TIMEOUT] Process killed after $TimeoutSeconds seconds.`n" }
  $stdout | Set-Content -Path $StdoutPath -Encoding UTF8
  $stderr | Set-Content -Path $StderrPath -Encoding UTF8

  return [pscustomobject]@{
    ExitCode = if ($timedOut) { -2 } else { $process.ExitCode }
    TimedOut = $timedOut
    DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
    Stdout = $StdoutPath
    Stderr = $StderrPath
  }
}

function Find-ProjectRoot {
  $starts = New-Object System.Collections.Generic.List[string]
  if ($env:TTG_PROJECT_ROOT) { $starts.Add($env:TTG_PROJECT_ROOT) }
  $starts.Add((Get-Location).Path)
  $starts.Add($ScriptRoot)

  foreach ($start in $starts) {
    if (!(Test-Path $start)) { continue }
    $dir = (Resolve-Path $start).Path
    while ($true) {
      if (Test-Path (Join-Path $dir "app\runtime\support\android\mtk")) { return $dir }
      $parent = Split-Path -Parent $dir
      if (!$parent -or $parent -eq $dir) { break }
      $dir = $parent
    }
  }
  throw "Project root not found. Run from the TGT ATO project that contains app\runtime\support\android\mtk, or set TTG_PROJECT_ROOT."
}

function Find-D4Runner([string]$ProjectRoot) {
  $candidates = @(
    (Join-Path $ProjectRoot "RUN_D4_NATIVE_METACORE_EXISTING_META.ps1"),
    (Join-Path $ProjectRoot "scripts\RUN_D4_NATIVE_METACORE_EXISTING_META.ps1"),
    (Join-Path $ProjectRoot "tools\mtk_meta\RUN_D4_NATIVE_METACORE_EXISTING_META.ps1"),
    (Join-Path $ScriptRoot "..\..\scripts\RUN_D4_NATIVE_METACORE_EXISTING_META.ps1")
  )
  foreach ($path in $candidates) {
    if (Test-Path $path) { return (Resolve-Path $path).Path }
  }
  $found = Get-ChildItem $ProjectRoot -Recurse -File -Filter "RUN_D4_NATIVE_METACORE_EXISTING_META.ps1" -ErrorAction SilentlyContinue |
    Sort-Object FullName | Select-Object -First 1
  if ($found) { return $found.FullName }
  throw "Missing RUN_D4_NATIVE_METACORE_EXISTING_META.ps1. Pull the handoff repo into the workspace first."
}

function Get-MtkUsbSnapshot {
  $items = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.PNPDeviceID -match "VID_0E8D" } |
    ForEach-Object {
      $pid = "UNKNOWN"
      if ($_.PNPDeviceID -match "PID_([0-9A-Fa-f]{4})") { $pid = $Matches[1].ToUpperInvariant() }
      $com = $null
      if ($_.Name -match "\(COM(\d+)\)") { $com = [int]$Matches[1] }
      [pscustomobject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        pid = $pid
        com = $com
        name = $_.Name
        pnp_device_id = $_.PNPDeviceID
        status = $_.Status
      }
    })
  return $items
}

function Get-MetaPort {
  return Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.PNPDeviceID -match "VID_0E8D.*PID_2007" -and $_.Name -match "\(COM\d+\)" } |
    Select-Object -First 1
}

function Add-UsbTimeline([System.Collections.ArrayList]$Timeline) {
  foreach ($item in @(Get-MtkUsbSnapshot)) { [void]$Timeline.Add($item) }
}

function Wait-ForStableMetaPort {
  param(
    [System.Collections.ArrayList]$Timeline,
    [int]$TimeoutSeconds,
    [int]$RequiredStablePolls = 2
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastId = ""
  $stable = 0
  while ((Get-Date) -lt $deadline) {
    Add-UsbTimeline $Timeline
    $port = Get-MetaPort
    if ($port) {
      $id = "$($port.PNPDeviceID)|$($port.Name)"
      if ($id -eq $lastId) { $stable++ } else { $lastId = $id; $stable = 1 }
      if ($stable -ge $RequiredStablePolls) { return $port }
    } else {
      $lastId = ""
      $stable = 0
    }
    Start-Sleep -Milliseconds 750
  }
  return $null
}

function Ensure-MtkClientMetaMode([string]$ProjectRoot) {
  $external = Join-Path $ProjectRoot "external\mtkclient-meta-mode"
  $helperUrl = "https://github.com/jaydumisuni/mtkclient-meta-mode.git"
  if (!(Test-Path $external)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $external) | Out-Null
    Write-Warn "Cloning META boot helper: $helperUrl"
    & git clone $helperUrl $external
    if ($LASTEXITCODE -ne 0) { throw "Could not clone mtkclient-meta-mode." }
  } else {
    Write-Warn "Updating META boot helper: $external"
    & git -C $external pull --ff-only
    if ($LASTEXITCODE -ne 0) { Write-Warn "Helper update failed; using the existing local copy." }
  }

  $mtkPy = Get-ChildItem $external -Recurse -File -Filter "mtk.py" | Select-Object -First 1
  if (!$mtkPy) { throw "mtk.py not found in mtkclient-meta-mode." }
  $mtkDir = Split-Path -Parent $mtkPy.FullName
  $venvPython = Join-Path $mtkDir ".venv\Scripts\python.exe"
  if (!(Test-Path $venvPython)) {
    Push-Location $mtkDir
    try {
      & python -m venv .venv
      if ($LASTEXITCODE -ne 0) { throw "Could not create the mtkclient-meta-mode virtual environment." }
      & $venvPython -m pip install --upgrade pip
      if (Test-Path ".\requirements.txt") { & $venvPython -m pip install -r .\requirements.txt }
      if ($LASTEXITCODE -ne 0) { throw "Could not install mtkclient-meta-mode requirements." }
    } finally { Pop-Location }
  }
  return @{ Python = $venvPython; MtkPy = $mtkPy.FullName; MtkDir = $mtkDir }
}

function Ensure-MetaMode {
  param(
    [string]$ProjectRoot,
    [string]$AuditRoot,
    [System.Collections.ArrayList]$Timeline
  )
  $existing = Wait-ForStableMetaPort -Timeline $Timeline -TimeoutSeconds 3
  if ($existing) { return $existing }
  if ($SkipBoot) { throw "No existing Kernel META PID_2007 port found and -SkipBoot was selected." }

  Write-Step "BOOT TO KERNEL META"
  $helper = Ensure-MtkClientMetaMode $ProjectRoot
  $bootStdout = Join-Path $AuditRoot "00_meta_boot_stdout.txt"
  $bootStderr = Join-Path $AuditRoot "00_meta_boot_stderr.txt"
  $boot = Invoke-CapturedProcess -FileName $helper.Python -Arguments @($helper.MtkPy, "meta", "METAMETA") `
    -WorkingDirectory $helper.MtkDir -TimeoutSeconds $BootTimeoutSeconds -StdoutPath $bootStdout -StderrPath $bootStderr

  Add-UsbTimeline $Timeline
  $port = Wait-ForStableMetaPort -Timeline $Timeline -TimeoutSeconds 45
  if (!$port) {
    throw "META boot helper finished with exit $($boot.ExitCode), but stable VID_0E8D PID_2007 was not detected. Review $bootStdout and $bootStderr."
  }
  Write-Ok "Kernel META detected: $($port.Name)"
  return $port
}

function Find-Python {
  $candidates = @("py", "python")
  foreach ($name in $candidates) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
      if ($name -eq "py") { return @{ File = $cmd.Source; Prefix = @("-3") } }
      return @{ File = $cmd.Source; Prefix = @() }
    }
  }
  throw "Python 3 was not found. The D5 analyzer uses only the standard library."
}

function Invoke-D4Experiment {
  param(
    [string]$ProjectRoot,
    [string]$Runner,
    [string]$AuditRoot,
    [hashtable]$Experiment
  )

  $runId = [string]$Experiment.Id
  Write-Step "D5 RUN: $runId"
  Write-Host "Hypothesis: $($Experiment.Hypothesis)" -ForegroundColor DarkCyan
  $stdout = Join-Path $AuditRoot ("{0}_stdout.txt" -f $runId)
  $stderr = Join-Path $AuditRoot ("{0}_stderr.txt" -f $runId)
  $args = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Runner,
    "-VendorRead", [string]$Experiment.VendorRead,
    "-NativeRead", [string]$Experiment.NativeRead,
    "-DiagnosticRead", [string]$Experiment.DiagnosticRead,
    "-ProbeTimeoutSeconds", [string]$ProbeTimeoutSeconds
  )
  if ($BuildOnly) { $args += "-BuildOnly" }
  $result = Invoke-CapturedProcess -FileName "powershell.exe" -Arguments $args -WorkingDirectory $ProjectRoot `
    -TimeoutSeconds $ModeTimeoutSeconds -StdoutPath $stdout -StderrPath $stderr

  $selected = Get-Content $stdout -ErrorAction SilentlyContinue |
    Select-String -Pattern "Platform|SoftwareVersion|BuildDate|ChipID|SpModem|APDB|MDDB|database|native-read-ret|vendor-ret|ConnectModem|GetAvailableHandle|InitModemHandle|QueryCurrentModem|QueryConnectionInfo|exception|timeout|failed|success|Audit:" |
    ForEach-Object { $_.Line }
  $selected | ForEach-Object { Write-Host $_ }

  return [pscustomobject]@{
    RunId = $runId
    Label = $runId
    Hypothesis = [string]$Experiment.Hypothesis
    VendorRead = [string]$Experiment.VendorRead
    NativeRead = [string]$Experiment.NativeRead
    DiagnosticRead = [string]$Experiment.DiagnosticRead
    ExitCode = $result.ExitCode
    TimedOut = $result.TimedOut
    DurationMs = $result.DurationMs
    Stdout = $result.Stdout
    Stderr = $result.Stderr
  }
}

function Find-HandoffRepo {
  param([string]$ProjectRoot)
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($HandoffRepoPath) { $candidates.Add($HandoffRepoPath) }
  $repoCandidate = Join-Path $ScriptRoot "..\.."
  if (Test-Path $repoCandidate) { $candidates.Add((Resolve-Path $repoCandidate).Path) }
  $candidates.Add((Join-Path $ProjectRoot "external\mtk-meta-boot-research-handoff"))
  $candidates.Add((Join-Path $ProjectRoot "mtk-meta-boot-research-handoff"))

  foreach ($candidate in $candidates) {
    if (!(Test-Path $candidate)) { continue }
    $gitMarker = Join-Path $candidate ".git"
    if (Test-Path $gitMarker) { return (Resolve-Path $candidate).Path }
  }

  if ($PublishMode -eq "None") { return $null }
  $target = Join-Path $ProjectRoot "external\mtk-meta-boot-research-handoff"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
  & git clone $RepoUrl $target
  if ($LASTEXITCODE -ne 0) { throw "Could not clone $RepoUrl for evidence publishing." }
  return (Resolve-Path $target).Path
}

function Invoke-Git {
  param([string]$Repo, [string[]]$Arguments, [switch]$AllowFailure)
  $output = & git -C $Repo @Arguments 2>&1
  $code = $LASTEXITCODE
  if ($code -ne 0 -and !$AllowFailure) { throw "git $($Arguments -join ' ') failed:`n$($output -join "`n")" }
  return [pscustomobject]@{ ExitCode=$code; Output=($output -join "`n") }
}

function Publish-Evidence {
  param(
    [string]$Repo,
    [string]$RunId,
    [string]$PublicBundle
  )
  if ($PublishMode -eq "None") {
    return [pscustomobject]@{ status="SKIPPED"; mode="None"; branch=$null; pull_request=$null }
  }

  Write-Step "PUBLISH SANITIZED FINDINGS"
  Invoke-Git -Repo $Repo -Arguments @("fetch", $RemoteName, $BaseBranch) | Out-Null
  $branch = "evidence/d5-$($RunId.ToLowerInvariant())"
  $worktreeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ttg-meta-" + $RunId)
  if (Test-Path $worktreeRoot) { Remove-Item $worktreeRoot -Recurse -Force }

  try {
    Invoke-Git -Repo $Repo -Arguments @("worktree", "add", "-B", $branch, $worktreeRoot, "$RemoteName/$BaseBranch") | Out-Null
    $destination = Join-Path $worktreeRoot ("evidence\runs\$RunId")
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item (Join-Path $PublicBundle "*") $destination -Recurse -Force

    $body = @"
Automated sanitized evidence from the D5 MTK META investigation loop.

- Run: `$RunId`
- Safety: read-only
- Raw local logs: not included
- Unique device identifiers: pseudonymized

Review `evidence/runs/$RunId/findings.md` and `next_experiment.json`.
"@
    $bodyPath = Join-Path $worktreeRoot "D5_PR_BODY.md"
    $body | Set-Content $bodyPath -Encoding UTF8

    $name = (Invoke-Git -Repo $worktreeRoot -Arguments @("config", "user.name") -AllowFailure).Output.Trim()
    if (!$name) { Invoke-Git -Repo $worktreeRoot -Arguments @("config", "user.name", "TTG META Lab") | Out-Null }
    $email = (Invoke-Git -Repo $worktreeRoot -Arguments @("config", "user.email") -AllowFailure).Output.Trim()
    if (!$email) { Invoke-Git -Repo $worktreeRoot -Arguments @("config", "user.email", "ttg-meta-lab@users.noreply.github.com") | Out-Null }

    Invoke-Git -Repo $worktreeRoot -Arguments @("add", "evidence/runs/$RunId") | Out-Null
    Invoke-Git -Repo $worktreeRoot -Arguments @("commit", "-m", "Add D5 META evidence $RunId") | Out-Null
    Invoke-Git -Repo $worktreeRoot -Arguments @("push", "-u", $RemoteName, $branch) | Out-Null

    $prUrl = $null
    $status = "BRANCH_PUSHED"
    if ($PublishMode -eq "PullRequest") {
      $gh = Get-Command gh -ErrorAction SilentlyContinue
      if ($gh) {
        $prOutput = & $gh.Source pr create --repo $RepoSlug --base $BaseBranch --head $branch `
          --title "D5 META evidence $RunId" --body-file $bodyPath 2>&1
        if ($LASTEXITCODE -eq 0) {
          $prUrl = ($prOutput | Select-Object -Last 1).ToString().Trim()
          $status = "PULL_REQUEST_CREATED"
        } else {
          Write-Warn "Branch was pushed, but gh could not create the PR: $($prOutput -join ' ')"
        }
      } else {
        Write-Warn "GitHub CLI not found; the evidence branch was pushed without a PR."
      }
    }
    return [pscustomobject]@{ status=$status; mode=$PublishMode; branch=$branch; pull_request=$prUrl }
  } finally {
    if (Test-Path $worktreeRoot) {
      Invoke-Git -Repo $Repo -Arguments @("worktree", "remove", "--force", $worktreeRoot) -AllowFailure | Out-Null
      if (Test-Path $worktreeRoot) { Remove-Item $worktreeRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
}

$ProjectRoot = Find-ProjectRoot
Set-Location $ProjectRoot
$Runner = Find-D4Runner $ProjectRoot
if (!(Test-Path $Analyzer)) { throw "Missing D5 analyzer: $Analyzer" }

$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RunId = "D5_$Stamp"
$AuditRoot = Join-Path $ProjectRoot "audit_shared_runtime\$RunId"
$PublicBundle = Join-Path $AuditRoot "public_evidence"
New-Item -ItemType Directory -Force -Path $AuditRoot | Out-Null

Write-Step "D5 META INVESTIGATION LOOP"
Write-Ok "ProjectRoot=$ProjectRoot"
Write-Ok "D4Runner=$Runner"
Write-Ok "AuditRoot=$AuditRoot"
Write-Warn "Raw logs remain local. Only sanitized evidence can be published."

$timeline = New-Object System.Collections.ArrayList
Add-UsbTimeline $timeline
$metaPort = Ensure-MetaMode -ProjectRoot $ProjectRoot -AuditRoot $AuditRoot -Timeline $timeline
Add-UsbTimeline $timeline
$metaPort | Format-List | Out-File (Join-Path $AuditRoot "meta_port.txt") -Encoding UTF8
$timeline | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $AuditRoot "usb_timeline.json") -Encoding UTF8

$experiments = @(
  @{ Id="01_baseline_attach"; VendorRead="None"; NativeRead="None"; DiagnosticRead="None"; Hypothesis="Prove AP-side existing-META attach, target version, chip ID, modem inventory, and clean disconnect." },
  @{ Id="02_database_inventory"; VendorRead="None"; NativeRead="None"; DiagnosticRead="DatabaseFileInventory"; Hypothesis="Prove APDB/MDDB visibility and collect database candidates without receiving or writing records." },
  @{ Id="03_database_acquire_init"; VendorRead="None"; NativeRead="None"; DiagnosticRead="DatabaseAcquireInit"; Hypothesis="Test whether matched APDB acquisition and host-side NVRAM parser initialization change identifier return codes." },
  @{ Id="04_native_barcode"; VendorRead="None"; NativeRead="Barcode"; DiagnosticRead="None"; Hypothesis="Test a read-only identifier through the dedicated modem bridge, with AP-side fallback only where already allowlisted." },
  @{ Id="05_native_imei1"; VendorRead=$(if ($IncludeVendorReads) { "IMEI" } else { "None" }); NativeRead="IMEI1"; DiagnosticRead="None"; Hypothesis="Test whether the dedicated MD/NVRAM handle is usable for one read-only IMEI record and compare native/vendor lanes when requested." }
)

$results = New-Object System.Collections.ArrayList
foreach ($experiment in ($experiments | Select-Object -First $MaxRuns)) {
  $result = Invoke-D4Experiment -ProjectRoot $ProjectRoot -Runner $Runner -AuditRoot $AuditRoot -Experiment $experiment
  [void]$results.Add($result)
  Add-UsbTimeline $timeline
  $timeline | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $AuditRoot "usb_timeline.json") -Encoding UTF8
}

$summary = [ordered]@{
  schema_version = "d5-orchestrator/1.0"
  run_id = $RunId
  created_at = (Get-Date).ToUniversalTime().ToString("o")
  project_root = $ProjectRoot
  meta_port = $metaPort.Name
  max_runs = $MaxRuns
  safety = [ordered]@{
    mode = "READ_ONLY"
    writes = $false
    resets = $false
    frp = $false
    format = $false
    unlock = $false
  }
  runs = @($results)
}
$summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $AuditRoot "orchestrator_summary.json") -Encoding UTF8

Write-Step "ANALYZE AND SANITIZE"
$python = Find-Python
$analyzerStdout = Join-Path $AuditRoot "d5_analyzer_stdout.txt"
$analyzerStderr = Join-Path $AuditRoot "d5_analyzer_stderr.txt"
$analyzerArgs = @($python.Prefix) + @($Analyzer, "analyze", "--input", $AuditRoot, "--output", $PublicBundle, "--run-id", $RunId, "--project-root", $ProjectRoot)
$analyzerResult = Invoke-CapturedProcess -FileName $python.File -Arguments $analyzerArgs -WorkingDirectory $ProjectRoot `
  -TimeoutSeconds 120 -StdoutPath $analyzerStdout -StderrPath $analyzerStderr
if ($analyzerResult.ExitCode -ne 0) {
  throw "D5 analyzer failed. Review $analyzerStdout and $analyzerStderr."
}
Get-Content $analyzerStdout | ForEach-Object { Write-Host $_ }

$repo = Find-HandoffRepo -ProjectRoot $ProjectRoot
$publish = if ($PublishMode -eq "None") {
  [pscustomobject]@{ status="SKIPPED"; mode="None"; branch=$null; pull_request=$null }
} else {
  Publish-Evidence -Repo $repo -RunId $RunId -PublicBundle $PublicBundle
}
$publish | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $AuditRoot "publish_result.json") -Encoding UTF8

Write-Step "DONE"
Write-Ok "Local raw audit: $AuditRoot"
Write-Ok "Sanitized evidence: $PublicBundle"
Write-Ok "Publish status: $($publish.status)"
if ($publish.branch) { Write-Ok "Evidence branch: $($publish.branch)" }
if ($publish.pull_request) { Write-Ok "Pull request: $($publish.pull_request)" }
Write-Warn "Pull the next patch from the handoff repo after the evidence PR is reviewed."
