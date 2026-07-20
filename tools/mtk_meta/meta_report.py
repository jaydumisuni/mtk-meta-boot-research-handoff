from __future__ import annotations

import json
import re
from dataclasses import asdict
from pathlib import Path
from typing import Any

from meta_common import (
    ANALYZER_VERSION,
    LONG_DIGITS_RE,
    MAC_RE,
    SCHEMA_VERSION,
    WINDOWS_USER_RE,
    read_text,
    sha256_bytes,
    sha256_file,
    utc_now,
)
from meta_parser import normalize_run
from meta_reasoner import build_hypotheses, build_specialists, campaign_verdict


def build_markdown(report: dict[str, Any]) -> str:
    lines = [
        f"# META campaign {report['campaign_id']}",
        "",
        f"- Verdict: **{report['verdict']}**",
        f"- Created: `{report['created_at']}`",
        f"- Runs: `{len(report['runs'])}`",
        "- Safety: read-only evidence; `write_allowed=false`",
        "",
        "## Confidence dimensions",
        "",
    ]
    for key, value in report["confidence"].items():
        lines.append(f"- `{key}`: `{value:.3f}`")

    lines.extend(["", "## Five-run results", ""])
    lines.append(
        "| Run | Bridge source | AP attach | Target info | MD bridge | "
        "NVRAM init | Identifier | Exceptions |"
    )
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|")
    for run in report["runs"]:
        dimensions = run["dimensions"]
        lines.append(
            f"| {run['run_id']} {run['label']} | {run['bridge_source']} "
            f"({run['bridge_value']}) | {int(dimensions['ap_attach'])} | "
            f"{int(dimensions['target_info'])} | "
            f"{int(dimensions['modem_bridge_connected'])} | "
            f"{int(dimensions['nvram_initialized'])} | "
            f"{int(dimensions['identifier_read'])} | {dimensions['exceptions']} |"
        )

    lines.extend(["", "## Examination council", ""])
    for finding in report["specialists"]:
        lines.append(
            f"### {finding['specialist']}: {finding['verdict']} "
            f"({finding['confidence']:.3f})"
        )
        lines.extend(f"- {item}" for item in finding["evidence"])
        lines.append("")

    lines.extend(["## Ranked hypotheses", ""])
    for hypothesis in report["hypotheses"]:
        lines.append(
            f"### {hypothesis['hypothesis_id']} — {hypothesis['status']} "
            f"({hypothesis['score']:.3f})"
        )
        lines.append(hypothesis["title"])
        lines.append("")
        lines.append("Evidence for:")
        lines.extend(f"- {item}" for item in hypothesis["evidence_for"])
        lines.append("Evidence against:")
        lines.extend(f"- {item}" for item in hypothesis["evidence_against"])
        lines.append(f"Next experiment: {hypothesis['next_experiment']}")
        lines.append("")

    lines.extend(["## Safety boundary", ""])
    lines.extend(
        [
            "- The publication bundle contains no raw stdout/stderr.",
            "- Device identifiers and long raw buffers are hashed or removed.",
            "- The campaign does not call write, reset, format, FRP, unlock, shell, or reboot functions.",
            "- Native connector exports with unknown ABI are inventoried but not called.",
            "",
        ]
    )
    return "\n".join(lines)


def verify_publication(output_dir: Path) -> list[str]:
    problems: list[str] = []
    for path in output_dir.rglob("*"):
        if not path.is_file() or path.name == "publication_manifest.json":
            continue
        text = read_text(path)
        if MAC_RE.search(text):
            problems.append(f"possible MAC address in {path.name}")
        if WINDOWS_USER_RE.search(text):
            problems.append(f"Windows user path in {path.name}")
        for match in LONG_DIGITS_RE.finditer(text):
            problems.append(
                f"bare 14-16 digit value in {path.name}: offset {match.start()}"
            )
        if re.search(
            r"(?i)\b(?:imei|barcode|serialnumber|chipid)\s*[=:]\s*"
            r"(?!<REDACTED)[A-Za-z0-9]{6,}",
            text,
        ):
            problems.append(f"unredacted identifier-like field in {path.name}")
    return sorted(set(problems))


def analyze(campaign_root: Path, output_dir: Path) -> dict[str, Any]:
    manifest_path = campaign_root / "campaign_manifest.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"missing campaign manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    campaign_id = str(manifest.get("campaign_id") or campaign_root.name)
    salt = sha256_bytes(f"{campaign_id}\0ttg-meta-publication-v1".encode())
    roots = [
        str(manifest.get("project_root", "")),
        str(manifest.get("research_repo_root", "")),
        str(campaign_root),
    ]

    runs = [
        normalize_run(campaign_root, run, salt, roots)
        for run in manifest.get("runs", [])
    ]
    boot = dict(manifest.get("boot") or {})
    public_boot = {
        "success": bool(boot.get("success")),
        "attempt_count": len(boot.get("attempts") or []),
        "pid_2000_observed": bool(boot.get("pid_2000_observed")),
        "pid_2007_observed": bool(boot.get("pid_2007_observed")),
        "elapsed_seconds": boot.get("elapsed_seconds"),
    }

    specialists = build_specialists(runs, public_boot)
    hypotheses = build_hypotheses(runs)
    verdict, confidence = campaign_verdict(runs, public_boot)

    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "analyzer_version": ANALYZER_VERSION,
        "campaign_id": campaign_id,
        "created_at": utc_now(),
        "research_mode": "read_only",
        "write_allowed": False,
        "verdict": verdict,
        "confidence": confidence,
        "boot": public_boot,
        "runs": runs,
        "specialists": [asdict(item) for item in specialists],
        "hypotheses": [asdict(item) for item in hypotheses],
        "next_focus": hypotheses[0].next_experiment
        if hypotheses
        else "Collect a complete campaign.",
        "source_manifest_sha256": sha256_file(manifest_path),
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "campaign_findings.json"
    md_path = output_dir / "campaign_findings.md"
    excerpt_path = output_dir / "sanitized_excerpts.log"

    json_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    md_path.write_text(build_markdown(report), encoding="utf-8")
    with excerpt_path.open("w", encoding="utf-8") as stream:
        for run in runs:
            stream.write(f"===== {run['run_id']} {run['label']} =====\n")
            for line in run["sanitized_excerpt"]:
                stream.write(line + "\n")
            stream.write("\n")

    problems = verify_publication(output_dir)
    publication_files = [json_path, md_path, excerpt_path]
    publication_manifest = {
        "schema_version": "ttg.mtk-meta.publication-manifest.v1",
        "campaign_id": campaign_id,
        "created_at": utc_now(),
        "research_mode": "read_only",
        "write_allowed": False,
        "raw_logs_included": False,
        "redaction_verified": not problems,
        "redaction_problems": problems,
        "files": {
            path.name: {
                "sha256": sha256_file(path),
                "size_bytes": path.stat().st_size,
            }
            for path in publication_files
        },
    }
    (output_dir / "publication_manifest.json").write_text(
        json.dumps(publication_manifest, indent=2), encoding="utf-8"
    )
    if problems:
        raise RuntimeError(
            "publication redaction verification failed: " + "; ".join(problems)
        )
    return report
