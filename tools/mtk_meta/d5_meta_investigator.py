#!/usr/bin/env python3
"""D5 MTK META evidence normalizer and SRG-style hypothesis analyzer.

This module is intentionally read-only. It consumes console evidence produced by
RUN_D5_META_INVESTIGATION_LOOP.ps1, writes a sanitized public evidence bundle,
and never invokes a device command itself.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import tempfile
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = "d5-meta-observation/1.0"
ANALYZER_VERSION = "0.1.0"

RET_PATTERNS: dict[str, re.Pattern[str]] = {
    "init": re.compile(r"\[ret\]\s+Init=(-?\d+)", re.I),
    "connect": re.compile(r"\[ret\]\s+Connect=(-?\d+)\s+activeHandle=(-?\d+)", re.I),
    "target_ver": re.compile(r"\[ret\]\s+TargetVerInfo=(-?\d+)", re.I),
    "chip_id": re.compile(r"\[ret\]\s+ChipID=(-?\d+)", re.I),
    "query_current_modem": re.compile(r"\[ret\]\s+QueryCurrentModem=(-?\d+)\s+currentModem=(-?\d+)", re.I),
    "query_current_modem_type": re.compile(r"\[ret\]\s+QueryCurrentModemType=(-?\d+)\s+currentModemType=(\d+)", re.I),
    "query_connection_info": re.compile(r"\[ret\]\s+QueryConnectionInfo=(-?\d+)\s+info0=(-?\d+)\s+info1=(-?\d+)", re.I),
    "available_handle": re.compile(r"\[ret\]\s+GetAvailableHandle=(-?\d+)\s+modemHandle=(-?\d+)", re.I),
    "modem_init": re.compile(r"\[ret\]\s+InitModemHandle=(-?\d+)", re.I),
    "modem_connect": re.compile(r"\[ret\]\s+ConnectModem=(-?\d+)", re.I),
    "nvram_init": re.compile(r"\[database-init-ret\]\s+ret=(-?\d+)\s+out=(\d+)", re.I),
    "barcode": re.compile(r"(?:\[database-identifier-ret\]|\[native-read-ret\])\s+Barcode=(-?\d+)", re.I),
    "imei1": re.compile(r"(?:\[database-identifier-ret\]|\[native-read-ret\])\s+IMEI1=(-?\d+)", re.I),
    "imei2": re.compile(r"(?:\[database-identifier-ret\]|\[native-read-ret\])\s+IMEI2=(-?\d+)", re.I),
    "disconnect": re.compile(r"\[ret\]\s+Disconnect=(-?\d+)", re.I),
    "deinit": re.compile(r"\[ret\]\s+Deinit=(-?\d+)", re.I),
}

SENSITIVE_LABEL_RE = re.compile(
    r"(?i)(IMEI1|IMEI2|IMEI|BarcodeText|Barcode|APPSN|PSN|Serial(?:Number)?|ChipID|BTMAC|WIFIMAC)"
    r"\s*(?:=|:)\s*([^\s,;]+)"
)
LONG_DIGIT_RE = re.compile(r"(?<!\d)\d{14,16}(?!\d)")
MAC_RE = re.compile(r"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])")
WINDOWS_USER_RE = re.compile(r"(?i)\b[A-Z]:\\Users\\[^\\\s]+")
PNP_TAIL_RE = re.compile(r"(?i)(VID_0E8D[^\s]*?PID_(?:2000|2007))(?:\\[^\s]+)?")
TOKEN_RE = re.compile(r"(?i)\b(?:ghp_|github_pat_|sk-|TTG-APPROVAL-)[A-Za-z0-9_\-]{8,}\b")
HEX_UNIQUE_RE = re.compile(r"(?i)(\[info\]\s+ChipID=)([0-9a-f]{16,})")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def pseudonym(label: str, value: str) -> str:
    digest = sha256_text(f"{label.lower()}:{value}")[:12]
    return f"<{label.upper()}:{digest}>"


def sanitize_text(text: str, replacements: dict[str, str] | None = None) -> str:
    replacements = replacements or {}
    for original, replacement in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
        if original:
            text = text.replace(original, replacement)

    def replace_label(match: re.Match[str]) -> str:
        label, value = match.group(1), match.group(2)
        if value in {"0", "-1", "None", "none", "null", "NULL"}:
            return match.group(0)
        return f"{label}={pseudonym(label, value)}"

    text = SENSITIVE_LABEL_RE.sub(replace_label, text)
    text = LONG_DIGIT_RE.sub(lambda m: pseudonym("IMEI", m.group(0)), text)
    text = MAC_RE.sub(lambda m: pseudonym("MAC", m.group(0)), text)
    text = WINDOWS_USER_RE.sub(r"C:\\Users\\<USER>", text)
    text = PNP_TAIL_RE.sub(lambda m: f"{m.group(1)}\\<INSTANCE>", text)
    text = TOKEN_RE.sub("<TOKEN:REDACTED>", text)
    text = HEX_UNIQUE_RE.sub(lambda m: m.group(1) + pseudonym("CHIPID", m.group(2)), text)
    return text


def load_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return default


def extract_first(pattern: re.Pattern[str], text: str) -> list[int] | None:
    match = pattern.search(text)
    if not match:
        return None
    return [int(value) for value in match.groups()]


def all_return_codes(text: str) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, pattern in RET_PATTERNS.items():
        values = extract_first(pattern, text)
        if values is None:
            result[key] = None
        elif len(values) == 1:
            result[key] = values[0]
        else:
            result[key] = values
    return result


@dataclass
class RunObservation:
    run_id: str
    label: str
    exit_code: int | None
    timed_out: bool
    duration_ms: int | None
    return_codes: dict[str, Any]
    callback_seen: bool
    exceptions: list[str]
    key_events: list[str]
    stdout_file: str | None
    stderr_file: str | None


def parse_run(entry: dict[str, Any], input_dir: Path) -> tuple[RunObservation, str, str]:
    label = str(entry.get("Label") or entry.get("label") or entry.get("RunId") or "unknown")
    stdout_path = Path(str(entry.get("Stdout") or entry.get("stdout") or ""))
    stderr_path = Path(str(entry.get("Stderr") or entry.get("stderr") or ""))
    if not stdout_path.is_absolute():
        stdout_path = input_dir / stdout_path
    if not stderr_path.is_absolute():
        stderr_path = input_dir / stderr_path

    stdout_text = stdout_path.read_text(encoding="utf-8-sig", errors="replace") if stdout_path.exists() else ""
    stderr_text = stderr_path.read_text(encoding="utf-8-sig", errors="replace") if stderr_path.exists() else ""
    combined = stdout_text + "\n" + stderr_text
    exception_lines = [
        line.strip()
        for line in combined.splitlines()
        if re.search(r"(?i)\[(?:exception|.*-exception)\]|\bTIMEOUT\b|access violation", line)
    ]
    key_events = [
        line.strip()
        for line in stdout_text.splitlines()
        if re.search(
            r"(?i)\[(?:ret|database-init-ret|database-identifier-ret|native-read-ret|vendor-ret|done|gate|guard)\]",
            line,
        )
    ][:200]

    observation = RunObservation(
        run_id=str(entry.get("RunId") or entry.get("run_id") or label),
        label=label,
        exit_code=_coerce_int(entry.get("ExitCode") if "ExitCode" in entry else entry.get("exit_code")),
        timed_out=bool(entry.get("TimedOut") if "TimedOut" in entry else entry.get("timed_out", False)),
        duration_ms=_coerce_int(entry.get("DurationMs") if "DurationMs" in entry else entry.get("duration_ms")),
        return_codes=all_return_codes(combined),
        callback_seen="[callback] TargetVerInfo" in combined,
        exceptions=exception_lines[:100],
        key_events=key_events,
        stdout_file=stdout_path.name if stdout_path.exists() else None,
        stderr_file=stderr_path.name if stderr_path.exists() else None,
    )
    return observation, stdout_text, stderr_text


def _coerce_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def successful(value: Any) -> bool:
    if isinstance(value, list):
        return bool(value) and value[0] == 0
    return value == 0


def ratio(items: Iterable[bool]) -> float:
    values = list(items)
    return sum(1 for item in values if item) / len(values) if values else 0.0


def build_claims(runs: list[RunObservation], usb_timeline: list[dict[str, Any]]) -> list[dict[str, Any]]:
    total = len(runs)
    connect_ratio = ratio(successful(run.return_codes.get("connect")) for run in runs)
    target_ratio = ratio(successful(run.return_codes.get("target_ver")) and run.callback_seen for run in runs)
    chip_ratio = ratio(successful(run.return_codes.get("chip_id")) for run in runs)
    bridge_ratio = ratio(successful(run.return_codes.get("modem_connect")) for run in runs)
    exception_ratio = ratio(bool(run.exceptions) or run.timed_out for run in runs)
    pid2007 = any("2007" in json.dumps(entry) for entry in usb_timeline)
    pid2000 = any("2000" in json.dumps(entry) for entry in usb_timeline)

    return [
        _claim("C1", "Kernel META PID_2007 was observed", pid2007, 0.99 if pid2007 else 0.15, ["usb_timeline.json"]),
        _claim("C2", "Preloader PID_2000 participated in the handover", pid2000, 0.95 if pid2000 else 0.35, ["usb_timeline.json"]),
        _claim(
            "C3",
            "AP-side existing-META attachment is stable",
            connect_ratio >= 0.8 and total >= 3,
            connect_ratio,
            [run.run_id for run in runs if successful(run.return_codes.get("connect"))],
        ),
        _claim(
            "C4",
            "Target-version callback is stable",
            target_ratio >= 0.8 and total >= 3,
            target_ratio,
            [run.run_id for run in runs if successful(run.return_codes.get("target_ver")) and run.callback_seen],
        ),
        _claim(
            "C5",
            "Chip-ID read is stable",
            chip_ratio >= 0.8 and total >= 3,
            chip_ratio,
            [run.run_id for run in runs if successful(run.return_codes.get("chip_id"))],
        ),
        _claim(
            "C6",
            "Dedicated modem/MD bridge is stable",
            bridge_ratio >= 0.6 and total >= 3,
            bridge_ratio,
            [run.run_id for run in runs if successful(run.return_codes.get("modem_connect"))],
        ),
        _claim(
            "C7",
            "Run set is free of native exceptions/timeouts",
            exception_ratio == 0.0,
            1.0 - exception_ratio,
            [run.run_id for run in runs if not run.exceptions and not run.timed_out],
        ),
    ]


def _claim(claim_id: str, statement: str, supported: bool, confidence: float, evidence: list[str]) -> dict[str, Any]:
    return {
        "claim_id": claim_id,
        "statement": statement,
        "status": "SUPPORTED" if supported else "NOT_YET_SUPPORTED",
        "confidence": round(max(0.0, min(1.0, confidence)), 3),
        "evidence": evidence,
    }


def build_hypotheses(runs: list[RunObservation], claims: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ap_ok = _claim_supported(claims, "C3")
    target_ok = _claim_supported(claims, "C4")
    bridge_ok = _claim_supported(claims, "C6")
    any_nvram_init = any(successful(run.return_codes.get("nvram_init")) for run in runs)
    getter_values = [
        run.return_codes.get(name)
        for run in runs
        for name in ("barcode", "imei1", "imei2")
        if run.return_codes.get(name) is not None
    ]
    getters_success = any(successful(value) for value in getter_values)
    getters_ret2 = any(value == 2 for value in getter_values if isinstance(value, int))
    exceptions = any(run.exceptions for run in runs)
    bridge_results = [run.return_codes.get("modem_connect") for run in runs if run.return_codes.get("modem_connect") is not None]
    bridge_consistent_failure = bool(bridge_results) and all(value != 0 for value in bridge_results)

    hypotheses: list[dict[str, Any]] = []
    hypotheses.append(
        _hypothesis(
            "H1",
            "The AP META session is valid, but META_ConnectModem_r is not the correct connector for this target generation.",
            score=0.9 if ap_ok and target_ok and bridge_consistent_failure else 0.35,
            supports=["C3", "C4"] if ap_ok and target_ok else [],
            contradicts=["C6"] if bridge_ok else [],
            next_test="Resolve and test META_ConnectWithMultiModeTarget_r / META_Connect_Ex_Req using the observed modem index and connection fields.",
        )
    )
    hypotheses.append(
        _hypothesis(
            "H2",
            "AP-side handle is being used where a dedicated MD/NVRAM handle is required.",
            score=0.88 if ap_ok and not bridge_ok and (getters_ret2 or any_nvram_init) else 0.4,
            supports=["C3"] if ap_ok else [],
            contradicts=["C6"] if bridge_ok else [],
            next_test="Keep AP and MD handles separate and route identifier getters only through a connector-confirmed MD handle.",
        )
    )
    hypotheses.append(
        _hypothesis(
            "H3",
            "APDB initialization succeeds, but the matching MDDB or modem target selection is incomplete.",
            score=0.86 if any_nvram_init and not getters_success else 0.3,
            supports=[run.run_id for run in runs if successful(run.return_codes.get("nvram_init"))],
            contradicts=[run.run_id for run in runs if any(successful(run.return_codes.get(name)) for name in ("barcode", "imei1", "imei2"))],
            next_test="Correlate SP_META_MODEM_Query_MDDBPath_r output with the selected modem index and initialize the matched MD database before identifier reads.",
        )
    )
    hypotheses.append(
        _hypothesis(
            "H4",
            "One or more function signatures, structure sizes, or calling conventions are wrong.",
            score=0.92 if exceptions else 0.25,
            supports=[run.run_id for run in runs if run.exceptions],
            contradicts=["C7"] if _claim_supported(claims, "C7") else [],
            next_test="Run the ABI examiner against export decorations and isolate one guarded call per process with canary buffers and structure-size logging.",
        )
    )
    hypotheses.append(
        _hypothesis(
            "H5",
            "The PID/COM handover or session timing is unstable.",
            score=0.85 if not ap_ok else 0.2,
            supports=[run.run_id for run in runs if not successful(run.return_codes.get("connect")) or run.timed_out],
            contradicts=["C3"] if ap_ok else [],
            next_test="Increase PID_2000→PID_2007 settling time, require stable COM identity for two polls, then retry AP attach.",
        )
    )
    return sorted(hypotheses, key=lambda item: item["score"], reverse=True)


def _hypothesis(
    hypothesis_id: str,
    statement: str,
    score: float,
    supports: list[str],
    contradicts: list[str],
    next_test: str,
) -> dict[str, Any]:
    return {
        "hypothesis_id": hypothesis_id,
        "statement": statement,
        "score": round(max(0.0, min(1.0, score)), 3),
        "supporting_evidence": supports,
        "contradicting_evidence": contradicts,
        "next_test": next_test,
    }


def _claim_supported(claims: list[dict[str, Any]], claim_id: str) -> bool:
    return any(item["claim_id"] == claim_id and item["status"] == "SUPPORTED" for item in claims)


def choose_verdict(claims: list[dict[str, Any]], runs: list[RunObservation]) -> tuple[str, str]:
    boot = _claim_supported(claims, "C1")
    ap = _claim_supported(claims, "C3") and _claim_supported(claims, "C4") and _claim_supported(claims, "C5")
    bridge = _claim_supported(claims, "C6")
    getter_success = any(
        successful(run.return_codes.get(name))
        for run in runs
        for name in ("barcode", "imei1", "imei2")
    )
    if boot and ap and bridge and getter_success:
        return "READ_PATH_CERTIFIED", "META boot, AP attach, MD bridge, and at least one identifier read are repeatably proven."
    if boot and ap and bridge:
        return "MD_BRIDGE_CONFIRMED", "Dedicated modem bridge is present; database/identifier correlation remains."
    if boot and ap:
        return "AP_META_CERTIFIED_MD_INVESTIGATE", "META boot and AP-side read path are stable; the MD/NVRAM connector remains unresolved."
    if boot:
        return "META_BOOT_CONFIRMED_AP_INVESTIGATE", "Kernel META was reached, but AP attachment is not yet stable."
    return "INCOMPLETE", "The run set did not prove the Kernel META handover."


def choose_next_experiment(verdict: str, hypotheses: list[dict[str, Any]]) -> dict[str, Any]:
    top = hypotheses[0] if hypotheses else None
    mapping = {
        "INCOMPLETE": ("PID_HANDOVER_STABILITY", "Stabilize PID_2000→PID_2007 and COM detection before native calls."),
        "META_BOOT_CONFIRMED_AP_INVESTIGATE": ("AP_ATTACH_TIMING_MATRIX", "Vary post-PID settling time and attach timeout; keep the native call sequence unchanged."),
        "AP_META_CERTIFIED_MD_INVESTIGATE": ("MULTIMODE_CONNECTOR_MATRIX", "Probe META_ConnectWithMultiModeTarget_r and META_Connect_Ex_Req with observed modem/connection fields."),
        "MD_BRIDGE_CONFIRMED": ("DATABASE_ALIGNMENT_MATRIX", "Match APDB/MDDB and validate identifier getters on the dedicated MD handle."),
        "READ_PATH_CERTIFIED": ("GRADUATE_READ_ONLY_CHAIN", "Freeze the proven call sequence into a deterministic read-only transport fixture."),
    }
    experiment_id, objective = mapping.get(verdict, ("REVIEW", "Review the evidence bundle."))
    return {
        "experiment_id": experiment_id,
        "objective": objective,
        "driven_by_hypothesis": top["hypothesis_id"] if top else None,
        "hypothesis_statement": top["statement"] if top else None,
        "safety": "READ_ONLY",
    }


def sanitize_bundle(
    output_dir: Path,
    runs: list[RunObservation],
    raw_logs: dict[str, tuple[str, str]],
    replacements: dict[str, str],
) -> None:
    logs_dir = output_dir / "sanitized_logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    for run in runs:
        stdout, stderr = raw_logs[run.run_id]
        if stdout:
            (logs_dir / f"{run.run_id}_stdout.txt").write_text(
                sanitize_text(stdout, replacements), encoding="utf-8"
            )
        if stderr:
            (logs_dir / f"{run.run_id}_stderr.txt").write_text(
                sanitize_text(stderr, replacements), encoding="utf-8"
            )


def write_manifest(output_dir: Path, run_id: str) -> dict[str, Any]:
    files: list[dict[str, Any]] = []
    for path in sorted(output_dir.rglob("*")):
        if not path.is_file() or path.name == "manifest.json":
            continue
        data = path.read_bytes()
        files.append(
            {
                "path": path.relative_to(output_dir).as_posix(),
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        )
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "analyzer_version": ANALYZER_VERSION,
        "run_id": run_id,
        "created_at": utc_now(),
        "privacy": "SANITIZED_PUBLIC_EVIDENCE",
        "files": files,
    }
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


def render_findings(
    run_id: str,
    verdict: str,
    verdict_reason: str,
    claims: list[dict[str, Any]],
    hypotheses: list[dict[str, Any]],
    next_experiment: dict[str, Any],
    runs: list[RunObservation],
) -> str:
    lines = [
        f"# D5 MTK META findings — `{run_id}`",
        "",
        f"- Verdict: **{verdict}**",
        f"- Reason: {verdict_reason}",
        f"- Runs analyzed: **{len(runs)}**",
        f"- Generated: `{utc_now()}`",
        "- Evidence class: **sanitized, read-only**",
        "",
        "## Claim ledger",
        "",
    ]
    for claim in claims:
        lines.append(
            f"- `{claim['claim_id']}` **{claim['status']}** "
            f"({claim['confidence']:.3f}) — {claim['statement']}"
        )
    lines.extend(["", "## Ranked hypotheses", ""])
    for item in hypotheses:
        lines.extend(
            [
                f"### {item['hypothesis_id']} — score {item['score']:.3f}",
                "",
                item["statement"],
                "",
                f"Next test: {item['next_test']}",
                "",
            ]
        )
    lines.extend(
        [
            "## Next experiment",
            "",
            f"- ID: `{next_experiment['experiment_id']}`",
            f"- Objective: {next_experiment['objective']}",
            f"- Safety: `{next_experiment['safety']}`",
            "",
            "## Per-run summary",
            "",
            "| Run | Exit | AP connect | Target | Chip | MD bridge | NVRAM init | Barcode | IMEI1 | Exceptions |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for run in runs:
        rc = run.return_codes
        lines.append(
            "| {run} | {exit} | {connect} | {target} | {chip} | {bridge} | {nvram} | {barcode} | {imei1} | {exceptions} |".format(
                run=run.run_id,
                exit=run.exit_code,
                connect=_fmt_rc(rc.get("connect")),
                target=_fmt_rc(rc.get("target_ver")),
                chip=_fmt_rc(rc.get("chip_id")),
                bridge=_fmt_rc(rc.get("modem_connect")),
                nvram=_fmt_rc(rc.get("nvram_init")),
                barcode=_fmt_rc(rc.get("barcode")),
                imei1=_fmt_rc(rc.get("imei1")),
                exceptions=len(run.exceptions),
            )
        )
    lines.extend(
        [
            "",
            "Raw local logs, binaries, vendor databases, and unique identifiers are intentionally excluded from this public bundle.",
            "",
        ]
    )
    return "\n".join(lines)


def _fmt_rc(value: Any) -> str:
    if value is None:
        return "—"
    if isinstance(value, list):
        return "/".join(str(item) for item in value)
    return str(value)


def analyze(input_dir: Path, output_dir: Path, run_id: str | None, project_root: str | None) -> dict[str, Any]:
    summary = load_json(input_dir / "orchestrator_summary.json", default=[])
    if isinstance(summary, dict):
        run_entries = summary.get("runs") or summary.get("Runs") or []
        inferred_run_id = summary.get("run_id") or summary.get("RunId")
    elif isinstance(summary, list):
        run_entries = summary
        inferred_run_id = None
    else:
        run_entries = []
        inferred_run_id = None

    run_id = run_id or inferred_run_id or input_dir.name
    output_dir.mkdir(parents=True, exist_ok=True)
    usb_timeline = load_json(input_dir / "usb_timeline.json", default=[])
    if not isinstance(usb_timeline, list):
        usb_timeline = []

    runs: list[RunObservation] = []
    raw_logs: dict[str, tuple[str, str]] = {}
    for entry in run_entries:
        if not isinstance(entry, dict):
            continue
        observation, stdout_text, stderr_text = parse_run(entry, input_dir)
        runs.append(observation)
        raw_logs[observation.run_id] = (stdout_text, stderr_text)

    claims = build_claims(runs, usb_timeline)
    hypotheses = build_hypotheses(runs, claims)
    verdict, verdict_reason = choose_verdict(claims, runs)
    next_experiment = choose_next_experiment(verdict, hypotheses)

    replacements = {str(input_dir): "<D5_AUDIT_ROOT>"}
    if project_root:
        replacements[project_root] = "<PROJECT_ROOT>"
    sanitize_bundle(output_dir, runs, raw_logs, replacements)

    observation = {
        "schema_version": SCHEMA_VERSION,
        "analyzer_version": ANALYZER_VERSION,
        "run_id": run_id,
        "created_at": utc_now(),
        "safety": {
            "mode": "READ_ONLY",
            "device_commands_executed_by_analyzer": False,
            "raw_unique_identifiers_published": False,
            "raw_logs_retained_locally": True,
        },
        "usb_timeline": _sanitize_json(usb_timeline, replacements),
        "runs": [_sanitize_json(asdict(run), replacements) for run in runs],
        "verdict": {"code": verdict, "reason": verdict_reason},
        "next_experiment": next_experiment,
    }
    (output_dir / "observation.json").write_text(json.dumps(observation, indent=2), encoding="utf-8")
    (output_dir / "claim_ledger.json").write_text(json.dumps(claims, indent=2), encoding="utf-8")
    (output_dir / "hypotheses.json").write_text(json.dumps(hypotheses, indent=2), encoding="utf-8")
    (output_dir / "next_experiment.json").write_text(json.dumps(next_experiment, indent=2), encoding="utf-8")
    findings = render_findings(run_id, verdict, verdict_reason, claims, hypotheses, next_experiment, runs)
    (output_dir / "findings.md").write_text(findings, encoding="utf-8")
    manifest = write_manifest(output_dir, run_id)
    return {
        "run_id": run_id,
        "verdict": verdict,
        "next_experiment": next_experiment["experiment_id"],
        "runs": len(runs),
        "manifest_files": len(manifest["files"]),
        "output": str(output_dir),
    }


def _sanitize_json(value: Any, replacements: dict[str, str]) -> Any:
    if isinstance(value, dict):
        return {key: _sanitize_json(item, replacements) for key, item in value.items()}
    if isinstance(value, list):
        return [_sanitize_json(item, replacements) for item in value]
    if isinstance(value, str):
        return sanitize_text(value, replacements)
    return value


def self_test() -> None:
    with tempfile.TemporaryDirectory() as temp_name:
        root = Path(temp_name)
        runs: list[dict[str, Any]] = []
        for index in range(1, 6):
            run_id = f"0{index}_test"
            stdout = root / f"{run_id}_stdout.txt"
            stdout.write_text(
                "\n".join(
                    [
                        "[ret] Init=0",
                        "[ret] Connect=0 activeHandle=3 report=00000000",
                        "[callback] TargetVerInfo token=1 context=0x1 cnf=0x2 first64=00",
                        "[ret] TargetVerInfo=0 token=1 callback=1",
                        "[ret] ChipID=0",
                        "[info] ChipID=0123456789ABCDEF0123456789ABCDEF",
                        "[ret] QueryCurrentModem=0 currentModem=0",
                        "[ret] QueryCurrentModemType=0 currentModemType=2 (0x00000002)",
                        "[ret] QueryConnectionInfo=0 info0=1 info1=2",
                        "[ret] GetAvailableHandle=0 modemHandle=4",
                        "[ret] InitModemHandle=0",
                        "[ret] ConnectModem=2",
                        "[database-init-ret] ret=0 out=1" if index == 3 else "[diagnostic] none",
                        "[database-identifier-ret] IMEI1=2 record=1 text=351234567890123 status=0" if index == 3 else "[native-read] none",
                        "[ret] Disconnect=0",
                        "[ret] Deinit=0",
                    ]
                ),
                encoding="utf-8",
            )
            stderr = root / f"{run_id}_stderr.txt"
            stderr.write_text("", encoding="utf-8")
            runs.append(
                {
                    "RunId": run_id,
                    "Label": run_id,
                    "ExitCode": 0,
                    "TimedOut": False,
                    "DurationMs": 100,
                    "Stdout": str(stdout),
                    "Stderr": str(stderr),
                }
            )
        (root / "orchestrator_summary.json").write_text(
            json.dumps({"run_id": "D5_SELF_TEST", "runs": runs}, indent=2), encoding="utf-8"
        )
        (root / "usb_timeline.json").write_text(
            json.dumps(
                [
                    {"pid": "2000", "pnp": "USB\\VID_0E8D&PID_2000\\UNIQUE"},
                    {"pid": "2007", "pnp": "USB\\VID_0E8D&PID_2007\\UNIQUE"},
                ],
                indent=2,
            ),
            encoding="utf-8",
        )
        result = analyze(root, root / "public", "D5_SELF_TEST", str(root))
        assert result["verdict"] == "AP_META_CERTIFIED_MD_INVESTIGATE", result
        public_text = "\n".join(path.read_text(encoding="utf-8") for path in (root / "public").rglob("*.txt"))
        assert "351234567890123" not in public_text
        assert "0123456789ABCDEF0123456789ABCDEF" not in public_text
        print(json.dumps({"self_test": "PASS", **result}, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    analyze_parser = sub.add_parser("analyze", help="Analyze one D5 audit directory")
    analyze_parser.add_argument("--input", required=True, type=Path)
    analyze_parser.add_argument("--output", required=True, type=Path)
    analyze_parser.add_argument("--run-id")
    analyze_parser.add_argument("--project-root")
    sub.add_parser("self-test", help="Run a synthetic offline proof")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "self-test":
        self_test()
        return 0
    result = analyze(args.input.resolve(), args.output.resolve(), args.run_id, args.project_root)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
