import 'dart:typed_data';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/device_probe.dart';
import 'package:honeybox/services/ota/ota_device_profile.dart';

class FakeConnection implements DeviceProbeConnection {
  bool connected = false;
  bool closed = false;
  bool failDisconnect = false;
  final notifications = StreamController<List<int>>.broadcast();
  bool hasBwps = false;
  List<int>? responseFrame;
  List<int>? written;
  bool hangRead = false;
  bool hangOnInfo = false;
  @override Stream<List<int>>? get bwpsNotifications => hasBwps ? notifications.stream : null;
  @override Future<void> enableBwpsNotifications() async {}
  @override Future<void> disableBwpsNotifications() async {}
  @override Future<void> writeBwps(List<int> value) async {
    written = value;
    notifications.add([0xab, 0x10, 0, 0, 0, 0, 0, 0]);
    if (responseFrame != null) notifications.add(responseFrame!);
  }
  final values = <String, List<int>>{};
  @override bool get isConnected => connected;
  @override Future<void> connect() async {}
  @override Future<Map<String, Future<List<int>> Function()>> discover() async =>
      values.map((key, value) => MapEntry(key, () async => (hangRead || (hangOnInfo && key.contains('fff1'))) ? await Completer<List<int>>().future : value));
  @override Future<void> disconnect() async { closed = true; if (failDisconnect) throw StateError('disconnect'); }
}

void main() {
  final profile = OtaProfileRegistry.defaultProfileById('s200');
  test('overall timeout preserves earlier values and disconnects', () async {
    final c = FakeConnection()..values['0000ffd4-0000-1000-8000-00805f9b34fb'] = [1, 0, 0, 0];
    c.values['0000fff1-0000-1000-8000-00805f9b34fb'] = [1];
    final probe = FlutterBlueDeviceProbe(connectionFactory: (_) => c, timeout: const Duration(milliseconds: 30));
    // Hang the second read only.
    c.hangOnInfo = true;
    final result = await probe.probe('x');
    expect(result.currentVersion, 1); expect(c.closed, isTrue);
  });
  test('ACK alone times out without losing BAS and version', () async {
    final c = FakeConnection()..hasBwps = true..values.addAll({
      '0000ffd4-0000-1000-8000-00805f9b34fb': [1, 0, 0, 0],
      '00002a19-0000-1000-8000-00805f9b34fb': [45],
    });
    final result = await FlutterBlueDeviceProbe(connectionFactory: (_) => c,
        bwpsTimeout: const Duration(milliseconds: 30)).probe('x', profile: profile);
    expect(result.currentVersion, 1); expect(result.batteryPercent, 45);
    expect(result.charging, isNull); expect(c.closed, isTrue);
  });
  test('BWPS response supplies charging and fallback percentage', () async {
    final c = FakeConnection()..hasBwps = true
      ..values['00002a19-0000-1000-8000-00805f9b34fb'] = [0]
      ..responseFrame = [0xab, 0x40, 0, 7, 0x68, 0xa4, 0, 1, 0x58, 0, 0x19, 0, 2, 1, 85];
    final result = await FlutterBlueDeviceProbe(connectionFactory: (_) => c).probe('x', profile: profile);
    expect(c.written, orderedEquals([0xab, 0, 0, 5, 0xca, 0xa1, 0, 0, 0x58, 0, 0x18, 0, 0]));
    expect(result.charging, isTrue); expect(result.batteryPercent, 85);
  });
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
