# D5 Sergeant review adjudication

## Review target

- Original merged change: PR #1
- Original merge commit: `67811cce5e43c021cf27fa73e259759f46e2ae46`
- Review method: pinned `sergeant-reviewer==0.4.0`, isolated checkout, explicit changed-file scope, deterministic officer review, verification-standard check, and proof-suite evidence.

## Initial Sergeant result

Sergeant returned `REQUEST_CHANGES` because:

1. the repository had no recognized project manifest, so the verification standard was incomplete; and
2. the changed scope contains CI and PowerShell orchestration files, which Sergeant correctly classifies as high-risk paths requiring explicit engineering review.

The result was treated as a blocker rather than overridden.

## Confirmed findings and corrections

- Added `pyproject.toml` so project identity and supported Python versions are machine-verifiable.
- Expanded the read-only guard so forbidden destructive command options are checked across the campaign, support module, and generated-runner builder—not only the campaign wrapper.
- Changed timeout handling to terminate the complete Windows process tree, preventing an abandoned child probe from retaining a COM handle or contaminating the next experiment.
- Required the same PID 2007 COM observation to remain stable across consecutive polls before certifying META handover.
- Required a stable META port both before and after every one of the five experiments.
- Added a Windows prepare-only integration proof that generates and parses the derived D5 experiment runner without touching a device.
- Added machine validation for the project manifest and evidence schema.

## High-risk path adjudication

The remaining high-risk-path classification is intentional and accepted only with the following evidence:

- GitHub Actions parses every PowerShell entry point on Windows.
- The generated experiment runner is produced and parsed in prepare-only mode.
- Python 3.10, 3.12, and 3.14 compile and test the analyzer.
- The static read-only guard rejects destructive CLI expansion and unexpected `mtk.py` commands.
- Unknown-ABI connector exports are inventoried but not invoked.
- Publication is restricted to an explicit sanitized-file allowlist and must pass redaction verification.
- Raw device logs, databases, binaries, local paths, and unique identifiers remain outside repository publication.

This adjudication does not waive a grounded correctness, security, architecture, test-contract, or verification finding. The correction PR remains blocked unless the rerun completes with no such finding and all CI evidence passes.
