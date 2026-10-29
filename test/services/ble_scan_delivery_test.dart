import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_manager.dart';

final class _ScanPlatform extends FlutterBluePlusPlatform {
  final responses = StreamController<BmScanResponse>.broadcast();

  @override
  Stream<BmScanResponse> get onScanResponse => responses.stream;
  @override
  Future<bool> startScan(BmScanSettings request) async => true;
  @override
  Future<bool> stopScan(BmStopScanRequest request) async => true;

  void advertise(String id, int rssi) {
    responses.add(BmScanResponse(
      success: true,
      errorCode: 0,
      errorString: '',
      advertisements: [
        BmScanAdvertisement(
          remoteId: DeviceIdentifier(id),
          platformName: null,
          advName: id,
          connectable: true,
          txPowerLevel: null,
          appearance: null,
          manufacturerData: {},
          serviceData: {},
          serviceUuids: [],
          rssi: rssi,
        ),
      ],
    ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scan delivers each new advertisement without replaying older devices',
      () async {
    final platform = _ScanPlatform();
    FlutterBluePlusPlatform.instance = platform;
    final manager = BleManager();
    addTearDown(() async {
      manager.dispose();
      await Future<void>.delayed(Duration.zero);
      await platform.responses.close();
    });
    final seen = <String>[];
    await manager.startScan((result) {
      seen.add('${result.device.remoteId.str}:${result.rssi}');
    });
    for (final (id, rssi) in [('one', -50), ('two', -60), ('one', -55)]) {
      platform.advertise(id, rssi);
      await Future<void>.delayed(Duration.zero);
    }
    expect(seen, ['one:-50', 'two:-60', 'one:-55']);
  });
}
