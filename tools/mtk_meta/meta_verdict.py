from __future__ import annotations

from typing import Any


def campaign_verdict(
    runs: list[dict[str, Any]], boot: dict[str, Any]
) -> tuple[str, dict[str, float]]:
    count = max(len(runs), 1)
    attach = sum(r["dimensions"]["ap_attach"] for r in runs)
    target = sum(r["dimensions"]["target_info"] for r in runs)
    bridge = sum(r["dimensions"]["modem_bridge_connected"] for r in runs)
    identifier = sum(r["dimensions"]["identifier_read"] for r in runs)
    no_exceptions = sum(r["dimensions"]["exceptions"] == 0 for r in runs)

    confidence = {
        "boot_confidence": round(1.0 if boot.get("success") else 0.0, 3),
        "ap_session_confidence": round(attach / count, 3),
        "identity_read_confidence": round(target / count, 3),
        "md_service_confidence": round(bridge / count, 3),
        "identifier_read_confidence": round(identifier / count, 3),
        "abi_stability_confidence": round(no_exceptions / count, 3),
    }
    if boot.get("success") and attach == count and target == count and bridge and identifier:
        verdict = "MD_SERVICE_RESOLVED_READ_ONLY"
    elif (
        boot.get("success")
        and attach >= max(1, count - 1)
        and target >= max(1, count - 1)
    ):
        verdict = "META_BOOT_AND_AP_ATTACH_CERTIFIED__MD_SERVICE_INVESTIGATE"
    elif boot.get("success"):
        verdict = "META_BOOT_CERTIFIED__AP_ATTACH_UNSTABLE"
    else:
        verdict = "META_BOOT_NOT_CERTIFIED"
    return verdict, confidence
