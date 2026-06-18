# MTK META Boot / Existing-META Read-Only Research Handoff

Sanitized research bundle generated on 2026-06-18 16:35:33 +02:00.

Purpose: preserve the D2/D3/D4 MTK META boot and existing-META attach research so another ChatGPT/Codex session can continue from GitHub.

## What Is Included

- scripts/: runnable PowerShell probe generators for D2, D3, and D4 stages.
- eports/: curated handoff notes, safety rules, export maps, and read-only inventory reports.
- udit_logs/: selected stdout/summary evidence from the successful D4 native existing-META runs.
- generated_sources/: generated x86 C++ source from the latest D4 runner for ABI review.

## What Is Excluded

- Vendor DLLs and EXEs.
- Object files and compiled probes.
- Downloaded APDB files from the device.
- Raw unique device identifiers; serials and chip IDs are redacted.
- Any destructive operation output.

## Current Technical State

- Existing META attach via native SP_META_ConnectInMetaModeByUSB on VID_0E8D PID_2007 COM15 succeeded.
- Read-only SP_META_GetTargetVerInfo_r and SP_META_GetChipID_r succeeded.
- SP modem inventory functions through the AP handle succeeded for capability/type/info/image/mode/status/database paths.
- Device APDB directory was enumerated and matched APDB filenames were identified; APDB binaries are not included here.
- SP_META_NVRAM_Init_r accepted the matched local APDB, but identifier getters still returned result 2.
- Separate MD/NVRAM service connector is still unresolved; next focus is native META_ConnectWithMultiModeTarget_r / META_Connect_Ex_Req recovery.

## Safety Lock

Do not run write/reset/destructive functions while continuing this research:

- No NVRAM write
- No FactoryReset
- No FRP / format / unlock
- No shell command
- No reboot/reset
- No Enable ADB unless explicitly approved after valid read-only handle


