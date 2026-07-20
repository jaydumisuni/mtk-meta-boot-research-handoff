#!/usr/bin/env python3
"""Static guard for the D5 read-only research lane."""
from __future__ import annotations

import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CAMPAIGN = ROOT / "tools" / "mtk_meta" / "RUN_D5_META_FIVE_RUN_CAMPAIGN.ps1"
PUBLISHER = ROOT / "tools" / "mtk_meta" / "PUBLISH_D5_FINDINGS.ps1"
ANALYZER = ROOT / "tools" / "mtk_meta" / "meta_investigator.py"


def fail(message: str) -> None:
    raise SystemExit(f"D5 read-only boundary failed: {message}")


def main() -> int:
    campaign = CAMPAIGN.read_text(encoding="utf-8")
    publisher = PUBLISHER.read_text(encoding="utf-8")
    analyzer = ANALYZER.read_text(encoding="utf-8")
    ast.parse(analyzer, filename=str(ANALYZER))

    if '@($boot.MtkPy, "meta", "METAMETA")' not in campaign:
        fail("boot helper invocation changed from the allowlisted META command")
    if 'write_allowed = $false' not in campaign:
        fail("raw campaign no longer fixes write_allowed=false")
    if 'unknown ABI functions are NOT called' not in campaign:
        fail("unknown connector no-call guard is missing")

    direct_mtk_calls = re.findall(
        r'@\(\$boot\.MtkPy,\s*"([^"]+)",\s*"([^"]+)"\)', campaign
    )
    if direct_mtk_calls != [("meta", "METAMETA")]:
        fail(f"unexpected direct mtk.py calls: {direct_mtk_calls}")
    forbidden_cli_tokens = {"-Write", "-Erase", "-Reset", "-Format", "-Unlock", "-Shell", "-Reboot"}
    if any(token in campaign for token in forbidden_cli_tokens):
        fail("D5 runner gained a destructive command-line option")

    allowed_publication_files = {
        "campaign_findings.json",
        "campaign_findings.md",
        "sanitized_excerpts.log",
        "publication_manifest.json",
    }
    match = re.search(r"\$AllowedFiles\s*=\s*@\((.*?)\)", publisher, re.DOTALL)
    if not match:
        fail("publisher allowlist was not found")
    published_names = set(re.findall(r'"([^"]+)"', match.group(1)))
    if published_names != allowed_publication_files:
        fail(f"publisher allowlist changed: {sorted(published_names)}")
    if "raw_logs_included" not in publisher or "redaction_verified" not in publisher:
        fail("publisher manifest checks are missing")
    if "subprocess" in analyzer or "ctypes" in analyzer:
        fail("analyzer gained process or DLL execution capability")

    print("D5 read-only boundary passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
