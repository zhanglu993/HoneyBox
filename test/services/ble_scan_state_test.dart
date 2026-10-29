import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/services/ble_manager.dart' as manager;

class _ScanManager implements manager.BleManager {
  final events = StreamController<manager.BleState>.broadcast();
  manager.BleState current = manager.BleState.disconnected;
  bool failImmediately = false;

  @override
  manager.BleState get state => current;
  @override
  Stream<manager.BleState> get onStateChanged => events.stream;
  @override
  Future<void> startScan(void Function(ScanResult) callback,
      {String? serviceUuid}) async {
    current = failImmediately
        ? manager.BleState.disconnected
        : manager.BleState.scanning;
  }

  @override
  void stopScan() => current = manager.BleState.disconnected;
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('scan startup failure does not leave the UI scanning', () async {
    final fake = _ScanManager()..failImmediately = true;
    final container = ProviderContainer(overrides: [
      bleManagerProvider.overrideWithValue(fake),
    ]);
    addTearDown(() async {
      container.dispose();
      await fake.events.close();
    });
    await container.read(bleNotifierProvider.notifier).startScan();
    expect(container.read(bleNotifierProvider), BleState.disconnected);
  });

  test('asynchronous scan failure clears scanning without a connected device',
      () async {
    final fake = _ScanManager();
    final container = ProviderContainer(overrides: [
      bleManagerProvider.overrideWithValue(fake),
    ]);
    addTearDown(() async {
      container.dispose();
      await fake.events.close();
    });
    await container.read(bleNotifierProvider.notifier).startScan();
    expect(container.read(bleNotifierProvider), BleState.scanning);
    fake.current = manager.BleState.disconnected;
    fake.events.add(manager.BleState.disconnected);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(bleNotifierProvider), BleState.disconnected);
  });

  test('delayed stop event does not cancel a restarted scan', () async {
    final fake = _ScanManager();
    final container = ProviderContainer(overrides: [
      bleManagerProvider.overrideWithValue(fake),
    ]);
    addTearDown(() async {
      container.dispose();
      await fake.events.close();
    });
    await container.read(bleNotifierProvider.notifier).startScan();
    fake.events.add(manager.BleState.disconnected);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(bleNotifierProvider), BleState.scanning);
  });
}
