#!/usr/bin/env python3
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

import serial
import serial.tools.list_ports


ACK1 = bytes.fromhex("0400000001000000010000c0")
ACK2 = bytes.fromhex("0400000001000000010000c0")
ACK3 = bytes.fromhex("0600000001000000010000c000800000")
SLA_ACK1 = bytes.fromhex("040000000100000003000000")
SLA_ACK2 = bytes.fromhex("06000000010000000300000001000000")

TECNO_ITEL_SECRET = b"\x4C\xEE\xCB\x1C\xB4\xB1\x1D\x2B\x43\x18\x84\x3F"
INFINIX_SECRET = b"\xC4\x92\xAD\x3A\x61\xF9\xCE\xC3\x13\x7F\xA9\xCB"

METAFORB_RSA = bytes.fromhex(
    "9109d0a071a54b1072ba893395853327333f62acd2033a10cfaffa3a561eed8a3"
    "72a0b66d4fa0747fb8bdcddd9ba7e2b159b3c6727bde3c5598f1a34bd00b0dff3"
    "6d44ad091971c2a9d30bbc1b8fff06062f7ed0dbb1e52557d2b8cf2a2b9816f81"
    "c53d1d23a929ba556d204dd03e6d69a6bcb0491a81d68c634af6b00a1d7a73219"
    "b886251931cbbaec31025cd8b9f8081df24feffb0fa6cfd3098a3c5842583b392"
    "36ff8b5879181e73a1d0a4066fd15a56194a35c3d727f53d45caefe6be29d57aa"
    "44f4c03903b0afaf4eaeff9b908ba174de36497ca4b1a8e75514643d5f6f7b1f0"
    "ad2ee6ddb1ccda5dec9db47986e6817e3befde94c7cb3f84111be65bf"
)


def log(msg):
    print(msg, flush=True)


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


def read_for(ser, seconds, size=512):
    out = b""
    end = time.time() + seconds
    while time.time() < end and len(out) < size:
        part = ser.read(min(64, size - len(out)))
        if part:
            out += part
        else:
            time.sleep(0.03)
    return out


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


def write_pause(ser, data, wait=0.15):
    ser.write(data)
    time.sleep(wait)


def write_large(ser, data, chunk_size=16, wait=0.03):
    if len(data) == 256:
        ser.write_timeout = 2
        ser.write(data)
        time.sleep(0.5)
        return
    for offset in range(0, len(data), chunk_size):
        ser.write(data[offset:offset + chunk_size])
        time.sleep(wait)


def do_atem_ack(ser):
    log("[TX] ATEM ack packets")
    write_pause(ser, ACK1, 0.05)
    write_pause(ser, ACK2, 0.05)
    write_pause(ser, ACK3, 0.1)
    drain = ser.read(32)
    log(f"[RX] ATEM drain {drain!r}")


def send_disconnect(ser):
    log("[TX] DISCONNECT")
    try:
        write_pause(ser, b"DISCONNECT", 0.3)
    except Exception as exc:
        log(f"[INFO] DISCONNECT write failed during handoff: {exc!r}")


def sla_response(challenge):
    if b"METAFORB" in challenge:
        return METAFORB_RSA, "METAFORB_RSA"
    if b"RANDOM" in challenge:
        timeval = challenge[6:10]
        vendor = "tecno_or_itel" if b"EXT" in challenge else "infinix"
        secret = TECNO_ITEL_SECRET if vendor == "tecno_or_itel" else INFINIX_SECRET
        return hashlib.md5(timeval + secret).digest(), f"RANDOM_MD5_{vendor}"
    timeval = challenge[4:8]
    return hashlib.md5(timeval + INFINIX_SECRET).digest(), "META_UNKNOWN_MD5_INFINIX"


def probe_at(port):
    try:
        with serial.Serial(port, 115200, timeout=0.5, write_timeout=0.5) as s:
            try:
                s.reset_input_buffer()
                s.reset_output_buffer()
            except Exception:
                pass
            write_pause(s, b"ATE0\r\n", 0.5)
            r = s.read(256)
            log(f"[AT] {port} ATE0 -> {r[:100]!r}")
            if b"OK" in r or b"AT" in r:
                return True
            write_pause(s, b"AT\r\n", 0.5)
            r = s.read(256)
            log(f"[AT] {port} AT -> {r[:100]!r}")
            return b"OK" in r or b"AT" in r
    except Exception as exc:
        return False


def wait_service_port(baseline, seconds):
    end = time.time() + seconds
    probed = set()
    last_hidden_scan = 0
    while time.time() < end:
        meta = find_meta()
        if meta:
            log(f"[SUCCESS] PID_2007 META found: {safe_port_label(meta)}")
            return {"kind": "pid2007", "port": meta.device, "description": meta.description, "vid": meta.vid, "pid": meta.pid}

        current = {p.device: p for p in serial.tools.list_ports.comports()}
        for dev, info in current.items():
            if not dev or dev in baseline or dev in probed:
                continue
            probed.add(dev)
            log(f"[PORT] New COM: {safe_port_label(info)}")
            if (info.vid or 0) == 0x0E8D and (info.pid or 0) == 0x2007:
                log(f"[SUCCESS] PID_2007 META found through new-port watch: {dev}")
                return {"kind": "pid2007", "port": dev, "description": info.description, "vid": info.vid, "pid": info.pid}
            if probe_at(dev):
                return {"kind": "at_service", "port": dev, "description": info.description, "vid": info.vid, "pid": info.pid}

        # Windows sometimes exposes the new modem/META COM port before list_ports
        # reports it. Probe boundedly so we do not miss the short service window.
        if time.time() - last_hidden_scan > 2:
            last_hidden_scan = time.time()
            current_names = set(current.keys())
            for number in range(1, 101):
                dev = f"COM{number}"
                if dev in baseline or dev in probed or dev in current_names:
                    continue
                probed.add(dev)
                if probe_at(dev):
                    return {"kind": "at_service", "port": dev, "description": "hidden COM scan", "vid": None, "pid": None}
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
        115200,
        timeout=2 if mode == "METAMETA" else 0.2,
        write_timeout=2,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        bytesize=serial.EIGHTBITS,
        rtscts=False,
        dsrdtr=False,
    )
    keep_open = False
    try:
        try:
            ser.dtr = False
            ser.rts = False
            ser.reset_output_buffer()
        except Exception:
            pass

        if mode == "METAMETA":
            ready = ser.read(64)
        else:
            ready = read_until(ser, b"READY", 8, 512)
        log(f"[RX READY] {ready[:160]!r}")
        if b"READY" not in ready:
            raise RuntimeError("READY not seen")

        log(f"[TX MODE] {mode}")
        write_pause(ser, token, 0.03)
        resp = read_for(ser, 2, 512)
        log(f"[RX MODE] {resp[:220]!r}")

        if b"METAFORB" in resp:
            log("[INFO] METAFORB present in mode response; using it as the SLA challenge")
            challenge = resp
        elif mode == "ADVEMETA" and b"ATEMEVDX" in resp:
            log("[INFO] ADVEMETA accepted with ATEMEVDX; sending bounded DISCONNECT")
            send_disconnect(ser)
            return
        elif b"METASLA" in resp:
            log("[TX] SLASTART")
            write_pause(ser, b"SLASTART", 0.2)
            challenge = read_for(ser, 5, 512)
            log(f"[RX SLA] {challenge[:220]!r}")
        else:
            challenge = resp

        if b"METAFORB" in challenge or b"RANDOM" in challenge or (b"METASLA" in resp and challenge):
            response, label = sla_response(challenge)
            log(f"[TX SLA] {label} length={len(response)}")
            if len(response) > 64:
                write_large(ser, response)
                time.sleep(0.6)
            else:
                write_pause(ser, response, 0.2)
            ack = read_for(ser, 4, 256)
            log(f"[RX SLA ACK] {ack[:180]!r}")

            if b"ATEM0001" in ack:
                write_pause(ser, SLA_ACK1, 0.1)
                ack2 = read_for(ser, 3, 128)
                log(f"[RX SLA ACK2] {ack2[:120]!r}")
                if b"ATEM0002" in ack2:
                    write_pause(ser, SLA_ACK2, 0.1)
                    ack3 = read_for(ser, 3, 128)
                    log(f"[RX SLA ACK3] {ack3[:120]!r}")
                send_disconnect(ser)
            elif b"METAFORB" in challenge:
                log("[INFO] METAFORB silent-ack path; keeping PreLoader handle open during enumeration")
                keep_open = True
            elif b"ATEMATEM" in ack:
                do_atem_ack(ser)
                send_disconnect(ser)
            elif mode == "ADVEMETA":
                send_disconnect(ser)
            else:
                log("[INFO] silent SLA handoff; leaving port without extra command")

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
    parser.add_argument("--modes", default="ADVEMETA,METAMETA")
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

        if mode not in ("ADVEMETA", "METAMETA", "FACTFACT", "FACTORYM"):
            log(f"[SKIP] Unsupported safe mode token: {mode}")
            continue
        result["modes_attempted"].append(mode)
        baseline = {p.device for p in serial.tools.list_ports.comports()}
        held_ser = None
        try:
            held_ser = boot_mode(preloader.device, mode)
        except Exception as exc:
            log(f"[BOOT ERROR] {mode}: {exc!r}")

        service = wait_service_port(baseline, args.post_wait)
        if held_ser:
            try:
                held_ser.close()
                log("[HOLD] Closed held PreLoader handle after enumeration window")
            except Exception:
                pass
        if service:
            result["service_kind"] = service["kind"]
            result["service_port"] = service["port"]
            if service["kind"] == "pid2007":
                result["success"] = True
                result["meta_port"] = service["port"]
                break
            log(f"[INFO] Readable AT service port found ({service['port']}) but not PID_2007; D4 MetaCore needs PID_2007.")
            break

        still_pre = find_preloader()
        if not still_pre:
            log("[INFO] PreLoader disappeared; next mode will wait for a fresh reconnect.")
            preloader = None
            continue
        preloader = still_pre

    (audit / "ports_after_boot.json").write_text(json.dumps(port_rows(), indent=2), encoding="utf-8")
    if not result["success"] and not result["error"]:
        result["error"] = "No PID_2007 META port found"
    result_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
    return 0 if result["success"] else 30


if __name__ == "__main__":
    sys.exit(main())
