import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/scan/scan_device_order.dart';
import 'package:honeybox/providers/ble_provider.dart';

ScanDevice device(String id, int rssi) =>
    ScanDevice(deviceId: id, name: id, rssi: rssi);

void main() {
  test(
      'stronger signal comes first; ties retain arrival order and invalid RSSI is last',
      () {
    final input = [
      device('weak', -80),
      device('tie-first', -40),
      device('unknown', 0),
      device('tie-second', -40),
      device('unavailable', -128),
      device('invalid', 7),
    ];
    expect(sortedScanDevicesBySignal(input).map((d) => d.deviceId), [
      'tie-first',
      'tie-second',
      'weak',
      'unknown',
      'unavailable',
      'invalid'
    ]);
    expect(input.first.deviceId, 'weak');
  });

  test(
      'repeat advertisement reorders an existing device without changing its identity',
      () {
    final scanned = ScannedDevicesNotifier();
    addTearDown(scanned.dispose);
    scanned.addDevice(device('A', -80));
    scanned.addDevice(device('B', -50));
    expect(sortedScanDevicesBySignal(scanned.state).map((d) => d.deviceId),
        ['B', 'A']);
    scanned.addDevice(device('A', -30));
    expect(scanned.state.length, 2);
    expect(sortedScanDevicesBySignal(scanned.state).map((d) => d.deviceId),
        ['A', 'B']);
    expect(
        sortedScanDevicesBySignal(
                scanned.state.where((d) => d.deviceId == 'B').toList())
            .single
            .deviceId,
        'B');
  });
}
