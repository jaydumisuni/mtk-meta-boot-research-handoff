# D3B - Attach to an existing META port through MetaApp wrapper, then run one
# approved read-only shape. No preloader boot or device modification calls.

param(
  [ValidateSet("None", "TargetVerInfo", "ChipId", "AdbStatus")]
  [string]$ReadTest = "None",
  [ValidateSet(0, 1)]
  [int]$ConnectMode = 0,
  [ValidateRange(5, 180)]
  [int]$ProbeTimeoutSeconds = 45,
  [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"
$Profile = (Resolve-Path ".\app\runtime\support\android\mtk\meta_backend_mtk_functions_d2g_minimal\bin").Path
$MetaApp = Join-Path $Profile "MtkCoreDlls2412\MetaApp.dll"
$MtkFunctions = Join-Path $Profile "MTK_Functions.dll"
if (!(Test-Path $MetaApp) -or !(Test-Path $MtkFunctions)) { throw "D3G profile is incomplete." }

$Meta = @(
  Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.PNPDeviceID -match "VID_0E8D.*PID_2007" -and $_.Name -match "\(COM(\d+)\)" } |
    ForEach-Object {
      $_.Name -match "\(COM(\d+)\)" | Out-Null
      [pscustomobject]@{ Com=[int]$Matches[1]; Name=$_.Name; PNPDeviceID=$_.PNPDeviceID; Status=$_.Status }
    }
) | Select-Object -First 1
if (!$Meta -and !$BuildOnly) { throw "No existing VID_0E8D PID_2007 META COM port found." }

$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Audit = ".\audit_shared_runtime\TSM_MTK_FUNCTIONS_D3B_WRAPPER_${ReadTest}_MODE${ConnectMode}_$Stamp"
New-Item -ItemType Directory -Force -Path $Audit | Out-Null
$Audit = (Resolve-Path $Audit).Path
$Meta | Export-Csv (Join-Path $Audit "selected_meta_port.csv") -NoTypeInformation

$Src = Join-Path $Audit "d3b_wrapper.cpp"
$Obj = Join-Path $Audit "d3b_wrapper.obj"
$Exe = Join-Path $Audit "d3b_wrapper.exe"
$Out = Join-Path $Audit "stdout.txt"
$Err = Join-Path $Audit "stderr.txt"

$ProfileC = $Profile.Replace('\','\\')
$MetaAppC = $MetaApp.Replace('\','\\')
$MtkFunctionsC = $MtkFunctions.Replace('\','\\')
$Com = [int]$Meta.Com

$ReadBody = switch ($ReadTest) {
  "None" { 'printf("[read] skipped by ReadTest=None\n");' }
  "TargetVerInfo" { @'
if (GetTargetVerInfo) {
    char out[512] = {0};
    printf("[call] _SPMeta_GetTargetVerInfo_r@12(selector=5,buffer,512)\n");
    __try {
        readRet = ((FN_READ3)GetTargetVerInfo)(5, out, sizeof(out));
        printf("[ret] TargetVerInfo=%d text=%s\n", readRet, out);
    } __except(EXCEPTION_EXECUTE_HANDLER) { printf("[exception] TargetVerInfo=0x%08lX\n", GetExceptionCode()); }
}
'@ }
  "ChipId" { @'
if (GetChipId) {
    char out[128] = {0};
    printf("[call] _SPMeta_GetChipId_r@12(timeout=3000,buffer,128)\n");
    __try {
        readRet = ((FN_READ3)GetChipId)(3000, out, sizeof(out));
        printf("[ret] ChipId=%d text=%s\n", readRet, out);
    } __except(EXCEPTION_EXECUTE_HANDLER) { printf("[exception] ChipId=0x%08lX\n", GetExceptionCode()); }
}
'@ }
  "AdbStatus" { @'
if (GetAdbStatus) {
    int status = -1;
    printf("[call] _SPMeta_Get_AdbDebug_Status@4(int*)\n");
    __try {
        readRet = ((FN_STATUS)GetAdbStatus)(&status);
        printf("[ret] AdbStatus=%d status=%d\n", readRet, status);
    } __except(EXCEPTION_EXECUTE_HANDLER) { printf("[exception] AdbStatus=0x%08lX\n", GetExceptionCode()); }
}
'@ }
}

$Code = @"
#include <windows.h>
#include <stdio.h>
typedef int (__stdcall *FN0)();

typedef int (__stdcall *FN_STATUS)(int*);
typedef int (__stdcall *FN2)(int,int);
typedef int (__stdcall *FN_HANDLE)(int,void**);
typedef int (__stdcall *FN_GET_HANDLES)(void**,void**);
typedef void (__stdcall *FN_SET_HANDLES)(void*,void*);
typedef int (__stdcall *FN1)(int);
typedef int (__stdcall *FN_READ3)(int,void*,int);
typedef unsigned char (__stdcall *FN_TEXT_STATUS)(char*);
static FARPROC r(HMODULE h,const char*n){FARPROC p=GetProcAddress(h,n);printf("[resolve] %s=0x%p\n",n,p);return p;}
int main(){
 setvbuf(stdout,NULL,_IONBF,0); setvbuf(stderr,NULL,_IONBF,0);
 SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX);
 printf("[gate] D3B wrapper-first existing META; shape=$ReadTest mode=$ConnectMode COM$Com\n");
 printf("[guard] NO preloader boot / NVRAM / reset / ADB enable / FRP / unlock / format / reboot / shell; existing-META kernel-hold attach\n");
 SetCurrentDirectoryA("$ProfileC"); SetDllDirectoryA("$ProfileC");
 HMODULE wm=LoadLibraryA("$MetaAppC"); HMODULE mf=LoadLibraryA("$MtkFunctionsC");
 printf("[load] MetaApp=0x%p MTK_Functions=0x%p\n",wm,mf); if(!wm||!mf)return 10;
 FN0 Init=(FN0)r(wm,"_SP_META_Wrapper_Init@0");
 FN2 Connect=(FN2)r(wm,"_SP_META_Wrapper_ConnectTargetByUsb@8");
 FN_HANDLE GetHandle=(FN_HANDLE)r(wm,"_SP_META_Wrapper_GetSPMetaHandle@8");
 FN1 Disconnect=(FN1)r(wm,"_SP_META_Wrapper_DisconnectInMetaMode_r@4");
 FN0 MdInit=(FN0)r(mf,"_MDMeta_Init_r@0");
 FN0 MdInitEx2=(FN0)r(mf,"_MDMeta_Init_Ex_2_r@0");
 FN0 InitMtk=(FN0)r(mf,"_InitMtkDll@0");
 FN0 SpAvailable=(FN0)r(mf,"_SPMeta_GetAvailableHandle@0");
 FN0 SpInit=(FN0)r(mf,"_SPMeta_Init_r@0");
 FN_GET_HANDLES GetMtkHandles=(FN_GET_HANDLES)r(mf,"_GetMtkHandle@8");
 FN_SET_HANDLES SetMtkHandles=(FN_SET_HANDLES)r(mf,"_SetMtkHandle@8");
 FN_TEXT_STATUS GetSlaStatus=(FN_TEXT_STATUS)r(mf,"_META_GetSlaStatus_r@4");
 FN_TEXT_STATUS VerifySla=(FN_TEXT_STATUS)r(mf,"_META_VerifySla_r@4");
 FN0 ReleaseMtk=(FN0)r(mf,"_ReleaseMtkDll@0");
 FARPROC GetTargetVerInfo=r(mf,"_SPMeta_GetTargetVerInfo_r@12");
 FARPROC GetChipId=r(mf,"_SPMeta_GetChipId_r@12");
 FARPROC GetAdbStatus=r(mf,"_SPMeta_Get_AdbDebug_Status@4");
 if(!Init||!Connect||!GetHandle||!Disconnect)return 20;
 int mdInitRet=-1,mdInitEx2Ret=-1,spPreInitRet=-1,initRet=-1,connectRet=-1,handleRet=-1,readRet=-1,disconnectRet=-1,releaseRet=-1,spHandle=0; void* hp=NULL; void* fp=NULL;
 printf("[call] _MDMeta_Init_r@0\n");
 __try{mdInitRet=MdInit?MdInit():-1;printf("[ret] MDMetaInit=%d\n",mdInitRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] MDMetaInit=0x%08lX\n",GetExceptionCode());}
 printf("[call] _MDMeta_Init_Ex_2_r@0\n");
 __try{mdInitEx2Ret=MdInitEx2?MdInitEx2():-1;printf("[ret] MDMetaInitEx2=%d\n",mdInitEx2Ret);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] MDMetaInitEx2=0x%08lX\n",GetExceptionCode());}
 printf("[call] _SPMeta_Init_r@0 kernel-hold pre-attach\n");
 __try{spPreInitRet=SpInit?SpInit():-1;printf("[ret] SPMetaPreInit=%d\n",spPreInitRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SPMetaPreInit=0x%08lX\n",GetExceptionCode());}
 printf("[call] _SP_META_Wrapper_Init@0\n");
 __try{initRet=Init();printf("[ret] WrapperInit=%d success=%d\n",initRet,initRet==0);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] WrapperInit=0x%08lX\n",GetExceptionCode());}
 if(initRet==0){
  printf("[call] _SP_META_Wrapper_ConnectTargetByUsb@8(COM$Com,mode=$ConnectMode)\n");
  __try{connectRet=Connect($Com,$ConnectMode);printf("[ret] WrapperConnect=%d success=%d\n",connectRet,connectRet==0||connectRet==2);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] WrapperConnect=0x%08lX\n",GetExceptionCode());}
 }
 if(connectRet==0||connectRet==2){
  printf("[call] _SP_META_Wrapper_GetSPMetaHandle@8(slot=0,out)\n");
  __try{handleRet=GetHandle(0,&hp);spHandle=(int)(INT_PTR)hp;printf("[ret] GetHandle=%d handle=%d/0x%p success=%d\n",handleRet,spHandle,hp,handleRet==0&&spHandle!=0);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] GetHandle=0x%08lX\n",GetExceptionCode());}
 }
 if((connectRet==0||connectRet==2)&&spHandle==0){
  printf("[call] _InitMtkDll@0 post-connect\n");
  __try{int x=InitMtk?InitMtk():-1;printf("[ret] InitMtkDll=%d\n",x);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] InitMtkDll=0x%08lX\n",GetExceptionCode());}
  printf("[call] _SPMeta_GetAvailableHandle@0 post-connect\n");
  __try{int x=SpAvailable?SpAvailable():-1;printf("[ret] SPMetaAvailable=%d\n",x);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SPMetaAvailable=0x%08lX\n",GetExceptionCode());}
   printf("[call] _SPMeta_Init_r@0 post-connect\n");
   __try{int x=SpInit?SpInit():-1;printf("[ret] SPMetaInit=%d\n",x);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SPMetaInit=0x%08lX\n",GetExceptionCode());}
  }
  if(spHandle==0){
   printf("[call] _GetMtkHandle@8(outSP,outFP) post-connect\n");
  __try{handleRet=GetMtkHandles?GetMtkHandles(&hp,&fp):-1;spHandle=(int)(INT_PTR)hp;printf("[ret] GetMtkHandle=%d SP=%d/0x%p FP=0x%p success=%d\n",handleRet,spHandle,hp,fp,handleRet!=0&&spHandle!=0);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] GetMtkHandle=0x%08lX\n",GetExceptionCode());}
 }
 if(spHandle!=0&&SetMtkHandles){
  printf("[call] _SetMtkHandle@8(SP,FP)\n");
  __try{SetMtkHandles(hp,fp);printf("[ret] SetMtkHandle completed\n");}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SetMtkHandle=0x%08lX\n",GetExceptionCode());}
 }
 if(spHandle!=0&&GetSlaStatus){
  char slaBefore[65536]={0},slaVerify[65536]={0},slaAfter[65536]={0};
  printf("[call] _META_GetSlaStatus_r@4(text-buffer) before\n");
  __try{unsigned char x=GetSlaStatus(slaBefore);printf("[ret] GetSlaStatusBefore=%u text=%s\n",(unsigned)x,slaBefore);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] GetSlaStatusBefore=0x%08lX\n",GetExceptionCode());}
  printf("[guard] VerifySla skipped on existing-META kernel hold because it blocks this session\n");
 }
 if(spHandle!=0){
$ReadBody
 }
 if(connectRet==0||connectRet==2){
  printf("[call] _SP_META_Wrapper_DisconnectInMetaMode_r@4(slot=0)\n");
  __try{disconnectRet=Disconnect(0);printf("[ret] WrapperDisconnect=%d\n",disconnectRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] WrapperDisconnect=0x%08lX\n",GetExceptionCode());}
 }
 if(ReleaseMtk){
  printf("[call] _ReleaseMtkDll@0\n");
  __try{releaseRet=ReleaseMtk();printf("[ret] ReleaseMtkDll=%d\n",releaseRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] ReleaseMtkDll=0x%08lX\n",GetExceptionCode());}
 }
 FreeLibrary(mf);FreeLibrary(wm);
 printf("[done] mdInit=%d mdInitEx2=%d spPreInit=%d init=%d wrapperConnect=%d handleRet=%d handle=%d read=%d disconnect=%d release=%d\n",mdInitRet,mdInitEx2Ret,spPreInitRet,initRet,connectRet,handleRet,spHandle,readRet,disconnectRet,releaseRet);
 return spHandle!=0?0:30;
}
"@
$Code | Set-Content $Src -Encoding ASCII

$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$VsPath = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$VcVars = Join-Path $VsPath "VC\Auxiliary\Build\vcvars32.bat"
$BuildBat = Join-Path $Audit "build.bat"
@"
@echo off
call "$VcVars"
cl /nologo /EHsc /MT /Fo:"$Obj" /Fe:"$Exe" "$Src"
"@ | Set-Content $BuildBat -Encoding ASCII
cmd.exe /c "`"$BuildBat`"" 2>&1 | Tee-Object -FilePath (Join-Path $Audit "build.log")
if (!(Test-Path $Exe)) { throw "Build failed." }
if ($BuildOnly) {
  [pscustomobject]@{ReadTest=$ReadTest;ConnectMode=$ConnectMode;Com=$Com;BuildOnly=$true;Audit=$Audit} |
    ConvertTo-Json | Set-Content (Join-Path $Audit "summary.json") -Encoding UTF8
  Write-Host "Build-only audit: $Audit" -ForegroundColor Green
  return
}

$OldPath=$env:PATH
$OldQtPlatform=$env:QT_QPA_PLATFORM
$OldQtPlatformPluginPath=$env:QT_QPA_PLATFORM_PLUGIN_PATH
$OldQtPluginPath=$env:QT_PLUGIN_PATH
try {
  $env:QT_QPA_PLATFORM="offscreen"
  $env:QT_QPA_PLATFORM_PLUGIN_PATH="$(Join-Path $Profile 'plugins\\platforms')"
  $env:QT_PLUGIN_PATH="$(Join-Path $Profile 'plugins')"
  $env:PATH="$Profile;$(Join-Path $Profile 'Objects');$(Join-Path $Profile 'MtkCoreDlls2412');$(Join-Path $Profile 'MtkCoreDlls');$(Join-Path $Profile 'MTKDLLs');$(Join-Path $Profile 'plugins');$(Join-Path $Profile 'plugins\\platforms');$OldPath"
  $p=Start-Process $Exe -RedirectStandardOutput $Out -RedirectStandardError $Err -NoNewWindow -PassThru
  if(!$p.WaitForExit($ProbeTimeoutSeconds*1000)){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;$p.WaitForExit();$Exit=-2;Add-Content $Err "[timeout] Probe stopped after $ProbeTimeoutSeconds seconds."}else{$Exit=$p.ExitCode}
} finally {
  $env:PATH=$OldPath
  $env:QT_QPA_PLATFORM=$OldQtPlatform
  $env:QT_QPA_PLATFORM_PLUGIN_PATH=$OldQtPlatformPluginPath
  $env:QT_PLUGIN_PATH=$OldQtPluginPath
}

Get-Content $Out -ErrorAction SilentlyContinue
Get-Content $Err -ErrorAction SilentlyContinue
[pscustomobject]@{ReadTest=$ReadTest;ConnectMode=$ConnectMode;Com=$Com;ExitCode=$Exit;Audit=$Audit} | ConvertTo-Json | Set-Content (Join-Path $Audit "summary.json") -Encoding UTF8
Write-Host "Audit: $Audit" -ForegroundColor Green




