[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackendRoot,

    [string]$AuditRoot = "",

    [int]$WaitSeconds = 45,

    [switch]$Run
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($WaitSeconds -lt 5 -or $WaitSeconds -gt 180) {
    throw "WaitSeconds must be between 5 and 180."
}

$backend = (Resolve-Path -LiteralPath $BackendRoot).Path
$required = @(
    "MTK_Functions.dll",
    "Basic.dll",
    "VirtualObject.dll",
    "Objects\MTKLibMetaCoreObj00.dll",
    "MtkCoreDlls2412\MetaCore.dll",
    "plugins\platforms\qwindows.dll"
)

foreach ($relative in $required) {
    $candidate = Join-Path $backend $relative
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Matched backend is incomplete: missing $relative"
    }
}

if ([string]::IsNullOrWhiteSpace($AuditRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $AuditRoot = Join-Path $PSScriptRoot "..\..\audit_shared_runtime\TTG_MTK_FUNCTIONS_CONNECT_$stamp"
}

$audit = [IO.Path]::GetFullPath($AuditRoot)
New-Item -ItemType Directory -Path $audit -Force | Out-Null

$sourcePath = Join-Path $audit "ttg_mtk_functions_preloader_connect.cpp"
$exePath = Join-Path $audit "ttg_mtk_functions_preloader_connect.exe"
$runtimeExePath = Join-Path $backend "ttg_mtk_functions_preloader_connect.exe"
$stdoutPath = Join-Path $audit "stdout.txt"
$stderrPath = Join-Path $audit "stderr.txt"
$buildPath = Join-Path $audit "build.log"
$summaryPath = Join-Path $audit "summary.json"
$dllPath = Join-Path $backend "MTK_Functions.dll"
$objectPath = Join-Path $backend "Objects\MTKLibMetaCoreObj00.dll"
$pluginPath = Join-Path $backend "plugins\platforms"
$escapedDllPath = $dllPath.Replace('\', '\\')
$escapedObjectPath = $objectPath.Replace('\', '\\')
$escapedPluginPath = $pluginPath.Replace('\', '\\')
$escapedBackend = $backend.Replace('\', '\\')

$source = @"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <devguid.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "setupapi.lib")

typedef void (__stdcall *FN_INIT)(void);
typedef void (__stdcall *FN_RELEASE)(void);
typedef unsigned char (__stdcall *FN_CONNECT)(int, int*);

static int contains_ci(const char* text, const char* needle) {
    if (!text || !needle) return 0;
    size_t text_len = strlen(text);
    size_t needle_len = strlen(needle);
    if (needle_len > text_len) return 0;
    for (size_t i = 0; i + needle_len <= text_len; ++i) {
        if (_strnicmp(text + i, needle, needle_len) == 0) return 1;
    }
    return 0;
}

static int parse_com(const char* friendly) {
    if (!friendly) return 0;
    const char* marker = strstr(friendly, "(COM");
    if (!marker) return 0;
    int value = atoi(marker + 4);
    return value > 0 && value < 4096 ? value : 0;
}

static int find_mtk_port(const char* pid) {
    HDEVINFO set = SetupDiGetClassDevsA(&GUID_DEVCLASS_PORTS, NULL, NULL, DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return 0;

    SP_DEVINFO_DATA info;
    ZeroMemory(&info, sizeof(info));
    info.cbSize = sizeof(info);
    int found = 0;

    for (DWORD index = 0; SetupDiEnumDeviceInfo(set, index, &info); ++index) {
        char hardware[2048] = {0};
        char friendly[512] = {0};
        DWORD type = 0;
        DWORD size = 0;
        if (!SetupDiGetDeviceRegistryPropertyA(
                set, &info, SPDRP_HARDWAREID, &type,
                reinterpret_cast<PBYTE>(hardware), sizeof(hardware), &size)) {
            continue;
        }
        if (!contains_ci(hardware, "VID_0E8D") || !contains_ci(hardware, pid)) continue;
        if (!SetupDiGetDeviceRegistryPropertyA(
                set, &info, SPDRP_FRIENDLYNAME, &type,
                reinterpret_cast<PBYTE>(friendly), sizeof(friendly), &size)) {
            continue;
        }
        found = parse_com(friendly);
        if (found) break;
    }

    SetupDiDestroyDeviceInfoList(set);
    return found;
}

static FARPROC require_export(HMODULE module, const char* name) {
    FARPROC address = GetProcAddress(module, name);
    printf("[resolve] %s=%s\n", name, address ? "OK" : "MISSING");
    return address;
}

int main(int argc, char** argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);

    int wait_seconds = argc > 1 ? atoi(argv[1]) : 45;
    if (wait_seconds < 5 || wait_seconds > 180) return 2;

    printf("[guard] TTG read-only META boot transition probe\n");
    printf("[guard] Allowed calls: InitMtkDll, ConnectWithPreloader, ReleaseMtkDll\n");
    printf("[guard] No device reads, identifiers, NVRAM, writes, reset, reboot, shell, unlock, or ADB\n");

    SetCurrentDirectoryA("$escapedBackend");
    SetDllDirectoryA("$escapedBackend");
    SetEnvironmentVariableA("QT_QPA_PLATFORM_PLUGIN_PATH", "$escapedPluginPath");

    HMODULE object_preflight = LoadLibraryExA(
        "$escapedObjectPath", NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!object_preflight) {
        printf("[result] OBJECT_PREFLIGHT_FAILED code=%lu\n", GetLastError());
        return 9;
    }
    printf("[state] OBJECT_PREFLIGHT_OK\n");
    FreeLibrary(object_preflight);

    HMODULE module = LoadLibraryA("$escapedDllPath");
    if (!module) {
        printf("[result] BACKEND_LOAD_FAILED code=%lu\n", GetLastError());
        return 10;
    }

    FN_INIT init = reinterpret_cast<FN_INIT>(require_export(module, "_InitMtkDll@0"));
    FN_CONNECT connect = reinterpret_cast<FN_CONNECT>(require_export(module, "_SPMeta_ConnectWithPreloader@8"));
    FN_RELEASE release = reinterpret_cast<FN_RELEASE>(require_export(module, "_ReleaseMtkDll@0"));
    if (!init || !connect || !release) {
        FreeLibrary(module);
        return 11;
    }

    init();
    printf("[state] BACKEND_READY\n");
    printf("[action] POWER_OFF_THEN_CONNECT_WITHOUT_VOLUME_BUTTONS\n");

    DWORD deadline = GetTickCount() + static_cast<DWORD>(wait_seconds * 1000);
    int preloader_port = 0;
    while (static_cast<LONG>(deadline - GetTickCount()) > 0) {
        preloader_port = find_mtk_port("PID_2000");
        if (preloader_port) break;
        Sleep(20);
    }

    if (!preloader_port) {
        printf("[result] PRELOADER_TIMEOUT\n");
        release();
        FreeLibrary(module);
        return 20;
    }

    printf("[state] PRELOADER_FOUND com=%d\n", preloader_port);
    int output_port = 0;
    unsigned char connected = connect(preloader_port, &output_port);
    printf("[state] CONNECT_RETURN success=%u output_com=%d\n", connected ? 1 : 0, output_port);

    int meta_port = 0;
    DWORD meta_deadline = GetTickCount() + 30000;
    while (static_cast<LONG>(meta_deadline - GetTickCount()) > 0) {
        meta_port = find_mtk_port("PID_2007");
        if (meta_port) break;
        Sleep(50);
    }

    if (meta_port) {
        printf("[result] META_ENUMERATED com=%d\n", meta_port);
    } else {
        printf("[result] META_NOT_ENUMERATED\n");
    }

    release();
    FreeLibrary(module);
    return meta_port ? 0 : 30;
}
"@

Set-Content -LiteralPath $sourcePath -Value $source -Encoding ASCII

$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vsWhere -PathType Leaf)) {
    throw "Visual Studio Build Tools were not found."
}

$vsPath = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    throw "Visual C++ x86 build tools were not found."
}

$vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars32.bat"
$buildCommand = 'call "{0}" >nul && cl /nologo /EHsc /MT /W4 /Fe:"{1}" "{2}" setupapi.lib' -f $vcvars, $exePath, $sourcePath
$buildOutput = & $env:ComSpec /d /s /c $buildCommand 2>&1
$buildOutput | Set-Content -LiteralPath $buildPath -Encoding ASCII
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "TTG probe build failed. Review $buildPath"
}

Copy-Item -LiteralPath $exePath -Destination $runtimeExePath -Force
Write-Host "TTG probe staged beside its matched runtime: $runtimeExePath"
if (-not $Run) {
    Write-Host "Build-only mode. Add -Run for the controlled live transition test."
    return
}

Write-Host "Power off the phone. Connect it without holding volume buttons when the probe starts waiting."
$process = Start-Process -FilePath $runtimeExePath -ArgumentList $WaitSeconds -WorkingDirectory $backend -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden
$timeoutMs = ($WaitSeconds + 40) * 1000
if (-not $process.WaitForExit($timeoutMs)) {
    $process.Kill()
    $process.WaitForExit()
    throw "TTG probe exceeded its bounded runtime."
}

$approved = [ordered]@{
    schema = "ttg.mtk.preloader-connect.v1"
    exit_code = $process.ExitCode
    result = "UNKNOWN"
    preloader_detected = $false
    meta_detected = $false
}

$stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath } else { @() }
if ($stdout -match '^\[state\] PRELOADER_FOUND com=\d+$') { $approved.preloader_detected = $true }
if ($stdout -match '^\[result\] META_ENUMERATED com=\d+$') {
    $approved.meta_detected = $true
    $approved.result = "META_ENUMERATED"
} elseif ($stdout -contains '[result] PRELOADER_TIMEOUT') {
    $approved.result = "PRELOADER_TIMEOUT"
} elseif ($stdout -contains '[result] META_NOT_ENUMERATED') {
    $approved.result = "META_NOT_ENUMERATED"
} elseif ($process.ExitCode -ne 0) {
    $approved.result = "PROCESS_FAILED"
}

$approved | ConvertTo-Json | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host "Result: $($approved.result)"
Write-Host "Sanitized evidence: $audit"
