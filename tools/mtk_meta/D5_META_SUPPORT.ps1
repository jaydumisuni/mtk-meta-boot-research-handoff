Set-StrictMode -Version Latest

function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host $Text -ForegroundColor Red }
function Quote-Arg([string]$Value) { '"' + ($Value -replace '"','\"') + '"' }

function Resolve-ResearchRepoRoot {
  return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Resolve-ProjectRoot([string]$ExplicitRoot) {
  if ($ExplicitRoot) {
    $resolved = (Resolve-Path $ExplicitRoot).Path
    if (!(Test-Path (Join-Path $resolved "app\runtime\support\android\mtk"))) {
      throw "ProjectRoot does not contain app\runtime\support\android\mtk: $resolved"
    }
    return $resolved
  }
  $dir = (Resolve-Path ".").Path
  while ($true) {
    if (Test-Path (Join-Path $dir "app\runtime\support\android\mtk")) { return $dir }
    $parent = Split-Path -Parent $dir
    if (!$parent -or $parent -eq $dir) { break }
    $dir = $parent
  }
  throw "Project root not found. Pass -ProjectRoot or run inside the TGT ATO workspace."
}

function Resolve-Python {
  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) { return @{ File = $py.Source; Prefix = @("-3") } }
  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($python) { return @{ File = $python.Source; Prefix = @() } }
  throw "Python 3 was not found."
}

function Get-MtkPnpSnapshot {
  $items = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
    $_.PNPDeviceID -match "VID_0E8D"
  })
  $observations = @()
  foreach ($item in $items) {
    $pid = $null
    if ($item.PNPDeviceID -match "PID_([0-9A-Fa-f]{4})") { $pid = $Matches[1].ToUpperInvariant() }
    $com = $null
    if ($item.Name -match "\((COM\d+)\)") { $com = $Matches[1].ToUpperInvariant() }
    $observations += [pscustomobject]@{
      Name = [string]$item.Name
      Vid = "0E8D"
      Pid = $pid
      ComPort = $com
      Pid2000 = ($pid -eq "2000")
      Pid2007 = ($pid -eq "2007")
    }
  }
  return @($observations)
}

function Get-MetaPort {
  return Get-MtkPnpSnapshot |
    Where-Object { $_.Pid2007 -and $_.ComPort } |
    Select-Object -First 1
}

function Invoke-CapturedProcess {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string[]]$ArgumentList,
    [Parameter(Mandatory=$true)][string]$WorkingDirectory,
    [Parameter(Mandatory=$true)][string]$StdoutPath,
    [Parameter(Mandatory=$true)][string]$StderrPath,
    [Parameter(Mandatory=$true)][int]$TimeoutSeconds
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.Arguments = (($ArgumentList | ForEach-Object { Quote-Arg ([string]$_) }) -join " ")
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $started = Get-Date
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  if (!$process.Start()) { throw "Failed to start process: $FilePath" }
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $timedOut = $false
  if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
    $timedOut = $true
    try {
      & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
    } catch {
      try { $process.Kill() } catch {}
    }
  }
  try { $process.WaitForExit() } catch {}
  $stdoutTask.GetAwaiter().GetResult() | Set-Content $StdoutPath -Encoding UTF8
  $stderrTask.GetAwaiter().GetResult() | Set-Content $StderrPath -Encoding UTF8
  $ended = Get-Date
  return [pscustomobject]@{
    ExitCode = $(if ($timedOut) { -2 } else { $process.ExitCode })
    TimedOut = $timedOut
    DurationSeconds = [Math]::Round(($ended - $started).TotalSeconds, 3)
    StartedAt = $started.ToUniversalTime().ToString("o")
    EndedAt = $ended.ToUniversalTime().ToString("o")
  }
}

function Ensure-MtkClientMetaMode([string]$ResolvedProjectRoot) {
  $external = Join-Path $ResolvedProjectRoot "external\mtkclient-meta-mode"
  $repoUrl = "https://github.com/jaydumisuni/mtkclient-meta-mode.git"
  if (!(Test-Path $external)) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $external) | Out-Null
    git clone $repoUrl $external
    if ($LASTEXITCODE -ne 0) { throw "Unable to clone mtkclient-meta-mode." }
  } elseif (!$SkipHelperUpdate) {
    Push-Location $external
    try {
      git pull --ff-only
      if ($LASTEXITCODE -ne 0) { throw "Unable to update mtkclient-meta-mode." }
    } finally { Pop-Location }
  }

  $mtkPy = Get-ChildItem $external -Recurse -File -Filter "mtk.py" | Select-Object -First 1
  if (!$mtkPy) { throw "mtk.py not found in mtkclient-meta-mode." }
  $mtkDir = Split-Path -Parent $mtkPy.FullName
  $venvPython = Join-Path $mtkDir ".venv\Scripts\python.exe"
  if (!(Test-Path $venvPython)) {
    Push-Location $mtkDir
    try {
      python -m venv .venv
      & $venvPython -m pip install --upgrade pip
      if (Test-Path ".\requirements.txt") {
        & $venvPython -m pip install -r .\requirements.txt
      }
      if ($LASTEXITCODE -ne 0) { throw "Failed to install META helper dependencies." }
    } finally { Pop-Location }
  }
  return @{ Python=$venvPython; MtkPy=$mtkPy.FullName; WorkingDirectory=$mtkDir }
}

function Wait-ForMetaPort([int]$Seconds, [int]$StablePolls = 2) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  $lastKey = ""
  $stableCount = 0
  do {
    $port = Get-MetaPort
    if ($port) {
      $key = "$($port.Pid)|$($port.ComPort)|$($port.Name)"
      if ($key -eq $lastKey) {
        $stableCount++
      } else {
        $lastKey = $key
        $stableCount = 1
      }
      if ($stableCount -ge $StablePolls) { return $port }
    } else {
      $lastKey = ""
      $stableCount = 0
    }
    Start-Sleep -Milliseconds 750
  } while ((Get-Date) -lt $deadline)
  return $null
}

function Start-MetaBootCampaign {
  param([string]$ResolvedProjectRoot, [string]$CampaignRoot)
  $bootStart = Get-Date
  $attempts = @()
  $before = @(Get-MtkPnpSnapshot)
  $existing = Wait-ForMetaPort 3
  if ($existing) {
    return [pscustomobject]@{
      success = $true
      existing_meta = $true
      pid_2000_observed = [bool](@($before | Where-Object { $_.Pid2000 }).Count)
      pid_2007_observed = $true
      elapsed_seconds = 0.0
      attempts = @()
      port = $existing
    }
  }
  if (!$BootIfNeeded) {
    return [pscustomobject]@{
      success = $false
      existing_meta = $false
      pid_2000_observed = [bool](@($before | Where-Object { $_.Pid2000 }).Count)
      pid_2007_observed = $false
      elapsed_seconds = 0.0
      attempts = @()
      port = $null
      reason = "PID_2007 not present and -BootIfNeeded was not supplied."
    }
  }

  $boot = Ensure-MtkClientMetaMode $ResolvedProjectRoot
  for ($attempt=1; $attempt -le $BootAttempts; $attempt++) {
    Write-Step "META BOOT ATTEMPT $attempt/$BootAttempts"
    $attemptRoot = Join-Path $CampaignRoot ("boot\attempt_{0:D2}" -f $attempt)
    New-Item -ItemType Directory -Force $attemptRoot | Out-Null
    $attemptBefore = @(Get-MtkPnpSnapshot)
    $stdout = Join-Path $attemptRoot "stdout.txt"
    $stderr = Join-Path $attemptRoot "stderr.txt"
    $process = Invoke-CapturedProcess -FilePath $boot.Python `
      -ArgumentList @($boot.MtkPy, "meta", "METAMETA") `
      -WorkingDirectory $boot.WorkingDirectory -StdoutPath $stdout `
      -StderrPath $stderr -TimeoutSeconds $BootCommandTimeoutSeconds
    $port = Wait-ForMetaPort $MetaWaitSeconds
    $attemptAfter = @(Get-MtkPnpSnapshot)
    $attempts += [pscustomobject]@{
      attempt = $attempt
      started_at = $process.StartedAt
      ended_at = $process.EndedAt
      duration_seconds = $process.DurationSeconds
      exit_code = $process.ExitCode
      timed_out = $process.TimedOut
      success = [bool]$port
      before = $attemptBefore
      after = $attemptAfter
      stdout = $stdout
      stderr = $stderr
    }
    if ($port) {
      return [pscustomobject]@{
        success = $true
        existing_meta = $false
        pid_2000_observed = [bool](@(($before+$attemptBefore+$attemptAfter) | Where-Object { $_.Pid2000 }).Count)
        pid_2007_observed = $true
        elapsed_seconds = [Math]::Round(((Get-Date)-$bootStart).TotalSeconds,3)
        attempts = $attempts
        port = $port
      }
    }
    Start-Sleep -Seconds 2
  }
  return [pscustomobject]@{
    success = $false
    existing_meta = $false
    pid_2000_observed = [bool](@($before | Where-Object { $_.Pid2000 }).Count)
    pid_2007_observed = $false
    elapsed_seconds = [Math]::Round(((Get-Date)-$bootStart).TotalSeconds,3)
    attempts = $attempts
    port = $null
    reason = "All META boot attempts completed without a stable PID_2007 port."
  }
}
