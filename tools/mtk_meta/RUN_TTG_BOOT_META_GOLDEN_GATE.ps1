param(
    [ValidateRange(20,900)]
    [int]$RawBootTimeoutSeconds = 180,

    [ValidateRange(10,240)]
    [int]$RawPostBootWaitSeconds = 90,

    [string]$RawBootModes = "METAMETA,ADVEMETA",

    [ValidateRange(10,180)]
    [int]$D4TimeoutSeconds = 90,

    [switch]$SkipRawBoot
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
    $Global:PSNativeCommandUseErrorActionPreference = $false
}

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Info([string]$Text) { Write-Host $Text -ForegroundColor Gray }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }

function Quote-Arg([string]$Value) {
    '"' + ($Value -replace '"', '\"') + '"'
}

function Get-ProjectRoot {
    $dir = (Resolve-Path ".").Path
    while ($true) {
        if ((Test-Path (Join-Path $dir "RUN_D4_NATIVE_METACORE_EXISTING_META.ps1")) -and
            (Test-Path (Join-Path $dir "tools\mtk_meta\ttg_raw_preloader_meta_boot.py"))) {
            return $dir
        }
        $parent = Split-Path -Parent $dir
        if (!$parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    throw "Project root not found. Run from inside the TGT ATO project."
}

function Test-PythonSerial([string]$PythonPath) {
    try {
        $output = & $PythonPath -c "import serial, sys; print(sys.executable); print(serial.__version__)" 2>&1
        return [pscustomobject]@{
            Ok = ($LASTEXITCODE -eq 0)
            Output = ($output -join "`n")
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Output = $_.Exception.Message }
    }
}

function Resolve-TtgPython {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $candidates = @(
        (Join-Path $ProjectRoot ".venv\Scripts\python.exe"),
        "python"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -ne "python" -and !(Test-Path -LiteralPath $candidate)) { continue }
        $probe = Test-PythonSerial -PythonPath $candidate
        if ($probe.Ok) {
            return [pscustomobject]@{
                Path = $candidate
                Probe = $probe.Output
            }
        }
        Write-Warn "Python candidate cannot import pyserial: $candidate"
        Write-Info $probe.Output
    }

    throw "No Python with pyserial is available. Install pyserial into the project venv or system Python."
}

function Get-MtkUsbState {
    $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PNPDeviceID -match "VID_0E8D" -or
            $_.Name -match "MediaTek|PreLoader|VCOM|MTK|META|Android|\(COM\d+\)"
        })

    foreach ($dev in $devices) {
        $pidCode = $null
        $com = $null
        if ($dev.PNPDeviceID -match "PID_([0-9A-Fa-f]{4})") { $pidCode = $Matches[1].ToUpperInvariant() }
        if ($dev.Name -match "\(COM(\d+)\)") { $com = "COM$($Matches[1])" }

        $role = switch ($pidCode) {
            "2000" { "PreloaderVcom"; break }
            "2001" { "PreloaderVcomAlt"; break }
            "2007" { "KernelMetaVcom"; break }
            "201C" { "AdbAfterMeta"; break }
            "20FF" { "DirtyOrSideInterface"; break }
            default {
                if ($dev.PNPDeviceID -match "VID_0E8D") { "MediaTekOther" } else { "Other" }
            }
        }

        [pscustomobject]@{
            Time = (Get-Date).ToString("o")
            Role = $role
            PID = $pidCode
            COM = $com
            Name = $dev.Name
            Status = $dev.Status
        }
    }
}

function Get-KernelMetaPort {
    @(Get-MtkUsbState | Where-Object {
        $_.PID -eq "2007" -and $_.COM -and ($_.Status -eq "OK" -or [string]::IsNullOrWhiteSpace($_.Status))
    }) | Select-Object -First 1
}

function Save-State {
    param(
        [Parameter(Mandatory)][string]$AuditRoot,
        [Parameter(Mandatory)][string]$Name
    )

    $state = @(Get-MtkUsbState)
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $AuditRoot "$Name.json") -Encoding UTF8
    $state | Export-Csv -LiteralPath (Join-Path $AuditRoot "$Name.csv") -NoTypeInformation -Encoding UTF8
    return $state
}

function Invoke-RawBoot {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$AuditRoot,
        [Parameter(Mandatory)][string]$PythonPath
    )

    $helper = Join-Path $ProjectRoot "tools\mtk_meta\ttg_raw_preloader_meta_boot.py"
    if (!(Test-Path -LiteralPath $helper)) { throw "Missing raw helper: $helper" }

    $rawAudit = Join-Path $AuditRoot "raw_preloader_meta_boot"
    New-Item -ItemType Directory -Force -Path $rawAudit | Out-Null

    $stdout = Join-Path $rawAudit "stdout.txt"
    $stderr = Join-Path $rawAudit "stderr.txt"
    $argList = @(
        "-u", $helper,
        "--audit", $rawAudit,
        "--timeout", [string]$RawBootTimeoutSeconds,
        "--post-wait", [string]$RawPostBootWaitSeconds,
        "--modes", $RawBootModes
    )
    $arguments = (($argList | ForEach-Object { Quote-Arg ([string]$_) }) -join " ")

    Write-Step "RAW PRELOADER TO KERNEL META"
    Write-Warn "Power phone fully off. Connect USB with no volume buttons when the raw helper starts."
    Write-Warn "Guard: no NVRAM write, no reset/reboot, no FRP/format/unlock/shell/ADB enable."
    Write-Info ("{0} {1}" -f (Quote-Arg $PythonPath), $arguments)

    $process = Start-Process -FilePath $PythonPath `
        -ArgumentList $arguments `
        -WorkingDirectory $ProjectRoot `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -WindowStyle Hidden `
        -PassThru

    $stdoutLines = 0
    $stderrLines = 0
    $deadline = (Get-Date).AddSeconds($RawBootTimeoutSeconds + $RawPostBootWaitSeconds + 45)
    while (!$process.HasExited) {
        foreach ($stream in @(
            @{ Path = $stdout; Prefix = "raw"; Color = "DarkGray"; Counter = [ref]$stdoutLines },
            @{ Path = $stderr; Prefix = "raw-err"; Color = "Yellow"; Counter = [ref]$stderrLines }
        )) {
            if (!(Test-Path -LiteralPath $stream.Path)) { continue }
            $lines = @(Get-Content -LiteralPath $stream.Path -ErrorAction SilentlyContinue)
            for ($i = $stream.Counter.Value; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Length -gt 0) { Write-Host "[$($stream.Prefix)] $($lines[$i])" -ForegroundColor $stream.Color }
            }
            $stream.Counter.Value = $lines.Count
        }
        if ((Get-Date) -gt $deadline) {
            Write-Warn "Raw boot helper hard timeout; stopping process tree."
            try { & taskkill.exe /PID $process.Id /T /F | Out-Null } catch { try { Stop-Process -Id $process.Id -Force } catch {} }
            "[TIMEOUT] Golden gate raw helper stopped after hard deadline." | Add-Content -LiteralPath $stderr -Encoding UTF8
            break
        }
        Start-Sleep -Milliseconds 300
    }

    try { $process.WaitForExit() } catch {}
    $rawExitCode = try { $process.ExitCode } catch { $null }

    $resultPath = Join-Path $rawAudit "raw_preloader_boot_result.json"
    $result = $null
    if (Test-Path -LiteralPath $resultPath) {
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $result | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $AuditRoot "raw_preloader_boot_result.json") -Encoding UTF8
    }

    return [pscustomobject]@{
        Audit = $rawAudit
        ExitCode = $rawExitCode
        Result = $result
    }
}

function Invoke-D4TargetRead {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$AuditRoot
    )

    $runner = Join-Path $ProjectRoot "RUN_D4_NATIVE_METACORE_EXISTING_META.ps1"
    if (!(Test-Path -LiteralPath $runner)) { throw "Missing D4 runner: $runner" }

    $d4Audit = Join-Path $AuditRoot "d4_targetverinfo_read"
    New-Item -ItemType Directory -Force -Path $d4Audit | Out-Null
    $stdout = Join-Path $d4Audit "stdout.txt"
    $stderr = Join-Path $d4Audit "stderr.txt"

    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $runner,
        "-ReadTest", "TargetVerInfo",
        "-VendorRead", "None",
        "-NativeRead", "None",
        "-DiagnosticRead", "None",
        "-ProbeTimeoutSeconds", "60"
    )
    $arguments = (($argList | ForEach-Object { Quote-Arg ([string]$_) }) -join " ")

    Write-Step "D4 READ-ONLY TARGETVERINFO"
    Write-Warn "Guard: TargetVerInfo + ChipID path only. No NVRAM, no identifiers, no write/repair/reset."

    $process = Start-Process -FilePath "powershell.exe" `
        -ArgumentList $arguments `
        -WorkingDirectory $ProjectRoot `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -WindowStyle Hidden `
        -PassThru

    if (!$process.WaitForExit($D4TimeoutSeconds * 1000)) {
        Write-Warn "D4 TargetVerInfo timed out; stopping process tree."
        try { & taskkill.exe /PID $process.Id /T /F | Out-Null } catch { try { Stop-Process -Id $process.Id -Force } catch {} }
        "[TIMEOUT] D4 TargetVerInfo stopped after $D4TimeoutSeconds seconds." | Add-Content -LiteralPath $stderr -Encoding UTF8
    }

    $stdoutText = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw } else { "" }
    $stderrText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { "" }
    $signals = [ordered]@{
        connectSucceeded = ($stdoutText -match "\[ret\] Connect=0")
        targetVerInfoSucceeded = ($stdoutText -match "\[ret\] TargetVerInfo=0")
        chipIdSucceeded = ($stdoutText -match "\[ret\] ChipID=0")
        exceptionSeen = ($stdoutText -match "\[exception\]" -or $stderrText -match "\[exception\]")
        timeoutSeen = ($stderrText -match "\[TIMEOUT\]")
    }

    $signals | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $d4Audit "d4_targetverinfo_signals.json") -Encoding UTF8
    return [pscustomobject]@{
        Audit = $d4Audit
        ExitCode = $process.ExitCode
        Signals = $signals
    }
}

$projectRoot = Get-ProjectRoot
Set-Location $projectRoot
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$audit = Join-Path $projectRoot "audit_shared_runtime\TTG_BOOT_META_GOLDEN_GATE_$stamp"
New-Item -ItemType Directory -Force -Path $audit | Out-Null

Write-Step "TTG BOOT META GOLDEN GATE"
Write-Info "ProjectRoot=$projectRoot"
Write-Info "Audit=$audit"
Write-Warn "Scope: prove PID_2000 -> PID_2007 -> D4 TargetVerInfo/ChipID only."
Write-Warn "Not in scope: ADB enable, shell, NVRAM, IMEI/SN, FRP, reset, format, unlock, write/repair."

$python = $null
if (!$SkipRawBoot) {
    $python = Resolve-TtgPython -ProjectRoot $projectRoot
    Write-Ok "Python selected: $($python.Path)"
    Write-Info $python.Probe
}

Save-State -AuditRoot $audit -Name "usb_before" | Out-Null

$rawResult = $null
if (!$SkipRawBoot) {
    $rawResult = Invoke-RawBoot -ProjectRoot $projectRoot -AuditRoot $audit -PythonPath $python.Path
} else {
    Write-Warn "Raw boot skipped. Expecting device to already be in PID_2007 Kernel META."
}

Save-State -AuditRoot $audit -Name "usb_after_raw" | Out-Null
$meta = Get-KernelMetaPort

if (!$meta) {
    $rawError = if ($rawResult -and $rawResult.Result) { [string]$rawResult.Result.error } else { "" }
    $nextStep = if ($rawError -match "unsupported") {
        "Standalone boot is blocked at the required SLA control frame. Do not guess, capture, store, or replay vendor authentication material."
    } else {
        "Retry from a fully powered-off device with no buttons. If an observed external tool still produces PID_2007, compare only its boot-token timing and serial-port settings."
    }
    $summary = [ordered]@{
        schema = "ttg.boot_meta_golden_gate.v1"
        generatedAt = (Get-Date).ToString("o")
        result = "blocked-no-pid2007"
        audit = $audit
        raw = $rawResult
        next = $nextStep
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $audit "golden_gate_summary.json") -Encoding UTF8
    Write-Warn "No live PID_2007 Kernel META port found. D4 read is skipped."
    Write-Host (Join-Path $audit "golden_gate_summary.json")
    exit 30
}

Write-Ok "Kernel META confirmed: $($meta.Name) / $($meta.COM)"
$d4 = Invoke-D4TargetRead -ProjectRoot $projectRoot -AuditRoot $audit
Save-State -AuditRoot $audit -Name "usb_after_d4" | Out-Null

$d4Pass = $d4.Signals.connectSucceeded -and $d4.Signals.targetVerInfoSucceeded -and $d4.Signals.chipIdSucceeded -and !$d4.Signals.exceptionSeen -and !$d4.Signals.timeoutSeen
$rawAttemptCount = if ($rawResult -and $rawResult.Result -and $rawResult.Result.modes_attempted) {
    @($rawResult.Result.modes_attempted).Count
} else {
    0
}
$rawTransitionProven = !$SkipRawBoot -and
    $rawResult -and
    $rawResult.Result -and
    $rawResult.Result.success -eq $true -and
    $rawResult.Result.service_kind -eq "pid2007" -and
    $rawAttemptCount -gt 0
$pass = $d4Pass -and $rawTransitionProven
$resultLabel = if ($pass) {
    "pass"
} elseif ($SkipRawBoot -and $d4Pass) {
    "attach-only-pass"
} elseif ($d4Pass) {
    "d4-pass-fresh-boot-unproven"
} else {
    "d4-read-incomplete"
}
$summary = [ordered]@{
    schema = "ttg.boot_meta_golden_gate.v1"
    generatedAt = (Get-Date).ToString("o")
    result = $resultLabel
    audit = $audit
    kernelMeta = $meta
    raw = $rawResult
    proof = [ordered]@{
        rawTransitionProven = $rawTransitionProven
        rawModesAttempted = $rawAttemptCount
        d4ReadPassed = $d4Pass
    }
    d4 = $d4
    next = if ($pass) {
        "Promote this to the TTG Boot META read-only gate and extend only non-unique target metadata coverage."
    } elseif ($SkipRawBoot -and $d4Pass) {
        "Read-only attach passed, but this run intentionally skipped raw boot and does not prove TTG PID_2000 to PID_2007 transition."
    } elseif ($d4Pass) {
        "Read-only attach passed, but no fresh TTG raw mode attempt produced PID_2007. Repeat from fully powered off and disconnected."
    } else {
        "Inspect d4_targetverinfo_read stdout/stderr and keep identifier and NV access disabled."
    }
}
$summary | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $audit "golden_gate_summary.json") -Encoding UTF8

Write-Step "GOLDEN GATE RESULT"
if ($pass) {
    Write-Ok "PASS: PID_2007 confirmed and D4 TargetVerInfo + ChipID succeeded."
    exit 0
}

if ($d4Pass) {
    Write-Warn "ATTACH-ONLY PASS: D4 read succeeded, but a fresh TTG PID_2000 -> PID_2007 transition was not proven."
    Write-Host (Join-Path $audit "golden_gate_summary.json")
    exit 35
}

Write-Warn "D4 read incomplete. Summary saved:"
Write-Host (Join-Path $audit "golden_gate_summary.json")
exit 40
