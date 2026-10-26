import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/capture/capture_scan_filter.dart';

ScanResult device(String id, int rssi, {String name = 'S100'}) => ScanResult(
      device: BluetoothDevice.fromId(id),
      rssi: rssi,
      timeStamp: DateTime.utc(2026, 10, 26),
      advertisementData: AdvertisementData(
          advName: name,
          txPowerLevel: null,
          appearance: null,
          connectable: true,
          manufacturerData: {},
          serviceData: {},
          serviceUuids: []),
    );
void main() {
  test('unnamed devices remain by default and are excluded when requested', () {
    final input = [
      device('named', -50),
      device('empty', -40, name: ''),
      device('blank', -45, name: '   ')
    ];
    expect(filterCaptureScanResults(input).length, 3);
    expect(
        filterCaptureScanResults(input, hideUnnamed: true)
            .map((r) => r.device.remoteId.str),
        ['named']);
    expect(filterCaptureScanResults(input, hideUnnamed: true, minimumRssi: -40),
        isEmpty);
  });
  test('strongest RSSI first, unknown signal last, without mutating input', () {
    final input = [
      device('weak', -90),
      device('unknown', 127),
      device('near', -40),
      device('middle', -70)
    ];
    expect(filterCaptureScanResults(input).map((r) => r.device.remoteId.str),
        ['near', 'middle', 'weak', 'unknown']);
    expect(input.first.device.remoteId.str, 'weak');
  });
  test(
      'RSSI cutoff includes boundary and combines with name and address search',
      () {
    final input = [
      device('A', -60),
      device('B', -61),
      device('C', -40, name: 'Other'),
      device('D', 127)
    ];
    expect(
        filterCaptureScanResults(input, query: 's100', minimumRssi: -60)
            .map((r) => r.device.remoteId.str),
        ['A']);
    expect(
        filterCaptureScanResults(input, query: 'b', minimumRssi: -70)
            .single
            .device
            .remoteId
            .str,
        'B');
  });
  test('ascending RSSI and deterministic tie order', () {
    expect(
        filterCaptureScanResults(
                [device('B', -40), device('A', -40), device('C', -80)],
                strongestFirst: false)
            .map((r) => r.device.remoteId.str),
        ['C', 'A', 'B']);
  });
}
