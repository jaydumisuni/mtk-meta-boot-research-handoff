# MTK META Boot / Existing-META Read-Only Research Handoff

Sanitized research bundle generated on 2026-06-18 16:35:33 +02:00.

Purpose: preserve the D2/D3/D4 MTK META boot and existing-META attach research so another ChatGPT/Codex session can continue from GitHub.

## What Is Included

- `scripts/`: runnable PowerShell probe generators for D2, D3, and D4 stages.
- `tools/mtk_meta/`: project-root helpers that can be copied/pulled into the real TGT ATO workspace.
- `reports/`: curated handoff notes, safety rules, export maps, and read-only inventory reports.
- `audit_logs/`: selected stdout/summary evidence from the successful D4 native existing-META runs.
- `generated_sources/`: generated x86 C++ source from the latest D4 runner for ABI review.

## What Is Excluded

- Vendor DLLs and EXEs.
- Object files and compiled probes.
- Downloaded APDB files from the device.
- Raw unique device identifiers; serials and chip IDs are redacted.
- Any destructive operation output.

## Current Technical State

- Existing META attach via native `SP_META_ConnectInMetaModeByUSB` on VID_0E8D PID_2007 succeeded.
- Read-only `SP_META_GetTargetVerInfo_r` and `SP_META_GetChipID_r` succeeded.
- SP modem inventory functions through the AP handle succeeded for capability/type/info/image/mode/status/database paths.
- Device APDB directory was enumerated and matched APDB filenames were identified; APDB binaries are not included here.
- `SP_META_NVRAM_Init_r` accepted the matched local APDB, but identifier getters still returned result `2` in the previous run.
- Separate MD/NVRAM service connector is still the unresolved part. The next focus is native `META_ConnectWithMultiModeTarget_r` / `META_Connect_Ex_Req` recovery.

## Important Correction

`jaydumisuni/mtkclient-meta-mode` is not the read test path. It is only the proven META boot helper. The read path remains this handoff repo's D4 MetaCore runner.

Use it like this:

1. `mtkclient-meta-mode` boots the phone to META when PID_2007 is not already present.
2. `RUN_D4_NATIVE_METACORE_EXISTING_META.ps1` attaches to the already booted PID_2007 META port and performs read-only inventory.
3. `tools/mtk_meta/RUN_D4_SAFE_READ_ORCHESTRATOR.ps1` ties those two together from the real project root.

## Pull + Test Command

From the real TGT ATO project root, after pulling this repo into the workspace:

```powershell
cd "D:\projects\in progress\TGT ATO iDiot proof"
powershell -ExecutionPolicy Bypass -File .\tools\mtk_meta\RUN_D4_SAFE_READ_ORCHESTRATOR.ps1
```

If the device is not already in Kernel META PID_2007, let the orchestrator use `mtkclient-meta-mode` only for booting:

```powershell
cd "D:\projects\in progress\TGT ATO iDiot proof"
powershell -ExecutionPolicy Bypass -File .\tools\mtk_meta\RUN_D4_SAFE_READ_ORCHESTRATOR.ps1 -BootIfNeeded
```

The orchestrator creates an audit folder under:

```text
audit_shared_runtime\D4_SAFE_READ_ORCHESTRATOR_<timestamp>
```

Paste back:

- `orchestrator_summary.json`
- `00_baseline_stdout.txt`
- `01_database_inventory_stdout.txt`
- `02_database_acquire_init_stdout.txt`
- any `native-read-ret`, `database-identifier-ret`, or `vendor-ret` lines

## Safety Lock

Do not run write/reset/destructive functions while continuing this research:

- No NVRAM write
- No FactoryReset
- No FRP / format / unlock
- No shell command
- No reboot/reset
- No Enable ADB unless explicitly approved after valid read-only handle
