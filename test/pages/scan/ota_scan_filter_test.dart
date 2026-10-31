import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/services/jw/jw_scan_policy.dart';

void main() {
  ScanDevice device(String name, {bool connectable = true}) => ScanDevice(
        deviceId: 'AA:BB:CC',
        name: name,
        rssi: -60,
        connectable: connectable,
      );

  test('OTA 默认排除无名称和不可连接设备，可关闭筛选找回', () {
    bool visible(ScanDevice d, {bool named = true, bool connectable = true}) =>
        JwScanPolicy.matches(
          query: '',
          isDefaultWatchFilter: false,
          device: d,
          onlyNamed: named,
          onlyConnectable: connectable,
        );
    expect(visible(device('V101')), isTrue);
    expect(visible(device('N/A')), isFalse);
    expect(visible(device('未知设备')), isFalse);
    expect(visible(device('S200', connectable: false)), isFalse);
    expect(visible(device('N/A'), named: false), isTrue);
    expect(visible(device('S200', connectable: false), connectable: false),
        isTrue);
  });
}
