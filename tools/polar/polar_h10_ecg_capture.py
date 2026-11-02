#!/usr/bin/env python3
"""Polar H10 — PMD ECG and/or ACC capture (Linux BlueZ).

Modes:
  (default)    ECG only            130 Hz, 14-bit, int24 µV
  --acc        ECG + ACC together  (ECG started first, ACC started once ECG flows)
  --acc-only   ACC only            --acc-rate 25|50|100|200 Hz, --acc-range 2|4|8 g

Flow:
  1. LE scan for the H10 (default EE:6A:57:F3:9E:00 / name prefix Polar H10)
  2. Connect and negotiate ATT MTU (232; default 23 cannot carry PMD frames)
  3. Enable PMD Data notify + PMD Control indicate (+ optional HR notify)
  4. STOP lingering streams → GET settings → validate → START
  5. Wait for the first frame (ECG: ~30 s after START on H10!; ACC: <1 s) → capture → STOP
  6. Write JSON summary + ECG CSV + ACC CSV + markdown report under docs/verification/

PMD UUIDs (Polar Measurement Data):
  Service  fb005c80-02e7-f387-1cad-8acd2d8df0c8
  Control  fb005c81-02e7-f387-1cad-8acd2d8df0c8  (read / write / indicate)
  Data     fb005c82-02e7-f387-1cad-8acd2d8df0c8  (notify)

Control response layout (Polar BLE SDK):
  [0]=0xF0  [1]=op  [2]=measurement_type  [3]=status  [4]=more  [5:]=params
  status 0 = success, 6 = already in state, 10 = invalid MTU, …

Data frame layout (polar-ble-sdk PmdDataFrame):
  [0]=measurement type (0 ECG, 2 ACC)  [1:9]=timestamp ns (u64 LE, last sample)
  [9]=frame type (bit 0x80 = delta-compressed)  [10:]=payload
  ECG raw type 0: int24 LE µV per sample
  ACC raw type 1: int16 LE X,Y,Z mG per sample (H10)   (type 0: int8, type 2: int24)
  Compressed: reference sample + blocks [bit_width][count][packed signed deltas]

Examples:
  python3 tools/polar/polar_h10_ecg_capture.py                       # ECG
  python3 tools/polar/polar_h10_ecg_capture.py --acc --seconds 20    # ECG + ACC 200 Hz ±8 g
  python3 tools/polar/polar_h10_ecg_capture.py --acc-only --acc-rate 50 --acc-range 2
  python3 tools/polar/polar_h10_ecg_capture.py --backend dbus --acc
  python3 tools/polar/polar_h10_ecg_capture.py --scan-only

Deps: bleak (preferred) or system dbus-python + PyGObject.
  python3 -m venv /tmp/polar-venv && /tmp/polar-venv/bin/pip install bleak
"""
from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import struct
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Awaitable, Callable, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_ADDR = "EE:6A:57:F3:9E:00"
NAME_PREFIX = "Polar H10"

PMD_SERVICE = "fb005c80-02e7-f387-1cad-8acd2d8df0c8"
PMD_CTRL = "fb005c81-02e7-f387-1cad-8acd2d8df0c8"
PMD_DATA = "fb005c82-02e7-f387-1cad-8acd2d8df0c8"
HR_MEAS = "00002a37-0000-1000-8000-00805f9b34fb"
BATTERY = "00002a19-0000-1000-8000-00805f9b34fb"

MT_ECG = 0x00
MT_ACC = 0x02

OP_GET = 0x01
OP_START = 0x02
OP_STOP = 0x03

# PMD setting types (u16 values for 0..2 on H10)
SET_SAMPLE_RATE = 0x00
SET_RESOLUTION = 0x01
SET_RANGE = 0x02

ECG_HZ = 130
ECG_RES = 14
ACC_RES = 16
TZ = timezone(timedelta(hours=8))

STATUS_NAMES = {
    0: "success",
    1: "invalid_op",
    2: "invalid_measurement_type",
    3: "not_supported",
    4: "invalid_length",
    5: "invalid_parameter",
    6: "already_in_state",
    7: "invalid_resolution",
    8: "invalid_sample_rate",
    9: "invalid_range",
    10: "invalid_mtu",
    11: "invalid_channels",
    12: "invalid_state",
    13: "device_in_charger",
    14: "disk_full",
}


def now_iso() -> str:
    return datetime.now(TZ).isoformat(timespec="seconds")


def b2h(b: bytes) -> str:
    return " ".join(f"{x:02x}" for x in b)


def cmd_get(mt: int) -> bytes:
    return bytes([OP_GET, mt])


def cmd_stop(mt: int) -> bytes:
    return bytes([OP_STOP, mt])


def cmd_start(mt: int, settings: Dict[int, int]) -> bytes:
    out = bytearray([OP_START, mt])
    for st in sorted(settings):
        out += bytes([st, 1]) + struct.pack("<H", settings[st])
    return bytes(out)


# Kept for compatibility / docs
ECG_START = cmd_start(MT_ECG, {SET_SAMPLE_RATE: ECG_HZ, SET_RESOLUTION: ECG_RES})
ECG_STOP = cmd_stop(MT_ECG)
GET_ECG = cmd_get(MT_ECG)
ACC_STOP = cmd_stop(MT_ACC)
GET_ACC = cmd_get(MT_ACC)
assert ECG_START == bytes.fromhex("02000001820001010e00")


def parse_cp_response(data: bytes) -> dict:
    """Parse PMD Control Point indicate / response."""
    if not data:
        return {"raw": "", "ok": False, "error": "empty"}
    if data[0] == 0x0F:
        return {"kind": "features", "raw": b2h(data), "features_byte": data[1] if len(data) > 1 else None, "ok": True}
    if data[0] != 0xF0 or len(data) < 4:
        return {"kind": "unknown", "raw": b2h(data), "ok": False}
    status = data[3]
    more = bool(data[4]) if len(data) > 4 else False
    params = data[5:] if len(data) > 5 else b""
    return {
        "kind": "cp_response",
        "raw": b2h(data),
        "op": data[1],
        "measurement_type": data[2],
        "status": status,
        "status_name": STATUS_NAMES.get(status, f"code_{status}"),
        "more": more,
        "params": b2h(params),
        "ok": status == 0,
    }


def parse_settings(params_hex: str) -> Dict[int, List[int]]:
    """GET-settings params → {setting_type: [values]} (types 0..2 are u16 lists)."""
    p = bytes.fromhex(params_hex.replace(" ", "")) if params_hex else b""
    out: Dict[int, List[int]] = {}
    i = 0
    while i + 2 <= len(p):
        st, cnt = p[i], p[i + 1]
        i += 2
        if st in (SET_SAMPLE_RATE, SET_RESOLUTION, SET_RANGE):
            vals = [struct.unpack_from("<H", p, i + 2 * k)[0] for k in range(cnt) if i + 2 * k + 2 <= len(p)]
            out[st] = vals
            i += 2 * cnt
        else:
            break  # unknown setting width — stop parsing
    return out


# ---------------------------------------------------------------------------
# Data frame parsing
# ---------------------------------------------------------------------------

def _signed(v: int, bits: int) -> int:
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def parse_delta_frames(payload: bytes, channels: int, resolution: int) -> List[List[int]]:
    """polar-ble-sdk parseDeltaFramesAll: ref sample + [bit_width][count][LSB-first packed deltas]."""
    nb = math.ceil(resolution / 8)
    ref = [_signed(int.from_bytes(payload[c * nb:(c + 1) * nb], "little"), resolution) for c in range(channels)]
    samples = [ref]
    off = channels * nb
    while off + 2 <= len(payload):
        width, count = payload[off], payload[off + 1]
        off += 2
        nbits = width * count * channels
        nbytes = math.ceil(nbits / 8)
        block = int.from_bytes(payload[off:off + nbytes], "little")
        off += nbytes
        if width == 0:
            for _ in range(count):
                samples.append(list(samples[-1]))
            continue
        bit = 0
        for _ in range(count):
            prev = samples[-1]
            nxt = []
            for c in range(channels):
                d = _signed((block >> bit) & ((1 << width) - 1), width)
                bit += width
                nxt.append(prev[c] + d)
            samples.append(nxt)
    return samples


def parse_frame_header(data: bytes) -> Optional[Tuple[int, int, int, bool, bytes]]:
    """→ (measurement_type, timestamp_ns, frame_type, compressed, payload)."""
    if not data or len(data) < 10:
        return None
    ts = int.from_bytes(data[1:9], "little", signed=False)
    ft = data[9]
    return data[0], ts, ft & 0x7F, bool(ft & 0x80), data[10:]


def parse_ecg_frame(data: bytes) -> tuple[Optional[int], List[int]]:
    """Return (timestamp_ns, samples_uV). Raw frame type 0 = int24 LE µV."""
    h = parse_frame_header(data)
    if not h or h[0] != MT_ECG:
        return None, []
    _, ts, ft, comp, raw = h
    if comp:
        return ts, [s[0] for s in parse_delta_frames(raw, 1, 24)]
    if ft != 0:
        return ts, []
    return ts, [int.from_bytes(raw[i:i + 3], "little", signed=True) for i in range(0, len(raw) - 2, 3)]


ACC_RAW_WIDTH = {0: 1, 1: 2, 2: 3}  # bytes per axis


def parse_acc_frame(data: bytes) -> tuple[Optional[int], int, bool, List[Tuple[int, int, int]]]:
    """Return (timestamp_ns, frame_type, compressed, [(x_mg, y_mg, z_mg)])."""
    h = parse_frame_header(data)
    if not h or h[0] != MT_ACC:
        return None, -1, False, []
    _, ts, ft, comp, raw = h
    if comp:
        # Compressed type 1 = 16-bit refs/deltas; factor assumed 1.0 (H10 does not send these)
        res = 16 if ft == 1 else 16
        return ts, ft, True, [tuple(s) for s in parse_delta_frames(raw, 3, res)]
    w = ACC_RAW_WIDTH.get(ft)
    if not w:
        return ts, ft, False, []
    step = 3 * w
    out = []
    for i in range(0, len(raw) - step + 1, step):
        out.append(tuple(int.from_bytes(raw[i + k * w:i + (k + 1) * w], "little", signed=True) for k in range(3)))
    return ts, ft, False, out


def parse_hr(data: bytes) -> int:
    flags = data[0]
    if flags & 0x01:
        return struct.unpack_from("<H", data, 1)[0]
    return data[1]


# ---------------------------------------------------------------------------
# Result model
# ---------------------------------------------------------------------------

@dataclass
class Stream:
    name: str
    nominal_hz: float
    wanted: bool = False
    settings: Dict[str, int] = field(default_factory=dict)
    available: Dict[str, List[int]] = field(default_factory=dict)
    start_status: Optional[str] = None
    frames: int = 0
    frame_sizes: List[int] = field(default_factory=list)
    frame_ts: List[int] = field(default_factory=list)
    frame_types: Dict[str, int] = field(default_factory=dict)
    compressed_frames: int = 0
    unparsed_frames: int = 0
    samples: list = field(default_factory=list)
    sample_ts: List[int] = field(default_factory=list)
    start_wall: Optional[float] = None
    first_wall: Optional[float] = None
    last_wall: Optional[float] = None

    def add(self, ts: int, ft: int, comp: bool, samples: list, log: Callable[[str], None]) -> None:
        key = f"{ft}{'+delta' if comp else ''}"
        self.frame_types[key] = self.frame_types.get(key, 0) + 1
        if comp:
            if self.compressed_frames == 0:
                log(f"{self.name}: delta-compressed frame type {ft} detected (decoded, factor=1)")
            self.compressed_frames += 1
        if not samples:
            if self.unparsed_frames == 0:
                log(f"{self.name}: unsupported frame type {ft} — skipped")
            self.unparsed_frames += 1
            return
        now = time.time()
        if self.first_wall is None:
            self.first_wall = now
            if self.start_wall is not None:
                log(f"first {self.name} frame {now - self.start_wall:.1f}s after START")
        self.last_wall = now
        n = len(samples)
        # per-sample timestamps (polar-ble-sdk PmdTimeStampUtils): frame ts = last sample
        if self.frame_ts and ts > self.frame_ts[-1]:
            delta = (ts - self.frame_ts[-1]) / n
        else:
            delta = 1e9 / self.nominal_hz
        self.sample_ts.extend(int(round(ts - (n - 1 - i) * delta)) for i in range(n))
        self.frames += 1
        self.frame_sizes.append(n)
        self.frame_ts.append(ts)
        self.samples.extend(samples)

    def stats(self) -> dict:
        n = len(self.samples)
        out: dict = {
            "wanted": self.wanted,
            "settings": self.settings,
            "available_settings": self.available,
            "start_status": self.start_status,
            "frames": self.frames,
            "samples": n,
            "frame_types": self.frame_types,
            "compressed_frames": self.compressed_frames,
            "unparsed_frames": self.unparsed_frames,
        }
        if self.frames:
            out["samples_per_frame"] = round(n / self.frames, 2)
        if len(self.frame_ts) >= 2:
            dt = (self.frame_ts[-1] - self.frame_ts[0]) / 1e9
            if dt > 0:
                out["rate_hz_sensor"] = round(sum(self.frame_sizes[1:]) / dt, 2)
                out["duration_s_sensor"] = round(dt, 2)
        if self.first_wall and self.last_wall and self.last_wall > self.first_wall:
            out["rate_hz_wall"] = round(sum(self.frame_sizes[1:]) / (self.last_wall - self.first_wall), 2)
        if self.first_wall and self.start_wall:
            out["first_frame_delay_s"] = round(self.first_wall - self.start_wall, 1)
        return out


@dataclass
class CaptureResult:
    started_at: str = ""
    ended_at: str = ""
    addr: str = DEFAULT_ADDR
    backend: str = ""
    mode: str = "ecg"
    ok: bool = False
    mtu: Optional[int] = None
    battery: Optional[int] = None
    ctrl: List[dict] = field(default_factory=list)
    frames: int = 0
    bytes_total: int = 0
    hr_bpm: List[int] = field(default_factory=list)
    errors: List[str] = field(default_factory=list)
    steps: List[str] = field(default_factory=list)
    cccd_data: Optional[str] = None
    other_frames: int = 0
    ecg: Stream = field(default_factory=lambda: Stream("ECG", ECG_HZ))
    acc: Stream = field(default_factory=lambda: Stream("ACC", 200))

    # compatibility helpers
    @property
    def ecg_samples(self) -> List[int]:
        return self.ecg.samples

    @property
    def ecg_frames(self) -> int:
        return self.ecg.frames

    @property
    def acc_frames(self) -> int:
        return self.acc.frames

    def log(self, msg: str) -> None:
        print(msg, flush=True)
        self.steps.append(msg)

    def add_data(self, raw: bytes) -> None:
        """Account one PMD Data notification (ECG type 0 / ACC type 2)."""
        self.frames += 1
        self.bytes_total += len(raw)
        h = parse_frame_header(raw)
        if h and h[0] == MT_ECG:
            ts, samples = parse_ecg_frame(raw)
            self.ecg.add(ts or 0, h[2], h[3], samples, self.log)
        elif h and h[0] == MT_ACC:
            ts, ft, comp, samples = parse_acc_frame(raw)
            self.acc.add(ts or 0, ft, comp, samples, self.log)
        else:
            self.other_frames += 1
        if self.frames <= 6 or self.frames % 50 == 0:
            self.log(
                f"DATA#{self.frames} len={len(raw)} ecg={len(self.ecg.samples)} acc={len(self.acc.samples)} "
                f"head={b2h(raw[:16])}"
            )

    def acc_stats(self) -> dict:
        s = self.acc.stats()
        if self.acc.samples:
            n = len(self.acc.samples)
            for k, ax in enumerate("xyz"):
                col = [v[k] for v in self.acc.samples]
                s[f"{ax}_min_mg"] = min(col)
                s[f"{ax}_max_mg"] = max(col)
                s[f"{ax}_mean_mg"] = round(sum(col) / n, 1)
            mags = [math.sqrt(x * x + y * y + z * z) for x, y, z in self.acc.samples]
            s["magnitude_mean_mg"] = round(sum(mags) / n, 1)
            s["magnitude_min_mg"] = round(min(mags), 1)
            s["magnitude_max_mg"] = round(max(mags), 1)
            s["magnitude_sane_1g"] = 800 <= s["magnitude_mean_mg"] <= 1200
            s["preview"] = [list(v) for v in self.acc.samples[:10]]
        return s

    def ecg_stats(self) -> dict:
        s = self.ecg.stats()
        if self.ecg.samples:
            v = self.ecg.samples
            s["min_uv"] = min(v)
            s["max_uv"] = max(v)
            s["mean_uv"] = round(sum(v) / len(v), 1)
            s["preview"] = v[:40]
        return s

    def summary(self) -> dict:
        e = self.ecg_stats()
        return {
            "started_at": self.started_at,
            "ended_at": self.ended_at,
            "addr": self.addr,
            "backend": self.backend,
            "mode": self.mode,
            "ok": self.ok,
            "mtu": self.mtu,
            "battery": self.battery,
            "frames": self.frames,
            "bytes_total": self.bytes_total,
            # legacy flat keys
            "ecg_sample_count": len(self.ecg.samples),
            "ecg_frames": self.ecg.frames,
            "ecg_rate_hz_sensor": e.get("rate_hz_sensor"),
            "ecg_first_frame_delay_s": e.get("first_frame_delay_s"),
            "acc_frames": self.acc.frames,
            "acc_sample_count": len(self.acc.samples),
            "ecg": e,
            "acc": self.acc_stats(),
            "other_frames": self.other_frames,
            "hr_count": len(self.hr_bpm),
            "hr_bpm_preview": self.hr_bpm[:24],
            "ctrl": self.ctrl,
            "cccd_data": self.cccd_data,
            "errors": self.errors,
            "steps": self.steps,
        }

    def short(self) -> str:
        e, a = self.ecg.stats(), self.acc.stats()
        parts = [f"mode={self.mode} mtu={self.mtu} frames={self.frames}"]
        if self.ecg.wanted or self.ecg.frames:
            parts.append(
                f"ECG frames={e['frames']} samples={e['samples']} spf={e.get('samples_per_frame')} "
                f"rate={e.get('rate_hz_sensor')}Hz delay={e.get('first_frame_delay_s')}s"
            )
        if self.acc.wanted or self.acc.frames:
            m = self.acc_stats().get("magnitude_mean_mg")
            parts.append(
                f"ACC frames={a['frames']} samples={a['samples']} spf={a.get('samples_per_frame')} "
                f"rate={a.get('rate_hz_sensor')}Hz delay={a.get('first_frame_delay_s')}s |a|={m}mg"
            )
        parts.append(f"hr={len(self.hr_bpm)}")
        return "  ".join(parts)


# ---------------------------------------------------------------------------
# Backend-independent streaming flow
# ---------------------------------------------------------------------------

CpWrite = Callable[[bytes, str], Awaitable[None]]
Wait = Callable[[float, Optional[Callable[[], bool]]], Awaitable[None]]


def _last_cp(result: CaptureResult, op: int, mt: int) -> Optional[dict]:
    for c in reversed(result.ctrl):
        if c.get("kind") == "cp_response" and c.get("op") == op and c.get("measurement_type") == mt:
            return c
    return None


async def _start_stream(result: CaptureResult, cp_write: CpWrite, stream: Stream, mt: int,
                        wanted: Dict[int, int]) -> bool:
    n0 = len(result.ctrl)
    await cp_write(cmd_get(mt), f"GET_{stream.name}")
    g = _last_cp(result, OP_GET, mt) if len(result.ctrl) > n0 else None
    if g and g["ok"]:
        avail = parse_settings(g["params"])
        names = {SET_SAMPLE_RATE: "sample_rate", SET_RESOLUTION: "resolution", SET_RANGE: "range"}
        stream.available = {names[k]: v for k, v in avail.items() if k in names}
        for st, val in wanted.items():
            if st in avail and val not in avail[st]:
                msg = f"{stream.name}: {names[st]}={val} not supported (device offers {avail[st]})"
                result.errors.append(msg)
                result.log(msg)
                return False
        result.log(f"{stream.name} settings offered: {stream.available}")
    else:
        result.log(f"{stream.name}: GET settings gave no/failed response — starting with requested values")
    stream.settings = {
        {SET_SAMPLE_RATE: "sample_rate", SET_RESOLUTION: "resolution", SET_RANGE: "range"}[k]: v
        for k, v in wanted.items()
    }
    stream.start_wall = time.time()
    n0 = len(result.ctrl)
    await cp_write(cmd_start(mt, wanted), f"{stream.name}_START")
    r = _last_cp(result, OP_START, mt) if len(result.ctrl) > n0 else None
    stream.start_status = r["status_name"] if r else "no_response"
    if not r or not r["ok"]:
        result.errors.append(f"{stream.name} START: {stream.start_status}")
        return False
    return True


async def run_streams(args: argparse.Namespace, result: CaptureResult, cp_write: CpWrite, wait: Wait) -> None:
    ecg, acc = result.ecg, result.acc
    acc_settings = {SET_SAMPLE_RATE: args.acc_rate, SET_RESOLUTION: ACC_RES, SET_RANGE: args.acc_range}
    ecg_settings = {SET_SAMPLE_RATE: ECG_HZ, SET_RESOLUTION: ECG_RES}

    for mt, lab in ((MT_ECG, "ECG_STOP"), (MT_ACC, "ACC_STOP")):
        try:
            await cp_write(cmd_stop(mt), lab)
        except Exception as e:
            result.log(f"{lab}: {e}")

    async def wait_first(stream: Stream, timeout: float) -> None:
        # H10 quirk: START acks at once, but the first PMD stream of a connection only
        # delivers its first frame ~30 s later (ECG *and* ACC). A stream started while
        # another one is already flowing arrives within ~0.5 s.
        result.log(f"waiting up to {timeout:.0f}s for first {stream.name} frame …")
        t0 = time.time()
        while stream.frames == 0 and time.time() - t0 < timeout:
            await wait(5.0, lambda: stream.frames > 0)
            if stream.frames == 0:
                result.log(f"  … {time.time() - t0:.0f}s, no {stream.name} yet (HR={result.hr_bpm[-1:]})")
        if stream.frames == 0:
            result.errors.append(f"no {stream.name} frame within {timeout:.0f}s of START")

    if ecg.wanted:
        if await _start_stream(result, cp_write, ecg, MT_ECG, ecg_settings):
            await wait_first(ecg, args.first_frame_timeout)

    if acc.wanted:
        # ACC starts after ECG is flowing (or ECG timed out) so both windows line up
        if await _start_stream(result, cp_write, acc, MT_ACC, acc_settings):
            await wait_first(acc, args.first_frame_timeout)

    if (ecg.wanted and ecg.frames) or (acc.wanted and acc.frames):
        result.log(f"capturing {args.seconds:.0f}s …")
        await wait(args.seconds, None)

    if ecg.wanted and not ecg.frames and not acc.wanted and args.also_acc:
        result.log("no ECG frames — starting ACC to validate the Data path")
        acc.wanted = True
        if await _start_stream(result, cp_write, acc, MT_ACC, acc_settings):
            await wait(min(8.0, args.seconds), None)

    for mt, lab in ((MT_ECG, "ECG_STOP"), (MT_ACC, "ACC_STOP")):
        try:
            await cp_write(cmd_stop(mt), lab)
        except Exception as e:
            result.log(f"{lab}: {e}")


def judge(args: argparse.Namespace, result: CaptureResult) -> None:
    ok = True
    if args.mode_ecg:
        ok = ok and result.ecg.frames > 0
    if args.mode_acc:
        ok = ok and result.acc.frames > 0
    result.ok = ok


# ---------------------------------------------------------------------------
# Bleak backend
# ---------------------------------------------------------------------------

async def run_bleak(args: argparse.Namespace, result: CaptureResult) -> int:
    try:
        from bleak import BleakClient, BleakScanner
    except ImportError:
        result.errors.append("bleak not installed")
        result.log("bleak missing — pip install bleak (or use --backend dbus)")
        return 10

    result.backend = "bleak"

    async def find_addr(timeout: float) -> Optional[str]:
        found = None

        def cb(device, adv):
            nonlocal found
            if found:
                return
            name = device.name or ""
            if device.address.upper() == args.addr.upper() or name.startswith(NAME_PREFIX):
                found = device.address
                result.log(f"seen {device.address} name={name!r} rssi={adv.rssi}")

        result.log(f"scanning up to {timeout:.0f}s for {args.addr} / {NAME_PREFIX}*")
        async with BleakScanner(detection_callback=cb):
            t0 = time.time()
            while time.time() - t0 < timeout and found is None:
                await asyncio.sleep(0.2)
        return found

    addr = await find_addr(args.scan_timeout)
    if args.scan_only:
        result.ok = addr is not None
        result.log("scan-only done" if addr else "not seen")
        return 0 if addr else 2
    if not addr:
        result.errors.append("device not seen (offline or out of range)")
        result.log("FAIL: device not seen")
        return 2

    result.addr = addr
    client = BleakClient(addr, timeout=40.0)
    connected = False
    for attempt in range(1, args.connect_retries + 1):
        try:
            result.log(f"connect attempt {attempt}/{args.connect_retries}")
            await client.connect()
            if client.is_connected:
                connected = True
                break
        except Exception as e:
            result.log(f"connect error: {e}")
            await asyncio.sleep(4.0)  # rapid reconnects → le-connection-abort
    if not connected:
        result.errors.append("connect failed")
        return 3

    result.log("connected")
    try:
        try:
            await client._backend._acquire_mtu()
            result.mtu = client.mtu_size
            result.log(f"ATT MTU={result.mtu}")
        except Exception as e:
            result.errors.append(f"mtu: {e}")
            result.log(f"MTU acquire failed: {e} (continuing; PMD may stay empty)")

        try:
            bat = await client.read_gatt_char(BATTERY)
            result.battery = int(bat[0])
            result.log(f"battery={result.battery}%")
        except Exception as e:
            result.log(f"battery read: {e}")

        def on_ctrl(_handle, data: bytearray):
            parsed = parse_cp_response(bytes(data))
            result.ctrl.append(parsed)
            result.log(f"CTRL {parsed.get('raw')} → {parsed.get('status_name', parsed.get('kind'))}")

        def on_data(_handle, data: bytearray):
            result.add_data(bytes(data))

        def on_hr(_handle, data: bytearray):
            bpm = parse_hr(bytes(data))
            result.hr_bpm.append(bpm)
            if len(result.hr_bpm) <= 3 or len(result.hr_bpm) % 20 == 0:
                result.log(f"HR {bpm}")

        await client.start_notify(PMD_CTRL, on_ctrl)
        await client.start_notify(PMD_DATA, on_data)  # before any START
        result.log("CTRL indicate + DATA notify on")
        if not args.no_hr:
            try:
                await client.start_notify(HR_MEAS, on_hr)
            except Exception as e:
                result.log(f"HR notify: {e}")

        try:
            feat = await client.read_gatt_char(PMD_CTRL)
            result.ctrl.append(parse_cp_response(bytes(feat)))
            result.log(f"CTRL read {b2h(bytes(feat))}")
        except Exception as e:
            result.log(f"CTRL read: {e}")

        async def cp_write(payload: bytes, label: str) -> None:
            await client.write_gatt_char(PMD_CTRL, bytearray(payload), response=True)
            result.log(f"WRITE {label}: {b2h(payload)}")
            await asyncio.sleep(0.5)

        async def wait(seconds: float, until: Optional[Callable[[], bool]]) -> None:
            t0 = time.time()
            while time.time() - t0 < seconds:
                if until and until():
                    return
                await asyncio.sleep(0.1)

        await run_streams(args, result, cp_write, wait)

        for uuid in (PMD_DATA, PMD_CTRL, HR_MEAS):
            try:
                await client.stop_notify(uuid)
            except Exception:
                pass
    finally:
        try:
            await client.disconnect()
            result.log("disconnected")
        except Exception as e:
            result.log(f"disconnect: {e}")

    judge(args, result)
    return 0 if result.ok else 6


# ---------------------------------------------------------------------------
# D-Bus / BlueZ backend (no bleak)
# ---------------------------------------------------------------------------

def run_dbus(args: argparse.Namespace, result: CaptureResult) -> int:
    try:
        from dbus.mainloop.glib import DBusGMainLoop
        from gi.repository import GLib
        import dbus
        import select
    except ImportError as e:
        result.errors.append(f"dbus backend deps: {e}")
        result.log("need dbus-python + PyGObject for --backend dbus")
        return 10

    result.backend = "dbus"
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    adapter = "/org/bluez/hci0"
    DEV = f"/org/bluez/hci0/dev_{args.addr.replace(':', '_').upper()}"

    def om():
        return dbus.Interface(
            bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager"
        ).GetManagedObjects()

    def props(path: str):
        return dbus.Interface(bus.get_object("org.bluez", path), "org.freedesktop.DBus.Properties")

    def gatt(path: str):
        return dbus.Interface(bus.get_object("org.bluez", path), "org.bluez.GattCharacteristic1")

    def drain(sec: float) -> None:
        t0 = time.time()
        while time.time() - t0 < sec:
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            time.sleep(0.02)

    def find_char(uuid: str) -> Optional[str]:
        u = uuid.lower()
        for path, ifaces in om().items():
            if not str(path).startswith(DEV + "/"):
                continue
            ch = ifaces.get("org.bluez.GattCharacteristic1")
            if ch and str(ch.get("UUID", "")).lower() == u:
                return str(path)
        return None

    def find_cccd(char_path: str) -> Optional[str]:
        for path, ifaces in om().items():
            if not str(path).startswith(char_path + "/"):
                continue
            d = ifaces.get("org.bluez.GattDescriptor1")
            if d and str(d.get("UUID", "")).lower().startswith("00002902"):
                return str(path)
        return None

    def connected() -> bool:
        try:
            return bool(props(DEV).Get("org.bluez.Device1", "Connected"))
        except Exception:
            return False

    def scan(timeout: float) -> bool:
        ad = dbus.Interface(bus.get_object("org.bluez", adapter), "org.bluez.Adapter1")
        try:
            ad.SetDiscoveryFilter({"Transport": "le", "DuplicateData": False})
        except Exception:
            pass
        result.log(f"scanning up to {timeout:.0f}s")
        try:
            ad.StartDiscovery()
        except Exception as e:
            result.log(f"StartDiscovery: {e}")
        t0 = time.time()
        seen = False
        while time.time() - t0 < timeout:
            if DEV in om():
                try:
                    rssi = int(props(DEV).Get("org.bluez.Device1", "RSSI"))
                except Exception:
                    rssi = None
                try:
                    name = str(props(DEV).Get("org.bluez.Device1", "Name"))
                except Exception:
                    name = "?"
                result.log(f"seen name={name} rssi={rssi}")
                if rssi is not None:
                    seen = True
                    break
            drain(0.25)
        try:
            ad.StopDiscovery()
        except Exception:
            pass
        return seen or DEV in om()

    def connect(timeout: float) -> bool:
        dev = dbus.Interface(bus.get_object("org.bluez", DEV), "org.bluez.Device1")
        for attempt in range(1, args.connect_retries + 1):
            if connected():
                break
            result.log(f"connect attempt {attempt}/{args.connect_retries}")
            try:
                dev.Connect()
            except Exception as e:
                result.log(f"Connect: {e}")
            t0 = time.time()
            while time.time() - t0 < 8 and not connected():
                drain(0.2)
            if connected():
                break
            time.sleep(4)
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                if connected() and bool(props(DEV).Get("org.bluez.Device1", "ServicesResolved")):
                    result.log("connected + ServicesResolved")
                    return True
            except Exception:
                pass
            drain(0.2)
        return False

    def on_props(iface, changed, invalidated, path=None):
        if iface != "org.bluez.GattCharacteristic1" or "Value" not in changed:
            return
        val = bytes(changed["Value"])
        try:
            uuid = str(props(str(path)).Get("org.bluez.GattCharacteristic1", "UUID")).lower()
        except Exception:
            return
        if uuid == PMD_CTRL:
            parsed = parse_cp_response(val)
            result.ctrl.append(parsed)
            result.log(f"CTRL {parsed.get('raw')} → {parsed.get('status_name', parsed.get('kind'))}")
        elif uuid == HR_MEAS:
            bpm = parse_hr(val)
            result.hr_bpm.append(bpm)
            if len(result.hr_bpm) <= 3 or len(result.hr_bpm) % 20 == 0:
                result.log(f"HR {bpm}")
        elif uuid == PMD_DATA:
            result.add_data(val)

    bus.add_signal_receiver(
        on_props,
        dbus_interface="org.freedesktop.DBus.Properties",
        signal_name="PropertiesChanged",
        path_keyword="path",
    )

    if not scan(args.scan_timeout):
        result.errors.append("device not seen (offline or out of range)")
        result.log("FAIL: device not seen")
        return 2
    if args.scan_only:
        result.ok = True
        return 0
    if not connect(35):
        result.errors.append("connect failed")
        result.log("FAIL: connect")
        return 3

    drain(0.8)
    ctrl = find_char(PMD_CTRL)
    data = find_char(PMD_DATA)
    hr = find_char(HR_MEAS)
    bat = find_char(BATTERY)
    if not ctrl or not data:
        result.errors.append("PMD characteristics missing")
        return 4
    result.log(f"ctrl={ctrl}")
    result.log(f"data={data}")

    if bat:
        try:
            result.battery = int(bytes(gatt(bat).ReadValue({}))[0])
            result.log(f"battery={result.battery}%")
        except Exception as e:
            result.log(f"battery: {e}")

    gatt(ctrl).StartNotify()
    result.log("CTRL StartNotify")
    if hr and not args.no_hr:
        try:
            gatt(hr).StartNotify()
            result.log("HR StartNotify")
        except Exception as e:
            result.log(f"HR: {e}")

    cccd = find_cccd(data)
    fd = None
    try:
        unix_fd, mtu = gatt(data).AcquireNotify({})
        result.mtu = int(mtu)
        fd = unix_fd.take()
        result.log(f"DATA AcquireNotify fd={fd} mtu={mtu}")
    except Exception as e:
        result.log(f"AcquireNotify failed ({e}); StartNotify fallback")
        try:
            gatt(data).StartNotify()
        except Exception as e2:
            result.errors.append(f"DATA notify: {e2}")
            return 5

    if cccd:
        try:
            desc = dbus.Interface(bus.get_object("org.bluez", cccd), "org.bluez.GattDescriptor1")
            result.cccd_data = b2h(bytes(desc.ReadValue({})))
            result.log(f"DATA CCCD={result.cccd_data}")
        except Exception as e:
            result.log(f"CCCD read: {e}")

    def pump(seconds: float, until: Optional[Callable[[], bool]] = None) -> None:
        t0 = time.time()
        while time.time() - t0 < seconds:
            if until and until():
                return
            drain(0.01)
            if fd is None:
                time.sleep(0.05)
                continue
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(fd, 1024)
            except OSError as e:
                result.log(f"fd read: {e}")
                return
            if chunk:
                result.add_data(chunk)

    async def cp_write(payload: bytes, label: str) -> None:
        gatt(ctrl).WriteValue(dbus.Array(payload, signature="y"), {"type": "request"})
        result.log(f"WRITE {label}: {b2h(payload)}")
        pump(0.55)

    async def wait(seconds: float, until: Optional[Callable[[], bool]]) -> None:
        pump(seconds, until)

    asyncio.run(run_streams(args, result, cp_write, wait))

    if fd is not None:
        try:
            os.close(fd)
        except Exception:
            pass
    for p in (ctrl, hr):
        if not p:
            continue
        try:
            gatt(p).StopNotify()
        except Exception:
            pass
    try:
        dbus.Interface(bus.get_object("org.bluez", DEV), "org.bluez.Device1").Disconnect()
        result.log("disconnected")
    except Exception as e:
        result.log(f"disconnect: {e}")

    judge(args, result)
    return 0 if result.ok else 6


# ---------------------------------------------------------------------------
# Artifacts
# ---------------------------------------------------------------------------

def write_artifacts(result: CaptureResult, out_dir: Path, repo_docs: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(TZ).strftime("%Y%m%d-%H%M%S")
    json_path = out_dir / f"polar-ecg-{stamp}.json"
    csv_path = out_dir / f"polar-ecg-{stamp}.csv"
    acc_path = out_dir / f"polar-acc-{stamp}.csv"

    summary = result.summary()
    summary["artifacts"] = {"json": str(json_path), "ecg_csv": str(csv_path), "acc_csv": str(acc_path)}
    json_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    with csv_path.open("w", encoding="utf-8") as f:
        f.write("index,uv,timestamp_ns\n")
        ts = result.ecg.sample_ts
        for i, v in enumerate(result.ecg.samples):
            f.write(f"{i},{v},{ts[i] if i < len(ts) else ''}\n")
    with acc_path.open("w", encoding="utf-8") as f:
        f.write("index,timestamp_ns,x_mg,y_mg,z_mg\n")
        ts = result.acc.sample_ts
        for i, (x, y, z) in enumerate(result.acc.samples):
            f.write(f"{i},{ts[i] if i < len(ts) else ''},{x},{y},{z}\n")
    for src, name in ((json_path, "polar-ecg-latest.json"), (csv_path, "polar-ecg-latest.csv"),
                      (acc_path, "polar-acc-latest.csv")):
        (out_dir / name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

    e, a = summary["ecg"], summary["acc"]
    repo_docs.mkdir(parents=True, exist_ok=True)
    md_path = repo_docs / "2026-10-26-polar-h10-ecg-capture.md"
    lines = [
        "# Polar H10 PMD ECG + ACC capture",
        "",
        f"- Device: `Polar H10` / `{result.addr}`",
        f"- Host: Linux BlueZ (`{result.backend}`), mode `{result.mode}`",
        f"- When: {result.started_at} → {result.ended_at} Asia/Shanghai",
        f"- Result: **{'PASS' if result.ok else 'FAIL'}**",
        f"- ATT MTU: **{result.mtu}**  Battery: {result.battery}%",
        f"- PMD frames total: **{result.frames}** ({result.bytes_total} bytes)",
        f"- HR notifies: {len(result.hr_bpm)}  bpm={result.hr_bpm[:20]}{'…' if len(result.hr_bpm) > 20 else ''}",
        "",
        "## ECG (130 Hz, 14-bit, µV)",
        "",
        f"- START: {e.get('start_status')}  settings={e.get('settings')}  offered={e.get('available_settings')}",
        f"- frames **{e['frames']}**, samples **{e['samples']}**, samples/frame {e.get('samples_per_frame')}, frame types {e.get('frame_types')}",
        f"- effective rate: sensor-ts **{e.get('rate_hz_sensor')} Hz**, wall-clock {e.get('rate_hz_wall')} Hz",
        f"- first frame **{e.get('first_frame_delay_s')} s** after START",
        f"- min/max/mean: {e.get('min_uv')} / {e.get('max_uv')} / {e.get('mean_uv')} µV",
        "",
        "## ACC (int16 X/Y/Z, mG)",
        "",
        f"- START: {a.get('start_status')}  settings={a.get('settings')}  offered={a.get('available_settings')}",
        f"- frames **{a['frames']}**, samples **{a['samples']}**, samples/frame {a.get('samples_per_frame')}, frame types {a.get('frame_types')} (compressed {a.get('compressed_frames')})",
        f"- effective rate: sensor-ts **{a.get('rate_hz_sensor')} Hz**, wall-clock {a.get('rate_hz_wall')} Hz",
        f"- first frame **{a.get('first_frame_delay_s')} s** after START",
        f"- X min/max/mean: {a.get('x_min_mg')} / {a.get('x_max_mg')} / {a.get('x_mean_mg')} mG",
        f"- Y min/max/mean: {a.get('y_min_mg')} / {a.get('y_max_mg')} / {a.get('y_mean_mg')} mG",
        f"- Z min/max/mean: {a.get('z_min_mg')} / {a.get('z_max_mg')} / {a.get('z_mean_mg')} mG",
        f"- |a| mean {a.get('magnitude_mean_mg')} mG (min {a.get('magnitude_min_mg')}, max {a.get('magnitude_max_mg')}); ~1000 mG sanity: {a.get('magnitude_sane_1g')}",
        "",
        "## Flow (script)",
        "",
        "1. Scan + connect; exchange ATT MTU (232)",
        "2. Indicate on Control `fb005c81` + notify on Data `fb005c82` (+ HR `2a37`) before any START",
        "3. `03 00` / `03 02` stop lingering streams",
        "4. ECG: `01 00` GET → `02 00 00 01 82 00 01 01 0E 00` START → wait for first frame (~30 s)",
        "5. ACC: `01 02` GET (validate rate/range) → `02 02 00 01 <rate> 01 01 10 00 02 01 <range>` START",
        "6. Capture `--seconds`; `03 00` / `03 02` STOP",
        "",
        "## Notes",
        "",
        "- Root cause of earlier \"0 ECG frames\": the H10 answers START ECG with success immediately, but the",
        "  **first ECG frame only arrives ~30 s after START** (reproduced repeatedly, bleak + dbus, with/without ACC,",
        "  Data-notify before/after START). Earlier runs gave up after 12–20 s. No bonding needed.",
        "- The ~30 s delay applies to the **first PMD stream of a connection**, ECG or ACC alike (ACC-only: 30.5 s @200 Hz,",
        "  30.8 s @50 Hz). A stream started while another is already flowing arrives in ~0.5 s (ACC after ECG).",
        "  Idling 35 s after connect before START shortened it to 10.8 s, so it is not purely START- or connect-relative.",
        "- ACC frame type 1 = int16 LE X/Y/Z in mG (polar-ble-sdk `AccData` raw TYPE_1), 36 samples/frame at MTU 232.",
        "  Effective ACC rate is ~1.3 % above nominal (≈202.7 Hz @200, ≈50.7 Hz @50); ECG stays 130.08 Hz with ACC on.",
        "- Delta-compressed frames (frame-type bit 0x80) are detected, counted and decoded (factor 1); the H10 sends raw frames.",
        "- `05` (GET_STATUS) returns invalid_op on H10 firmware — not used.",
        "",
        "Script: `tools/polar/polar_h10_ecg_capture.py`",
        "",
        "## Control traffic",
        "",
    ]
    for c in result.ctrl:
        lines.append(f"- `{c.get('raw', c)}` → {c.get('status_name', c.get('kind'))}")
    if not result.ctrl:
        lines.append("- _(none)_")
    lines += [
        "",
        "## Artifacts",
        "",
        f"- `{json_path}`",
        f"- `{csv_path}` (index,uv,timestamp_ns)",
        f"- `{acc_path}` (index,timestamp_ns,x_mg,y_mg,z_mg)",
        f"- latest: `{out_dir}/polar-ecg-latest.json`, `polar-ecg-latest.csv`, `polar-acc-latest.csv`",
        "",
        "## Log",
        "",
    ]
    lines += [f"- {s}" for s in result.steps]
    if result.errors:
        lines += ["", "## Errors", ""] + [f"- {x}" for x in result.errors]
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    result.log(f"wrote {json_path}")
    result.log(f"wrote {csv_path}")
    result.log(f"wrote {acc_path}")
    result.log(f"wrote {md_path}")


def build_argparser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Polar H10 PMD ECG / ACC capture (Linux BlueZ)")
    p.add_argument("--addr", default=DEFAULT_ADDR, help="H10 BLE address")
    p.add_argument("--seconds", type=float, default=20.0, help="capture duration after the first frame")
    p.add_argument("--first-frame-timeout", type=float, default=60.0,
                   help="max seconds to wait after START for a stream's first frame (H10: ~30 s for the first stream)")
    m = p.add_mutually_exclusive_group()
    m.add_argument("--acc", action="store_true", help="capture ECG + ACC simultaneously")
    m.add_argument("--acc-only", action="store_true", help="capture ACC only (no ECG)")
    p.add_argument("--acc-rate", type=int, choices=(25, 50, 100, 200), default=200, help="ACC sample rate Hz")
    p.add_argument("--acc-range", type=int, choices=(2, 4, 8), default=8, help="ACC range ±g")
    p.add_argument("--also-acc", action="store_true",
                   help="ECG mode: if no ECG frame arrives, start ACC briefly to validate the Data path")
    p.add_argument("--scan-timeout", type=float, default=25.0)
    p.add_argument("--connect-retries", type=int, default=4)
    p.add_argument("--backend", choices=("auto", "bleak", "dbus"), default="auto",
                   help="auto: bleak if importable else dbus")
    p.add_argument("--no-hr", action="store_true", help="skip Heart Rate notify")
    p.add_argument("--scan-only", action="store_true", help="only verify device is advertising")
    p.add_argument("--out-dir", default="/tmp/polar-ecg", help="directory for JSON/CSV artifacts")
    p.add_argument("--docs-dir", default="", help="verification markdown dir (default: <repo>/docs/verification)")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_argparser().parse_args(argv)
    args.mode_ecg = not args.acc_only
    args.mode_acc = args.acc or args.acc_only
    result = CaptureResult(started_at=now_iso(), addr=args.addr)
    result.mode = "acc" if args.acc_only else ("ecg+acc" if args.acc else "ecg")
    result.ecg.wanted = args.mode_ecg
    result.acc.wanted = args.mode_acc
    result.acc.nominal_hz = args.acc_rate

    here = Path(__file__).resolve()
    repo_root = here.parents[2]  # tools/polar → HoneyBox
    docs_dir = Path(args.docs_dir) if args.docs_dir else repo_root / "docs" / "verification"
    out_dir = Path(args.out_dir)

    backend = args.backend
    if backend == "auto":
        try:
            import bleak  # noqa: F401
            backend = "bleak"
        except ImportError:
            backend = "dbus"
        result.log(f"backend auto → {backend}")
    result.log(f"mode={result.mode} acc_rate={args.acc_rate} acc_range=±{args.acc_range}g seconds={args.seconds}")

    rc = 1
    try:
        if backend == "bleak":
            rc = asyncio.run(run_bleak(args, result))
        else:
            rc = run_dbus(args, result)
    except KeyboardInterrupt:
        result.errors.append("interrupted")
        result.log("interrupted")
        rc = 130
    except Exception as e:
        result.errors.append(str(e))
        result.log(f"fatal: {e}")
        import traceback
        traceback.print_exc()
        rc = 1
    finally:
        result.ended_at = now_iso()
        if not args.scan_only:
            try:
                write_artifacts(result, out_dir, docs_dir)
            except Exception as e:
                print(f"artifact write failed: {e}", flush=True)

    print(f"\n{'PASS' if result.ok else 'FAIL'}  {result.short()}  rc={rc}", flush=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
