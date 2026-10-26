"""Stream capture JSONL records without loading an overnight file into RAM."""
import datetime
import json


def records(path):
    with open(path, encoding='utf-8') as source:
        for number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
                yield record
            except (ValueError, TypeError) as error:
                raise ValueError(f'{path}:{number}: {error}') from error


def host_ns(record):
    value = datetime.datetime.fromisoformat(record['time'].replace('Z', '+00:00'))
    if value.tzinfo is None:
        raise ValueError('capture time must include a timezone')
    delta = value - datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
    return ((delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds) * 1000


def uuid(value):
    value = (value or '').lower()
    if value.startswith('0000') and value.endswith('-0000-1000-8000-00805f9b34fb'):
        return value[4:8]
    return value
