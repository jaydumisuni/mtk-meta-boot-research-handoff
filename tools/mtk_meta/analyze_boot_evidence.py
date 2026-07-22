#!/usr/bin/env python3
"""Build a sanitized, evidence-weighted verdict from TTG Boot META campaigns."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


RUN_PREFIX = "TTG_BOOT_META_GOLDEN_GATE_"


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return ""


def _json(path: Path) -> dict:
    try:
        value = json.loads(_read(path))
        return value if isinstance(value, dict) else {}
    except json.JSONDecodeError:
        return {}


def _raw_files(run: Path) -> tuple[Path, Path]:
    for child in ("raw_preloader_meta_boot", "raw_preloader_boot"):
        folder = run / child
        stdout = folder / "stdout.txt"
        result = folder / "raw_preloader_boot_result.json"
        if stdout.exists() or result.exists():
            return stdout, result
    return run / "stdout.txt", run / "raw_preloader_boot_result.json"


def _count(text: str, pattern: str) -> int:
    return len(re.findall(pattern, text, flags=re.IGNORECASE | re.MULTILINE))


def _signals(run: Path) -> dict[str, int | bool | str]:
    stdout_path, result_path = _raw_files(run)
    summary_path = run / "golden_gate_summary.json"
    text = _read(stdout_path)
    raw = _json(result_path)
    summary = _json(summary_path)
    modes = raw.get("modes_attempted") if isinstance(raw.get("modes_attempted"), list) else []
    d4 = summary.get("d4") if isinstance(summary.get("d4"), dict) else {}
    d4_signals = d4.get("Signals") or d4.get("signals") or {}
    if not isinstance(d4_signals, dict):
        d4_signals = {}
    d4_pass = all(
        d4_signals.get(key) is True
        for key in ("connectSucceeded", "targetVerInfoSucceeded", "chipIdSucceeded")
    )
    raw_proof = bool(
        raw.get("success") is True
        and modes
        and raw.get("service_kind") == "pid2007"
    )
    return {
        "has_evidence": stdout_path.exists() or result_path.exists() or summary_path.exists(),
        "run_id": run.name.removeprefix(RUN_PREFIX),
        "preloader_windows": _count(text, r"\[OK\] PreLoader found"),
        "ready_misses": _count(text, r"READY not seen"),
        "metasla_responses": _count(text, r"\[RX MODE\].*METASLA"),
        "zero_length_sla_reads": _count(text, r"\[RX SLA\].*length['\"]?\s*:\s*0"),
        "metaforb_reads": _count(text, r"\[RX SLA\].*METAFORB"),
        "static_256_attempts": _count(text, r"\[TX SLA\].*length=256"),
        "advemeta_accepts": _count(text, r"ADVEMETA accepted with ATEMEVDX"),
        "raw_pid2007_proof": raw_proof,
        "already_meta": bool(re.search(r"already in PID_2007", text, flags=re.IGNORECASE)),
        "d4_pass": d4_pass,
        "legacy_false_pass": bool(summary.get("result") == "pass" and not raw_proof),
    }


def _confidence(successes: int, trials: int, floor: float = 0.55) -> float:
    if trials <= 0:
        return floor
    return round(min(0.99, floor + 0.44 * (successes / trials)), 2)


def analyze(audit_root: Path, metacore_inventory: Path | None = None) -> dict:
    runs = []
    for path in sorted(audit_root.glob(f"{RUN_PREFIX}*")):
        if path.is_dir():
            row = _signals(path)
            if row["has_evidence"]:
                runs.append(row)

    def total(key: str) -> int:
        return sum(int(row[key]) for row in runs)

    preloader = total("preloader_windows")
    ready_misses = total("ready_misses")
    advemeta = total("advemeta_accepts")
    static_256 = total("static_256_attempts")
    raw_proofs = total("raw_pid2007_proof")
    d4_passes = total("d4_pass")
    metasla = total("metasla_responses")
    zero_challenge = total("zero_length_sla_reads")

    inventory = _read(metacore_inventory) if metacore_inventory else ""
    callback_markers = {
        "boot_argument_required": "Preloader_BootMode(): invalid arguments!" in inventory,
        "challenge_callback": "SLA challenge callback" in inventory,
        "challenge_end_callback": "SLA challenge end callback" in inventory,
        "sla_start_state": "Need SLA START" in inventory,
    }
    callback_count = sum(callback_markers.values())

    hypotheses = [
        {
            "id": "H1",
            "hypothesis": "TTG misses the short Preloader or READY window.",
            "verdict": "REFUTED" if preloader and ready_misses == 0 else "INVESTIGATE",
            "confidence": _confidence(preloader - ready_misses, preloader),
            "evidence": f"{preloader} Preloader windows; {ready_misses} READY misses.",
        },
        {
            "id": "H2",
            "hypothesis": "ADVEMETA acceptance is sufficient to enumerate Kernel META.",
            "verdict": "REFUTED" if advemeta and raw_proofs == 0 else "INVESTIGATE",
            "confidence": _confidence(advemeta if raw_proofs == 0 else 0, advemeta),
            "evidence": f"{advemeta} ATEMEVDX accepts; {raw_proofs} certified raw PID_2007 transitions.",
        },
        {
            "id": "H3",
            "hypothesis": "The historical static 256-byte response completes this target's SLA stage.",
            "verdict": "REFUTED" if static_256 and raw_proofs == 0 else "INSUFFICIENT",
            "confidence": _confidence(static_256 if raw_proofs == 0 else 0, static_256, 0.6),
            "evidence": f"{static_256} historical attempts; {raw_proofs} certified raw PID_2007 transitions.",
        },
        {
            "id": "H4",
            "hypothesis": "A callback-driven SLA boot context is required after METASLA.",
            "verdict": "SUPPORTED" if metasla and callback_count >= 3 else "INVESTIGATE",
            "confidence": round(min(0.99, 0.55 + 0.06 * min(metasla, 4) + 0.05 * callback_count), 2),
            "evidence": (
                f"{metasla} METASLA responses; {zero_challenge} zero-length post-SLASTART reads; "
                f"{callback_count}/4 MetaCore context markers."
            ),
        },
        {
            "id": "H5",
            "hypothesis": "The existing-META D4 read-only attach layer is the boot blocker.",
            "verdict": "REFUTED" if d4_passes else "INSUFFICIENT",
            "confidence": _confidence(d4_passes, max(d4_passes, 1), 0.65),
            "evidence": f"{d4_passes} read-only D4 attach passes after PID_2007 already existed.",
        },
    ]

    return {
        "schema": "ttg.meta_boot_evidence_council.v1",
        "verdict": "BLOCKED_CALLBACK_AUTH_REQUIRED" if hypotheses[3]["verdict"] == "SUPPORTED" else "NEEDS_MORE_EVIDENCE",
        "counts": {
            "campaigns_with_evidence": len(runs),
            "preloader_windows": preloader,
            "ready_misses": ready_misses,
            "metasla_responses": metasla,
            "zero_length_sla_reads": zero_challenge,
            "metaforb_reads": total("metaforb_reads"),
            "static_256_attempts": static_256,
            "advemeta_accepts": advemeta,
            "certified_raw_pid2007_transitions": raw_proofs,
            "existing_meta_d4_passes": d4_passes,
            "legacy_false_passes": total("legacy_false_pass"),
        },
        "metacore_context_markers": callback_markers,
        "hypotheses": hypotheses,
        "boundary": {
            "allowed": ["token classification", "timing counts", "export/signature metadata", "read-only D4 result codes"],
            "blocked": ["authentication payload extraction", "key replay", "identifier reads", "NVRAM/NVDATA access", "write/reset/unlock operations"],
        },
        "rule": "External products and historical probes are witnesses; only a fresh TTG raw transition plus D4 attach can certify boot.",
    }


def to_markdown(report: dict) -> str:
    counts = report["counts"]
    lines = [
        "# TTG META Boot Evidence Council",
        "",
        f"Verdict: `{report['verdict']}`",
        "",
        "## Counts",
        "",
    ]
    for key, value in counts.items():
        lines.append(f"- `{key}`: {value}")
    lines.extend(["", "## Ranked hypotheses", ""])
    for item in report["hypotheses"]:
        lines.append(
            f"- **{item['id']} {item['verdict']} ({item['confidence']:.2f})**: "
            f"{item['hypothesis']} {item['evidence']}"
        )
    lines.extend([
        "",
        "## Boundary",
        "",
        "This report contains counts and classifications only. It excludes raw serial frames, authentication material, device identifiers, local paths, and proprietary binaries.",
        "",
    ])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audit-root", type=Path, required=True)
    parser.add_argument("--metacore-inventory", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    args = parser.parse_args()
    report = analyze(args.audit_root, args.metacore_inventory)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    args.markdown.write_text(to_markdown(report), encoding="utf-8")
    print(report["verdict"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
