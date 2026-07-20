# D5 META five-run investigation protocol

D5 connects the proven META boot helper, the D4 native MetaCore reader, X-Ray-style evidence normalization, and a Sergeant-style examination council into one repeatable read-only campaign.

## One-command workflow

From a clone of this research repository:

```powershell
powershell -ExecutionPolicy Bypass -File .\RUN_D5_META_RESEARCH.ps1 `
  -ProjectRoot "D:\projects\in progress\TGT ATO iDiot proof"
```

The root wrapper defaults to:

- boot Kernel META when PID `2007` is not already present
- retry boot up to five times
- run the five read-only experiments
- sanitize and analyze the evidence
- push only sanitized findings to the `evidence/auto` branch

Add `-OpenPullRequest` when GitHub CLI is installed and authenticated. Use `-NoPublish` for a local-only campaign or `-PrepareOnly -NoPublish` to generate the D5 runner without touching a device.

## The five runs

| Run | Bridge selector | Additional read-only evidence | Purpose |
|---|---|---|---|
| 01 | `Fixed2` | bridge-only baseline | Preserve the previously tested request value. |
| 02 | `CurrentModem` | modem-version query | Test the AP session's observed current modem. |
| 03 | `ConnectionInfo0` | APDB/MDDB inventory | Correlate the first connection-info field with database visibility. |
| 04 | `ConnectionInfo1` | APDB receive/NVRAM init and barcode return code | Compare the second connection-info field after host database initialization. |
| 05 | `CurrentModemType` | IMEI1 return code | Test the observed modem type with a dedicated handle. Identifier values are never published. |

Every run repeats the known-safe AP attach, target-version, chip, modem capability, database-path, handle-allocation, and cleanup sequence. The unknown-ABI exports `META_ConnectWithMultiModeTarget_r` and `META_Connect_Ex_Req` are inventoried only; D5 does not call them.

## Evidence flow

```text
PID_2000 / boot helper
→ PID_2007 / COM observation
→ D4 read-only AP session
→ five selector experiments
→ X-Ray normalization
→ specialist council + challenger
→ confidence dimensions and ranked hypotheses
→ redaction verifier
→ evidence/auto branch
```

Raw output remains under the private project workspace:

```text
audit_shared_runtime\D5-<UTC timestamp>\
```

Only these sanitized files are eligible for publication:

```text
campaign_findings.json
campaign_findings.md
sanitized_excerpts.log
publication_manifest.json
```

The publisher refuses to commit when the publication manifest reports raw logs, write permission, or failed redaction.

## Reading results without copy/paste

The automatic evidence branch maintains:

```text
evidence/latest.json
evidence/index.json
evidence/campaigns/<campaign-id>/...
```

A later ChatGPT/Codex session can inspect `evidence/auto` directly, patch the research code, and ask the operator only to pull and rerun. No three-day console copy/paste loop is required.

## Verdicts

- `META_BOOT_NOT_CERTIFIED`
- `META_BOOT_CERTIFIED__AP_ATTACH_UNSTABLE`
- `META_BOOT_AND_AP_ATTACH_CERTIFIED__MD_SERVICE_INVESTIGATE`
- `MD_SERVICE_RESOLVED_READ_ONLY`

The campaign separately scores boot, AP session, identity read, MD service, identifier read, and ABI stability. A stable AP session does not falsely certify the unresolved MD/NVRAM service.

## Safety boundary

D5 is observation-only.

- no NVRAM write
- no partition write or erase
- no FactoryReset
- no FRP, unlock, format, shell, or reboot command
- no invocation of unresolved connector exports
- no raw identifier or vendor database publication

Write adapters remain outside this public research loop.
