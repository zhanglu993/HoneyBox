"""Convert E0FF/FFE1 notifications to firmware ADBG parser input (local time)."""
import argparse
import datetime
from capture_jsonl import records, uuid


def convert(source, target):
    count = 0
    with open(target, 'w', encoding='utf-8', newline='') as out:
        for record in records(source):
            if record.get('event') or uuid(record.get('service')) != 'e0ff' or uuid(record.get('characteristic')) != 'ffe1':
                continue
            payload = bytes.fromhex(record['hex']).hex().upper()
            time = datetime.datetime.fromisoformat(record['time'].replace('Z', '+00:00'))
            if time.tzinfo is None:
                raise ValueError('capture time must include a timezone')
            local = time.astimezone()
            stamp = local.strftime('%Y:%m:%d:%H:%M:%S.') + f'{local.microsecond // 1000:03d}'
            out.write(f'{payload} {stamp}\n')
            count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input')
    parser.add_argument('output')
    args = parser.parse_args()
    print(f'{convert(args.input, args.output)} packets')


if __name__ == '__main__':
    main()
