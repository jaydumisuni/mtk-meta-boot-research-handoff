#!/usr/bin/env python3
"""Static guard for the D5 read-only research lane."""
from __future__ import annotations

import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CAMPAIGN = ROOT / "tools" / "mtk_meta" / "RUN_D5_META_FIVE_RUN_CAMPAIGN.ps1"
SUPPORT = ROOT / "tools" / "mtk_meta" / "D5_META_SUPPORT.ps1"
BUILDER = ROOT / "tools" / "mtk_meta" / "BUILD_D5_EXPERIMENT_RUNNER.ps1"
PUBLISHER = ROOT / "tools" / "mtk_meta" / "PUBLISH_D5_FINDINGS.ps1"
ANALYZER = ROOT / "tools" / "mtk_meta" / "meta_investigator.py"
ANALYZER_MODULES = [
    ANALYZER,
    ROOT / "tools" / "mtk_meta" / "meta_common.py",
    ROOT / "tools" / "mtk_meta" / "meta_parser.py",
    ROOT / "tools" / "mtk_meta" / "meta_specialists.py",
    ROOT / "tools" / "mtk_meta" / "meta_hypotheses.py",
    ROOT / "tools" / "mtk_meta" / "meta_verdict.py",
    ROOT / "tools" / "mtk_meta" / "meta_reasoner.py",
    ROOT / "tools" / "mtk_meta" / "meta_report.py",
]


def fail(message: str) -> None:
    raise SystemExit(f"D5 read-only boundary failed: {message}")


def main() -> int:
    campaign = CAMPAIGN.read_text(encoding="utf-8")
    support = SUPPORT.read_text(encoding="utf-8")
    builder = BUILDER.read_text(encoding="utf-8")
    combined = "\n".join((campaign, support, builder))
    publisher = PUBLISHER.read_text(encoding="utf-8")

    for module in ANALYZER_MODULES:
        source = module.read_text(encoding="utf-8")
        ast.parse(source, filename=str(module))
        if "subprocess" in source or "ctypes" in source:
            fail(f"analyzer module gained process or DLL execution capability: {module.name}")

    if '@($boot.MtkPy, "meta", "METAMETA")' not in combined:
        fail("boot helper invocation changed from the allowlisted META command")
    if re.search(r"write_allowed\s*=\s*\$false", campaign) is None:
        fail("raw campaign no longer fixes write_allowed=false")
    if 'unknown ABI functions are NOT called' not in combined:
        fail("unknown connector no-call guard is missing")

    direct_mtk_calls = re.findall(
        r'@\(\$boot\.MtkPy,\s*"([^"]+)",\s*"([^"]+)"\)', combined
    )
    if direct_mtk_calls != [("meta", "METAMETA")]:
        fail(f"unexpected direct mtk.py calls: {direct_mtk_calls}")

    forbidden_cli_tokens = {
        "-Write",
        "-Erase",
        "-Reset",
        "-Format",
        "-Unlock",
        "-Shell",
        "-Reboot",
    }
    if any(token in combined for token in forbidden_cli_tokens):
        fail("D5 support, campaign, or generated-runner builder gained a destructive command-line option")

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

    print("D5 read-only boundary passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
