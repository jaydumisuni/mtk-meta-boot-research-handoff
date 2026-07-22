import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "mtk_meta" / "RUN_TTG_MTK_FUNCTIONS_PRELOADER_CONNECT.ps1"


def test_connect_wrapper_uses_real_output_pointer():
    text = SCRIPT.read_text(encoding="utf-8")

    assert "typedef unsigned char (__stdcall *FN_CONNECT)(int, int*);" in text
    assert "int output_port = 0;" in text
    assert "connect(preloader_port, &output_port)" in text


def test_boot_mode_is_default_and_uses_boolean_option():
    text = SCRIPT.read_text(encoding="utf-8")

    assert '[string]$Operation = "BootMode"' in text
    assert "typedef unsigned char (__stdcall *FN_BOOTMODE)(int, unsigned char);" in text
    assert "boot_mode(preloader_port, 1)" in text


def test_probe_resolves_only_approved_runtime_exports():
    text = SCRIPT.read_text(encoding="utf-8")
    resolved = re.findall(r'require_export\(module, "([^"]+)"\)', text)

    assert resolved == [
        "_InitMtkDll@0",
        "_SPMeta_ConnectWithPreloader@8",
        "_SPMeta_Preloader_BootMode@8",
        "_ReleaseMtkDll@0",
    ]


def test_probe_stages_next_to_matched_runtime():
    text = SCRIPT.read_text(encoding="utf-8")

    assert 'Join-Path $backend "ttg_mtk_functions_preloader_connect.exe"' in text
    assert "QT_QPA_PLATFORM_PLUGIN_PATH" in text
