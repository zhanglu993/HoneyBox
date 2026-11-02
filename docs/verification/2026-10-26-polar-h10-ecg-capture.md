# Polar H10 PMD ECG + ACC capture

- Device: `Polar H10` / `EE:6A:57:F3:9E:00`
- Host: Linux BlueZ (`bleak`), mode `ecg+acc`
- When: 2026-10-26T13:32:15+08:00 → 2026-10-26T13:33:37+08:00 Asia/Shanghai
- Result: **PASS**
- ATT MTU: **232**  Battery: 90%
- PMD frames total: **161** (36509 bytes)
- HR notifies: 58  bpm=[91, 91, 90, 90, 90, 88, 87, 86, 86, 87, 87, 87, 86, 85, 84, 84, 84, 84, 84, 84]…

## ECG (130 Hz, 14-bit, µV)

- START: success  settings={'sample_rate': 130, 'resolution': 14}  offered={'sample_rate': [130], 'resolution': [14]}
- frames **41**, samples **2993**, samples/frame 73.0, frame types {'0': 41}
- effective rate: sensor-ts **130.08 Hz**, wall-clock 135.8 Hz
- first frame **32.2 s** after START
- min/max/mean: -584 / 1284 / -23.6 µV

## ACC (int16 X/Y/Z, mG)

- START: success  settings={'sample_rate': 200, 'resolution': 16, 'range': 8}  offered={'sample_rate': [25, 50, 100, 200], 'resolution': [16], 'range': [2, 4, 8]}
- frames **120**, samples **4320**, samples/frame 36.0, frame types {'1': 120} (compressed 0)
- effective rate: sensor-ts **202.75 Hz**, wall-clock 202.08 Hz
- first frame **0.7 s** after START
- X min/max/mean: -961 / -889 / -929.3 mG
- Y min/max/mean: -211 / -135 / -170.5 mG
- Z min/max/mean: -399 / -288 / -348.8 mG
- |a| mean 1007.3 mG (min 955.0, max 1045.0); ~1000 mG sanity: True

## Flow (script)

1. Scan + connect; exchange ATT MTU (232)
2. Indicate on Control `fb005c81` + notify on Data `fb005c82` (+ HR `2a37`) before any START
3. `03 00` / `03 02` stop lingering streams
4. ECG: `01 00` GET → `02 00 00 01 82 00 01 01 0E 00` START → wait for first frame (~30 s)
5. ACC: `01 02` GET (validate rate/range) → `02 02 00 01 <rate> 01 01 10 00 02 01 <range>` START
6. Capture `--seconds`; `03 00` / `03 02` STOP

## Notes

- Root cause of earlier "0 ECG frames": the H10 answers START ECG with success immediately, but the
  **first ECG frame only arrives ~30 s after START** (reproduced repeatedly, bleak + dbus, with/without ACC,
  Data-notify before/after START). Earlier runs gave up after 12–20 s. No bonding needed.
- The ~30 s delay applies to the **first PMD stream of a connection**, ECG or ACC alike (ACC-only: 30.5 s @200 Hz,
  30.8 s @50 Hz). A stream started while another is already flowing arrives in ~0.5 s (ACC after ECG).
  Idling 35 s after connect before START shortened it to 10.8 s, so it is not purely START- or connect-relative.
- ACC frame type 1 = int16 LE X/Y/Z in mG (polar-ble-sdk `AccData` raw TYPE_1), 36 samples/frame at MTU 232.
  Effective ACC rate is ~1.3 % above nominal (≈202.7 Hz @200, ≈50.7 Hz @50); ECG stays 130.08 Hz with ACC on.
- Delta-compressed frames (frame-type bit 0x80) are detected, counted and decoded (factor 1); the H10 sends raw frames.
- `05` (GET_STATUS) returns invalid_op on H10 firmware — not used.

Script: `tools/polar/polar_h10_ecg_capture.py`

## Control traffic

- `0f 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00` → features
- `0f 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00` → features
- `f0 03 00 06 00` → already_in_state
- `f0 03 02 06 00` → already_in_state
- `f0 01 00 00 00 00 01 82 00 01 01 0e 00` → success
- `f0 02 00 00 00 00` → success
- `f0 01 02 00 00 00 04 19 00 32 00 64 00 c8 00 01 01 10 00 02 03 02 00 04 00 08 00` → success
- `f0 02 02 00 00 01` → success
- `f0 03 00 00 00` → success
- `f0 03 02 00 00` → success

## Artifacts

- `/tmp/polar-ecg/polar-ecg-20261026-133337.json`
- `/tmp/polar-ecg/polar-ecg-20261026-133337.csv` (index,uv,timestamp_ns)
- `/tmp/polar-ecg/polar-acc-20261026-133337.csv` (index,timestamp_ns,x_mg,y_mg,z_mg)
- latest: `/tmp/polar-ecg/polar-ecg-latest.json`, `polar-ecg-latest.csv`, `polar-acc-latest.csv`

## Log

- backend auto → bleak
- mode=ecg+acc acc_rate=200 acc_range=±8g seconds=20.0
- scanning up to 25s for EE:6A:57:F3:9E:00 / Polar H10*
- seen EE:6A:57:F3:9E:00 name='Polar H10 790A8026' rssi=-57
- connect attempt 1/4
- connected
- ATT MTU=232
- battery=90%
- CTRL indicate + DATA notify on
- HR 91
- CTRL 0f 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 → features
- CTRL read 0f 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
- WRITE ECG_STOP: 03 00
- CTRL f0 03 00 06 00 → already_in_state
- HR 91
- WRITE ACC_STOP: 03 02
- CTRL f0 03 02 06 00 → already_in_state
- WRITE GET_ECG: 01 00
- CTRL f0 01 00 00 00 00 01 82 00 01 01 0e 00 → success
- HR 90
- ECG settings offered: {'sample_rate': [130], 'resolution': [14]}
- WRITE ECG_START: 02 00 00 01 82 00 01 01 0e 00
- CTRL f0 02 00 00 00 00 → success
- waiting up to 60s for first ECG frame …
-   … 5s, no ECG yet (HR=[86])
-   … 10s, no ECG yet (HR=[85])
-   … 15s, no ECG yet (HR=[84])
- HR 84
-   … 20s, no ECG yet (HR=[86])
-   … 25s, no ECG yet (HR=[87])
-   … 30s, no ECG yet (HR=[84])
- first ECG frame 32.2s after START
- DATA#1 len=229 ecg=73 acc=0 head=00 5b 5f 9d 2d 44 45 52 08 00 2d ff ff 13 ff ff
- DATA#2 len=229 ecg=146 acc=0 head=00 f2 25 10 4f 44 45 52 08 00 e9 ff ff 02 00 00
- DATA#3 len=229 ecg=219 acc=0 head=00 43 14 83 70 44 45 52 08 00 9c ff ff a0 ff ff
- WRITE GET_ACC: 01 02
- CTRL f0 01 02 00 00 00 04 19 00 32 00 64 00 c8 00 01 01 10 00 02 03 02 00 04 00 08 00 → success
- DATA#4 len=229 ecg=292 acc=0 head=00 52 2a f6 91 44 45 52 08 00 0b 00 00 eb ff ff
- ACC settings offered: {'sample_rate': [25, 50, 100, 200], 'resolution': [16], 'range': [2, 4, 8]}
- WRITE ACC_START: 02 02 00 01 c8 00 01 01 10 00 02 01 08 00
- CTRL f0 02 02 00 00 01 → success
- DATA#5 len=229 ecg=365 acc=0 head=00 86 2c 69 b3 44 45 52 08 00 9e ff ff b5 ff ff
- waiting up to 60s for first ACC frame …
- first ACC frame 0.7s after START
- DATA#6 len=226 ecg=365 acc=36 head=02 2c 8b 62 ba 44 45 52 08 01 52 fc 79 ff ab fe
- capturing 20s …
- HR 82
- DATA#50 len=226 ecg=1095 acc=1260 head=02 3a 52 1f 22 46 45 52 08 01 69 fc 55 ff aa fe
- DATA#100 len=226 ecg=1971 acc=2628 head=02 b8 eb 4e b4 47 45 52 08 01 54 fc 54 ff 92 fe
- DATA#150 len=226 ecg=2847 acc=3996 head=02 ca f4 8c 46 49 45 52 08 01 5d fc 54 ff ae fe
- WRITE ECG_STOP: 03 00
- CTRL f0 03 00 00 00 → success
- WRITE ACC_STOP: 03 02
- CTRL f0 03 02 00 00 → success
- disconnected
