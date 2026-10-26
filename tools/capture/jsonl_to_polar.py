"""Decode a single-device Polar H10 capture. No third-party dependencies."""
import argparse
import csv
import json
from contextlib import ExitStack
from fractions import Fraction
from pathlib import Path
from capture_jsonl import records, host_ns, uuid

PMD_SERVICE = 'fb005c80-02e7-f387-1cad-8acd2d8df0c8'
PMD_DATA = 'fb005c82-02e7-f387-1cad-8acd2d8df0c8'
PMD_CP = 'fb005c81-02e7-f387-1cad-8acd2d8df0c8'


def decode_hr(data):
    if len(data) < 2:
        raise ValueError('truncated HR packet')
    flags = data[0]
    width = 2 if flags & 1 else 1
    offset = 1 + width
    if len(data) < offset:
        raise ValueError('truncated HR value')
    hr = int.from_bytes(data[1:offset], 'little')
    contact = ('detected' if flags & 2 else 'not_detected') if flags & 4 else 'unsupported'
    if flags & 8:
        offset += 2
    if len(data) < offset or (flags & 16 and (len(data) == offset or (len(data) - offset) % 2)):
        raise ValueError('truncated energy/RR value')
    rr = [int.from_bytes(data[i:i + 2], 'little') * 1000 / 1024
          for i in range(offset, len(data), 2)] if flags & 16 else []
    return hr, contact, rr


def decode_frame(data):
    if len(data) < 10:
        raise ValueError('truncated PMD header')
    kind, frame_type = data[0], data[9]
    if kind not in (0, 2):
        return None
    if frame_type != (0 if kind == 0 else 1):
        raise ValueError(f'unsupported PMD frame type {frame_type:#x} for {kind} (delta compression is not decoded)')
    width = 3 if kind == 0 else 6
    if (len(data) - 10) % width or len(data) == 10:
        raise ValueError('truncated/empty PMD samples')
    values = []
    for i in range(10, len(data), width):
        if kind == 0:
            values.append((int.from_bytes(data[i:i + 3], 'little', signed=True),))
        else:
            values.append(tuple(int.from_bytes(data[j:j + 2], 'little', signed=True)
                                for j in range(i, i + 6, 2)))
    return kind, int.from_bytes(data[1:9], 'little'), values


def convert(source, output, acc_rate=None):
    source, output = Path(source), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    if acc_rate is None:
        metadata = source.with_name('device.json')
        saved = json.loads(metadata.read_text(encoding='utf-8')) if metadata.exists() else {}
        acc_rate = saved.get('polarOptions', {}).get('rate', 25)
    if acc_rate not in (25, 50, 100, 200):
        raise ValueError('ACC rate must be 25/50/100/200 Hz')
    previous = {}
    segment = {0: -1, 2: -1}
    row_counts = {0: 0, 2: 0}
    with ExitStack() as stack:
        writers = {}
        for name, header in {
            'rr': ['host_ns', 'hr_bpm', 'contact', 'rr_ms'],
            'ecg': ['host_ns', 'sensor_ns', 'uv'],
            'acc': ['host_ns', 'sensor_ns', 'x_mg', 'y_mg', 'z_mg'],
            'segments': ['stream', 'segment', 'first_row', 'host_ns', 'last_sample_sensor_ns'],
        }.items():
            writers[name] = csv.writer(stack.enter_context(open(output / f'{name}.csv', 'w', newline='', encoding='utf-8')))
            writers[name].writerow(header)
        for record in records(source):
            if record.get('event'):
                if record['event'] in ('disconnected', 'reconnected'):
                    previous.clear()
                # A start/stop resets stream interpolation even without a link loss.
                if (record['event'] == 'write' and uuid(record.get('characteristic')) == PMD_CP):
                    command = bytes.fromhex(record['hex'])
                    if len(command) >= 2 and command[0] in (2, 3):
                        previous.pop(command[1], None)
                    if len(command) >= 6 and command[:2] == b'\x02\x02':
                        acc_rate = int.from_bytes(command[4:6], 'little')
                        if acc_rate not in (25, 50, 100, 200):
                            raise ValueError('unsupported ACC rate in start command')
                continue
            service, characteristic = uuid(record.get('service')), uuid(record.get('characteristic'))
            if (service, characteristic) != ('180d', '2a37') and (service, characteristic) != (PMD_SERVICE, PMD_DATA):
                continue
            data, host = bytes.fromhex(record['hex']), host_ns(record)
            if characteristic == '2a37':
                hr, contact, rr = decode_hr(data)
                for value in rr or ['']:
                    writers['rr'].writerow([host, hr, contact, value])
                continue
            decoded = decode_frame(data)
            if decoded is None:
                continue
            kind, last, values = decoded
            old = previous.get(kind)
            name = 'ecg' if kind == 0 else 'acc'
            if old is None or last <= old:
                segment[kind] += 1
                writers['segments'].writerow([name, segment[kind], row_counts[kind] + 1, host, last])
                spacing = Fraction(1000000000, 1) / (Fraction('130.08') if kind == 0 else acc_rate)
            else:
                spacing = Fraction(last - old, len(values))
            for index, sample in enumerate(values):
                sensor = last - round((len(values) - 1 - index) * spacing)
                writers[name].writerow([host, sensor, *sample])
            row_counts[kind] += len(values)
            previous[kind] = last
    return row_counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input')
    parser.add_argument('output_dir')
    parser.add_argument('--acc-rate', type=int, choices=[25, 50, 100, 200])
    args = parser.parse_args()
    convert(args.input, args.output_dir, args.acc_rate)


if __name__ == '__main__':
    main()
