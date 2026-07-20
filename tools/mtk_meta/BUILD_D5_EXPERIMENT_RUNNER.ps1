Set-StrictMode -Version Latest

function New-D5ExperimentRunner {
  param([string]$D4Runner, [string]$OutputPath)

  $source = (Get-Content $D4Runner -Raw) -replace "`r`n", "`n"
  $paramAnchor = (@(
    '  [ValidateRange(10,180)]',
    '  [int]$ProbeTimeoutSeconds = 60,'
  ) -join "`n") + "`n"
  $paramReplacement = (@(
    '  [ValidateSet("Fixed2","CurrentModem","CurrentModemType","ConnectionInfo0","ConnectionInfo1","Zero")]',
    '  [string]$BridgeRequestSource = "Fixed2",',
    '  [ValidateRange(10,180)]',
    '  [int]$ProbeTimeoutSeconds = 60,'
  ) -join "`n") + "`n"
  if (!$source.Contains($paramAnchor)) {
    throw "D4 runner parameter anchor changed; D5 patch refused."
  }
  $source = $source.Replace($paramAnchor, $paramReplacement)

  $exportAnchor = '  FN_CONNECT_MODEM ConnectModem=(FN_CONNECT_MODEM)r(h,"META_ConnectModem_r");'
  $exportReplacement = @(
    '  FN_CONNECT_MODEM ConnectModem=(FN_CONNECT_MODEM)r(h,"META_ConnectModem_r");',
    '  r(h,"META_ConnectWithMultiModeTarget_r");',
    '  r(h,"META_Connect_Ex_Req");',
    '  printf("[connector-inventory] unresolved connector exports are inventoried only; unknown ABI functions are NOT called\n");'
  ) -join "`n"
  if (!$source.Contains($exportAnchor)) {
    throw "D4 runner connector anchor changed; D5 patch refused."
  }
  $source = $source.Replace($exportAnchor, $exportReplacement)

  $requestAnchor = (@(
    '   *(int*)&modemReq[0x24]=2;',
    '   printf("[bridge-request] offset24=2 (native CShare existing-AP transport)\n");'
  ) -join "`n") + "`n"
  $requestReplacement = (@(
    '   int bridgeRequestValue=2;',
    '   const char* bridgeRequestSource="$BridgeRequestSource";',
    '   if(strcmp(bridgeRequestSource,"Zero")==0)bridgeRequestValue=0;',
    '   else if(strcmp(bridgeRequestSource,"CurrentModem")==0)bridgeRequestValue=currentModem;',
    '   else if(strcmp(bridgeRequestSource,"CurrentModemType")==0)bridgeRequestValue=(int)currentModemType;',
    '   else if(strcmp(bridgeRequestSource,"ConnectionInfo0")==0)bridgeRequestValue=connectionInfo0;',
    '   else if(strcmp(bridgeRequestSource,"ConnectionInfo1")==0)bridgeRequestValue=connectionInfo1;',
    '   int bridgeRequestUsable=(bridgeRequestValue>=0&&bridgeRequestValue<=32)?1:0;',
    '   if(bridgeRequestUsable)*(int*)&modemReq[0x24]=bridgeRequestValue;',
    '   printf("[bridge-request] source=%s value=%d usable=%d offset24\n",bridgeRequestSource,bridgeRequestValue,bridgeRequestUsable);'
  ) -join "`n") + "`n"
  if (!$source.Contains($requestAnchor)) {
    throw "D4 runner bridge-request anchor changed; D5 patch refused."
  }
  $source = $source.Replace($requestAnchor, $requestReplacement)

  $connectAnchor = '__try{modemConnectRet=(modemInitRet==0&&ConnectModem)?ConnectModem(modemHandle,modemReq,modemReport):-1;printf("[ret] ConnectModem=%d report=",modemConnectRet);PrintHex("ModemConnectReport",modemReport,32);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] ConnectModem=0x%08lX\n",GetExceptionCode());}'
  $connectReplacement = '__try{modemConnectRet=(bridgeRequestUsable&&modemInitRet==0&&ConnectModem)?ConnectModem(modemHandle,modemReq,modemReport):-1;printf("[ret] ConnectModem=%d report=",modemConnectRet);PrintHex("ModemConnectReport",modemReport,32);}__except(EXCEPTION_EXECUTE_HANDLER){printf("[exception] ConnectModem=0x%08lX\n",GetExceptionCode());}'
  if (!$source.Contains($connectAnchor)) {
    throw "D4 runner ConnectModem anchor changed; D5 patch refused."
  }
  $source = $source.Replace($connectAnchor, $connectReplacement)
  $source = $source.Replace(
    "D4 native MetaCore existing-META only",
    "D5 native MetaCore selector experiment"
  )
  $source | Set-Content $OutputPath -Encoding UTF8
}
