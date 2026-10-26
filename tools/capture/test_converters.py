import csv
import datetime
import json
import tempfile
import uuid
import shutil
import unittest
from pathlib import Path
from jsonl_to_adbg import convert as adbg
from jsonl_to_polar import convert as polar, decode_hr, decode_frame, PMD_SERVICE, PMD_DATA
from capture_jsonl import host_ns


class ConverterTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.gettempdir()) / ('capture_' + uuid.uuid4().hex)
        self.root.mkdir()
        self.addCleanup(shutil.rmtree, self.root)
        self.source = self.root / 'raw.jsonl'

    def write(self, rows):
        self.source.write_text(''.join(json.dumps(r) + '\n' for r in rows), encoding='utf-8')

    def packet(self, data, service=PMD_SERVICE, characteristic=PMD_DATA, **extra):
        return dict(time='2026-10-26T00:00:00.123456Z', deviceId='P', service=service,
                    characteristic=characteristic, hex=data.hex(), **extra)

    def frame(self, kind, last, samples):
        width = 3 if kind == 0 else 2
        values = samples if kind == 0 else [v for xyz in samples for v in xyz]
        return bytes([kind]) + last.to_bytes(8, 'little') + bytes([0 if kind == 0 else 1]) + b''.join(v.to_bytes(width, 'little', signed=True) for v in values)

    def read(self, name):
        with open(self.root / 'out' / (name + '.csv'), newline='', encoding='utf-8') as f:
            return list(csv.DictReader(f))

    def test_adbg_local_time_and_event_filter(self):
        row = self.packet(b'\x00\xff\x80', service='e0ff', characteristic='ffe1')
        self.write([row, dict(row, event='write'), self.packet(b'\x99')])
        target = self.root / 'adbg.txt'
        self.assertEqual(adbg(self.source, target), 1)
        local = datetime.datetime.fromisoformat(row['time']).astimezone()
        self.assertEqual(target.read_text(encoding='utf-8'), '00FF80 ' + local.strftime('%Y:%m:%d:%H:%M:%S.') + '123\n')

    def test_hr_flags_energy_multiple_rr_and_no_rr(self):
        data = bytes([0x1f]) + (300).to_bytes(2, 'little') + bytes([0, 0]) + (1024).to_bytes(2, 'little') + (512).to_bytes(2, 'little')
        self.assertEqual(decode_hr(data), (300, 'detected', [1000, 500]))
        self.assertEqual(decode_hr(bytes([0, 70])), (70, 'unsupported', []))
        self.write([self.packet(data, service='180d', characteristic='2a37')])
        polar(self.source, self.root / 'out')
        rr = self.read('rr')
        self.assertEqual([float(r['rr_ms']) for r in rr], [1000, 500])
        self.assertEqual(int(rr[0]['host_ns']), host_ns(self.packet(b'')))

    def test_frames_spacing_sign_and_timestamp_reset(self):
        self.write([
            self.packet(self.frame(0, 1000000000, [-8388608, 8388607])),
            self.packet(self.frame(0, 1020000000, [1, -1])),
            self.packet(self.frame(0, 10000000, [2, 3])),
            self.packet(self.frame(2, 2000000000, [(-1, 2, -32768), (32767, 0, 0)])),
            self.packet(self.frame(2, 2080000000, [(1, 2, 3), (4, 5, 6)])),
        ])
        polar(self.source, self.root / 'out', 25)
        ecg, acc = self.read('ecg'), self.read('acc')
        self.assertEqual([int(r['uv']) for r in ecg], [-8388608, 8388607, 1, -1, 2, 3])
        self.assertEqual(int(ecg[2]['sensor_ns']), 1010000000)
        self.assertEqual(int(ecg[4]['sensor_ns']), 10000000 - round(1e9 / 130.08))
        self.assertEqual(int(acc[0]['sensor_ns']), 1960000000)
        self.assertEqual(int(acc[2]['sensor_ns']), 2040000000)
        self.assertEqual(len(self.read('segments')), 3)

    def test_explicit_reconnect_resets_even_on_positive_jump(self):
        self.write([self.packet(self.frame(0, 1000000000, [1, 2])),
                    self.packet(b'', event='disconnected'), self.packet(b'', event='reconnected'),
                    self.packet(self.frame(0, 9000000000, [3, 4]))])
        polar(self.source, self.root / 'out')
        self.assertEqual(len(self.read('segments')), 2)
        self.assertEqual(int(self.read('ecg')[2]['sensor_ns']), 9000000000 - round(1e9 / 130.08))

    def test_compressed_and_truncated_packets_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            decode_frame(bytes([2]) + bytes(8) + bytes([0x81, 0, 0, 0, 0, 0, 0]))
        with self.assertRaises(ValueError):
            decode_hr(bytes([0x11, 80, 1]))
        with self.assertRaises(ValueError):
            decode_frame(bytes([0]) + bytes(11))


if __name__ == '__main__':
    unittest.main()
