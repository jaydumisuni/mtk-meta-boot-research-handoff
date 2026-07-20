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

  $exportPattern = '(?m)^(?<indent>\s*)FN_CONNECT_MODEM ConnectModem=\(FN_CONNECT_MODEM\)r\(h,"META_ConnectModem_r"\);\s*$'
  $exportMatches = [regex]::Matches($source, $exportPattern)
  if ($exportMatches.Count -ne 1) {
    throw "D4 runner connector anchor changed or is ambiguous; D5 patch refused."
  }
  $indent = $exportMatches[0].Groups['indent'].Value
  $exportReplacement = @(
    "${indent}FN_CONNECT_MODEM ConnectModem=(FN_CONNECT_MODEM)r(h,`"META_ConnectModem_r`");",
    "${indent}r(h,`"META_ConnectWithMultiModeTarget_r`");",
    "${indent}r(h,`"META_Connect_Ex_Req`");",
    "${indent}printf(`"[connector-inventory] unresolved connector exports are inventoried only; unknown ABI functions are NOT called\n`");"
  ) -join "`n"
  $source = [regex]::Replace($source, $exportPattern, [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    return $exportReplacement
  }, 1)

  $requestPattern = '(?m)^(?<indent>\s*)\*\(int\*\)&modemReq\[0x24\]=2;\s*\n\s*printf\("\[bridge-request\] offset24=2 \(native CShare existing-AP transport\)\\n"\);\s*$'
  $requestMatches = [regex]::Matches($source, $requestPattern)
  if ($requestMatches.Count -ne 1) {
    throw "D4 runner bridge-request anchor changed or is ambiguous; D5 patch refused."
  }
  $requestIndent = $requestMatches[0].Groups['indent'].Value
  $requestReplacement = @(
    "${requestIndent}int bridgeRequestValue=2;",
    "${requestIndent}const char* bridgeRequestSource=`"$BridgeRequestSource`";",
    "${requestIndent}if(strcmp(bridgeRequestSource,`"Zero`")==0)bridgeRequestValue=0;",
    "${requestIndent}else if(strcmp(bridgeRequestSource,`"CurrentModem`")==0)bridgeRequestValue=currentModem;",
    "${requestIndent}else if(strcmp(bridgeRequestSource,`"CurrentModemType`")==0)bridgeRequestValue=(int)currentModemType;",
    "${requestIndent}else if(strcmp(bridgeRequestSource,`"ConnectionInfo0`")==0)bridgeRequestValue=connectionInfo0;",
    "${requestIndent}else if(strcmp(bridgeRequestSource,`"ConnectionInfo1`")==0)bridgeRequestValue=connectionInfo1;",
    "${requestIndent}int bridgeRequestUsable=(bridgeRequestValue>=0&&bridgeRequestValue<=32)?1:0;",
    "${requestIndent}if(bridgeRequestUsable)*(int*)&modemReq[0x24]=bridgeRequestValue;",
    "${requestIndent}printf(`"[bridge-request] source=%s value=%d usable=%d offset24\n`",bridgeRequestSource,bridgeRequestValue,bridgeRequestUsable);"
  ) -join "`n"
  $source = [regex]::Replace($source, $requestPattern, [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    return $requestReplacement
  }, 1)

  $connectNeedle = 'modemConnectRet=(modemInitRet==0&&ConnectModem)?ConnectModem(modemHandle,modemReq,modemReport)'
  $connectReplacement = 'modemConnectRet=(bridgeRequestUsable&&modemInitRet==0&&ConnectModem)?ConnectModem(modemHandle,modemReq,modemReport)'
  $connectMatches = [regex]::Matches($source, [regex]::Escape($connectNeedle))
  if ($connectMatches.Count -ne 1) {
    throw "D4 runner ConnectModem anchor changed or is ambiguous; D5 patch refused."
  }
  $source = $source.Replace($connectNeedle, $connectReplacement)
  $source = $source.Replace(
    "D4 native MetaCore existing-META only",
    "D5 native MetaCore selector experiment"
  )
  $source | Set-Content $OutputPath -Encoding UTF8
}
