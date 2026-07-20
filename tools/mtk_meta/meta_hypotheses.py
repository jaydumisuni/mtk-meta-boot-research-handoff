from __future__ import annotations

from typing import Any

from meta_common import Hypothesis


def build_hypotheses(runs: list[dict[str, Any]]) -> list[Hypothesis]:
    if not runs:
        return []
    count = len(runs)
    ap_ok = sum(r["dimensions"]["ap_attach"] for r in runs)
    bridge_alloc_ok = sum(r["dimensions"]["modem_handle_allocated"] for r in runs)
    bridge_init_ok = sum(r["dimensions"]["modem_handle_initialized"] for r in runs)
    bridge_ok_runs = [r for r in runs if r["dimensions"]["modem_bridge_connected"]]
    bridge_fail_runs = [r for r in runs if not r["dimensions"]["modem_bridge_connected"]]
    nvram_ok = any(r["dimensions"]["nvram_initialized"] for r in runs)
    identifiers_ok = any(r["dimensions"]["identifier_read"] for r in runs)
    mddb_seen = any(r["dimensions"]["mddb_observed"] for r in runs)
    apdb_seen = any(r["dimensions"]["apdb_observed"] for r in runs)
    ret2 = any(2 in codes for r in runs for codes in r["return_codes"].values())
    exceptions = sum(r["dimensions"]["exceptions"] for r in runs)
    pid_loss = any(
        r["dimensions"]["pid_2007_before"]
        and not r["dimensions"]["pid_2007_after"]
        for r in runs
    )
    source_results = {
        r["bridge_source"]: r["dimensions"]["modem_bridge_connected"] for r in runs
    }
    differing_sources = len(source_results) >= 2
    selector_changed_outcome = differing_sources and len(set(source_results.values())) > 1
    exports_present = any(
        r["dimensions"]["multimode_export_present"]
        or r["dimensions"]["connect_ex_export_present"]
        for r in runs
    )

    hypotheses: list[Hypothesis] = []

    score = (
        0.92
        if selector_changed_outcome
        else (0.68 if differing_sources and bridge_fail_runs else 0.25)
    )
    hypotheses.append(
        Hypothesis(
            "H1",
            "The bridge request selector or request-field mapping is wrong for this target.",
            score,
            "SUPPORTED" if score >= 0.7 else "OPEN",
            [
                f"Bridge sources tested: {', '.join(sorted(source_results)) or 'none'}",
                f"Selector changed outcome={selector_changed_outcome}",
            ],
            [
                "Successful bridge sources: "
                f"{', '.join(r['bridge_source'] for r in bridge_ok_runs) or 'none'}"
            ],
            "Promote a successful selector into a deterministic fixture, or recover the request structure before adding fields.",
        )
    )

    score = (
        0.93
        if ap_ok >= count - 1
        and bridge_alloc_ok
        and bridge_init_ok
        and not bridge_ok_runs
        else 0.45
    )
    hypotheses.append(
        Hypothesis(
            "H2",
            "The AP META handle is valid, but the operation needs a distinct MD/NVRAM service handle.",
            score,
            "SUPPORTED" if score >= 0.7 else "OPEN",
            [
                f"AP attach passed {ap_ok}/{count}",
                f"Handle allocation passed {bridge_alloc_ok}/{count}",
                f"Handle initialization passed {bridge_init_ok}/{count}",
                f"Bridge connections passed {len(bridge_ok_runs)}/{count}",
            ],
            ["A successful dedicated bridge would weaken this hypothesis."],
            "Recover and fixture the MultiModeTarget/ConnectEx ABI without calling it until structure size and ownership are proven.",
        )
    )

    score = 0.82 if ap_ok and not bridge_ok_runs and differing_sources else 0.4
    hypotheses.append(
        Hypothesis(
            "H3",
            "The modem index/type selected for the dedicated connection is not the device's active target.",
            score,
            "SUPPORTED" if score >= 0.7 else "OPEN",
            [
                f"Observed selector candidates={', '.join(sorted(source_results))}",
                f"Dedicated bridge success count={len(bridge_ok_runs)}",
            ],
            ["A selector-specific success resolves this directly."],
            "Compare current modem, current modem type, and both connection-info fields against successful vendor traces.",
        )
    )

    score = (
        0.9
        if apdb_seen and nvram_ok and ret2 and not identifiers_ok and not mddb_seen
        else (0.72 if apdb_seen and not mddb_seen else 0.35)
    )
    hypotheses.append(
        Hypothesis(
            "H4",
            "APDB is available but the matching MDDB/service database chain is absent or mismatched.",
            score,
            "SUPPORTED" if score >= 0.7 else "OPEN",
            [
                f"APDB observed={apdb_seen}",
                f"MDDB observed={mddb_seen}",
                f"Host NVRAM init passed={nvram_ok}",
                f"Return code 2 observed={ret2}",
                f"Identifier read passed={identifiers_ok}",
            ],
            ["A matched MDDB plus successful identifier getter would close this hypothesis."],
            "Acquire only matched MDDB metadata/name first, then add a read-only MD database initialization experiment.",
        )
    )

    score = 0.88 if exceptions else 0.18
    hypotheses.append(
        Hypothesis(
            "H5",
            "A calling-convention, structure-size, pointer-lifetime, or buffer-layout mismatch remains.",
            score,
            "SUPPORTED" if score >= 0.7 else "LOW",
            [
                f"Native exception count={exceptions}",
                f"Connector exports observed={exports_present}",
            ],
            ["No native exceptions weaken an immediate ABI-crash explanation."],
            "Generate an export/stack-decoration inventory and compare x86 call sites before invoking any unresolved connector.",
        )
    )

    score = 0.78 if pid_loss or (0 < ap_ok < count) else 0.2
    hypotheses.append(
        Hypothesis(
            "H6",
            "PID/COM handover or session lifetime is being lost between boot, attach, and the MD phase.",
            score,
            "SUPPORTED" if score >= 0.7 else "LOW",
            [f"PID loss observed={pid_loss}", f"AP attach consistency={ap_ok}/{count}"],
            ["Stable PID_2007 and repeated AP attach weaken this hypothesis."],
            "Record monotonic timestamps for PID_2000, PID_2007, COM assignment, Init, Connect, and disconnect events.",
        )
    )

    score = 0.84 if nvram_ok and ret2 and not identifiers_ok else 0.38
    hypotheses.append(
        Hypothesis(
            "H7",
            "The native getter is called before a required modem/database initialization stage.",
            score,
            "SUPPORTED" if score >= 0.7 else "OPEN",
            [
                f"Host NVRAM init passed={nvram_ok}",
                f"Return code 2 observed={ret2}",
                f"Identifier read passed={identifiers_ok}",
            ],
            ["A getter success without additional initialization weakens this hypothesis."],
            "Compare pre-init and post-init return codes in one session while keeping the same validated handle.",
        )
    )

    hypotheses.sort(key=lambda item: item.score, reverse=True)
    return hypotheses
