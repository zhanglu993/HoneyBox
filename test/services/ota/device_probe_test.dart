import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/device_probe.dart';
import 'package:honeybox/services/ota/ota_device_profile.dart';

class FakeConnection implements DeviceProbeConnection {
  bool connected = false;
  bool closed = false;
  bool failDisconnect = false;
  final values = <String, List<int>>{};
  @override bool get isConnected => connected;
  @override Future<void> connect() async {}
  @override Future<Map<String, Future<List<int>> Function()>> discover() async =>
      values.map((key, value) => MapEntry(key, () async => value));
  @override Future<void> disconnect() async { closed = true; if (failDisconnect) throw StateError('disconnect'); }
}

void main() {
  final profile = OtaProfileRegistry.defaultProfileById('s200');
  test('FFF1 fields and lengths', () {
    final info = OtaDeviceInfoRecord.parse(Uint8List.fromList([9, 2, 3, 16, 0, 8, 4, 0, 1, 2, 3, 4]));
    expect(info!.maxBuffer, 2048);
    expect(info.tempBankSizeBytes, 16384);
    expect(info.imgIndicator, 0x04030201);
    expect(OtaDeviceInfoRecord.parse(Uint8List(11)), isNull);
    expect(OtaDeviceInfoRecord.parse(Uint8List(12))!.tempBankSizeBytes, isNull);
  });
  test('one connection reads version, info and BAS; zero is unknown', () async {
    final c = FakeConnection()..values.addAll({
      '0000ffd4-0000-1000-8000-00805f9b34fb': [16, 0, 0, 48],
      '0000fff1-3c17-d293-8e48-14fe2e4da212': [9, 1, 0, 0, 0, 8, 9, 0, 0, 0, 0, 0],
      '00002a19-0000-1000-8000-00805f9b34fb': [0],
    });
    final result = await FlutterBlueDeviceProbe(connectionFactory: (_) => c).probe('x', profile: profile);
    expect(result.currentVersion, 0x30000010);
    expect(result.otaDeviceInfo!.icType, 9);
    expect(result.batteryPercent, isNull);
    expect(result.charging, isNull);
    expect(c.closed, isTrue);
  });
  test('BAS percentage is read when available', () async {
    final c = FakeConnection()..values['00002a19-0000-1000-8000-00805f9b34fb'] = [30];
    final result = await FlutterBlueDeviceProbe(connectionFactory: (_) => c).probe('x', profile: profile);
    expect(result.batteryPercent, 30);
  });
  test('missing and malformed characteristics remain unknown', () async {
    final c = FakeConnection()..values.addAll({'0000ffd4-0000-1000-8000-00805f9b34fb': [1], '0000fff1-0000-1000-8000-00805f9b34fb': [1], '00002a19-0000-1000-8000-00805f9b34fb': [101]});
    final result = await FlutterBlueDeviceProbe(connectionFactory: (_) => c).probe('x', profile: profile);
    expect(result.currentVersion, isNull); expect(result.otaDeviceInfo, isNull); expect(result.batteryPercent, isNull);
  });
  test('already connected is not taken over', () async {
    final c = FakeConnection()..connected = true;
    final result = await FlutterBlueDeviceProbe(connectionFactory: (_) => c).probe('x', profile: profile);
    expect(result.currentVersion, isNull); expect(c.closed, isFalse);
  });
  test('disconnect failure propagates', () async {
    final c = FakeConnection()..failDisconnect = true;
    await expectLater(FlutterBlueDeviceProbe(connectionFactory: (_) => c).probe('x'), throwsStateError);
  });
}
