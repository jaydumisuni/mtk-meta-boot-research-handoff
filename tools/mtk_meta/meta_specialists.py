from __future__ import annotations

from typing import Any

from meta_common import SpecialistFinding


def build_specialists(
    runs: list[dict[str, Any]], boot: dict[str, Any]
) -> list[SpecialistFinding]:
    count = max(len(runs), 1)
    attach_count = sum(bool(run["dimensions"]["ap_attach"]) for run in runs)
    target_count = sum(bool(run["dimensions"]["target_info"]) for run in runs)
    bridge_count = sum(
        bool(run["dimensions"]["modem_bridge_connected"]) for run in runs
    )
    nvram_count = sum(bool(run["dimensions"]["nvram_initialized"]) for run in runs)
    exception_count = sum(int(run["dimensions"]["exceptions"]) for run in runs)
    pid_losses = sum(
        run["dimensions"]["pid_2007_before"]
        and not run["dimensions"]["pid_2007_after"]
        for run in runs
    )

    return [
        SpecialistFinding(
            "transport_examiner",
            "STABLE" if boot.get("success") and attach_count >= count - 1 else "UNSTABLE",
            round(
                min(
                    1.0,
                    (attach_count / count + (1.0 if boot.get("success") else 0.0))
                    / 2,
                ),
                3,
            ),
            [
                f"Kernel META boot success={bool(boot.get('success'))}",
                f"AP attach passed in {attach_count}/{count} runs",
                f"PID_2007 was lost after {pid_losses} runs",
            ],
        ),
        SpecialistFinding(
            "session_examiner",
            "AP_SESSION_PROVEN"
            if target_count >= count - 1
            else "AP_SESSION_INCONSISTENT",
            round(target_count / count, 3),
            [
                f"Target-version callback passed in {target_count}/{count} runs",
                f"Dedicated modem bridge passed in {bridge_count}/{count} runs",
            ],
        ),
        SpecialistFinding(
            "database_examiner",
            "HOST_NVRAM_INIT_PROVEN" if nvram_count else "DATABASE_CHAIN_INCOMPLETE",
            round(nvram_count / count, 3),
            [
                f"NVRAM initialization passed in {nvram_count}/{count} runs",
                f"APDB observed={any(r['dimensions']['apdb_observed'] for r in runs)}",
                f"MDDB observed={any(r['dimensions']['mddb_observed'] for r in runs)}",
            ],
        ),
        SpecialistFinding(
            "abi_examiner",
            "NO_NATIVE_EXCEPTIONS"
            if exception_count == 0
            else "ABI_OR_BUFFER_REVIEW_REQUIRED",
            1.0
            if exception_count == 0
            else max(0.1, round(1.0 / (1 + exception_count), 3)),
            [
                f"Native exception count={exception_count}",
                "MultiMode export observed="
                f"{any(r['dimensions']['multimode_export_present'] for r in runs)}",
                "ConnectEx export observed="
                f"{any(r['dimensions']['connect_ex_export_present'] for r in runs)}",
            ],
        ),
        SpecialistFinding(
            "modem_examiner",
            "MD_SERVICE_CONNECTED" if bridge_count else "MD_SERVICE_NOT_CONNECTED",
            round(bridge_count / count, 3),
            [
                f"ConnectModem passed in {bridge_count}/{count} runs",
                "Each run used a separately recorded bridge selector source.",
            ],
        ),
    ]
