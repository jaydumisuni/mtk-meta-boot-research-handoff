# D5 MTK META investigation loop

D5 connects the proven META boot helper and D4 MetaCore reader into one repeatable five-run investigation loop:

```text
PID_2000 / Preloader observation
→ mtkclient-meta-mode boot helper
→ stable PID_2007 / Kernel META COM port
→ five isolated D4 read-only experiments
→ evidence normalization
→ SRG-style claim and hypothesis ranking
→ X-Ray-style sanitized observation bundle
→ evidence branch / pull request
```

## What it changes

You no longer need to paste three days of console output back into chat. The tool keeps complete raw logs locally, builds a sanitized public bundle, and can push that bundle into this repository as a branch or pull request. The next patch can therefore be based directly on the tool's evidence.

## Default five runs

1. `01_baseline_attach` — AP attach, target version, chip ID, modem inventory, clean shutdown.
2. `02_database_inventory` — APDB/MDDB inventory only.
3. `03_database_acquire_init` — receive matched APDB and initialize the host-side parser; no record writes.
4. `04_native_barcode` — read-only identifier test through the dedicated modem bridge, with the existing allowlisted fallback.
5. `05_native_imei1` — one read-only IMEI record to distinguish AP-session, MD-handle, database, and ABI failures.

Each D4 process is isolated. A crash or bad ABI hypothesis in one run does not contaminate the next run.

## Run it

From the real TGT ATO project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\external\mtk-meta-boot-research-handoff\RUN_D5_META_INVESTIGATION_LOOP.ps1
```

The default behavior is:

- boot to Kernel META automatically when PID_2007 is absent;
- run all five experiments;
- keep raw evidence under `audit_shared_runtime\D5_<timestamp>`;
- sanitize IMEI, serial, barcode, MAC, ChipID, PnP-instance tails, user paths, and token-shaped text;
- push `evidence/d5-<run-id>`;
- create a pull request when GitHub CLI authentication is available.

Useful alternatives:

```powershell
# Local evidence only
.\RUN_D5_META_INVESTIGATION_LOOP.ps1 -PublishMode None

# Push a branch but do not open a PR
.\RUN_D5_META_INVESTIGATION_LOOP.ps1 -PublishMode Branch

# Device is already in PID_2007; never invoke the boot helper
.\RUN_D5_META_INVESTIGATION_LOOP.ps1 -SkipBoot

# Short preliminary run
.\RUN_D5_META_INVESTIGATION_LOOP.ps1 -MaxRuns 3 -PublishMode None
```

## Evidence bundle

The public bundle contains:

```text
observation.json
claim_ledger.json
hypotheses.json
next_experiment.json
findings.md
manifest.json
sanitized_logs/
```

Raw local logs, generated executables, generated C++ sources, APDB/MDDB binaries, vendor DLLs, and unique identifiers are never copied into the public bundle.

## Verdicts

- `INCOMPLETE`
- `META_BOOT_CONFIRMED_AP_INVESTIGATE`
- `AP_META_CERTIFIED_MD_INVESTIGATE`
- `MD_BRIDGE_CONFIRMED`
- `READ_PATH_CERTIFIED`

The analyzer chooses the next read-only experiment from the actual five-run consensus. The expected next step for the currently documented state is `MULTIMODE_CONNECTOR_MATRIX`, targeting `META_ConnectWithMultiModeTarget_r` and `META_Connect_Ex_Req` with observed modem and connection fields.

## Safety boundary

D5 does not add NVRAM writes, factory reset, FRP, formatting, unlock, shell, reboot, or generic destructive calls. The analyzer never invokes the device. It only reads local evidence and writes a sanitized report.

## Offline proof

The analyzer has a dependency-free synthetic self-test:

```powershell
python .\tools\mtk_meta\d5_meta_investigator.py self-test
```
