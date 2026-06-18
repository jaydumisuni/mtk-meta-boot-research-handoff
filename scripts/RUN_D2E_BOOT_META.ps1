# D2E — Boot-to-META shape test
# NO Init_r / NO GetAvailableHandle / NO read/write/reset/FRP/format/unlock
# One mode per fresh preloader plug

param(
  [ValidateRange(1,5)][int]$Mode = 1
)

$ErrorActionPreference = "Stop"

if (Get-Variable <REDACTED_HEX_IDENTIFIER> -Scope Global -ErrorAction SilentlyContinue) {
  $Global:<REDACTED_HEX_IDENTIFIER> = $false
}

$ProfileBin = ".\app\runtime\support\android\mtk\meta_backend_mtk_functions_gold\bin"
if (!(Test-Path $ProfileBin)) {
  throw "Missing sealed profile: $ProfileBin"
}

$Dll = Join-Path (Resolve-Path $ProfileBin).Path "MTK_Functions.dll"
$ObjBin = Join-Path $ProfileBin "Objects"

if (!(Test-Path $Dll)) {
  throw "Missing MTK_Functions.dll: $Dll"
}
if (!(Test-Path $ObjBin)) {
  throw "Missing Objects folder: $ObjBin"
}

$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Audit = ".\audit_shared_runtime\TSM_MTK_FUNCTIONS_D2E_BOOT_META_MODE${Mode}_$Stamp"
New-Item -ItemType Directory -Force -Path $Audit | Out-Null

$Src = Join-Path $Audit "d2e_mode${Mode}.cpp"
$Exe = Join-Path $Audit "d2e_mode${Mode}.exe"
$Out = Join-Path $Audit "stdout.txt"
$Err = Join-Path $Audit "stderr.txt"

Write-Host "D2e MODE $Mode - Boot-to-META shape test only" -ForegroundColor Cyan
Write-Host "NO Init_r / NO GetAvailableHandle / NO read/write/reset/FRP/format/unlock" -ForegroundColor Yellow
Write-Host "Audit: $Audit" -ForegroundColor Green

function Get-MtkCom {
  @(
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
      Where-Object {
        $_.PNPDeviceID -match "VID_0E8D.*PID_2000" -and
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

Write-Host ""
Write-Host "Power phone OFF. Unplug/replug USB with NO buttons." -ForegroundColor Yellow
Write-Host "Waiting for VID_0E8D PID_2000 preloader..." -ForegroundColor Cyan

$Preloader = $null
$Deadline = (Get-Date).AddSeconds(60)

while ((Get-Date) -lt $Deadline) {
  $Preloader = Get-MtkCom
  if ($Preloader) { break }
  Start-Sleep -Milliseconds 100
}

if (!$Preloader) {
  throw "No preloader detected. Stopping safely."
}

$ComNumber = [int]$Preloader.Com
Write-Host ""
Write-Host "Preloader: COM$ComNumber" -ForegroundColor Green
$Preloader | Format-List
$Preloader | Export-Csv (Join-Path $Audit "selected_preloader.csv") -NoTypeInformation

$ConnectCall = switch ($Mode) {
  1 { "_SPMeta_Preloader_BootMode@8 with (int COM$ComNumber, int timeout)" }
  2 { "_SPMeta_Preloader_BootMode@8 with (char* `"COM$ComNumber`", int timeout)" }
  3 { "_SPMeta_Preloader_BootMode@8 with (char* `"\\\\.\\COM$ComNumber`", int timeout)" }
  4 { "_SPMeta_ConnectWithPreloader@8 with (char* `"COM$ComNumber`", int timeout)" }
  5 { "_SPMeta_ConnectWithPreloader@8 with (char* `"\\\\.\\COM$ComNumber`", int timeout)" }
}

Write-Host "Testing: $ConnectCall" -ForegroundColor Cyan

$BinDirForC = ((Resolve-Path $ProfileBin).Path).Replace('\','\\')
$DllForC = $Dll.Replace('\','\\')

$ModeBody = switch ($Mode) {
  1 {
@"
    if (!BootMode) {
        printf("[fail] BootMode not resolved\n");
    } else {
        printf("[call] _SPMeta_Preloader_BootMode@8(int %d, %d)\n", comPort, timeout);
        rConn = ((int(__stdcall*)(int,int))BootMode)(comPort, timeout);
        printf("[ret] BootMode=%d / 0x%08X\n", rConn, (unsigned)rConn);
        pgle("BootMode");
    }
"@
  }
  2 {
@"
    if (!BootMode) {
        printf("[fail] BootMode not resolved\n");
    } else {
        printf("[call] _SPMeta_Preloader_BootMode@8(char* \"%s\", %d)\n", comStr, timeout);
        rConn = ((int(__stdcall*)(const char*,int))BootMode)(comStr, timeout);
        printf("[ret] BootMode=%d / 0x%08X\n", rConn, (unsigned)rConn);
        pgle("BootMode");
    }
"@
  }
  3 {
@"
    if (!BootMode) {
        printf("[fail] BootMode not resolved\n");
    } else {
        printf("[call] _SPMeta_Preloader_BootMode@8(char* \"%s\", %d)\n", devStr, timeout);
        rConn = ((int(__stdcall*)(const char*,int))BootMode)(devStr, timeout);
        printf("[ret] BootMode=%d / 0x%08X\n", rConn, (unsigned)rConn);
        pgle("BootMode");
    }
"@
  }
  4 {
@"
    if (!ConnectPre) {
        printf("[fail] ConnectPre not resolved\n");
    } else {
        printf("[call] _SPMeta_ConnectWithPreloader@8(char* \"%s\", %d)\n", comStr, timeout);
        rConn = ((int(__stdcall*)(const char*,int))ConnectPre)(comStr, timeout);
        printf("[ret] ConnectPre=%d / 0x%08X\n", rConn, (unsigned)rConn);
        pgle("ConnectPre");
    }
"@
  }
  5 {
@"
    if (!ConnectPre) {
        printf("[fail] ConnectPre not resolved\n");
    } else {
        printf("[call] _SPMeta_ConnectWithPreloader@8(char* \"%s\", %d)\n", devStr, timeout);
        rConn = ((int(__stdcall*)(const char*,int))ConnectPre)(devStr, timeout);
        printf("[ret] ConnectPre=%d / 0x%08X\n", rConn, (unsigned)rConn);
        pgle("ConnectPre");
    }
"@
  }
}

$CSource = @"
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

typedef int (__stdcall *FN0)();

static void pgle(const char* t) {
    DWORD e = GetLastError();
    char b[512] = {0};
    FormatMessageA(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL, e, 0, b, sizeof(b)-1, NULL
    );
    printf("[%s] gle=%lu %s\n", t, e, b);
    fflush(stdout);
}

static FARPROC need(HMODULE h, const char* n) {
    FARPROC p = GetProcAddress(h, n);
    printf("[resolve] %-40s = 0x%p\n", n, p);
    fflush(stdout);
    return p;
}

int main() {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);

    const char* binDir  = "$BinDirForC";
    const char* dllPath = "$DllForC";

    int comPort = $ComNumber;
    int timeout = 60000;

    char comStr[32] = {0};
    char devStr[64] = {0};

    sprintf_s(comStr, sizeof(comStr), "COM%d", comPort);
    sprintf_s(devStr, sizeof(devStr), "\\\\.\\COM%d", comPort);

    printf("[gate] D2e mode $Mode boot-to-META shape test\n");
    printf("[guard] NO Init_r / NO GetAvailableHandle / NO read/write/reset/FRP/format/unlock\n");
    printf("[target] COM%d plain=%s device=%s timeout=%d\n", comPort, comStr, devStr, timeout);
    fflush(stdout);

    SetCurrentDirectoryA(binDir);
    SetDllDirectoryA(binDir);

    HMODULE h = LoadLibraryA(dllPath);
    printf("[LoadLibrary] h=0x%p\n", h);
    pgle("LoadLibrary");

    if (!h) return 10;

    FN0 Init = (FN0)need(h, "_InitMtkDll@0");
    FN0 Release = (FN0)need(h, "_ReleaseMtkDll@0");

    FARPROC BootMode   = need(h, "_SPMeta_Preloader_BootMode@8");
    FARPROC ConnectPre = need(h, "_SPMeta_ConnectWithPreloader@8");

    need(h, "_SPMeta_SearchKernelPort@8");
    need(h, "_SPMeta_ConnectInMetaMode_r@4");
    need(h, "_SPMeta_GetAvailableHandle@0");
    need(h, "_SPMeta_Init_r@0");

    if (!Init || !Release) {
        printf("[fail] missing Init/Release\n");
        FreeLibrary(h);
        return 20;
    }

    printf("[call] _InitMtkDll@0\n");
    int rInit = Init();
    printf("[ret] InitMtkDll=%d / 0x%08X\n", rInit, (unsigned)rInit);
    pgle("Init");

    int rConn = -1;

$ModeBody

    printf("[note] No Init_r / GetAvailableHandle / read / write / reset operation was called.\n");

    printf("[call] _ReleaseMtkDll@0\n");
    int rRel = Release();
    printf("[ret] Release=%d / 0x%08X\n", rRel, (unsigned)rRel);
    pgle("Release");

    FreeLibrary(h);
    printf("[done] mode=$Mode rConn=%d\n", rConn);

    return 0;
}
"@

$CSource | Set-Content $Src -Encoding ASCII

$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $VsWhere)) {
  throw "vswhere.exe not found: $VsWhere"
}

$VsPath = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$VsPath) {
  throw "Visual Studio C++ Build Tools not found."
}

$VcVars = Join-Path $VsPath "VC\Auxiliary\Build\vcvars32.bat"
if (!(Test-Path $VcVars)) {
  throw "vcvars32.bat not found: $VcVars"
}

$BuildBat = Join-Path $Audit "build.bat"

@"
@echo off
call "$VcVars"
cl /nologo /EHsc /MT /Fe:"$Exe" "$Src"
"@ | Set-Content $BuildBat -Encoding ASCII

Write-Host ""
Write-Host "Compiling..." -ForegroundColor Cyan
cmd.exe /c "`"$BuildBat`"" 2>&1 | Tee-Object -FilePath (Join-Path $Audit "build.log")

if (!(Test-Path $Exe)) {
  throw "Build failed."
}

$OldPath = $env:PATH
$env:PATH = "$((Resolve-Path $ProfileBin).Path);$((Resolve-Path $ObjBin).Path);$OldPath"

Write-Host ""
Write-Host "Running mode $Mode on COM$ComNumber..." -ForegroundColor Cyan

$p = Start-Process -FilePath (Resolve-Path $Exe).Path `
  -RedirectStandardOutput $Out `
  -RedirectStandardError $Err `
  -NoNewWindow `
  -Wait `
  -PassThru

$env:PATH = $OldPath
$Code = $p.ExitCode

Write-Host ""
Write-Host "Exit code: $Code" -ForegroundColor Yellow

Write-Host ""
Write-Host "STDOUT:" -ForegroundColor Cyan
Get-Content $Out -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "STDERR:" -ForegroundColor Cyan
Get-Content $Err -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Watching for PID_2007 META port..." -ForegroundColor Cyan

$MetaFound = $null
$Deadline3 = (Get-Date).AddSeconds(15)

while ((Get-Date) -lt $Deadline3) {
  $MetaFound = Get-MetaCom
  if ($MetaFound) { break }
  Start-Sleep -Milliseconds 150
}

if ($MetaFound) {
  Write-Host ""
  Write-Host "PID_2007 META DETECTED:" -ForegroundColor Green
  $MetaFound | Format-List
} else {
  Write-Host "No PID_2007 META detected." -ForegroundColor DarkGray
}

$Summary = [pscustomobject]@{
  Mode          = $Mode
  Com           = $ComNumber
  ConnectShape  = $ConnectCall
  ExitCode      = $Code
  MetaDetected  = [bool]$MetaFound
  MetaCom       = if ($MetaFound) { $MetaFound.Com } else { $null }
  Audit         = $Audit
}

$Summary | ConvertTo-Json | Set-Content (Join-Path $Audit "summary.json") -Encoding UTF8

Write-Host ""
Write-Host "SUMMARY:" -ForegroundColor Green
$Summary | Format-List

Write-Host ""
Write-Host "Audit: $Audit" -ForegroundColor Green


