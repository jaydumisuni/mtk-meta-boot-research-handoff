from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "mtk_meta"))

import meta_investigator  # noqa: E402


BASE_LOG = """
[gate] D5 native MetaCore existing-META only
[load] MetaCore=0x12340000 gle=0
[resolve] META_ConnectWithMultiModeTarget_r=0x12345000
[resolve] META_Connect_Ex_Req=0x12346000
[ret] Init=0
[ret] Connect=0 activeHandle=2
[ret] TargetVerInfo=0 token=1 callback=1
[info] Platform=MT6789
[info] SoftwareVersion=CM6-H8123
[ret] ChipID=0
[info] ChipID=00112233445566778899AABBCCDDEEFF
[ret] SpModemCapability=0
[ret] QueryCurrentModem=0 currentModem=1
[ret] QueryCurrentModemType=0 currentModemType=2
[ret] QueryConnectionInfo=0 info0=1 info1=2
[bridge-request] source={source} value={value} usable=1 offset24
[ret] GetAvailableHandle=0 modemHandle=3
[ret] InitModemHandle=0
[ret] ConnectModem={bridge_ret}
{extra}
[ret] Disconnect=0
[ret] Deinit=0
[done] init=0 connect=0 active=2 targetVer=0 callback=1 chipId=0
"""


class MetaInvestigatorTests(unittest.TestCase):
    def test_five_run_campaign_is_sanitized_and_ranked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runs = []
            sources = ["Fixed2", "CurrentModem", "ConnectionInfo0", "ConnectionInfo1", "CurrentModemType"]
            for index, source in enumerate(sources, start=1):
                run_dir = root / "runs" / f"{index:02d}"
                run_dir.mkdir(parents=True)
                extra = ""
                if index == 3:
                    extra = "[file-inventory-entry] index=0 ret=0 size=123 type=1 name=APDB_MT6789_TEST\n"
                if index == 4:
                    extra = (
                        "[database-receive-ret] name=APDB_MT6789_TEST ret=0 hostSize=123\n"
                        "[database-init-ret] ret=0 out=1\n"
                        "[database-identifier-ret] IMEI1=2 record=1 text=351234567890123 status=0\n"
                    )
                text = BASE_LOG.format(
                    source=source,
                    value=index,
                    bridge_ret=0 if index == 5 else 2,
                    extra=extra,
                )
                (run_dir / "stdout.txt").write_text(text, encoding="utf-8")
                (run_dir / "stderr.txt").write_text("", encoding="utf-8")
                runs.append(
                    {
                        "run_id": f"{index:02d}",
                        "label": source.lower(),
                        "bridge_source": source,
                        "diagnostic": "None",
                        "native_read": "BridgeOnly",
                        "exit_code": 0,
                        "timed_out": False,
                        "duration_seconds": 1.0,
                        "stdout": str((run_dir / "stdout.txt").relative_to(root)),
                        "stderr": str((run_dir / "stderr.txt").relative_to(root)),
                        "port_before": {"pid_2007": True},
                        "port_after": {"pid_2007": True},
                    }
                )
            manifest = {
                "campaign_id": "D5-2026-07-20T10-30-00Z",
                "project_root": r"D:\projects\private\TGT",
                "research_repo_root": r"D:\projects\private\handoff",
                "boot": {
                    "success": True,
                    "attempts": [{"attempt": 1, "success": True}],
                    "pid_2000_observed": True,
                    "pid_2007_observed": True,
                    "elapsed_seconds": 3.2,
                },
                "runs": runs,
            }
            (root / "campaign_manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            output = root / "sanitized"
            report = meta_investigator.analyze(root, output)
            self.assertIn(
                report["verdict"],
                {
                    "META_BOOT_AND_AP_ATTACH_CERTIFIED__MD_SERVICE_INVESTIGATE",
                    "MD_SERVICE_RESOLVED_READ_ONLY",
                },
            )
            self.assertEqual(len(report["runs"]), 5)
            self.assertTrue((output / "publication_manifest.json").exists())
            published = (output / "sanitized_excerpts.log").read_text(encoding="utf-8")
            self.assertNotIn("351234567890123", published)
            self.assertNotIn("00112233445566778899AABBCCDDEEFF", published)
            self.assertIn("REDACTED", published)
            self.assertEqual(meta_investigator.verify_publication(output), [])
            self.assertEqual(report["hypotheses"][0]["hypothesis_id"], "H1")

    def test_redaction_blocks_user_paths_and_mac(self):
        text = r"C:\Users\John\file IMEI=351234567890123 MAC=AA:BB:CC:DD:EE:FF"
        redacted = meta_investigator.redact_line(text, salt="test")
        self.assertNotIn("John", redacted)
        self.assertNotIn("351234567890123", redacted)
        self.assertNotIn("AA:BB:CC:DD:EE:FF", redacted)


if __name__ == "__main__":
    unittest.main()
