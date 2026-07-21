param(
    [ValidateRange(10,600)]
    [int]$WatchSeconds = 180,

    [ValidateRange(10,180)]
    [int]$D4TimeoutSeconds = 45,

    [ValidateNotNullOrEmpty()]
    [string]$ObservedProductLabel = "TSM"
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host $Text -ForegroundColor Gray }

function Get-ProjectRoot {
    $dir = (Resolve-Path ".").Path
    while ($true) {
        if ((Test-Path (Join-Path $dir "RUN_D4_NATIVE_METACORE_EXISTING_META.ps1")) -and
            (Test-Path (Join-Path $dir "tools\mtk_meta"))) {
            return $dir
        }
        $parent = Split-Path -Parent $dir
        if (!$parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    throw "Project root not found. Run from inside the TGT ATO project."
}

function Get-MtkState {
    @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PNPDeviceID -match "VID_0E8D" -or
            $_.Name -match "MediaTek|PreLoader|VCOM|MTK|META|Android|\(COM\d+\)"
        } |
        ForEach-Object {
            $pidCode = $null
            $com = $null
            if ($_.PNPDeviceID -match "PID_([0-9A-Fa-f]{4})") { $pidCode = $Matches[1].ToUpperInvariant() }
            if ($_.Name -match "\(COM(\d+)\)") { $com = "COM$($Matches[1])" }

            $role = switch ($pidCode) {
                "2000" { "PreloaderVcom"; break }
                "2001" { "PreloaderVcomAlt"; break }
                "2007" { "KernelMetaVcom"; break }
                "201C" { "AdbAfterMeta"; break }
                "20FF" { "DirtyOrSideInterface"; break }
                default {
                    if ($_.PNPDeviceID -match "VID_0E8D") { "MediaTekOther" } else { "OtherCom" }
                }
            }

            [pscustomobject]@{
                time = (Get-Date).ToString("o")
                role = $role
                pid = $pidCode
                com = $com
                name = $_.Name
                status = $_.Status
            }
        })
}

function Get-StateKey($Rows) {
    (($Rows | Sort-Object pid,com,name | ForEach-Object { "$($_.pid)|$($_.com)|$($_.name)|$($_.status)" }) -join "`n")
}

function Quote-Arg([string]$Value) {
    '"' + ($Value -replace '"', '\"') + '"'
}

$projectRoot = Get-ProjectRoot
Set-Location $projectRoot

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$audit = Join-Path $projectRoot "audit_shared_runtime\TTG_OBSERVED_PRODUCT_HOT_PID2007_WATCH_$stamp"
New-Item -ItemType Directory -Force -Path $audit | Out-Null
$eventsPath = Join-Path $audit "usb_transition_events.jsonl"

Write-Step "TTG OBSERVED PRODUCT HOT PID_2007 WATCH"
Write-Info "Audit=$audit"
Write-Info "ObservedProduct=$ObservedProductLabel"
Write-Warn "Scope: observe USB mode transitions and attempt read-only D4 TargetVerInfo/ChipID when PID_2007 appears."
Write-Warn "Not in scope: passwords, tokens, cookies, session files, NVRAM, IMEI/SN, FRP, reset, format, unlock, write/repair."
Write-Warn "Now trigger the META operation in $ObservedProductLabel. TTG will not control it or store its private data."

$deadline = (Get-Date).AddSeconds($WatchSeconds)
$lastKey = $null
$d4Started = $false
$d4Result = $null

while ((Get-Date) -lt $deadline) {
    $rows = @(Get-MtkState)
    $key = Get-StateKey $rows
    if ($key -ne $lastKey) {
        $lastKey = $key
        $event = [ordered]@{
            time = (Get-Date).ToString("o")
            rows = $rows
        }
        ($event | ConvertTo-Json -Depth 7 -Compress) | Add-Content -LiteralPath $eventsPath -Encoding UTF8

        foreach ($row in $rows) {
            if ($row.pid -in @("2000","2001","2007","201C","20FF")) {
                Write-Host ("[{0}] {1} {2} {3}" -f $row.time, $row.role, $row.com, $row.name) -ForegroundColor Gray
            }
        }
    }

    $meta = @($rows | Where-Object { $_.pid -eq "2007" -and $_.com } | Select-Object -First 1)
    if ($meta -and !$d4Started) {
        $d4Started = $true
        Write-Ok "PID_2007 detected on $($meta.com). Attempting read-only D4 attach."

        $runner = Join-Path $projectRoot "RUN_D4_NATIVE_METACORE_EXISTING_META.ps1"
        $d4Audit = Join-Path $audit "d4_hot_attach"
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
            "-ProbeTimeoutSeconds", "20"
        )
        $arguments = (($argList | ForEach-Object { Quote-Arg ([string]$_) }) -join " ")
        $process = Start-Process -FilePath "powershell.exe" `
            -ArgumentList $arguments `
            -WorkingDirectory $projectRoot `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr `
            -WindowStyle Hidden `
            -PassThru

        if (!$process.WaitForExit($D4TimeoutSeconds * 1000)) {
            try { & taskkill.exe /PID $process.Id /T /F | Out-Null } catch { try { Stop-Process -Id $process.Id -Force } catch {} }
            "[TIMEOUT] D4 hot attach stopped after $D4TimeoutSeconds seconds." | Add-Content -LiteralPath $stderr -Encoding UTF8
        }

        $stdoutText = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw } else { "" }
        $stderrText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { "" }
        $d4Result = [ordered]@{
            exitCode = $process.ExitCode
            connectSucceeded = ($stdoutText -match "\[ret\] Connect=0")
            targetVerInfoSucceeded = ($stdoutText -match "\[ret\] TargetVerInfo=0")
            chipIdSucceeded = ($stdoutText -match "\[ret\] ChipID=0")
            timeoutSeen = ($stderrText -match "\[TIMEOUT\]")
            audit = $d4Audit
        }
        $d4Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $d4Audit "d4_hot_attach_signals.json") -Encoding UTF8
    }

    Start-Sleep -Milliseconds 80
}

$summary = [ordered]@{
    schema = "ttg.observed_product_hot_pid2007_watch.v1"
    generatedAt = (Get-Date).ToString("o")
    observedProduct = $ObservedProductLabel
    audit = $audit
    events = $eventsPath
    d4 = $d4Result
    next = "Use this transition timing to finish TTG-owned PID_2000 to PID_2007 boot path. Evidence is USB metadata and read-only D4 signals only."
}
$summary | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $audit "hot_pid2007_summary.json") -Encoding UTF8

Write-Step "WATCH COMPLETE"
Write-Host (Join-Path $audit "hot_pid2007_summary.json")
if ($d4Result -and $d4Result.connectSucceeded -and $d4Result.targetVerInfoSucceeded -and $d4Result.chipIdSucceeded) {
    Write-Ok "D4 hot attach succeeded."
    exit 0
}

Write-Warn "Watch finished. Inspect summary for PID transitions and D4 result."
exit 30
