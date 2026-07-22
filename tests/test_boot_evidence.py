from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "mtk_meta"))

import analyze_boot_evidence  # noqa: E402


class BootEvidenceTests(unittest.TestCase):
    def test_council_refutes_timing_and_requires_callback_context(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index in range(2):
                run = root / f"TTG_BOOT_META_GOLDEN_GATE_20260722_00000{index}"
                raw = run / "raw_preloader_meta_boot"
                raw.mkdir(parents=True)
                (raw / "stdout.txt").write_text(
                    "\n".join([
                        "[OK] PreLoader found: COM3 VID_0E8D PID_2000",
                        "[RX READY] {'length': 64, 'tokens': ['READY']}",
                        "[RX MODE] {'length': 13, 'tokens': ['READY', 'METASLA']}",
                        "[RX SLA] {'length': 0, 'tokens': []}",
                        "[INFO] ADVEMETA accepted with ATEMEVDX",
                    ]),
                    encoding="utf-8",
                )
                (raw / "raw_preloader_boot_result.json").write_text(
                    json.dumps({"success": False, "modes_attempted": ["METAMETA"], "service_kind": None}),
                    encoding="utf-8",
                )
            inventory = root / "inventory.txt"
            inventory.write_text(
                "\n".join([
                    "Preloader_BootMode(): invalid arguments!",
                    "DumpBootArg(): SLA challenge callback",
                    "DumpBootArg(): SLA challenge end callback",
                    "PreloaderCmd::CMD_BootAsMETA(): Need SLA START!",
                ]),
                encoding="utf-8",
            )
            report = analyze_boot_evidence.analyze(root, inventory)
            self.assertEqual(report["verdict"], "BLOCKED_CALLBACK_AUTH_REQUIRED")
            self.assertEqual(report["counts"]["preloader_windows"], 2)
            self.assertEqual(report["counts"]["ready_misses"], 0)
            self.assertEqual(report["hypotheses"][0]["verdict"], "REFUTED")
            self.assertEqual(report["hypotheses"][3]["verdict"], "SUPPORTED")
            published = analyze_boot_evidence.to_markdown(report)
            self.assertNotIn(str(root), published)
            self.assertNotIn("COM3", published)

    def test_existing_meta_without_raw_attempt_is_a_legacy_false_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run = root / "TTG_BOOT_META_GOLDEN_GATE_20260722_000010"
            raw = run / "raw_preloader_meta_boot"
            raw.mkdir(parents=True)
            (raw / "stdout.txt").write_text("[SUCCESS] Device already in PID_2007 META", encoding="utf-8")
            (raw / "raw_preloader_boot_result.json").write_text(
                json.dumps({"success": True, "modes_attempted": [], "service_kind": "pid2007"}),
                encoding="utf-8",
            )
            (run / "golden_gate_summary.json").write_text(
                json.dumps({
                    "result": "pass",
                    "d4": {
                        "Signals": {
                            "connectSucceeded": True,
                            "targetVerInfoSucceeded": True,
                            "chipIdSucceeded": True,
                        }
                    },
                }),
                encoding="utf-8-sig",
            )
            report = analyze_boot_evidence.analyze(root)
            self.assertEqual(report["counts"]["certified_raw_pid2007_transitions"], 0)
            self.assertEqual(report["counts"]["legacy_false_passes"], 1)
            self.assertEqual(report["counts"]["existing_meta_d4_passes"], 1)


if __name__ == "__main__":
    unittest.main()
