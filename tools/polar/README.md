# Polar H10 tools (Linux)

## `polar_h10_ecg_capture.py`

End-to-end **PMD ECG and ACC (accelerometer)** capture from a Polar H10 on BlueZ.

```bash
python3 -m venv /tmp/polar-venv && /tmp/polar-venv/bin/pip install bleak
PY=/tmp/polar-venv/bin/python

$PY tools/polar/polar_h10_ecg_capture.py                         # ECG only (default)
$PY tools/polar/polar_h10_ecg_capture.py --acc --seconds 20      # ECG + ACC (200 Hz, ±8 g)
$PY tools/polar/polar_h10_ecg_capture.py --acc-only              # ACC only
$PY tools/polar/polar_h10_ecg_capture.py --acc-only --acc-rate 50 --acc-range 2
$PY tools/polar/polar_h10_ecg_capture.py --also-acc              # ECG; if no ECG arrives, brief ACC Data-path check
python3 tools/polar/polar_h10_ecg_capture.py --backend dbus --acc  # system dbus-python instead of bleak
$PY tools/polar/polar_h10_ecg_capture.py --scan-only             # is it advertising?
```

| Option | Meaning |
|---|---|
| `--acc` / `--acc-only` | ECG+ACC together / ACC only (mutually exclusive; default is ECG only) |
| `--acc-rate {25,50,100,200}` | ACC sample rate (Hz), validated against the device's GET_ACC settings |
| `--acc-range {2,4,8}` | ACC range ±g, validated the same way (resolution fixed at 16-bit) |
| `--seconds N` | capture length **after** the stream(s) start flowing (default 20) |
| `--first-frame-timeout N` | max wait for a stream's first frame after START (default 60) |
| `--also-acc` | ECG mode only: if ECG never arrives, start ACC briefly to prove the Data path |
| `--out-dir`, `--docs-dir` | artifact dir (default `/tmp/polar-ecg`), verification md dir |

Default address: `EE:6A:57:F3:9E:00` (790A8026). No pairing/bonding needed.

### Artifacts

- `/tmp/polar-ecg/polar-ecg-<stamp>.json` — summary: `ecg{...}` and `acc{...}` blocks with frames,
  samples, samples/frame, effective rate (sensor timestamps + wall clock), first-frame delay,
  ECG min/max/mean µV, ACC per-axis min/max/mean mG and |a| mean (≈1000 mG at rest → `magnitude_sane_1g`)
- `polar-ecg-<stamp>.csv` — `index,uv,timestamp_ns`
- `polar-acc-<stamp>.csv` — `index,timestamp_ns,x_mg,y_mg,z_mg`
- `polar-ecg-latest.json|csv`, `polar-acc-latest.csv`
- `docs/verification/2026-10-26-polar-h10-ecg-capture.md` — regenerated each run

### Important: first stream arrives ~30 s after START

The H10 acknowledges START (`f0 02 .. 00`) immediately, but the **first PMD stream of a
connection delivers its first frame only ~30 s later — ECG and ACC alike** (ECG 30.9–31.1 s,
ACC-only 30.5 s @200 Hz / 30.8 s @50 Hz). A stream started while another is already flowing
starts within ~0.5 s, so in `--acc` mode ECG is started first and ACC is started once ECG
flows, giving aligned windows. (Idling 35 s after connect before START gave 10.8 s, so the
delay is not purely START- or connect-relative.) The script simply waits up to
`--first-frame-timeout`. This was the root cause of the earlier "0 frames" runs.

### Frame formats (polar-ble-sdk `PmdDataFrame` / `EcgData` / `AccData`)

```
[0] measurement type (0x00 ECG, 0x02 ACC)
[1:9] u64 LE timestamp ns (of the last sample in the frame)
[9] frame type; bit 0x80 = delta-compressed
ECG raw type 0 : int24 LE µV              → 73 samples/frame at MTU 232
ACC raw type 1 : int16 LE X,Y,Z in mG     → 36 samples/frame at MTU 232
```

Delta-compressed frames (ref sample + `[bit_width][count][packed deltas]`) are detected,
logged, counted (`compressed_frames`) and decoded with factor 1. The H10 sends raw frames.
Per-sample timestamps follow `PmdTimeStampUtils` (spaced between consecutive frame timestamps).

### Verified 2026-10-26 (strap worn)

| Run | Stream | frames | samples | /frame | rate (sensor ts) | first frame | stats |
|---|---|---|---|---|---|---|---|
| `--acc` 200 Hz ±8 g | ECG | 39 | 2847 | 73 | 130.08 Hz | 30.9 s | −518…1227 µV |
| | ACC | 119 | 4284 | 36 | 202.69 Hz | 0.5 s | \|a\| 1007.5 mG |
| `--acc-only` 200 Hz ±8 g | ACC | 62 | 2232 | 36 | 202.75 Hz | 30.5 s | \|a\| 1006.3 mG |
| `--acc-only` 50 Hz ±2 g | ACC | 16 | 576 | 36 | 50.70 Hz | 30.8 s | \|a\| 1005.0 mG |
| ECG only | ECG | 46 | 3358 | 73 | 130.08 Hz | 31.1 s | −389…1408 µV |

Running ACC alongside ECG does not change the ECG rate (130.08 Hz both ways). ACC runs
~1.3 % above nominal (H10 clock), as seen with the official SDK.

### Notes

- ECG needs the strap worn with moist electrodes; ACC works off-body too.
- `05` (GET_STATUS) returns `invalid_op` on H10 — not used.
- MTU exchange is required (232); keep reconnect attempts a few seconds apart
  (rapid reconnects → `le-connection-abort`).
