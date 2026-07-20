from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from meta_common import (
    INTERESTING_MARKERS,
    all_return_codes,
    contains_success,
    count_matching,
    read_text,
    redact_line,
)


def normalize_run(
    campaign_root: Path,
    run: dict[str, Any],
    salt: str,
    roots: list[str],
) -> dict[str, Any]:
    stdout_path = Path(str(run.get("stdout", "")))
    stderr_path = Path(str(run.get("stderr", "")))
    if not stdout_path.is_absolute():
        stdout_path = campaign_root / stdout_path
    if not stderr_path.is_absolute():
        stderr_path = campaign_root / stderr_path

    stdout = read_text(stdout_path)
    stderr = read_text(stderr_path)
    combined = stdout + "\n" + stderr
    return_codes = all_return_codes(combined)

    bridge_source_match = re.search(
        r"\[bridge-request\].*?source=([A-Za-z0-9_]+).*?value=(-?\d+).*?usable=([01])",
        combined,
        re.IGNORECASE,
    )
    bridge_source = str(run.get("bridge_source", "unknown"))
    bridge_value = None
    bridge_usable = None
    if bridge_source_match:
        bridge_source = bridge_source_match.group(1)
        bridge_value = int(bridge_source_match.group(2))
        bridge_usable = bridge_source_match.group(3) == "1"

    file_entries = [
        line.strip()
        for line in combined.splitlines()
        if "[file-inventory-entry]" in line
    ]
    apdb_entries = sum("APDB" in line.upper() for line in file_entries)
    mddb_entries = sum(
        any(token in line.upper() for token in ("MDDB", "BPLGUINFO", "INFOCUSTOMAPPSRCP"))
        for line in file_entries
    )
    exception_lines = [
        line.strip()
        for line in combined.splitlines()
        if "exception" in line.lower() or "access violation" in line.lower()
    ]

    dimensions = {
        "process_completed": int(run.get("exit_code", -999)) == 0
        and not bool(run.get("timed_out")),
        "pid_2007_before": bool((run.get("port_before") or {}).get("pid_2007")),
        "pid_2007_after": bool((run.get("port_after") or {}).get("pid_2007")),
        "metacore_loaded": re.search(
            r"\[load\]\s+MetaCore=0x(?!0+\b)", combined, re.IGNORECASE
        )
        is not None,
        "global_init": contains_success(combined, "Init"),
        "ap_attach": contains_success(combined, "Connect"),
        "target_info": contains_success(combined, "TargetVerInfo")
        and ("callback=1" in combined or "[callback] TargetVerInfo" in combined),
        "chip_id": contains_success(combined, "ChipID"),
        "modem_inventory": any(
            contains_success(combined, key)
            for key in (
                "SpModemCapability",
                "SpCurrentModemType",
                "SpModemState",
                "SpModemInfo",
                "SpMdImgType",
                "SpModemMode",
            )
        ),
        "modem_handle_allocated": contains_success(combined, "GetAvailableHandle"),
        "modem_handle_initialized": contains_success(combined, "InitModemHandle"),
        "modem_bridge_connected": contains_success(combined, "ConnectModem"),
        "database_inventory": count_matching(
            combined, r"\[file-inventory-ret\]\s*Parse=0"
        )
        > 0,
        "apdb_observed": apdb_entries > 0 or "APDB" in combined,
        "mddb_observed": mddb_entries > 0 or "MDDB" in combined,
        "database_received": count_matching(
            combined, r"\[database-receive-ret\].*?\bret=0"
        )
        > 0,
        "nvram_initialized": count_matching(
            combined, r"\[database-init-ret\]\s*ret=0"
        )
        > 0,
        "identifier_read": count_matching(
            combined,
            r"\[(?:native-read-ret|database-identifier-ret|vendor-ret)\].*?=(-?0)\b",
        )
        > 0,
        "multimode_export_present": re.search(
            r"\[resolve\]\s+META_ConnectWithMultiModeTarget_r=0x(?!0+\b)",
            combined,
            re.IGNORECASE,
        )
        is not None,
        "connect_ex_export_present": re.search(
            r"\[resolve\]\s+META_Connect_Ex_Req=0x(?!0+\b)",
            combined,
            re.IGNORECASE,
        )
        is not None,
        "exceptions": len(exception_lines),
    }

    excerpt: list[str] = []
    for line in combined.splitlines():
        if any(marker.lower() in line.lower() for marker in INTERESTING_MARKERS):
            sanitized = redact_line(line, salt=salt, roots=roots)
            if sanitized and sanitized not in excerpt:
                excerpt.append(sanitized)
        if len(excerpt) >= 450:
            excerpt.append("<EXCERPT_TRUNCATED>")
            break

    return {
        "run_id": str(run.get("run_id", "unknown")),
        "label": str(run.get("label", "unknown")),
        "bridge_source": bridge_source,
        "bridge_value": bridge_value,
        "bridge_usable": bridge_usable,
        "diagnostic": str(run.get("diagnostic", "None")),
        "native_read": str(run.get("native_read", "None")),
        "exit_code": int(run.get("exit_code", -999)),
        "timed_out": bool(run.get("timed_out")),
        "duration_seconds": run.get("duration_seconds"),
        "dimensions": dimensions,
        "return_codes": return_codes,
        "database_counts": {
            "apdb_entries": apdb_entries,
            "mddb_entries": mddb_entries,
        },
        "exception_count": len(exception_lines),
        "sanitized_excerpt": excerpt,
    }
