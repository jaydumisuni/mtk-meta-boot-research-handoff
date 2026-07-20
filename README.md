# MTK META Boot / Existing-META Read-Only Research Handoff

Sanitized research bundle generated on 2026-06-18 16:35:33 +02:00 and extended with the D5 automated investigation loop.

Purpose: preserve and advance the D2/D3/D4/D5 MTK META boot, existing-META attach, and MD/NVRAM service research so another ChatGPT/Codex session can continue directly from GitHub.

## What Is Included

- `scripts/`: runnable PowerShell probe generators for D2, D3, and D4 stages.
- `tools/mtk_meta/`: project-root helpers plus the D5 five-run campaign, analyzer, and publisher.
- `reports/`: curated handoff notes, safety rules, export maps, and investigation protocols.
- `audit_logs/`: selected sanitized evidence from successful read-only runs.
- `generated_sources/`: generated x86 C++ source from the latest D4 runner for ABI review.
- `schemas/`: versioned evidence contracts.

## What Is Excluded

- Vendor DLLs and EXEs.
- Object files and compiled probes.
- Downloaded APDB/MDDB files.
- Raw unique device identifiers.
- Raw D5 campaign logs.
- Any destructive operation output.

## Current Technical State

- Existing META attach via native `SP_META_ConnectInMetaModeByUSB` on VID_0E8D PID_2007 succeeded.
- Read-only `SP_META_GetTargetVerInfo_r` and `SP_META_GetChipID_r` succeeded.
- SP modem inventory functions through the AP handle succeeded for capability/type/info/image/mode/status/database paths.
- Device APDB inventory and host-side NVRAM initialization were reached.
- The separate MD/NVRAM service connector remains the focused unresolved part.
- D5 now compares five evidence-backed bridge selector hypotheses rather than repeating one hard-coded request.

## One-command D5 campaign

Pull this repository, then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\RUN_D5_META_RESEARCH.ps1 `
  -ProjectRoot "D:\projects\in progress\TGT ATO iDiot proof"
```

By default this command:

1. detects an existing PID_2007 META port or retries the proven META boot helper up to five times
2. derives a read-only D5 experiment runner from the current D4 runner
3. performs five linked selector/database experiments
4. normalizes evidence with X-Ray-style dimensions
5. challenges findings with transport/session/database/ABI/modem examiners
6. ranks H1-H7 hypotheses
7. redacts identifiers and local paths
8. pushes only sanitized findings to `evidence/auto`

Useful switches:

```text
-NoPublish       keep all results local
-OpenPullRequest open/update the sanitized evidence PR when gh is available
-PrepareOnly     verify/generate the D5 runner without touching a device
-NoBoot          require the phone to already be in PID_2007 META
```

Raw logs remain only under:

```text
audit_shared_runtime\D5-<UTC timestamp>\
```

Sanitized repository evidence is indexed at:

```text
evidence/auto:evidence/latest.json
evidence/auto:evidence/index.json
evidence/auto:evidence/campaigns/<campaign-id>/
```

See [`reports/D5_META_INVESTIGATION_PROTOCOL.md`](reports/D5_META_INVESTIGATION_PROTOCOL.md) for the experiment matrix and evidence contract.

## Older D4 path

`jaydumisuni/mtkclient-meta-mode` is the proven META boot helper. The D4 read path remains:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\mtk_meta\RUN_D4_SAFE_READ_ORCHESTRATOR.ps1 -BootIfNeeded
```

D5 wraps and extends that evidence chain so console output no longer needs to be copied into chat manually.

## Safety Lock

The research lane remains observation-only:

- No NVRAM write
- No partition write or erase
- No FactoryReset
- No FRP / format / unlock
- No shell command
- No reboot/reset command
- Unknown connector ABIs are inventoried but not called
- Raw device identifiers and vendor database files are never published
