#include <windows.h>
#include <stdio.h>
#include <string.h>
typedef void (__stdcall *FN_ERROR_CALLBACK)(int);
typedef int (__stdcall *FN_INIT)(FN_ERROR_CALLBACK);
typedef int (__stdcall *FN_DEINIT)();
typedef int (__stdcall *FN_CONNECT)(void*,int*,void*);
typedef int (__stdcall *FN_DISCONNECT)(int);
typedef void (__stdcall *FN_VER_CALLBACK)(const void*,short,void*);
typedef int (__stdcall *FN_TARGET)(int,FN_VER_CALLBACK,short*,void*);
typedef int (__stdcall *FN_CHIPID)(int,unsigned int,unsigned char*);
typedef int (__stdcall *FN_READ_HANDLE_BUFFER)(int,char*);
typedef int (__stdcall *FN_READ_BUFFER)(char*);
typedef int (__stdcall *FN_READ_BUFFER_SIZE)(char*,int);
typedef int (__stdcall *FN_READ_IMEI)(int,char*,char*,int);
typedef int (__stdcall *FN_NATIVE_MISC_BUFFER)(int,int,void*);
typedef int (__stdcall *FN_NATIVE_MISC_LOCATION)(int,int,void*);
#pragma pack(push,1)
typedef struct { unsigned short record; char value[16]; unsigned char status; } NATIVE_IMEI_VALUE;
#pragma pack(pop)
typedef int (__stdcall *FN_NATIVE_MISC_IMEI)(int,int,NATIVE_IMEI_VALUE*);
typedef int (__stdcall *FN_CONNECT_MODEM)(int,void*,void*);
typedef int (__stdcall *FN_GET_AVAILABLE_HANDLE)(int*);
typedef int (__stdcall *FN_INIT_R)(int,FN_ERROR_CALLBACK);
typedef int (__stdcall *FN_DEINIT_R)(int*);
typedef int (__stdcall *FN_DISCONNECT_TARGET)(int);
typedef int (__stdcall *FN_QUERY_CURRENT_MODEM)(int,int*);
typedef int (__stdcall *FN_QUERY_CURRENT_MODEM_TYPE)(int,unsigned int*);
typedef int (__stdcall *FN_QUERY_CONNECTION_INFO)(int,int*,int*);
typedef int (__stdcall *FN_GET_MODEM_VERSION_INFO)(int,int,void*);
typedef int (__stdcall *FN_SP_MODEM_READ)(int,int,void*,void*);
typedef int (__stdcall *FN_FILE_OPERATION)(int,unsigned int,void*,void*);
typedef int (__stdcall *FN_FILE_RECEIVE)(int,unsigned int,const char*,const char*);
typedef int (__stdcall *FN_NVRAM_INIT)(int,const char*,unsigned long*);
typedef struct { char path_name[256]; char filename_substr[256]; } FILE_OPERATION_PARSE_REQ;
typedef struct { unsigned int file_count; } FILE_OPERATION_PARSE_CNF;
typedef struct { unsigned int index; } FILE_OPERATION_GETFILEINFO_REQ;
typedef struct { unsigned int file_type; unsigned int file_size; char file_name[256]; } FT_FILE_INFO;
typedef struct { FT_FILE_INFO file_info; } FILE_OPERATION_GETFILEINFO_CNF;
typedef int (__stdcall *FN_VENDOR_INIT)();
typedef int (__stdcall *FN_VENDOR_GET_HANDLES)(void**,void**);
typedef void (__stdcall *FN_VENDOR_RELEASE)();
typedef int (__stdcall *FN_VENDOR_CONNECT)(int);
typedef int (__stdcall *FN_VENDOR_DISCONNECT)();
static FARPROC r(HMODULE h,const char*n){FARPROC p=GetProcAddress(h,n);printf("[resolve] %s=0x%p\n",n,p);return p;}
static volatile LONG g_callback=0;
static void __stdcall ErrorCallback(int code){printf("[callback] MetaCore error=%d\n",code);}
static void PrintFixed(const char* label,const unsigned char* p,int n){
 char value[129]={0};if(n>128)n=128;memcpy(value,p,n);value[n]=0;printf("[info] %s=%s\n",label,value);
}
static void PrintHex(const char* label,const unsigned char* p,int n){
 printf("[info] %s=",label);for(int i=0;i<n;i++)printf("%02X",p[i]);printf("\n");
}
static void __stdcall TargetVerCallback(const void* cnf,short token,void* context){
 InterlockedExchange(&g_callback,1);
 printf("[callback] TargetVerInfo token=%d context=0x%p cnf=0x%p first64=",token,context,cnf);
 if(cnf){const unsigned char*p=(const unsigned char*)cnf;for(int i=0;i<64;i++)printf("%02X",p[i]);}
 printf("\n");
 if(cnf){const unsigned char*p=(const unsigned char*)cnf;PrintFixed("Platform",p+0,64);PrintFixed("SoftwareVersion",p+196,64);PrintFixed("BuildDate",p+452,64);}
}
static void __stdcall RawReadCallback(const void* cnf,short token,void* context){
 printf("[callback] RawRead token=%d context=0x%p cnf=0x%p raw256=",token,context,cnf);
 if(cnf){const unsigned char*p=(const unsigned char*)cnf;for(int i=0;i<256;i++)printf("%02X",p[i]);}
 printf("\n");
}
int main(){
 setvbuf(stdout,NULL,_IONBF,0);SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX);
 printf("[gate] D4 native MetaCore existing-META only; COM15 shape=TargetVerInfo nativeRead=None vendorRead=None\n");
 printf("[guard] native attach is source of truth; post-connect allowlisted read helper only; NO generic NVRAM/write/reset/FRP/format/unlock/shell/reboot\n");
 SetCurrentDirectoryA("D:\\projects\\in progress\\TGT ATO iDiot proof\\app\\runtime\\support\\android\\mtk\\meta_backend_mtk_functions_d2g_minimal\\bin");SetDllDirectoryA("D:\\projects\\in progress\\TGT ATO iDiot proof\\app\\runtime\\support\\android\\mtk\\meta_backend_mtk_functions_d2g_minimal\\bin");
 HMODULE h=LoadLibraryA("D:\\projects\\in progress\\TGT ATO iDiot proof\\app\\runtime\\support\\android\\mtk\\meta_backend_mtk_functions_d2g_minimal\\bin\\metacore.dll");printf("[load] MetaCore=0x%p gle=%lu\n",h,GetLastError());if(!h)return 10;
 FN_INIT Init=(FN_INIT)r(h,"SP_META_Init");
 FN_DEINIT Deinit=(FN_DEINIT)r(h,"SP_META_Deinit");
 FN_CONNECT Connect=(FN_CONNECT)r(h,"SP_META_ConnectInMetaModeByUSB");
 FN_DISCONNECT Disconnect=(FN_DISCONNECT)r(h,"SP_META_DisconnectInMetaMode_r");
 FN_TARGET GetTargetVerInfo=(FN_TARGET)r(h,"SP_META_GetTargetVerInfo_r");
 FN_CHIPID GetChipId=(FN_CHIPID)r(h,"SP_META_GetChipID_r");
 FN_CONNECT_MODEM ConnectModem=(FN_CONNECT_MODEM)r(h,"META_ConnectModem_r");
 FN_GET_AVAILABLE_HANDLE GetAvailableHandle=(FN_GET_AVAILABLE_HANDLE)r(h,"META_GetAvailableHandle");
 FN_INIT_R InitModemHandle=(FN_INIT_R)r(h,"META_Init_r");
 FN_DEINIT_R DeinitModemHandle=(FN_DEINIT_R)r(h,"META_Deinit_r");
 FN_DISCONNECT_TARGET DisconnectTarget=(FN_DISCONNECT_TARGET)r(h,"META_DisconnectWithTarget_r");
 FN_QUERY_CURRENT_MODEM QueryCurrentModem=(FN_QUERY_CURRENT_MODEM)r(h,"META_QueryCurrentModem_r");
 FN_QUERY_CURRENT_MODEM_TYPE QueryCurrentModemType=(FN_QUERY_CURRENT_MODEM_TYPE)r(h,"META_QueryCurrentModemType_r");
 FN_QUERY_CONNECTION_INFO QueryConnectionInfo=(FN_QUERY_CONNECTION_INFO)r(h,"META_QueryConnectionInfo_r");
 FN_GET_MODEM_VERSION_INFO GetModemVersionInfo=(FN_GET_MODEM_VERSION_INFO)r(h,"META_GetModemVersionInfo_r");
 FN_SP_MODEM_READ SpModemCapability=(FN_SP_MODEM_READ)r(h,"SP_META_MODEM_Capability_r");
 FN_SP_MODEM_READ SpCurrentModemType=(FN_SP_MODEM_READ)r(h,"SP_META_MODEM_Get_CurrentModemType_r");
 FN_SP_MODEM_READ SpModemState=(FN_SP_MODEM_READ)r(h,"SP_META_MODEM_Get_ModemState_r");
 FN_SP_MODEM_READ SpModemInfo=(FN_SP_MODEM_READ)r(h,"SP_META_MODEM_Query_Info_r");
 FN_SP_MODEM_READ SpMdImgType=(FN_SP_MODEM_READ)r(h,"SP_META_MODEM_Query_MDIMGType_r");
 FN_SP_MODEM_READ SpModemMode=(FN_SP_MODEM_READ)r(h,"SP_META_MODEM_Get_ModemMode_r");
 FN_SP_MODEM_READ SpDownloadStatus=(FN_SP_MODEM_READ)r(h,"SP_META_MODEM_Query_Download_Status_r");
 FN_SP_MODEM_READ SpMdDbPath=(FN_SP_MODEM_READ)r(h,"SP_META_MODEM_Query_MDDBPath_r");
 FN_SP_MODEM_READ SpEeInfo=(FN_SP_MODEM_READ)r(h,"SP_META_MODEM_Get_EEInfo_r");
 FN_SP_MODEM_READ SpApDbPath=(FN_SP_MODEM_READ)r(h,"SP_META_Query_APDBPath_r");
 FN_FILE_OPERATION FileParse=(FN_FILE_OPERATION)r(h,"SP_META_File_Operation_Parse_r");
 FN_FILE_OPERATION FileGetInfo=(FN_FILE_OPERATION)r(h,"SP_META_File_Operation_GetFileInfo_r");
 FN_FILE_RECEIVE FileReceive=(FN_FILE_RECEIVE)r(h,"SP_META_File_Operation_ReceiveFile_r");
 FN_NVRAM_INIT NvramInit=(FN_NVRAM_INIT)r(h,"SP_META_NVRAM_Init_r");
 FN_NATIVE_MISC_BUFFER GetImeiRecNum=(FN_NATIVE_MISC_BUFFER)r(h,"META_MISC_GetIMEIRecNum_r");
 FN_NATIVE_MISC_LOCATION GetImeiLocation=(FN_NATIVE_MISC_LOCATION)r(h,"META_MISC_GetIMEILocation_r");
 FN_NATIVE_MISC_BUFFER GetBarcode=(FN_NATIVE_MISC_BUFFER)r(h,"META_MISC_GetBarCodeValue_r");
 FN_NATIVE_MISC_IMEI GetImeiValue=(FN_NATIVE_MISC_IMEI)r(h,"META_MISC_GetIMEIValue_r");
 FN_NATIVE_MISC_BUFFER GetCalFlagEnum=(FN_NATIVE_MISC_BUFFER)r(h,"META_MISC_GetCalFlagEnum_r");
 FN_NATIVE_MISC_BUFFER GetRfCalEnvEnum=(FN_NATIVE_MISC_BUFFER)r(h,"META_MISC_GetRfCalEnvEnum_r");
 if(!Init||!Connect||!Disconnect||!GetTargetVerInfo||!GetChipId)return 20;
 int initRet=-1,activeHandle=-1,connectRet=-1,readRet=-1,chipRet=-1,nativeReadRet=-1,diagnosticRet=-1,vendorRet=-1,discRet=-1,deinitRet=-1;
 short token=0;
 unsigned char req[512]={0},report[512]={0},chipId[17]={0},modemReq[256]={0},modemReport[512]={0};
 unsigned char diagnosticOut[2048]={0};
 char vendorOut[256]={0},vendorOut2[256]={0};
 char nativeOut[256]={0};
 NATIVE_IMEI_VALUE nativeImei={0};
 *(int*)&req[0]=15;
 *(unsigned long*)&req[4]=90000;
 printf("[call] SP_META_Init(errorCallback) native global session only\n");
 __try{initRet=Init(ErrorCallback);printf("[ret] Init=%d\n",initRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] Init=0x%08lX\n",GetExceptionCode());}
 printf("[call] SP_META_ConnectInMetaModeByUSB(req,outHandle,report) COM15\n");
 __try{connectRet=Connect(req,&activeHandle,report);printf("[ret] Connect=%d activeHandle=%d report=%02X%02X%02X%02X%02X%02X%02X%02X\n",connectRet,activeHandle,report[0],report[1],report[2],report[3],report[4],report[5],report[6],report[7]);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] Connect=0x%08lX\n",GetExceptionCode());}
 if(connectRet==0&&activeHandle>=0){
  printf("[call] SP_META_GetTargetVerInfo_r(activeHandle,callback,token,context)\n");
  __try{readRet=GetTargetVerInfo(activeHandle,TargetVerCallback,&token,(void*)0xD4000001);printf("[ret] TargetVerInfo=%d token=%d callback=%ld\n",readRet,token,g_callback);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] TargetVerInfo=0x%08lX\n",GetExceptionCode());}
  printf("[call] SP_META_GetChipID_r(activeHandle,timeout,out[17])\n");
  __try{chipRet=GetChipId(activeHandle,90000,chipId);printf("[ret] ChipID=%d\n",chipRet);if(chipRet==0)PrintHex("ChipID",chipId,16);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] ChipID=0x%08lX\n",GetExceptionCode());}
  unsigned char spModemReq[256]={0},capabilityCnf[2048]={0},currentTypeCnf[2048]={0},modemStateCnf[2048]={0},modemInfoCnf[2048]={0};
  int capabilityRet=-1,currentTypeRet=-1,modemStateRet=-1,modemInfoRet=-1;
  printf("[call] SP_META_MODEM_Capability_r(activeHandle,timeout,zeroQuery,confirmation) read-only\n");
  __try{capabilityRet=SpModemCapability?SpModemCapability(activeHandle,90000,spModemReq,capabilityCnf):-1;printf("[ret] SpModemCapability=%d\n",capabilityRet);PrintHex("SpModemCapabilityCnf",capabilityCnf,128);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SpModemCapability=0x%08lX\n",GetExceptionCode());}
  printf("[call] SP_META_MODEM_Get_CurrentModemType_r(activeHandle,timeout,zeroQuery,confirmation) read-only\n");
  __try{currentTypeRet=SpCurrentModemType?SpCurrentModemType(activeHandle,90000,spModemReq,currentTypeCnf):-1;printf("[ret] SpCurrentModemType=%d\n",currentTypeRet);PrintHex("SpCurrentModemTypeCnf",currentTypeCnf,128);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SpCurrentModemType=0x%08lX\n",GetExceptionCode());}
  printf("[call] SP_META_MODEM_Get_ModemState_r(activeHandle,timeout,zeroQuery,confirmation) read-only\n");
  __try{modemStateRet=SpModemState?SpModemState(activeHandle,90000,spModemReq,modemStateCnf):-1;printf("[ret] SpModemState=%d\n",modemStateRet);PrintHex("SpModemStateCnf",modemStateCnf,128);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SpModemState=0x%08lX\n",GetExceptionCode());}
  printf("[call] SP_META_MODEM_Query_Info_r(activeHandle,timeout,zeroQuery,confirmation) read-only\n");
  __try{modemInfoRet=SpModemInfo?SpModemInfo(activeHandle,90000,spModemReq,modemInfoCnf):-1;printf("[ret] SpModemInfo=%d\n",modemInfoRet);PrintHex("SpModemInfoCnf",modemInfoCnf,256);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SpModemInfo=0x%08lX\n",GetExceptionCode());}
  unsigned char mdImgTypeCnf[2048]={0},modemModeCnf[2048]={0},downloadStatusCnf[2048]={0},mdDbPathCnf[4096]={0},eeInfoCnf[4096]={0};
  unsigned char apDbPathCnf[4096]={0};
  int mdImgTypeRet=-1,modemModeRet=-1,downloadStatusRet=-1,mdDbPathRet=-1,eeInfoRet=-1,apDbPathRet=-1;
  printf("[call] SP_META_MODEM_Query_MDIMGType_r(activeHandle,timeout,zeroQuery,confirmation) read-only\n");
  __try{mdImgTypeRet=SpMdImgType?SpMdImgType(activeHandle,90000,spModemReq,mdImgTypeCnf):-1;printf("[ret] SpMdImgType=%d\n",mdImgTypeRet);PrintHex("SpMdImgTypeCnf",mdImgTypeCnf,256);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SpMdImgType=0x%08lX\n",GetExceptionCode());}
  printf("[call] SP_META_MODEM_Get_ModemMode_r(activeHandle,timeout,zeroQuery,confirmation) read-only\n");
  __try{modemModeRet=SpModemMode?SpModemMode(activeHandle,90000,spModemReq,modemModeCnf):-1;printf("[ret] SpModemMode=%d\n",modemModeRet);PrintHex("SpModemModeCnf",modemModeCnf,256);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SpModemMode=0x%08lX\n",GetExceptionCode());}
  printf("[call] SP_META_MODEM_Query_Download_Status_r(activeHandle,timeout,zeroQuery,confirmation) read-only\n");
  __try{downloadStatusRet=SpDownloadStatus?SpDownloadStatus(activeHandle,90000,spModemReq,downloadStatusCnf):-1;printf("[ret] SpDownloadStatus=%d\n",downloadStatusRet);PrintHex("SpDownloadStatusCnf",downloadStatusCnf,256);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SpDownloadStatus=0x%08lX\n",GetExceptionCode());}
  printf("[call] SP_META_MODEM_Query_MDDBPath_r(activeHandle,timeout,zeroQuery,confirmation) read-only\n");
  __try{mdDbPathRet=SpMdDbPath?SpMdDbPath(activeHandle,90000,spModemReq,mdDbPathCnf):-1;printf("[ret] SpMdDbPath=%d\n",mdDbPathRet);PrintHex("SpMdDbPathCnf",mdDbPathCnf,512);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SpMdDbPath=0x%08lX\n",GetExceptionCode());}
  printf("[call] SP_META_Query_APDBPath_r(activeHandle,timeout,zeroQuery,confirmation) read-only\n");
  __try{apDbPathRet=SpApDbPath?SpApDbPath(activeHandle,90000,spModemReq,apDbPathCnf):-1;printf("[ret] SpApDbPath=%d\n",apDbPathRet);PrintHex("SpApDbPathCnf",apDbPathCnf,512);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SpApDbPath=0x%08lX\n",GetExceptionCode());}
  printf("[call] SP_META_MODEM_Get_EEInfo_r(activeHandle,timeout,zeroQuery,confirmation) read-only\n");
  __try{eeInfoRet=SpEeInfo?SpEeInfo(activeHandle,90000,spModemReq,eeInfoCnf):-1;printf("[ret] SpEeInfo=%d\n",eeInfoRet);PrintHex("SpEeInfoCnf",eeInfoCnf,512);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] SpEeInfo=0x%08lX\n",GetExceptionCode());}
  unsigned char imeiRecNumOut[256]={0},imeiLocationOut[256]={0},calFlagEnumOut[2048]={0},rfCalEnvEnumOut[2048]={0};
  int imeiRecNumRet=-1,imeiLocationRet=-1,calFlagEnumRet=-1,rfCalEnvEnumRet=-1;
  printf("[call] META_MISC_GetIMEIRecNum_r(activeHandle,timeout,out) read-only\n");
  __try{imeiRecNumRet=GetImeiRecNum?GetImeiRecNum(activeHandle,90000,imeiRecNumOut):-1;printf("[ret] ImeiRecNum=%d\n",imeiRecNumRet);PrintHex("ImeiRecNumOut",imeiRecNumOut,64);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] ImeiRecNum=0x%08lX\n",GetExceptionCode());}
  printf("[call] META_MISC_GetIMEILocation_r(activeHandle,timeout,out) read-only\n");
  __try{imeiLocationRet=GetImeiLocation?GetImeiLocation(activeHandle,90000,imeiLocationOut):-1;printf("[ret] ImeiLocation=%d\n",imeiLocationRet);PrintHex("ImeiLocationOut",imeiLocationOut,128);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] ImeiLocation=0x%08lX\n",GetExceptionCode());}
  printf("[call] META_MISC_GetCalFlagEnum_r(activeHandle,timeout,out) read-only\n");
  __try{calFlagEnumRet=GetCalFlagEnum?GetCalFlagEnum(activeHandle,90000,calFlagEnumOut):-1;printf("[ret] CalFlagEnum=%d\n",calFlagEnumRet);PrintHex("CalFlagEnumOut",calFlagEnumOut,256);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] CalFlagEnum=0x%08lX\n",GetExceptionCode());}
  printf("[call] META_MISC_GetRfCalEnvEnum_r(activeHandle,timeout,out) read-only\n");
  __try{rfCalEnvEnumRet=GetRfCalEnvEnum?GetRfCalEnvEnum(activeHandle,90000,rfCalEnvEnumOut):-1;printf("[ret] RfCalEnvEnum=%d\n",rfCalEnvEnumRet);PrintHex("RfCalEnvEnumOut",rfCalEnvEnumOut,256);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] RfCalEnvEnum=0x%08lX\n",GetExceptionCode());}
  int currentModem=-1,connectionInfo0=-1,connectionInfo1=-1,currentModemRet=-1,currentModemTypeRet=-1,connectionInfoRet=-1;
  unsigned int currentModemType=0xFFFFFFFF;
  printf("[call] META_QueryCurrentModem_r(activeHandle,outCurrentModem) read-only\n");
  __try{currentModemRet=QueryCurrentModem?QueryCurrentModem(activeHandle,&currentModem):-1;printf("[ret] QueryCurrentModem=%d currentModem=%d\n",currentModemRet,currentModem);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] QueryCurrentModem=0x%08lX\n",GetExceptionCode());}
  printf("[call] META_QueryCurrentModemType_r(activeHandle,outCurrentModemType) read-only\n");
  __try{currentModemTypeRet=QueryCurrentModemType?QueryCurrentModemType(activeHandle,&currentModemType):-1;printf("[ret] QueryCurrentModemType=%d currentModemType=%u (0x%08X)\n",currentModemTypeRet,currentModemType,currentModemType);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] QueryCurrentModemType=0x%08lX\n",GetExceptionCode());}
  printf("[call] META_QueryConnectionInfo_r(activeHandle,out0,out1) read-only\n");
  __try{connectionInfoRet=QueryConnectionInfo?QueryConnectionInfo(activeHandle,&connectionInfo0,&connectionInfo1):-1;printf("[ret] QueryConnectionInfo=%d info0=%d info1=%d\n",connectionInfoRet,connectionInfo0,connectionInfo1);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] QueryConnectionInfo=0x%08lX\n",GetExceptionCode());}
  printf("[diagnostic-call] receive matched APDB files then initialize host-side SP NVRAM parser; no record read/write\n");
const char* apdbNames[2]={"APDB_MT6789___W2452","APDB_MT6789___W2452_ENUM"};
int primaryReceiveRet=-1;
for(int apdbIndex=0;apdbIndex<2;apdbIndex++){
 char sourcePath[512]={0},destPath[1024]={0};
 _snprintf(sourcePath,sizeof(sourcePath)-1,"/vendor/etc/apdb/%s",apdbNames[apdbIndex]);
 _snprintf(destPath,sizeof(destPath)-1,"D:\\projects\\in progress\\TGT ATO iDiot proof\\audit_shared_runtime\\D4_NATIVE_METACORE_TargetVerInfo_None_20260613_010709\\%s",apdbNames[apdbIndex]);
 printf("[database-receive-call] source=%s dest=%s\n",sourcePath,destPath);
 int receiveRet=FileReceive?FileReceive(activeHandle,90000,sourcePath,destPath):-1;
 printf("[database-receive-ret] name=%s ret=%d hostSize=%lu\n",apdbNames[apdbIndex],receiveRet,GetFileAttributesA(destPath)==INVALID_FILE_ATTRIBUTES?0:GetFileSize(CreateFileA(destPath,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL),NULL));
 if(apdbIndex==0)primaryReceiveRet=receiveRet;
}
char primaryDbPath[1024]="D:\\projects\\in progress\\TGT ATO iDiot proof\\audit_shared_runtime\\D4_NATIVE_METACORE_TargetVerInfo_None_20260613_010709\\APDB_MT6789___W2452";
unsigned long nvramInitOut=0;
 if(primaryReceiveRet==0&&GetFileAttributesA(primaryDbPath)!=INVALID_FILE_ATTRIBUTES){
 printf("[database-init-call] SP_META_NVRAM_Init_r(activeHandle,matchedLocalAPDB,out) host parser initialization\n");
 int nvramInitRet=NvramInit?NvramInit(activeHandle,primaryDbPath,&nvramInitOut):-1;
 printf("[database-init-ret] ret=%d out=%lu\n",nvramInitRet,nvramInitOut);
 if(nvramInitRet==0){
  unsigned char postInitMeta[2048]={0};char barcode[256]={0};NATIVE_IMEI_VALUE imei1={0},imei2={0};imei1.record=1;imei2.record=2;
  int postRet=GetImeiRecNum?GetImeiRecNum(activeHandle,90000,postInitMeta):-1;
  printf("[database-post-init-ret] ImeiRecNum=%d raw=",postRet);PrintHex("PostInitImeiRecNum",postInitMeta,64);
  memset(postInitMeta,0,sizeof(postInitMeta));postRet=GetImeiLocation?GetImeiLocation(activeHandle,90000,postInitMeta):-1;
  printf("[database-post-init-ret] ImeiLocation=%d raw=",postRet);PrintHex("PostInitImeiLocation",postInitMeta,64);
  int barcodeRet=GetBarcode?GetBarcode(activeHandle,90000,barcode):-1;
  printf("[database-identifier-ret] Barcode=%d text=%s raw=",barcodeRet,barcode);PrintHex("BarcodeRaw",(unsigned char*)barcode,64);
  int imei1Ret=GetImeiValue?GetImeiValue(activeHandle,90000,&imei1):-1;
  printf("[database-identifier-ret] IMEI1=%d record=%u text=%s status=%u\n",imei1Ret,imei1.record,imei1.value,imei1.status);
  int imei2Ret=GetImeiValue?GetImeiValue(activeHandle,90000,&imei2):-1;
  printf("[database-identifier-ret] IMEI2=%d record=%u text=%s status=%u\n",imei2Ret,imei2.record,imei2.value,imei2.status);
 }
}else{printf("[database-init-gate] matched primary APDB not received; init skipped\n");}
  printf("[bridge-request] currentModem=%d connectionInfo=%d/%d logged; not copied into transport fields\n",currentModem,connectionInfo0,connectionInfo1);
  *(int*)&modemReq[0x24]=2;
  printf("[bridge-request] offset24=2 (native CShare existing-AP transport)\n");
  int modemHandle=-1,modemHandleRet=-1,modemInitRet=-1,modemConnectRet=-1,modemDisconnectRet=-1,modemDeinitRet=-1;
  printf("[call] META_GetAvailableHandle(&modemHandle) host-side modem session allocation\n");
  __try{modemHandleRet=GetAvailableHandle?GetAvailableHandle(&modemHandle):-1;printf("[ret] GetAvailableHandle=%d modemHandle=%d\n",modemHandleRet,modemHandle);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] GetAvailableHandle=0x%08lX\n",GetExceptionCode());}
  if(modemHandleRet==0&&modemHandle>=0&&modemHandle!=activeHandle){
   printf("[call] META_Init_r(modemHandle,errorCallback) isolated host-side modem session\n");
   __try{modemInitRet=InitModemHandle?InitModemHandle(modemHandle,ErrorCallback):-1;printf("[ret] InitModemHandle=%d\n",modemInitRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] InitModemHandle=0x%08lX\n",GetExceptionCode());}
  }
  printf("[call] META_ConnectModem_r(modemHandle,query-populated-modem-request,report)\n");
  __try{modemConnectRet=(modemInitRet==0&&ConnectModem)?ConnectModem(modemHandle,modemReq,modemReport):-1;printf("[ret] ConnectModem=%d report=",modemConnectRet);PrintHex("ModemConnectReport",modemReport,32);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] ConnectModem=0x%08lX\n",GetExceptionCode());}
  if(modemConnectRet==0){
   printf("[native-read] modem bridge valid; dedicated read-only helper\n");
   __try{
    int savedActiveHandle=activeHandle;activeHandle=modemHandle;
    printf("[native-read] no additional native read selected\n");
    activeHandle=savedActiveHandle;
   }__except(EXCEPTION_EXECUTE_HANDLER){printf("[native-read-exception] 0x%08lX\n",GetExceptionCode());}
  } else if(strcmp("None","Barcode")==0){
   printf("[native-read] modem bridge unavailable; testing dedicated AP-side read-only barcode getter\n");
   __try{printf("[native-read] no additional native read selected\n");}__except(EXCEPTION_EXECUTE_HANDLER){printf("[native-read-exception] 0x%08lX\n",GetExceptionCode());}
  } else { printf("[native-read-gate] modem bridge unavailable; modem getter skipped\n"); }
  if(modemConnectRet==0&&DisconnectTarget){printf("[call] META_DisconnectWithTarget_r(modemHandle)\n");__try{modemDisconnectRet=DisconnectTarget(modemHandle);printf("[ret] DisconnectTarget=%d\n",modemDisconnectRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] DisconnectTarget=0x%08lX\n",GetExceptionCode());}}
  if(modemInitRet==0&&DeinitModemHandle){printf("[call] META_Deinit_r(&modemHandle)\n");__try{modemDeinitRet=DeinitModemHandle(&modemHandle);printf("[ret] DeinitModemHandle=%d modemHandle=%d\n",modemDeinitRet,modemHandle);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] DeinitModemHandle=0x%08lX\n",GetExceptionCode());}}
  if(0){
  printf("[vendor] load allowlisted read helper after valid native handle\n");
  HMODULE vendor=LoadLibraryA("D:\\projects\\in progress\\TGT ATO iDiot proof\\app\\runtime\\support\\android\\mtk\\meta_backend_mtk_functions_d2g_minimal\\bin\\MTK_Functions.dll");printf("[vendor-load] MTK_Functions=0x%p gle=%lu\n",vendor,GetLastError());
  if(vendor){
   FN_VENDOR_INIT VendorInit=(FN_VENDOR_INIT)r(vendor,"_InitMtkDll@0");
   FN_VENDOR_GET_HANDLES VendorGetHandles=(FN_VENDOR_GET_HANDLES)r(vendor,"_GetMtkHandle@8");
   FN_VENDOR_RELEASE VendorRelease=(FN_VENDOR_RELEASE)r(vendor,"_ReleaseMtkDll@0");
   void* vendorSp=0;void* vendorFp=0;int vendorInitRet=0,vendorHandlesRet=0;
   printf("[vendor-guard] object creation only; no wrapper connect/init/available-handle/NVRAM-init\n");
   __try{
    if(VendorInit){vendorInitRet=VendorInit();printf("[vendor-ret] InitMtkDll=%d\n",vendorInitRet);}
    if(VendorGetHandles){vendorHandlesRet=VendorGetHandles(&vendorSp,&vendorFp);printf("[vendor-ret] GetMtkHandle=%d SP=0x%p FP=0x%p\n",vendorHandlesRet,vendorSp,vendorFp);}
    if(vendorInitRet&&vendorHandlesRet&&vendorSp){printf("[vendor] no post-connect vendor read selected\n");}else{printf("[vendor-gate] wrapper objects unavailable; read helper skipped\n");}
   }__except(EXCEPTION_EXECUTE_HANDLER){printf("[vendor-exception] 0x%08lX\n",GetExceptionCode());}
   if(VendorRelease){__try{VendorRelease();printf("[vendor-ret] ReleaseMtkDll=called\n");}__except(EXCEPTION_EXECUTE_HANDLER){printf("[vendor-exception] ReleaseMtkDll=0x%08lX\n",GetExceptionCode());}}
  }
  } else { printf("[vendor] disabled\n"); }
  printf("[call] SP_META_DisconnectInMetaMode_r(activeHandle)\n");
  __try{discRet=Disconnect(activeHandle);printf("[ret] Disconnect=%d\n",discRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] Disconnect=0x%08lX\n",GetExceptionCode());}
  if(Deinit){printf("[call] SP_META_Deinit() before secondary phase\n");__try{deinitRet=Deinit();printf("[ret] Deinit=%d\n",deinitRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] Deinit=0x%08lX\n",GetExceptionCode());}}
  FreeLibrary(h);h=NULL;printf("[native] MetaCore unloaded before secondary phase\n");
  if(strcmp("None","None")!=0){
   printf("[vendor-secondary] native device validation complete and native port released\n");
   HMODULE vendor=LoadLibraryA("D:\\projects\\in progress\\TGT ATO iDiot proof\\app\\runtime\\support\\android\\mtk\\meta_backend_mtk_functions_d2g_minimal\\bin\\MTK_Functions.dll");printf("[vendor-load] MTK_Functions=0x%p gle=%lu\n",vendor,GetLastError());
   if(vendor){
    FN_VENDOR_INIT VendorInit=(FN_VENDOR_INIT)r(vendor,"_InitMtkDll@0");
    FN_VENDOR_GET_HANDLES VendorGetHandles=(FN_VENDOR_GET_HANDLES)r(vendor,"_GetMtkHandle@8");
    FN_VENDOR_CONNECT VendorConnect=(FN_VENDOR_CONNECT)r(vendor,"_SPMeta_ConnectInMetaMode_r@4");
    FN_VENDOR_DISCONNECT VendorDisconnect=(FN_VENDOR_DISCONNECT)r(vendor,"_SPMeta_DisconnectInMetaMode_r@0");
    FN_VENDOR_RELEASE VendorRelease=(FN_VENDOR_RELEASE)r(vendor,"_ReleaseMtkDll@0");
    void* vendorSp=0;void* vendorFp=0;int vendorInitRet=0,vendorHandlesRet=0,vendorConnectRet=0;
    printf("[vendor-guard] secondary existing-META attach only; one allowlisted dedicated read; no boot/init_r/available-handle/generic-NVRAM/write\n");
    __try{
     if(VendorInit){vendorInitRet=VendorInit();printf("[vendor-ret] InitMtkDll=%d\n",vendorInitRet);}
     if(VendorGetHandles){vendorHandlesRet=VendorGetHandles(&vendorSp,&vendorFp);printf("[vendor-ret] GetMtkHandle=%d SP=0x%p FP=0x%p\n",vendorHandlesRet,vendorSp,vendorFp);}
     if(vendorInitRet&&vendorHandlesRet&&vendorSp&&VendorConnect){vendorConnectRet=VendorConnect(15);printf("[vendor-ret] ConnectInMetaMode=%d COM=15\n",vendorConnectRet);}
     if(vendorConnectRet){printf("[vendor] no post-connect vendor read selected\n");}else{printf("[vendor-gate] secondary connect failed; read helper skipped\n");}
     if(vendorConnectRet&&VendorDisconnect){printf("[vendor-ret] DisconnectInMetaMode=%d\n",VendorDisconnect());}
    }__except(EXCEPTION_EXECUTE_HANDLER){printf("[vendor-exception] 0x%08lX\n",GetExceptionCode());}
    if(VendorRelease){__try{VendorRelease();printf("[vendor-ret] ReleaseMtkDll=called\n");}__except(EXCEPTION_EXECUTE_HANDLER){printf("[vendor-exception] ReleaseMtkDll=0x%08lX\n",GetExceptionCode());}}
   }
  }
 } else { printf("[gate] no valid connected handle; read skipped\n"); }
 if(h&&Deinit){printf("[call] SP_META_Deinit()\n");__try{deinitRet=Deinit();printf("[ret] Deinit=%d\n",deinitRet);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] Deinit=0x%08lX\n",GetExceptionCode());}}
 printf("[done] init=%d connect=%d active=%d targetVer=%d callback=%ld chipId=%d vendorRead=%d disconnect=%d deinit=%d\n",initRet,connectRet,activeHandle,readRet,g_callback,chipRet,vendorRet,discRet,deinitRet);
 return connectRet==0&&activeHandle>=0?0:40;
}


