import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/watch_health_protocol.dart';
import 'package:honeybox/services/watch_health_repository.dart';

void main() {
  test('requests and aggregates health frames until sync end', () async {
    final notifications = StreamController<Uint8List>.broadcast();
    addTearDown(notifications.close);
    final sent = <Uint8List>[];
    final repository = WatchHealthBleRepository(
      commandAvailable: () => true,
      sendCommand: (frame) {
        sent.add(frame);
        return sent.length;
      },
      notifications: notifications.stream,
      clock: () => DateTime(2026, 7, 30, 12),
    );

    final future = repository.sync('watch-01');
    expect(sent, [WatchHealthProtocol.buildRequest()]);

    notifications.add(_frame([
      (WatchHealthKey.syncStart, Uint8List(0)),
      (WatchHealthKey.sportData, _sportValue()),
      (WatchHealthKey.heartRateData, _heartValue()),
      (WatchHealthKey.more, Uint8List(0)),
    ]));
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(2));
    expect(sent.last, WatchHealthProtocol.buildRequest());

    notifications.add(_frame([
      (WatchHealthKey.sleepData, _sleepValue()),
      (WatchHealthKey.syncEnd, Uint8List(0)),
    ]));
    final snapshot = await future;

    expect(snapshot.sportRecords, hasLength(1));
    expect(snapshot.sportRecords.single.steps, 600);
    expect(snapshot.heartRateRecords.map((record) => record.bpm), [72, 78]);
    expect(snapshot.sleepRecords, hasLength(2));
    expect(snapshot.syncedAt, DateTime(2026, 7, 30, 12));
  });

  test('fails without sending when command channel is unavailable', () async {
    final repository = WatchHealthBleRepository(
      commandAvailable: () => false,
      sendCommand: (_) => null,
      notifications: const Stream.empty(),
    );

    expect(
      () => repository.sync('watch-01'),
      throwsA(isA<WatchHealthSyncException>()),
    );
  });

  test('times out when watch does not finish synchronization', () async {
    final notifications = StreamController<Uint8List>.broadcast();
    addTearDown(notifications.close);
    final repository = WatchHealthBleRepository(
      commandAvailable: () => true,
      sendCommand: (_) => 1,
      notifications: notifications.stream,
      timeout: const Duration(milliseconds: 20),
    );

    final future = repository.sync('watch-01');
    notifications.add(_frame([
      (WatchHealthKey.syncStart, Uint8List(0)),
    ]));

    expect(future, throwsA(isA<TimeoutException>()));
  });

  test('fails the transaction when a health frame is malformed', () async {
    final notifications = StreamController<Uint8List>.broadcast();
    addTearDown(notifications.close);
    final repository = WatchHealthBleRepository(
      commandAvailable: () => true,
      sendCommand: (_) => 1,
      notifications: notifications.stream,
    );

    final future = repository.sync('watch-01');
    notifications.add(Uint8List.fromList([
      0x05,
      0x00,
      WatchHealthKey.sportData,
      0x00,
      0x08,
      0x01,
    ]));

    expect(future, throwsFormatException);
  });
}

Uint8List _frame(List<(int, Uint8List)> entries) {
  final bytes = <int>[0x05, 0x00];
  for (final (key, value) in entries) {
    bytes.addAll([key, value.length >> 8, value.length & 0xFF, ...value]);
  }
  return Uint8List.fromList(bytes);
}

Uint8List _sportValue() => Uint8List.fromList([
      ..._date(2026, 7, 30),
      0x00,
      0x01,
      ..._packBits([
        (32, 11),
        (1, 2),
        (600, 12),
        (10, 4),
        (12500, 19),
        (420, 16),
      ]),
    ]);

Uint8List _heartValue() => Uint8List.fromList([
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

Uint8List _sleepValue() => Uint8List.fromList([
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

List<int> _date(int year, int month, int day) {
  final packed = ((year - 2000) << 9) | (month << 5) | day;
  return [packed >> 8, packed & 0xFF];
}

List<int> _packBits(List<(int, int)> fields) {
  var packed = BigInt.zero;
  for (final (value, width) in fields) {
    packed = (packed << width) | BigInt.from(value);
  }
  final bytes = List<int>.filled(8, 0);
  for (var i = bytes.length - 1; i >= 0; i--) {
    bytes[i] = (packed & BigInt.from(0xFF)).toInt();
    packed >>= 8;
  }
  return bytes;
}
