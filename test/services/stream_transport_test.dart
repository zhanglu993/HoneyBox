import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_manager.dart';
import 'package:honeybox/services/stream_transport.dart';

void main() {
  test('BLE transport forwards only stream availability changes', () async {
    final manager = _FakeBleManager();
    final transport = BleStreamTransport(manager);

    final expectation =
        expectLater(transport.availabilityChanges, emitsInOrder([true, false]));
    manager.emitStreamAvailability(true);
    manager.emitStreamAvailability(false);
    await expectation;
    await manager.disposeFake();
  });

  test('reserved WiFi transport has no availability events', () {
    expect(
      WifiStreamTransport().availabilityChanges,
      emitsDone,
    );
  });
}

class _FakeBleManager implements BleManager {
  final _availability = StreamController<bool>.broadcast();
  bool _available = false;

  void emitStreamAvailability(bool available) {
    _available = available;
    _availability.add(available);
  }

  Future<void> disposeFake() => _availability.close();

  @override
  Stream<bool> get onStreamAvailabilityChanged => _availability.stream;

  @override
  Stream<Uint8List> get streamNotifications => const Stream<Uint8List>.empty();

  @override
  bool get streamAvailable => _available;

  @override
  int get streamChunkSize => 64;

  @override
  Future<void> writeStream(Uint8List l2) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(invocation.memberName.toString());
  }
}
