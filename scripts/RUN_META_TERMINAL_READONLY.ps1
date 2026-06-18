# META PID_2007 terminal read-only probe
# NO write / NO reset / NO FRP / NO format / NO unlock / NO reboot
# Sends read-only AT/info commands only.

$ErrorActionPreference = "Stop"

$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Audit = ".\audit_shared_runtime\META_TERMINAL_READONLY_$Stamp"
New-Item -ItemType Directory -Force -Path $Audit | Out-Null

$Log = Join-Path $Audit "meta_terminal_readonly.txt"

function Get-MetaCom {
  @(
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
      Where-Object {
        $_.PNPDeviceID -match "VID_0E8D.*PID_2007" -and
        $_.Name -match "\(COM(\d+)\)"
      } |
      ForEach-Object {
        $_.Name -match "\(COM(\d+)\)" | Out-Null
        [pscustomobject]@{
          Com    = [int]$Matches[1]
          Name   = $_.Name
          PNP    = $_.PNPDeviceID
          Status = $_.Status
        }
      }
  ) | Select-Object -First 1
}

"[$(Get-Date)] META TERMINAL READONLY" | Tee-Object -FilePath $Log
"Guard: NO write / NO reset / NO FRP / NO format / NO unlock / NO reboot" | Tee-Object -FilePath $Log -Append

$Meta = Get-MetaCom
if (!$Meta) {
  "No VID_0E8D PID_2007 META COM port found." | Tee-Object -FilePath $Log -Append
  throw "No META COM port found."
}

"`nMETA PORT:" | Tee-Object -FilePath $Log -Append
$Meta | Format-List | Tee-Object -FilePath $Log -Append

$ComName = "COM$($Meta.Com)"

# Read-only terminal commands only.
$Commands = @(
  "AT",
  "ATE0",
  "ATI",
  "AT+GMR",
  "AT+CGMI",
  "AT+CGMM",
  "AT+CGMR",
  "AT+CGSN"
)

$Bauds = @(115200, 921600)

foreach ($Baud in $Bauds) {
  "`n===== TRY $ComName BAUD $Baud =====" | Tee-Object -FilePath $Log -Append

  $sp = New-Object System.IO.Ports.SerialPort $ComName,$Baud,None,8,one
  $sp.ReadTimeout = 1200
  $sp.WriteTimeout = 1200
  $sp.NewLine = "`r"
  $sp.DtrEnable = $true
  $sp.RtsEnable = $true

  try {
    $sp.Open()
    "OPEN OK: $ComName baud=$Baud" | Tee-Object -FilePath $Log -Append

    Start-Sleep -Milliseconds 300

    try { $sp.DiscardInBuffer() } catch {}
    try { $sp.DiscardOutBuffer() } catch {}

    foreach ($cmd in $Commands) {
      "`n>>> $cmd" | Tee-Object -FilePath $Log -Append

      try {
        $sp.Write("$cmd`r")
      } catch {
        "[write-error] $($_.Exception.Message)" | Tee-Object -FilePath $Log -Append
        continue
      }

      Start-Sleep -Milliseconds 900

      $resp = ""
      try {
        $resp = $sp.ReadExisting()
      } catch {
        $resp = ""
      }

      if ([string]::IsNullOrWhiteSpace($resp)) {
        "[no text response]" | Tee-Object -FilePath $Log -Append
      } else {
        $resp | Tee-Object -FilePath $Log -Append
      }
    }
  }
  catch {
    "[open-error] $($_.Exception.Message)" | Tee-Object -FilePath $Log -Append
  }
  finally {
    if ($sp -and $sp.IsOpen) {
      $sp.Close()
      "CLOSED $ComName" | Tee-Object -FilePath $Log -Append
    }
  }
}

"`nAudit: $Audit" | Tee-Object -FilePath $Log -Append
Write-Host "Audit: $Audit" -ForegroundColor Green


