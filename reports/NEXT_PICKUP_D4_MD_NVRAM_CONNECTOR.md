# NEXT PICKUP: D4 MD/NVRAM Connector Recovery

## Ground truth

Do not restart from booting or generic DLL scanning.

The working base is D4 native existing-META:

- Device is already in Kernel META: VID_0E8D PID_2007.
- Native `SP_META_ConnectInMetaModeByUSB` attach succeeds.
- Native AP handle is valid, seen as handle `0` in successful runs.
- `SP_META_GetTargetVerInfo_r` succeeds.
- `SP_META_GetChipID_r` succeeds.
- SP modem inventory / APDB path / file inventory reads succeed through the AP handle.
- Device exposes APDB names such as `APDB_MT6789___W2452` and `APDB_MT6789___W2452_ENUM`.
- `SP_META_NVRAM_Init_r` accepted the matched APDB, but the direct identifier getters still returned result `2`.

## Current blocker

The remaining blocker is not META boot. It is not TargetVerInfo. It is the secondary MD/NVRAM service session.

The next work item is to recover the exact request structure and sequence for one of these native connector paths:

- `META_ConnectWithMultiModeTarget_r`
- `META_Connect_Ex_Req`
- related MD/NVRAM existing-META connector fields

The previous `META_ConnectModem_r` attempt returned result `2` because the request was not fully populated / bound to the existing AP META transport.

## Safety lock

Until the MD/NVRAM handle is proven valid:

- No generic NVRAM read by guessed LID.
- No NVRAM write.
- No reset, reboot, FRP, format, unlock, ADB enable, shell, factory reset.
- No calibration flag read/write if the export can write or changes state.
- No wrapper attach while native MetaCore owns the COM port in the same process.

## Correct continuation sequence

1. Start with the proven D4 native runner.
2. Native init and existing-META attach only:
   - `SP_META_Init`
   - `SP_META_ConnectInMetaModeByUSB`
3. Gate the session with known good reads:
   - `SP_META_GetTargetVerInfo_r`
   - `SP_META_GetChipID_r`
   - SP modem info / APDB path inventory reads
4. Recover and log APDB/MDDB discovery output.
5. Use matched APDB files for NVRAM init.
6. Recover the MD/NVRAM connect request structure before calling identifier getters.
7. Only after the MD/NVRAM handle is valid, call read-only identifier getters one at a time.

## What to inspect next

Use the local DLL set, not GitHub, because binaries are intentionally excluded from this repo.

Focus on disassembling / string cross-referencing:

- `META_ConnectWithMultiModeTarget_r`
- `META_Connect_Ex_Req`
- `META_ConnectModem_r`
- `META_QueryConnectionInfo_r`
- `META_QueryCurrentModem_r`
- `META_GetAvailableHandle`
- `META_Init_r`
- `SP_META_NVRAM_Init_r`
- `META_MISC_GetIMEIRecNum_r`
- `META_MISC_GetIMEILocation_r`

Look for request structures containing these fields:

- COM port number
- existing META / connect-in-META mode flag
- modem index / current modem
- modem type
- database path pointers
- APDB path
- MDDB/BPLGU path
- transport / share / AP channel field
- timeout field
- report pointer / callback pointer

## Stop conditions

Stop and save logs if any of these happen:

- call blocks longer than timeout
- return is result `2` with no valid handle
- access violation before callback/confirmation
- COM port disappears
- any function tries to reset or reconnect the phone

## Success condition

The next milestone is not IMEI yet. The next milestone is:

- AP validation still passes,
- MD/NVRAM connector returns success,
- a second valid handle/session is produced or existing handle is confirmed usable for MD/NVRAM,
- a harmless MD/NVRAM info getter succeeds without result `2`.

After that, PSN/IMEI/BT MAC/Wi-Fi MAC reads can be attempted using matched database contracts.
