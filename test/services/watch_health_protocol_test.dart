import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/watch_health_protocol.dart';

void main() {
  test('builds an empty health data request', () {
    expect(
      WatchHealthProtocol.buildRequest(),
      Uint8List.fromList([0x05, 0x00, 0x01, 0x00, 0x00]),
    );
  });

  test('parses sport records from big-endian packed fields', () {
    final value = Uint8List.fromList([
      ..._date(2026, 7, 30),
      0x00,
      0x01,
      ..._packBits([
        (37, 11),
        (2, 2),
        (1234, 12),
        (12, 4),
        (45678, 19),
        (987, 16),
      ]),
    ]);

    final event = WatchHealthProtocol.parseFrame(
      _frame([(WatchHealthKey.sportData, value)]),
    ).single as WatchSportData;

    expect(event.date, DateTime(2026, 7, 30));
    expect(event.items, hasLength(1));
    expect(event.items.single.offset, 37);
    expect(event.items.single.mode, 2);
    expect(event.items.single.steps, 1234);
    expect(event.items.single.activeMinutes, 12);
    expect(event.items.single.caloriesMilliKcal, 45678);
    expect(event.items.single.distanceMeters, 987);
  });

  test('parses sleep and per-measurement heart rate records', () {
    final sleepValue = Uint8List.fromList([
      ..._date(2026, 7, 29),
      0x00,
      0x02,
      0x05,
      0x64,
      0x00,
      0x01,
      0x05,
      0x8C,
      0x00,
      0x03,
    ]);
    final heartValue = Uint8List.fromList([
      ..._date(2026, 7, 30),
      0x00,
      0x02,
      0x00,
      0x8F,
      0x10,
      72,
      0x00,
      0x8F,
      0x2A,
      78,
    ]);

    final events = WatchHealthProtocol.parseFrame(_frame([
      (WatchHealthKey.sleepData, sleepValue),
      (WatchHealthKey.heartRateData, heartValue),
    ]));

    final sleep = events[0] as WatchSleepData;
    expect(sleep.items.map((item) => item.minutes), [1380, 1420]);
    expect(sleep.items.map((item) => item.mode), [1, 3]);

    final heart = events[1] as WatchHeartRateData;
    expect(heart.items.map((item) => item.seconds), [36624, 36650]);
    expect(heart.items.map((item) => item.bpm), [72, 78]);
  });

  test('parses synchronization markers and more flag', () {
    final events = WatchHealthProtocol.parseFrame(_frame([
      (WatchHealthKey.syncStart, Uint8List(0)),
      (WatchHealthKey.more, Uint8List(0)),
      (WatchHealthKey.syncEnd, Uint8List(0)),
    ]));

    expect(events, [
      WatchHealthMarker.syncStart,
      WatchHealthMarker.more,
      WatchHealthMarker.syncEnd,
    ]);
  });

  test('rejects malformed item counts and invalid dates', () {
    final badCount = Uint8List.fromList([
      ..._date(2026, 7, 30),
      0x00,
      0x02,
      0,
      0,
      0,
      0,
    ]);
    final badDate = Uint8List.fromList([
      0x00,
      0x00,
      0x00,
      0x00,
    ]);

    expect(
      () => WatchHealthProtocol.parseFrame(
        _frame([(WatchHealthKey.heartRateData, badCount)]),
      ),
      throwsFormatException,
    );
    expect(
      () => WatchHealthProtocol.parseFrame(
        _frame([(WatchHealthKey.sleepData, badDate)]),
      ),
      throwsFormatException,
    );
  });
}

Uint8List _frame(List<(int, Uint8List)> entries) {
  final bytes = <int>[0x05, 0x00];
  for (final (key, value) in entries) {
    bytes.addAll([key, value.length >> 8, value.length & 0xFF, ...value]);
  }
  return Uint8List.fromList(bytes);
}

List<int> _date(int year, int month, int day) {
  final packed = ((year - 2000) << 9) | (month << 5) | day;
  return [packed >> 8, packed & 0xFF];
}

List<int> _packBits(List<(int, int)> fields) {
  var packed = BigInt.zero;
  var bits = 0;
  for (final (value, width) in fields) {
    packed = (packed << width) | BigInt.from(value);
    bits += width;
  }
  final bytes = List<int>.filled((bits + 7) ~/ 8, 0);
  for (var i = bytes.length - 1; i >= 0; i--) {
    bytes[i] = (packed & BigInt.from(0xFF)).toInt();
    packed >>= 8;
  }
  return bytes;
}
