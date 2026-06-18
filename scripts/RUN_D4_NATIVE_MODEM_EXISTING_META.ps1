param(
  [ValidateSet("ConnectOnly","Barcode","IMEI1","IMEI2")]
  [string]$ReadTest = "ConnectOnly",
  [ValidateRange(10,180)]
  [int]$ProbeTimeoutSeconds = 60,
  [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path ".").Path
$Profile = (Resolve-Path ".\app\runtime\support\android\mtk\meta_backend_mtk_functions_d2g_minimal\bin").Path
$MetaCore = Join-Path $Profile "MetaCore.dll"
$TimeoutMs = $ProbeTimeoutSeconds * 1000
$Meta = Get-CimInstance Win32_PnPEntity | Where-Object {
  $_.PNPDeviceID -match "VID_0E8D.*PID_2007" -and $_.Name -match "\(COM(\d+)\)"
} | Select-Object -First 1
if (!$Meta) { throw "No existing VID_0E8D PID_2007 META port found." }
$Meta.Name -match "\(COM(\d+)\)" | Out-Null
$Com = [int]$Matches[1]

$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Audit = Join-Path $Root "audit_shared_runtime\D4_NATIVE_MODEM_${ReadTest}_$Stamp"
New-Item -ItemType Directory -Force $Audit | Out-Null
$Src = Join-Path $Audit "d4_native_modem.cpp"
$Exe = Join-Path $Audit "d4_native_modem.exe"
$Out = Join-Path $Audit "stdout.txt"
$Err = Join-Path $Audit "stderr.txt"
$ProfileC = $Profile.Replace('\','\\')
$MetaCoreC = $MetaCore.Replace('\','\\')

$ReadBody = switch ($ReadTest) {
  "Barcode" { 'readRet=GetBarcode(activeHandle,timeoutMs,barcode); printf("[read-ret] Barcode=%d text=%s\n",readRet,barcode); PrintHex("BarcodeRaw",(unsigned char*)barcode,64);' }
  "IMEI1" { 'imei.record=1; readRet=GetImei(activeHandle,timeoutMs,&imei); printf("[read-ret] IMEI1=%d record=%u text=%s status=%u\n",readRet,imei.record,imei.value,imei.status);' }
  "IMEI2" { 'imei.record=2; readRet=GetImei(activeHandle,timeoutMs,&imei); printf("[read-ret] IMEI2=%d record=%u text=%s status=%u\n",readRet,imei.record,imei.value,imei.status);' }
  default { 'printf("[read] connect-only run; no getter called\n");' }
}

$Code = @"
#include <windows.h>
#include <stdio.h>
#include <string.h>
typedef void (__stdcall *FN_ERROR_CALLBACK)(int);
typedef int (__stdcall *FN_INIT)(FN_ERROR_CALLBACK);
typedef int (__stdcall *FN_CONNECT)(void*,int*,void*);
typedef int (__stdcall *FN_DISCONNECT_R)(int);
typedef int (__stdcall *FN_DEINIT)();
typedef int (__stdcall *FN_BARCODE_R)(int,int,void*);
#pragma pack(push,1)
typedef struct { unsigned short record; char value[16]; unsigned char status; } IMEI_VALUE;
#pragma pack(pop)
typedef int (__stdcall *FN_IMEI_R)(int,int,IMEI_VALUE*);
typedef const char* (__stdcall *FN_BAUD_NAME)(int);
static FARPROC Resolve(HMODULE h,const char*n){FARPROC p=GetProcAddress(h,n);printf("[resolve] %s=0x%p\n",n,p);return p;}
static void __stdcall ErrorCallback(int code){printf("[callback] MetaCore error=%d\n",code);}
static void PrintHex(const char* label,const unsigned char* p,int n){printf("[info] %s=",label);for(int i=0;i<n;i++)printf("%02X",p[i]);printf("\n");}
int main(){
 setvbuf(stdout,NULL,_IONBF,0);
 SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX);
 printf("[gate] D4 native modem existing-META COM$Com read=$ReadTest\n");
 printf("[guard] dedicated read-only getter only; NO wrapper/database/generic-NVRAM/write/reset/FRP/format/unlock/shell/reboot\n");
 SetCurrentDirectoryA("$ProfileC"); SetDllDirectoryA("$ProfileC");
 HMODULE h=LoadLibraryA("$MetaCoreC"); printf("[load] MetaCore=0x%p gle=%lu\n",h,GetLastError()); if(!h)return 10;
 FN_INIT Init=(FN_INIT)Resolve(h,"META_Init");
 FN_CONNECT Connect=(FN_CONNECT)Resolve(h,"META_ConnectInMetaModeByUSB");
 FN_DISCONNECT_R Disconnect=(FN_DISCONNECT_R)Resolve(h,"META_DisconnectInMetaMode_r");
 FN_DEINIT Deinit=(FN_DEINIT)Resolve(h,"META_Deinit");
 FN_BARCODE_R GetBarcode=(FN_BARCODE_R)Resolve(h,"META_MISC_GetBarCodeValue_r");
 FN_IMEI_R GetImei=(FN_IMEI_R)Resolve(h,"META_MISC_GetIMEIValue_r");
 FN_BAUD_NAME BaudName=(FN_BAUD_NAME)Resolve(h,"META_BaudrateEnumToName");
 if(!Init||!Connect||!Disconnect||!Deinit||!GetBarcode||!GetImei)return 20;
 int initRet=-1,connectRet=-1,activeHandle=-1,readRet=-1,discRet=-1,deinitRet=-1;
 const int timeoutMs=$TimeoutMs;
 unsigned char req[512]={0},report[512]={0}; char barcode[256]={0}; IMEI_VALUE imei={0};
 if(BaudName){for(int i=0;i<=10;i++)printf("[baud-enum] %d=%s\n",i,BaudName(i));}
 *(int*)&req[0]=6; *(int*)&req[4]=-1; *(int*)&req[0x60]=$Com;
 printf("[call] META_Init(errorCallback)\n");
 __try{initRet=Init(ErrorCallback);printf("[ret] Init=%d\n",initRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] Init=0x%08lX\n",GetExceptionCode());}
 if(initRet==0){
  printf("[call] META_ConnectInMetaModeByUSB(req,outHandle,report) COM$Com\n");
  __try{connectRet=Connect(req,&activeHandle,report);printf("[ret] Connect=%d activeHandle=%d report=",connectRet,activeHandle);PrintHex("ConnectReport",report,16);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] Connect=0x%08lX\n",GetExceptionCode());}
 }
 if(connectRet==0&&activeHandle>=0){
  printf("[gate] valid modem handle; invoking one dedicated read-only getter\n");
  __try{$ReadBody}__except(EXCEPTION_EXECUTE_HANDLER){printf("[read-exception] 0x%08lX\n",GetExceptionCode());}
  printf("[call] META_DisconnectInMetaMode_r(activeHandle)\n");
  __try{discRet=Disconnect(activeHandle);printf("[ret] Disconnect=%d\n",discRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] Disconnect=0x%08lX\n",GetExceptionCode());}
 } else printf("[gate] no valid modem handle; getter skipped\n");
 printf("[call] META_Deinit()\n");
 __try{deinitRet=Deinit();printf("[ret] Deinit=%d\n",deinitRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] Deinit=0x%08lX\n",GetExceptionCode());}
 FreeLibrary(h);
 printf("[done] init=%d connect=%d active=%d read=%d disconnect=%d deinit=%d\n",initRet,connectRet,activeHandle,readRet,discRet,deinitRet);
 return connectRet==0&&activeHandle>=0?0:40;
}
"@
Set-Content -LiteralPath $Src -Value $Code -Encoding ASCII

$VsWhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$VsPath=& $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$VcVars=Join-Path $VsPath "VC\Auxiliary\Build\vcvars32.bat"
$Bat=Join-Path $Audit "build.bat"
"@echo off`r`ncall `"$VcVars`"`r`ncl /nologo /EHsc /MT /Fe:`"$Exe`" `"$Src`"" | Set-Content $Bat -Encoding ASCII
cmd.exe /c "`"$Bat`"" 2>&1 | Tee-Object (Join-Path $Audit "build.log")
if (!(Test-Path $Exe)) { throw "D4 modem build failed." }
if ($BuildOnly) { Write-Host "Build-only audit: $Audit"; return }

$OldPath=$env:PATH
try {
 $env:PATH="$Profile;$OldPath"
 $p=Start-Process $Exe -RedirectStandardOutput $Out -RedirectStandardError $Err -NoNewWindow -PassThru
 if(!$p.WaitForExit($ProbeTimeoutSeconds*1000)){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;$p.WaitForExit();Add-Content $Err "[timeout] stopped after $ProbeTimeoutSeconds seconds";$Exit=-2}else{$Exit=$p.ExitCode}
} finally {$env:PATH=$OldPath}
Get-Content $Out -ErrorAction SilentlyContinue
Get-Content $Err -ErrorAction SilentlyContinue
[pscustomobject]@{ReadTest=$ReadTest;Com=$Com;ExitCode=$Exit;Audit=$Audit}|ConvertTo-Json|Set-Content (Join-Path $Audit "summary.json")
Write-Host "Audit: $Audit"


