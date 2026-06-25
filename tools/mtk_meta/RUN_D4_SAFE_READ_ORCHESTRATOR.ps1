param(
  [ValidateRange(10,300)]
  [int]$ProbeTimeoutSeconds = 60,

  [ValidateRange(20,900)]
  [int]$ModeTimeoutSeconds = 120,

  [switch]$BootIfNeeded,
  [switch]$IncludeVendorReads,
  [switch]$SkipDatabaseAcquire,
  [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host $Text -ForegroundColor Red }

function Find-ProjectRoot {
  $dir = (Resolve-Path ".").Path
  while ($true) {
    if (Test-Path (Join-Path $dir "app\runtime\support\android\mtk")) { return $dir }
    $parent = Split-Path -Parent $dir
    if (!$parent -or $parent -eq $dir) { break }
    $dir = $parent
  }
  throw "Project root not found. Run this from inside the TGT ATO project that contains app\runtime\support\android\mtk."
}

function Find-D4Runner([string]$ProjectRoot) {
  $candidates = @(
    (Join-Path $ProjectRoot "RUN_D4_NATIVE_METACORE_EXISTING_META.ps1"),
    (Join-Path $ProjectRoot "scripts\RUN_D4_NATIVE_METACORE_EXISTING_META.ps1"),
    (Join-Path $ProjectRoot "tools\mtk_meta\RUN_D4_NATIVE_METACORE_EXISTING_META.ps1")
  )
  foreach ($p in $candidates) { if (Test-Path $p) { return (Resolve-Path $p).Path } }
  $found = Get-ChildItem $ProjectRoot -Recurse -File -Filter "RUN_D4_NATIVE_METACORE_EXISTING_META.ps1" -ErrorAction SilentlyContinue |
    Sort-Object FullName |
    Select-Object -First 1
  if ($found) { return $found.FullName }
  throw "Missing RUN_D4_NATIVE_METACORE_EXISTING_META.ps1. Pull jaydumisuni/mtk-meta-boot-research-handoff into this project first."
}

function Get-MetaPort {
  Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.PNPDeviceID -match "VID_0E8D.*PID_2007" -and $_.Name -match "\(COM\d+\)" } |
    Select-Object -First 1
}

function Ensure-MtkClientMetaMode([string]$ProjectRoot) {
  $External = Join-Path $ProjectRoot "external\mtkclient-meta-mode"
  $RepoUrl = "https://github.com/jaydumisuni/mtkclient-meta-mode.git"

  if (!(Test-Path $External)) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $External) | Out-Null
    Write-Warn "Cloning META boot helper: $RepoUrl"
    git clone $RepoUrl $External
  } else {
    Write-Warn "Updating META boot helper: $External"
    Push-Location $External
    try { git pull --ff-only } finally { Pop-Location }
  }

  $MtkPy = Get-ChildItem $External -Recurse -File -Filter "mtk.py" | Select-Object -First 1
  if (!$MtkPy) { throw "mtk.py not found after cloning mtkclient-meta-mode." }

  $MtkDir = Split-Path -Parent $MtkPy.FullName
  $VenvPython = Join-Path $MtkDir ".venv\Scripts\python.exe"
  if (!(Test-Path $VenvPython)) {
    Push-Location $MtkDir
    try {
      python -m venv .venv
      & $VenvPython -m pip install --upgrade pip
      if (Test-Path ".\requirements.txt") { & $VenvPython -m pip install -r .\requirements.txt }
    } finally { Pop-Location }
  }

  return @{ Python = $VenvPython; MtkPy = $MtkPy.FullName; MtkDir = $MtkDir }
}

function Boot-ToMetaIfNeeded([string]$ProjectRoot) {
  $port = Get-MetaPort
  if ($port) { return $port }
  if (!$BootIfNeeded) { throw "No existing META PID_2007 port found. Boot phone to META first, or rerun with -BootIfNeeded." }

  Write-Step "BOOT TO META USING mtkclient-meta-mode"
  $boot = Ensure-MtkClientMetaMode $ProjectRoot
  Push-Location $boot.MtkDir
  try {
    Write-Warn "Using helper repo only for META boot. The read phase stays in D4 MetaCore."
    & $boot.Python $boot.MtkPy meta METAMETA
  } finally { Pop-Location }

  Start-Sleep -Seconds 3
  $port = Get-MetaPort
  if (!$port) { throw "META boot command completed but PID_2007 port was not detected." }
  return $port
}

function Invoke-D4Mode {
  param(
    [string]$ProjectRoot,
    [string]$Runner,
    [string]$AuditRoot,
    [string]$Label,
    [string]$VendorRead = "None",
    [string]$NativeRead = "None",
    [string]$DiagnosticRead = "None"
  )

  Write-Step "D4 READ: $Label"
  $stdout = Join-Path $AuditRoot ("{0}_stdout.txt" -f $Label)
  $stderr = Join-Path $AuditRoot ("{0}_stderr.txt" -f $Label)

  $args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $Runner,
    "-VendorRead", $VendorRead,
    "-NativeRead", $NativeRead,
    "-DiagnosticRead", $DiagnosticRead,
    "-ProbeTimeoutSeconds", $ProbeTimeoutSeconds
  )
  if ($BuildOnly) { $args += "-BuildOnly" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "powershell.exe"
  $psi.WorkingDirectory = $ProjectRoot
  foreach ($a in $args) { [void]$psi.ArgumentList.Add($a) }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $p = [System.Diagnostics.Process]::Start($psi)
  if (!$p.WaitForExit($ModeTimeoutSeconds * 1000)) {
    try { $p.Kill() } catch {}
    "[TIMEOUT] $Label killed after $ModeTimeoutSeconds seconds" | Set-Content $stdout -Encoding UTF8
    "" | Set-Content $stderr -Encoding UTF8
    Write-Bad "TIMEOUT: $Label"
    return [pscustomobject]@{ Label=$Label; ExitCode=-2; TimedOut=$true; Stdout=$stdout; Stderr=$stderr }
  }

  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $out | Set-Content $stdout -Encoding UTF8
  $err | Set-Content $stderr -Encoding UTF8

  $out | Select-String -Pattern "Platform|SoftwareVersion|BuildDate|ChipID|SpModem|APDB|MDDB|database|Barcode|IMEI|BTMAC|WIFIMAC|vendor-ret|native-read-ret|ret|exception|timeout|failed|success|Audit:" | ForEach-Object { $_.Line }

  return [pscustomobject]@{ Label=$Label; ExitCode=$p.ExitCode; TimedOut=$false; Stdout=$stdout; Stderr=$stderr }
}

$ProjectRoot = Find-ProjectRoot
Set-Location $ProjectRoot

Write-Step "PROJECT"
Write-Ok "ProjectRoot=$ProjectRoot"

$Profile = Join-Path $ProjectRoot "app\runtime\support\android\mtk\meta_backend_mtk_functions_d2g_minimal\bin"
if (!(Test-Path $Profile)) {
  throw "Missing D4 DLL profile: $Profile"
}

$Runner = Find-D4Runner $ProjectRoot
Write-Ok "D4Runner=$Runner"

Write-Step "META PORT"
$MetaPort = Boot-ToMetaIfNeeded $ProjectRoot
Write-Ok "Found: $($MetaPort.Name)"

$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$AuditRoot = Join-Path $ProjectRoot "audit_shared_runtime\D4_SAFE_READ_ORCHESTRATOR_$Stamp"
New-Item -ItemType Directory -Force $AuditRoot | Out-Null
$MetaPort | Format-List | Out-File (Join-Path $AuditRoot "meta_port.txt") -Encoding UTF8

$results = @()
$results += Invoke-D4Mode -ProjectRoot $ProjectRoot -Runner $Runner -AuditRoot $AuditRoot -Label "00_baseline" -VendorRead "None" -NativeRead "None" -DiagnosticRead "None"
$results += Invoke-D4Mode -ProjectRoot $ProjectRoot -Runner $Runner -AuditRoot $AuditRoot -Label "01_database_inventory" -VendorRead "None" -NativeRead "None" -DiagnosticRead "DatabaseFileInventory"

if (!$SkipDatabaseAcquire) {
  $results += Invoke-D4Mode -ProjectRoot $ProjectRoot -Runner $Runner -AuditRoot $AuditRoot -Label "02_database_acquire_init" -VendorRead "None" -NativeRead "None" -DiagnosticRead "DatabaseAcquireInit"
}

$results += Invoke-D4Mode -ProjectRoot $ProjectRoot -Runner $Runner -AuditRoot $AuditRoot -Label "03_native_barcode" -VendorRead "None" -NativeRead "Barcode" -DiagnosticRead "None"
$results += Invoke-D4Mode -ProjectRoot $ProjectRoot -Runner $Runner -AuditRoot $AuditRoot -Label "04_native_imei1" -VendorRead "None" -NativeRead "IMEI1" -DiagnosticRead "None"
$results += Invoke-D4Mode -ProjectRoot $ProjectRoot -Runner $Runner -AuditRoot $AuditRoot -Label "05_native_imei2" -VendorRead "None" -NativeRead "IMEI2" -DiagnosticRead "None"

if ($IncludeVendorReads) {
  $results += Invoke-D4Mode -ProjectRoot $ProjectRoot -Runner $Runner -AuditRoot $AuditRoot -Label "06_vendor_btmac" -VendorRead "BTMAC" -NativeRead "None" -DiagnosticRead "None"
  $results += Invoke-D4Mode -ProjectRoot $ProjectRoot -Runner $Runner -AuditRoot $AuditRoot -Label "07_vendor_wifimac" -VendorRead "WIFIMAC" -NativeRead "None" -DiagnosticRead "None"
  $results += Invoke-D4Mode -ProjectRoot $ProjectRoot -Runner $Runner -AuditRoot $AuditRoot -Label "08_vendor_imei" -VendorRead "IMEI" -NativeRead "None" -DiagnosticRead "None"
}

$results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $AuditRoot "orchestrator_summary.json") -Encoding UTF8

Write-Step "DONE"
Write-Ok "Audit=$AuditRoot"
Write-Warn "Next paste orchestrator_summary.json plus the *_stdout lines that contain database/native-read/vendor-ret."
