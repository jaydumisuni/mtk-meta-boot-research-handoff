# THETECHGUY MTK / TSM META Research Handoff

Project root:
`D:\projects\in progress\TGT ATO iDiot proof`

Target device evidence:
- TECNO CM6 / MT6789 / Android 15
- Build: `CM6-15.1.0.155SP03(OP001PF001AZ)`
- Serial observed: `<REDACTED_SERIAL>`
- Security patch: `2025-08-05`
- Device state: locked

## Confirmed USB sequence

Powered-off phone, no buttons:
- Preloader: `MediaTek PreLoader USB VCOM (Android) (COM13)`
- VID/PID: `USB\VID_0E8D&PID_2000\...`
- Status: OK

When external tool successfully boots META:
- META: `MediaTek USB VCOM (Android) (COM15)`
- VID/PID: `USB\VID_0E8D&PID_2007\...`
- Status: OK

After external tool Enable ADB:
- `Android ADB Interface`
- VID/PID: `USB\VID_0E8D&PID_201C\\<REDACTED_SERIAL>`
- Status: OK

Dirty/non-useful state:
- `USB Input Device`
- VID/PID: `USB\VID_0E8D&PID_20FF\\<REDACTED_SERIAL>`
- Status: Error
- Treat as dirty state. Hard power off and clean USB cycle required.

## External tool success reference

TSM TOOL PRO v2.4.1 Build 2025.12.22 14:21 successfully did:

```text
Waiting for mtk usb device : Preloader[COM13]
Driver Info : MediaTek Inc. oem414.inf v3.0.1512.0 - 1-4-2023
Handshaking Port : OK
Rebooting to Meta Mode : OK
Waiting for mtk usb device : MTK VCOM[COM15]
Driver Info : MediaTek Inc. oem414.inf v3.0.1512.0 - 1-4-2023
Handshaking META : OK
Reading Version Info : OK
Reading Device Info : OK
Enable ADB : OK
Rebooting device : OK
```

Read-info returned:
```text
Platform : mt6789
Build Date : Thu Sep  4 13:04:01 CST 2025
Software Version : alps-mp-s0.mp1.rc-V17.23_reallytek.s0mp1rc.k61v1.64.bsp_P24
DispID : CM6-15.1.0.155SP03(OP001PF001AZ)
manufacturer : TECNO
Brand : TECNO
Model : TECNO CM6
DevName : TECNO-CM6
Name : CM6-OP
Board : TECNO-CM6
Build ID : CM6-15.1.0.155SP03(OP001PF001AZ)
Android Ver : 15
EMI ID : sys_tssi_64_armv82_tecno_dolby-user
Sec Patch : 2025-08-05
Build Type : user
Hardware : mt6789
Device State : locked
SDKVer : 35
Fingerprint : TECNO/CM6-OP/TECNO-CM6:15/AP3A.240905.015.A2/155022:user/release-keys
OEM SerialNumber #1 : <REDACTED_SERIAL>
```

## Sealed profiles

Clean/golden profile:
```text
.\app\runtime\support\android\mtk\meta_backend_mtk_functions_gold\bin
```

Created from:
```text
.\audit_shared_runtime\TSM_MTK_FUNCTIONS_D0J_GOLDEN_D0F_COPY_20260611_181603\A_golden_no_relative\bin
```

Clean backup before MetaCore/MTKDLL staging:
```text
.\audit_shared_runtime\BACKUP_gold_bin_before_metacore_mtkdlls_20260611_235334
```

Gold profile core files:
```text
MTK_Functions.dll
Basic.dll
mfc100.dll
MSVCR100.dll
MSVCP100.dll
metacomm.dll
ValidityCheck.dll
SysCheck.dll
VirtualObject.dll
MetaCore.dll
Objects\MTKLibMetaObj00.dll
Objects\MTKLibMetaCoreObj00.dll
Objects\MTKLibSPMetaObj00.dll
Objects\MTKLibCalFtObj00.dll
Objects\MTKLibCalFtCoreObj00.dll
```

D2G minimal profile:
```text
.\app\runtime\support\android\mtk\meta_backend_mtk_functions_d2g_minimal\bin
```

D2G is clean gold plus:
```text
MtkCoreDlls2412\MetaCore.dll
MtkCoreDlls2412\MetaApp.dll
MTKDLLs\META_DLL.dll
```

Use D2G for tests that need dynamic MetaCore/META_DLL paths. Keep gold clean.

## Export map highlights from MTK_Functions.dll

Important exports:
```text
_InitMtkDll@0
_ReleaseMtkDll@0
_GetMtkHandle@8
_SetMtkHandle@8

_SPMeta_ConnectWithPreloader@8
_SPMeta_Preloader_BootMode@8
_SPMeta_SearchKernelPort@8
_SPMeta_ConnectInMetaMode_r@4
_SPMeta_DisconnectInMetaMode_r@0
_SPMeta_DisconnectWithTarget_r@0
_SPMeta_GetAvailableHandle@0
_SPMeta_Init_r@0

_SPMeta_GetTargetVerInfo_r@12
_SPMeta_GetChipId_r@12
_SPMeta_Get_AdbDebug_Status@4
_SPMeta_Enable_AdbDebug@4

_SPMeta_NVRAM_Init_r@4
_SPMeta_NVRAM_Read_r@16
_SPMeta_NVRAM_Write_r@16

_SPMeta_Customer_FactoryReset@0
_SPMeta_Customer_Reboot@0
_SPMeta_Customer_Shell_Command@12
```

Direct imports:
```text
Basic.dll
mfc100.dll
MSVCR100.dll
KERNEL32.dll
SHLWAPI.dll
MSVCP100.dll
```

Dynamic popup dependencies observed:
```text
bin\MtkCoreDlls2412\MetaCore.dll
bin\MTKDLLs\META_DLL.dll
```

## Confirmed good and bad calls

Good:
```text
_InitMtkDll@0 -> OK
_ReleaseMtkDll@0 -> OK
```

Bad before connect:
```text
_SPMeta_Init_r@0 -> access violation / full META/Qt stack path
_SPMeta_GetAvailableHandle@0 -> access violation before connect
```

Important conclusion:
- Do not call `_SPMeta_Init_r@0` before connection.
- Do not call `_SPMeta_GetAvailableHandle@0` before connection.

## D2/D2E/D2F/D2G results

`_SPMeta_Preloader_BootMode@8(int COM13, value)`:
```text
BootValue 0 -> ret 0, no PID_2007
BootValue 1 -> ret 0, no PID_2007
BootValue 2 -> ret 0, no PID_2007
BootValue 3 -> ret 0, no PID_2007
```

Conclusion:
- BootMode returns success but does not push this device from PID_2000 to PID_2007.
- Return `0` means function call completed, not that META boot happened.

`_SPMeta_ConnectWithPreloader@8` tested shapes:
```text
(char* "COM13", int timeout) -> access violation
(char* "\\.\COM13", int timeout) -> access violation
(int COM13, int timeout) -> access violation
```

Likely missing:
- Correct function signature.
- Correct hidden context/handle setup.
- Correct feature verification.
- Correct TSM init sequence.
- Correct use of `_GetMtkHandle@8` / `_SetMtkHandle@8`.
- Correct use of `Meta_ConnectPhone@40` or `MDMeta_ConnectWithMultiModeTarget_r@20`.
- Correct config/INI/profile expected by wrapper.

## Current best engineering conclusion

We have two separate lanes:

### Lane A — attach/read existing META
External tool proves PID_2007 COM15 and META handshake/read info are real. Best next gate is to let external tool boot META, then use our staged DLL to attach to COM15 and read info only.

### Lane B — boot preloader to META
Our BootMode calls complete but do not switch to PID_2007. Our guessed ConnectWithPreloader signatures crash. This lane needs reverse engineering of the actual TSM call sequence/signature.

## Next gate: D3 attach to already-existing META

Purpose:
- Do not boot preloader.
- Wait for existing PID_2007 COM port.
- Attach and read version/device info only.

Use profile:
```text
.\app\runtime\support\android\mtk\meta_backend_mtk_functions_d2g_minimal\bin
```

D3 safe flow:
```text
Wait for VID_0E8D PID_2007 COM port.

Load MTK_Functions.dll.

Call:
_InitMtkDll@0

Try:
_SPMeta_ConnectInMetaMode_r@4(COM number int)

Only if connect succeeds, test safe read-only exports one at a time:
_SPMeta_GetTargetVerInfo_r@12
_SPMeta_GetChipId_r@12
_SPMeta_Get_AdbDebug_Status@4

Then:
_SPMeta_DisconnectInMetaMode_r@0
_ReleaseMtkDll@0
```

Do not call:
```text
_SPMeta_Init_r@0 before connect
_SPMeta_GetAvailableHandle@0 before connect
_SPMeta_NVRAM_Read_r@16
_SPMeta_NVRAM_Write_r@16
_SPMeta_Customer_FactoryReset@0
_SPMeta_Enable_AdbDebug@4
_SPMeta_Customer_Reboot@0
_SPMeta_Customer_Shell_Command@12
```

## Codex prompt for D3

```text
Create RUN_D3_ATTACH_EXISTING_META_READINFO.ps1.

Purpose:
Attach to an already-booted MTK META port and perform read-only info checks.

Profile:
.\app\runtime\support\android\mtk\meta_backend_mtk_functions_d2g_minimal\bin

Safety:
NO preloader boot.
NO reset.
NO FactoryReset.
NO Enable_AdbDebug.
NO FRP.
NO unlock.
NO format.
NO NVRAM read/write.
NO reboot.
Do not call _SPMeta_Init_r@0 before connect.
Do not call _SPMeta_GetAvailableHandle@0 before connect.

Flow:
1. Wait for VID_0E8D PID_2007 COM port.
2. Build x86 C++ probe.
3. Load MTK_Functions.dll.
4. Resolve:
   _InitMtkDll@0
   _ReleaseMtkDll@0
   _SPMeta_ConnectInMetaMode_r@4
   _SPMeta_DisconnectInMetaMode_r@0
   _SPMeta_GetTargetVerInfo_r@12
   _SPMeta_GetChipId_r@12
   _SPMeta_Get_AdbDebug_Status@4
5. Call _InitMtkDll@0.
6. Call _SPMeta_ConnectInMetaMode_r@4 using COM number int first.
7. If connect succeeds, run read-only info functions one at a time with guarded buffers.
8. Disconnect and release.
9. Save stdout/stderr, selected META port, summary JSON, and ports before/after into audit_shared_runtime.
```

## Locked safety rules

- Keep `meta_backend_mtk_functions_gold` clean.
- Use `meta_backend_mtk_functions_d2g_minimal` for dynamic dependency experiments.
- Never call `_SPMeta_Init_r@0` before a known-good connection.
- Never call `_SPMeta_GetAvailableHandle@0` before a known-good connection.
- BootMode return `0` is not proof of META.
- PID_2007 alone is only transport evidence; success requires META handshake/read-info.
- External tool may be used temporarily only to create PID_2007 for attach research.
- Destructive functions remain locked unless manually approved:
  - FactoryReset
  - FRP
  - format
  - unlock
  - NVRAM write
  - reboot
  - Enable ADB
  - shell command


