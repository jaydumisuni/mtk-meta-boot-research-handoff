#!/usr/bin/env python3
import argparse
import ctypes
import json
import sys
import time
from pathlib import Path

import serial
import serial.tools.list_ports


ACK1 = bytes.fromhex("0400000001000000010000c0")
ACK2 = bytes.fromhex("0400000001000000010000c0")
ACK3 = bytes.fromhex("0600000001000000010000c000800000")
KNOWN_TOKENS = (
    b"READY", b"METASLA", b"METAFORB", b"RANDOM", b"ATEM0001",
    b"ATEM0002", b"ATEMATEM", b"ATEMATEX", b"ATEMEVDX",
    b"TOOBTSAF", b"TCAFTCAF", b"MYROTCAF",
)


class UnsupportedSlaControlFrame(RuntimeError):
    pass


STARTED_AT = time.monotonic()


def log(msg):
    elapsed_ms = int((time.monotonic() - STARTED_AT) * 1000)
    print(f"{msg} t_ms={elapsed_ms}", flush=True)


def port_rows():
    rows = []
    for p in serial.tools.list_ports.comports():
        rows.append({
            "device": p.device,
            "description": p.description or "",
            "vid": p.vid,
            "pid": p.pid,
        })
    return rows


def find_mtk(pid):
    for p in serial.tools.list_ports.comports():
        if (p.vid or 0) == 0x0E8D and (p.pid or 0) == pid:
            return p
        hwid = (p.hwid or "").upper()
        if f"VID:PID=0E8D:{pid:04X}" in hwid or f"PID_{pid:04X}" in hwid:
            return p
    return None


def find_preloader():
    return find_mtk(0x2000) or find_mtk(0x2001)


def find_meta():
    return find_mtk(0x2007)


def safe_port_label(port):
    vid = f"{port.vid:04X}" if port.vid is not None else "----"
    pid = f"{port.pid:04X}" if port.pid is not None else "----"
    return f"{port.device} {port.description or ''} VID_{vid} PID_{pid}"


def read_until(ser, token, seconds, size=512):
    out = b""
    end = time.time() + seconds
    while time.time() < end and token not in out and len(out) < size:
        part = ser.read(min(64, size - len(out)))
        if part:
            out += part
        else:
            time.sleep(0.03)
    return out


def read_until_any(ser, tokens, seconds, size=512):
    out = b""
    end = time.time() + seconds
    while time.time() < end and len(out) < size:
        part = ser.read(min(64, size - len(out)))
        if part:
            out += part
            if any(token in out for token in tokens):
                return out
        else:
            time.sleep(0.005)
    return out


def write_pause(ser, data, wait=0.15):
    ser.write(data)
    time.sleep(wait)


def response_summary(data):
    tokens = [token.decode("ascii") for token in KNOWN_TOKENS if token in data]
    return {"length": len(data), "tokens": tokens}


def escape_comm(ser, function_code):
    handle = getattr(ser, "_port_handle", None)
    if handle is None:
        return False
    return bool(ctypes.windll.kernel32.EscapeCommFunction(handle, function_code))


def purge_all(ser):
    handle = getattr(ser, "_port_handle", None)
    if handle is None:
        return False
    return bool(ctypes.windll.kernel32.PurgeComm(handle, 0x000F))


def ttg_serial_line_setup(ser):
    time.sleep(0.08)
    escape_comm(ser, 3)
    time.sleep(0.02)
    escape_comm(ser, 5)
    time.sleep(0.06)
    escape_comm(ser, 9)
    time.sleep(0.02)
    escape_comm(ser, 3)
    time.sleep(0.02)
    escape_comm(ser, 5)
    time.sleep(0.02)
    purge_all(ser)


def ttg_serial_line_reset(ser):
    time.sleep(0.02)
    escape_comm(ser, 9)
    escape_comm(ser, 3)
    escape_comm(ser, 5)
    purge_all(ser)


def do_atem_ack(ser):
    log("[TX] ATEM ack packets")
    write_pause(ser, ACK1, 0.05)
    write_pause(ser, ACK2, 0.05)
    write_pause(ser, ACK3, 0.1)
    drain = ser.read(32)
    log(f"[RX] ATEM drain {response_summary(drain)}")


def send_disconnect(ser):
    log("[TX] DISCONNECT")
    try:
        write_pause(ser, b"DISCONNECT", 0.01)
    except Exception as exc:
        log(f"[INFO] DISCONNECT write failed during handoff: {exc!r}")


def wait_service_port(baseline, seconds):
    end = time.time() + seconds
    reported = set()
    while time.time() < end:
        meta = find_meta()
        if meta:
            log(f"[SUCCESS] PID_2007 META found: {safe_port_label(meta)}")
            return {"kind": "pid2007", "port": meta.device, "description": meta.description, "vid": meta.vid, "pid": meta.pid}

        current = {p.device: p for p in serial.tools.list_ports.comports()}
        for dev, info in current.items():
            if not dev or dev in baseline or dev in reported:
                continue
            reported.add(dev)
            log(f"[PORT] New COM: {safe_port_label(info)}")
            if (info.vid or 0) == 0x0E8D and (info.pid or 0) == 0x2007:
                log(f"[SUCCESS] PID_2007 META found through new-port watch: {dev}")
                return {"kind": "pid2007", "port": dev, "description": info.description, "vid": info.vid, "pid": info.pid}
        time.sleep(0.05)
    return None


def wait_preloader_until(deadline):
    last_20ff = 0
    while time.time() < deadline:
        meta = find_meta()
        if meta:
            log(f"[SUCCESS] Device already in PID_2007 META: {meta.device}")
            return "meta", meta

        preloader = find_preloader()
        if preloader:
            log(f"[OK] PreLoader found: {safe_port_label(preloader)}")
            return "preloader", preloader

        bad = find_mtk(0x20FF)
        if bad and time.time() - last_20ff > 2:
            log(f"[WARN] PID_20FF visible: {safe_port_label(bad)}")
            last_20ff = time.time()
        time.sleep(0.02)
    return None, None


def boot_mode(port, mode):
    token = mode.encode("ascii")
    log(f"[BOOT] Opening {port} for {mode}")
    ser = serial.Serial(
        port,
        921600,
        timeout=2 if mode == "METAMETA" else 0.2,
        write_timeout=None,
        parity=serial.PARITY_EVEN,
        stopbits=serial.STOPBITS_ONE,
        bytesize=serial.EIGHTBITS,
        rtscts=False,
        dsrdtr=False,
    )
    keep_open = False
    try:
        ttg_serial_line_setup(ser)

        if mode == "METAMETA":
            ready = ser.read(64)
        else:
            ready = read_until(ser, b"READY", 8, 512)
        log(f"[RX READY] {response_summary(ready)}")
        if b"READY" not in ready:
            raise RuntimeError("READY not seen")

        log(f"[TX MODE] {mode}")
        write_pause(ser, token, 0.03)
        resp = read_until_any(
            ser,
            (b"METASLA", b"METAFORB", b"ATEMEVDX", b"ATEMATEM", b"TOOBTSAF", b"TCAFTCAF", b"MYROTCAF"),
            2,
            512,
        )
        log(f"[RX MODE] {response_summary(resp)}")

        if b"METAFORB" in resp:
            log("[INFO] METAFORB present in mode response; using it as the SLA challenge")
            challenge = resp
        elif mode == "ADVEMETA" and b"ATEMEVDX" in resp:
            log("[INFO] ADVEMETA accepted with ATEMEVDX; sending bounded DISCONNECT")
            send_disconnect(ser)
            return
        elif b"METASLA" in resp:
            log("[TX] METASLA pre-ack")
            write_pause(ser, ACK1, 0)
            ttg_serial_line_reset(ser)
            log("[TX] SLASTART")
            write_pause(ser, b"SLASTART\x00", 0.001)
            challenge = read_until_any(ser, (b"METAFORB", b"RANDOM", b"ATEMATEM"), 5, 512)
            log(f"[RX SLA] {response_summary(challenge)}")
        else:
            challenge = resp

        if b"METAFORB" in challenge or b"RANDOM" in challenge or b"METASLA" in resp:
            raise UnsupportedSlaControlFrame(
                "Unsupported SLA control frame. TTG will not guess, capture, store, or replay vendor authentication material."
            )

        elif b"ATEMATEM" in resp:
            do_atem_ack(ser)
            send_disconnect(ser)
        elif any(x in resp for x in (b"ATEMEVDX", b"TOOBTSAF", b"TCAFTCAF", b"MYROTCAF")):
            log("[INFO] direct service response accepted")
            send_disconnect(ser)
        else:
            log("[WARN] Unknown mode response; watching ports anyway")

        if keep_open:
            return ser
        return None
    finally:
        if keep_open:
            log("[HOLD] Leaving serial handle open for caller-side enumeration window")
        else:
            try:
                ser.close()
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audit", required=True)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--post-wait", type=int, default=60)
    parser.add_argument("--modes", default="METAMETA,ADVEMETA")
    args = parser.parse_args()

    audit = Path(args.audit)
    audit.mkdir(parents=True, exist_ok=True)
    result_path = audit / "raw_preloader_boot_result.json"

    result = {
        "success": False,
        "meta_port": None,
        "service_port": None,
        "service_kind": None,
        "modes_attempted": [],
        "attempt_results": [],
        "error": None,
    }

    log("=== TTG RAW PRELOADER META BOOT ===")
    log("Guard: no NVRAM write, no reset/reboot, no FRP/format/unlock, no shell, no ADB enable.")
    log("Power phone OFF and keep USB unplugged until ARMED is printed.")
    (audit / "ports_start.json").write_text(json.dumps(port_rows(), indent=2), encoding="utf-8")

    deadline = time.time() + args.timeout
    log("[ARMED] Plug USB now with no volume buttons.")
    state, preloader = wait_preloader_until(deadline)

    if result["success"]:
        result_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
        return 0

    if state == "meta" and preloader:
        result.update(success=True, meta_port=preloader.device, service_kind="pid2007")
        result_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
        return 0

    if state != "preloader" or not preloader:
        result["error"] = "No PID_2000/PID_2001 PreLoader found before timeout"
        result_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
        return 20

    (audit / "ports_before_boot.json").write_text(json.dumps(port_rows(), indent=2), encoding="utf-8")

    for mode in [m.strip().upper() for m in args.modes.split(",") if m.strip()]:
        if not preloader:
            log(f"[WAIT] Reconnect powered-off phone for next mode: {mode}")
            state, preloader = wait_preloader_until(deadline)
            if state == "meta" and preloader:
                result.update(success=True, meta_port=preloader.device, service_kind="pid2007")
                break
            if state != "preloader" or not preloader:
                result["error"] = f"No PreLoader available for mode {mode}"
                break

        if mode not in ("ADVEMETA", "METAMETA"):
            log(f"[SKIP] Unsupported safe mode token: {mode}")
            continue
        result["modes_attempted"].append(mode)
        baseline = {p.device for p in serial.tools.list_ports.comports()}
        held_ser = None
        attempt_status = "no-pid2007"
        try:
            held_ser = boot_mode(preloader.device, mode)
            attempt_status = "accepted-awaiting-enumeration"
        except UnsupportedSlaControlFrame as exc:
            attempt_status = "blocked-unsupported-control-frame"
            log(f"[BOOT BLOCKED] {mode}: {exc}")
        except Exception as exc:
            attempt_status = "boot-error"
            log(f"[BOOT ERROR] {mode}: {exc!r}")

        service = wait_service_port(baseline, args.post_wait)
        if held_ser:
            try:
                held_ser.close()
                log("[HOLD] Closed held PreLoader handle after enumeration window")
            except Exception:
                pass
        if service:
            attempt_status = "pid2007" if service["kind"] == "pid2007" else "at-service-not-pid2007"
            result["attempt_results"].append({"mode": mode, "status": attempt_status})
            result["service_kind"] = service["kind"]
            result["service_port"] = service["port"]
            if service["kind"] == "pid2007":
                result["success"] = True
                result["meta_port"] = service["port"]
                break
            log(f"[INFO] Readable AT service port found ({service['port']}) but not PID_2007; D4 MetaCore needs PID_2007.")
            break

        if attempt_status == "accepted-awaiting-enumeration":
            attempt_status = "accepted-no-pid2007"
        result["attempt_results"].append({"mode": mode, "status": attempt_status})

        still_pre = find_preloader()
        if not still_pre:
            log("[INFO] PreLoader disappeared; next mode will wait for a fresh reconnect.")
            preloader = None
            continue
        preloader = still_pre

    (audit / "ports_after_boot.json").write_text(json.dumps(port_rows(), indent=2), encoding="utf-8")
    if not result["success"] and not result["error"]:
        statuses = [item["status"] for item in result["attempt_results"]]
        if "blocked-unsupported-control-frame" in statuses:
            result["error"] = "Required SLA control frame is unsupported; no PID_2007 META port found"
        else:
            result["error"] = "No PID_2007 META port found"
    result_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
    return 0 if result["success"] else 30


if __name__ == "__main__":
    sys.exit(main())
