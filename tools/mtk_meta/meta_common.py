"""Shared primitives for the read-only MTK META campaign analyzer."""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

SCHEMA_VERSION = "ttg.mtk-meta.campaign-findings.v1"
ANALYZER_VERSION = "1.0.0"

INTERESTING_MARKERS = (
    "[gate]",
    "[guard]",
    "[load]",
    "[resolve]",
    "[call]",
    "[ret]",
    "[callback]",
    "[exception]",
    "[diagnostic-",
    "[file-inventory",
    "[database-",
    "[bridge-request]",
    "[native-read",
    "[vendor-",
    "[done]",
)

LONG_DIGITS_RE = re.compile(r"(?<!\d)(\d{14,16})(?!\d)")
MAC_RE = re.compile(r"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])")
LONG_HEX_RE = re.compile(r"(?i)(?<![0-9a-f])([0-9a-f]{24,})(?![0-9a-f])")
WINDOWS_USER_RE = re.compile(r"(?i)\b([a-z]:\\users\\)([^\\\s]+)")
PNP_TAIL_RE = re.compile(r"(?i)(USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\)([^\s]+)")
SENSITIVE_TEXT_RE = re.compile(
    r"(?i)\b(imei(?:1|2)?|barcode(?:text)?|apps?n|psn|serial(?:number)?|chipid)"
    r"\s*([=:])\s*([^\s,;]+)"
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_token(value: str, salt: str, label: str = "VALUE") -> str:
    digest = hashlib.sha256(f"{salt}\0{value}".encode("utf-8", "replace")).hexdigest()[:16]
    return f"<REDACTED_{label}_SHA256:{digest}>"


def redact_line(line: str, *, salt: str, roots: Iterable[str] = ()) -> str:
    result = line.rstrip("\r\n")
    for root in sorted((r for r in roots if r), key=len, reverse=True):
        result = result.replace(root, "<LOCAL_ROOT>")
        result = result.replace(root.replace("\\", "/"), "<LOCAL_ROOT>")

    result = WINDOWS_USER_RE.sub(r"\1<USER>", result)
    result = PNP_TAIL_RE.sub(
        lambda match: match.group(1) + stable_token(match.group(2), salt, "PNP_TAIL"), result
    )
    result = MAC_RE.sub(lambda match: stable_token(match.group(0), salt, "MAC"), result)
    result = LONG_DIGITS_RE.sub(lambda match: stable_token(match.group(1), salt, "DIGITS"), result)

    def sensitive_text_sub(match: re.Match[str]) -> str:
        label, separator, value = match.groups()
        # Return codes such as IMEI1=2 are evidence, not identifiers.
        if re.fullmatch(r"-?\d{1,3}", value):
            return match.group(0)
        return f"{label}{separator}{stable_token(value, salt, label.upper())}"

    result = SENSITIVE_TEXT_RE.sub(sensitive_text_sub, result)
    # Raw buffers and chip IDs are useful only by presence/length in the public bundle.
    result = LONG_HEX_RE.sub(
        lambda match: f"<REDACTED_HEX_LEN:{len(match.group(1))}>", result
    )
    return result


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def contains_success(text: str, key: str) -> bool:
    return re.search(rf"(?im)\b{re.escape(key)}=0(?:\b|\s)", text) is not None


def first_int(text: str, pattern: str) -> int | None:
    match = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
    if not match:
        return None
    try:
        return int(match.group(1), 0)
    except (TypeError, ValueError):
        return None


def all_return_codes(text: str) -> dict[str, list[int]]:
    result: dict[str, list[int]] = {}
    patterns = [
        r"\[(?:ret|native-read-ret|vendor-ret|diagnostic-ret)\]\s*([A-Za-z0-9_]+)=(-?\d+)",
        r"\[database-init-ret\]\s*ret=(-?\d+)",
        r"\[database-identifier-ret\]\s*([A-Za-z0-9_]+)=(-?\d+)",
        r"\[file-inventory-ret\]\s*Parse=(-?\d+)",
        r"\[database-receive-ret\].*?\bret=(-?\d+)",
    ]
    for index, pattern in enumerate(patterns):
        for match in re.finditer(pattern, text, re.IGNORECASE):
            if index == 1:
                key, code = "NvramInit", match.group(1)
            elif index == 3:
                key, code = "FileInventoryParse", match.group(1)
            elif index == 4:
                key, code = "DatabaseReceive", match.group(1)
            else:
                key, code = match.group(1), match.group(2)
            result.setdefault(key, []).append(int(code))
    return result


def count_matching(text: str, pattern: str) -> int:
    return len(re.findall(pattern, text, re.IGNORECASE | re.MULTILINE))


@dataclass
class Hypothesis:
    hypothesis_id: str
    title: str
    score: float
    status: str
    evidence_for: list[str]
    evidence_against: list[str]
    next_experiment: str


@dataclass
class SpecialistFinding:
    specialist: str
    verdict: str
    confidence: float
    evidence: list[str]
