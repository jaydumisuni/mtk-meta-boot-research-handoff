# D3 - Attach to an already-existing META port and run one read-only shape.
# NO preloader boot / Init_r / GetAvailableHandle / NVRAM / reset / ADB enable /
# FRP / unlock / format / reboot.

param(
  [ValidateSet("None", "TargetVerInfo", "ChipId", "AdbStatus")]
  [string]$ReadTest = "TargetVerInfo",

  [ValidateRange(1, 600)]
  [int]$WaitSeconds = 120,

  [ValidateRange(5, 300)]
  [int]$ProbeTimeoutSeconds = 60,

  [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"

if (Get-Variable <REDACTED_HEX_IDENTIFIER> -Scope Global -ErrorAction SilentlyContinue) {
  $Global:<REDACTED_HEX_IDENTIFIER> = $false
}

$ProfileBin = ".\app\runtime\support\android\mtk\meta_backend_mtk_functions_d2g_minimal\bin"
if (!(Test-Path $ProfileBin)) {
  throw "Missing sealed D2G minimal profile: $ProfileBin"
}

$ProfileBin = (Resolve-Path $ProfileBin).Path
$Dll = Join-Path $ProfileBin "MTK_Functions.dll"
$ObjBin = Join-Path $ProfileBin "Objects"

if (!(Test-Path $Dll)) { throw "Missing MTK_Functions.dll: $Dll" }
if (!(Test-Path $ObjBin)) { throw "Missing Objects folder: $ObjBin" }

$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Audit = ".\audit_shared_runtime\TSM_MTK_FUNCTIONS_D3_ATTACH_EXISTING_META_${ReadTest}_$Stamp"
New-Item -ItemType Directory -Force -Path $Audit | Out-Null
$Audit = (Resolve-Path $Audit).Path

$Src = Join-Path $Audit "d3_attach_existing_meta.cpp"
$Obj = Join-Path $Audit "d3_attach_existing_meta.obj"
$Exe = Join-Path $Audit "d3_attach_existing_meta.exe"
$Out = Join-Path $Audit "stdout.txt"
$Err = Join-Path $Audit "stderr.txt"
$BuildLog = Join-Path $Audit "build.log"
$PortsBefore = Join-Path $Audit "ports_before.csv"
$PortsAfter = Join-Path $Audit "ports_after.csv"
$SelectedMeta = Join-Path $Audit "selected_meta_port.csv"
$SummaryPath = Join-Path $Audit "summary.json"

function Get-ComInventory {
  @(
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match "\(COM(\d+)\)" } |
      ForEach-Object {
        $_.Name -match "\(COM(\d+)\)" | Out-Null
        [pscustomobject]@{
          Com       = [int]$Matches[1]
          Name      = $_.Name
          PNPDevice = $_.PNPDeviceID
          Status    = $_.Status
        }
      } |
      Sort-Object Com
  )
}

function Get-ExistingMetaCom {
  @(
    Get-ComInventory |
      Where-Object { $_.PNPDevice -match "VID_0E8D.*PID_2007" }
  ) | Select-Object -First 1
}

Write-Host "D3 attach-to-existing-META read-only shape test" -ForegroundColor Cyan
Write-Host "ReadTest: $ReadTest" -ForegroundColor Cyan
Write-Host "NO preloader boot / Init_r / GetAvailableHandle / NVRAM / reset / ADB enable / FRP / unlock / format / reboot" -ForegroundColor Yellow
Write-Host "Audit: $Audit" -ForegroundColor Green

Get-ComInventory | Export-Csv $PortsBefore -NoTypeInformation

$Meta = $null
if (!$BuildOnly) {
  Write-Host ""
  Write-Host "Waiting only for an existing VID_0E8D PID_2007 COM port..." -ForegroundColor Cyan
  $Deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $Deadline) {
    $Meta = Get-ExistingMetaCom
    if ($Meta) { break }
    Start-Sleep -Milliseconds 150
  }

  if (!$Meta) {
    Get-ComInventory | Export-Csv $PortsAfter -NoTypeInformation
    $Summary = [pscustomobject]@{
      ReadTest       = $ReadTest
      BuildOnly      = $false
      MetaDetected   = $false
      Com            = $null
      ProbeExitCode  = $null
      Audit          = $Audit
      SafetyStop     = "No existing VID_0E8D PID_2007 COM port detected"
    }
    $Summary | ConvertTo-Json | Set-Content $SummaryPath -Encoding UTF8
    throw "No existing VID_0E8D PID_2007 COM port detected. Stopping without loading or calling MTK_Functions.dll."
  }

  $Meta | Export-Csv $SelectedMeta -NoTypeInformation
  Write-Host "Existing META port selected: COM$($Meta.Com)" -ForegroundColor Green
}

$ComNumber = if ($Meta) { [int]$Meta.Com } else { 1 }
$BinDirForC = $ProfileBin.Replace('\', '\\')
$DllForC = $Dll.Replace('\', '\\')

$ReadBody = switch ($ReadTest) {
  "None" {
@"
        printf("[read] skipped by ReadTest=None\n");
"@
  }
  "TargetVerInfo" {
@"
        if (!GetTargetVerInfo) {
            printf("[fail] _SPMeta_GetTargetVerInfo_r@12 not resolved\n");
        } else {
            GuardedBuffer out = {};
            prepare_buffer(&out);
            printf("[call] _SPMeta_GetTargetVerInfo_r@12(int selector=5, void* guardedBuffer, int size=%u)\n", (unsigned)sizeof(out.data));
            __try {
                readRet = ((FN_READ3)GetTargetVerInfo)(5, out.data, (int)sizeof(out.data));
                printf("[ret] GetTargetVerInfo=%d / 0x%08X\n", readRet, (unsigned)readRet);
                print_buffer(&out);
            } __except(EXCEPTION_EXECUTE_HANDLER) {
                printf("[exception] GetTargetVerInfo code=0x%08lX\n", GetExceptionCode());
            }
        }
"@
  }
  "ChipId" {
@"
        if (!GetChipId) {
            printf("[fail] _SPMeta_GetChipId_r@12 not resolved\n");
        } else {
            GuardedBuffer out = {};
            prepare_buffer(&out);
            printf("[call] _SPMeta_GetChipId_r@12(int timeoutMs=3000, void* guardedBuffer, int size=%u)\n", (unsigned)sizeof(out.data));
            __try {
                readRet = ((FN_READ3)GetChipId)(3000, out.data, (int)sizeof(out.data));
                printf("[ret] GetChipId=%d / 0x%08X\n", readRet, (unsigned)readRet);
                print_buffer(&out);
            } __except(EXCEPTION_EXECUTE_HANDLER) {
                printf("[exception] GetChipId code=0x%08lX\n", GetExceptionCode());
            }
        }
"@
  }
  "AdbStatus" {
@"
        if (!GetAdbStatus) {
            printf("[fail] _SPMeta_Get_AdbDebug_Status@4 not resolved\n");
        } else {
            GuardedStatus out = { CANARY, -1, CANARY };
            printf("[call] _SPMeta_Get_AdbDebug_Status@4(int* guardedStatus)\n");
            __try {
                readRet = ((FN_STATUS)GetAdbStatus)(&out.value);
                printf("[ret] GetAdbDebugStatus=%d / 0x%08X status=%d guardBefore=0x%08X guardAfter=0x%08X\n",
                    readRet, (unsigned)readRet, out.value, out.before, out.after);
            } __except(EXCEPTION_EXECUTE_HANDLER) {
                printf("[exception] GetAdbDebugStatus code=0x%08lX\n", GetExceptionCode());
            }
        }
"@
  }
}

$CSource = @"
#include <windows.h>
#include <stdio.h>
#include <ctype.h>

typedef int (__stdcall *FN0)();
typedef int (__stdcall *FN_CONNECT)(int);
typedef int (__stdcall *FN_READ3)(int, void*, int);
typedef int (__stdcall *FN_STATUS)(int*);

static const unsigned CANARY = 0xD3A77AC3u;

struct GuardedBuffer {
    unsigned before;
    unsigned char data[512];
    unsigned after;
};

struct GuardedStatus {
    unsigned before;
    int value;
    unsigned after;
};

static FARPROC resolve(HMODULE h, const char* name) {
    FARPROC p = GetProcAddress(h, name);
    printf("[resolve] %-38s = 0x%p\n", name, p);
    return p;
}

static void prepare_buffer(GuardedBuffer* out) {
    out->before = CANARY;
    out->after = CANARY;
    memset(out->data, 0, sizeof(out->data));
}

static void print_buffer(const GuardedBuffer* out) {
    printf("[guard] before=0x%08X after=0x%08X intact=%d\n",
        out->before, out->after, out->before == CANARY && out->after == CANARY);
    printf("[buffer.hex.first64]");
    for (int i = 0; i < 64; ++i) printf(" %02X", out->data[i]);
    printf("\n[buffer.ascii.first128] ");
    for (int i = 0; i < 128 && out->data[i]; ++i) {
        putchar(isprint(out->data[i]) ? out->data[i] : '.');
    }
    printf("\n");
}

int main() {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);

    const char* binDir = "$BinDirForC";
    const char* dllPath = "$DllForC";
    const int comPort = $ComNumber;

    printf("[gate] D3 attach-to-existing-META only; read shape=$ReadTest\n");
    printf("[guard] NO preloader boot / Init_r / GetAvailableHandle / NVRAM / reset / ADB enable / FRP / unlock / format / reboot\n");
    printf("[target] existing VID_0E8D PID_2007 COM%d\n", comPort);

    SetCurrentDirectoryA(binDir);
    SetDllDirectoryA(binDir);

    HMODULE h = LoadLibraryA(dllPath);
    printf("[LoadLibrary] h=0x%p gle=%lu\n", h, GetLastError());
    if (!h) return 10;

    FN0 Init = (FN0)resolve(h, "_InitMtkDll@0");
    FN0 Release = (FN0)resolve(h, "_ReleaseMtkDll@0");
    FN_CONNECT Connect = (FN_CONNECT)resolve(h, "_SPMeta_ConnectInMetaMode_r@4");
    FN0 Disconnect = (FN0)resolve(h, "_SPMeta_DisconnectInMetaMode_r@0");
    FARPROC GetTargetVerInfo = resolve(h, "_SPMeta_GetTargetVerInfo_r@12");
    FARPROC GetChipId = resolve(h, "_SPMeta_GetChipId_r@12");
    FARPROC GetAdbStatus = resolve(h, "_SPMeta_Get_AdbDebug_Status@4");

    if (!Init || !Release || !Connect || !Disconnect) {
        printf("[fail] missing required lifecycle export\n");
        FreeLibrary(h);
        return 20;
    }

    int initRet = -1;
    int connectRet = 0;
    int readRet = -1;
    int disconnectRet = -1;
    int releaseRet = -1;

    printf("[call] _InitMtkDll@0\n");
    __try {
        initRet = Init();
        printf("[ret] InitMtkDll=%d / 0x%08X\n", initRet, (unsigned)initRet);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        printf("[exception] InitMtkDll code=0x%08lX\n", GetExceptionCode());
    }

    printf("[call] _SPMeta_ConnectInMetaMode_r@4(int COM%d)\n", comPort);
    __try {
        connectRet = Connect(comPort);
        printf("[ret] ConnectInMetaMode=%d / 0x%08X success=%d\n",
            connectRet, (unsigned)connectRet, connectRet != 0);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        printf("[exception] ConnectInMetaMode code=0x%08lX\n", GetExceptionCode());
    }

    if (connectRet != 0) {
$ReadBody
        printf("[call] _SPMeta_DisconnectInMetaMode_r@0\n");
        __try {
            disconnectRet = Disconnect();
            printf("[ret] DisconnectInMetaMode=%d / 0x%08X\n", disconnectRet, (unsigned)disconnectRet);
        } __except(EXCEPTION_EXECUTE_HANDLER) {
            printf("[exception] DisconnectInMetaMode code=0x%08lX\n", GetExceptionCode());
        }
    } else {
        printf("[gate] connect did not return success; read and disconnect skipped\n");
    }

    printf("[call] _ReleaseMtkDll@0\n");
    __try {
        releaseRet = Release();
        printf("[ret] ReleaseMtkDll=%d / 0x%08X\n", releaseRet, (unsigned)releaseRet);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        printf("[exception] ReleaseMtkDll code=0x%08lX\n", GetExceptionCode());
    }

    FreeLibrary(h);
    printf("[done] init=%d connect=%d read=%d disconnect=%d release=%d\n",
        initRet, connectRet, readRet, disconnectRet, releaseRet);
    return connectRet != 0 ? 0 : 30;
}
"@

$CSource | Set-Content $Src -Encoding ASCII

$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $VsWhere)) { throw "vswhere.exe not found: $VsWhere" }

$VsPath = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$VsPath) { throw "Visual Studio C++ Build Tools not found." }

$VcVars = Join-Path $VsPath "VC\Auxiliary\Build\vcvars32.bat"
if (!(Test-Path $VcVars)) { throw "vcvars32.bat not found: $VcVars" }

$BuildBat = Join-Path $Audit "build.bat"
@"
@echo off
call "$VcVars"
cl /nologo /EHsc /MT /Fo:"$Obj" /Fe:"$Exe" "$Src"
"@ | Set-Content $BuildBat -Encoding ASCII

Write-Host ""
Write-Host "Compiling x86 probe..." -ForegroundColor Cyan
cmd.exe /c "`"$BuildBat`"" 2>&1 | Tee-Object -FilePath $BuildLog
if (!(Test-Path $Exe)) { throw "Build failed. See $BuildLog" }

if ($BuildOnly) {
  Get-ComInventory | Export-Csv $PortsAfter -NoTypeInformation
  $Summary = [pscustomobject]@{
    ReadTest       = $ReadTest
    BuildOnly      = $true
    MetaDetected   = $false
    Com            = $null
    ProbeExitCode  = $null
    Audit          = $Audit
    SafetyStop     = "Compile-only; probe was not run"
  }
  $Summary | ConvertTo-Json | Set-Content $SummaryPath -Encoding UTF8
  Write-Host "Build-only verification complete. Probe was not run." -ForegroundColor Green
  Write-Host "Audit: $Audit" -ForegroundColor Green
  return
}

$OldPath = $env:PATH
try {
  $env:PATH = "$ProfileBin;$ObjBin;$OldPath"
  Write-Host ""
  Write-Host "Running one D3 shape on existing META COM$ComNumber..." -ForegroundColor Cyan
  $Process = Start-Process -FilePath $Exe `
    -RedirectStandardOutput $Out `
    -RedirectStandardError $Err `
    -NoNewWindow `
    -PassThru
  if (!$Process.WaitForExit($ProbeTimeoutSeconds * 1000)) {
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    $Process.WaitForExit()
    $ExitCode = -2
    Add-Content -Path $Err -Value "[timeout] Probe exceeded $ProbeTimeoutSeconds seconds and was stopped."
  } else {
    $ExitCode = $Process.ExitCode
  }
} finally {
  $env:PATH = $OldPath
}

Get-ComInventory | Export-Csv $PortsAfter -NoTypeInformation

Write-Host ""
Write-Host "STDOUT:" -ForegroundColor Cyan
Get-Content $Out -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "STDERR:" -ForegroundColor Cyan
Get-Content $Err -ErrorAction SilentlyContinue

$Summary = [pscustomobject]@{
  ReadTest       = $ReadTest
  BuildOnly      = $false
  MetaDetected   = $true
  Com            = $ComNumber
  ProbeExitCode  = $ExitCode
  Audit          = $Audit
  SafetyStop     = $null
}
$Summary | ConvertTo-Json | Set-Content $SummaryPath -Encoding UTF8

Write-Host ""
Write-Host "SUMMARY:" -ForegroundColor Green
$Summary | Format-List
Write-Host "Audit: $Audit" -ForegroundColor Green


