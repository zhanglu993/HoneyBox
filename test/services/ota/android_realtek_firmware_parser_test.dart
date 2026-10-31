import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/android_realtek_firmware_parser.dart';
import 'package:honeybox/services/ota/firmware_inspection.dart';
import 'package:honeybox/services/ota/ota_preflight.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/realtek-firmware');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late File file;
  late Map<String, Object?> response;
  const caps = DeviceCapabilities(confirmed: true, icType: 5,
      currentVersion: 2, capacity: 100, imageId: 1, layoutConfirmed: true);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('firmware_test');
    file = File('${directory.path}/firmware.bin');
    await file.writeAsBytes(List.filled(32, 1));
    response = {'status': 4096, 'updateEnabled': true, 'icType': 5,
      'version': 3, 'formatVerified': true,
      'images': [{'imageId': 1, 'offset': 0, 'size': 80, 'version': 3}],
      'capacityCheckAvailable': true, 'versionCheckAvailable': true};
    messenger.setMockMethodCallHandler(channel, (call) async => response);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  Future<FirmwareInspection> inspect([DeviceCapabilities device = caps]) =>
      FirmwareInspection.inspect(file.path, device,
          AndroidRealtekFirmwareParser(channel: channel));
  OtaCheckStatus check(FirmwareInspection result, String id) =>
      result.report.checks.firstWhere((c) => c.id == id).status;

  test('confirmed matching upgrade passes all checks', () async {
    final result = await inspect();
    expect(result.report.canStart, isTrue);
    for (final id in ['format', 'compatibility', 'chip', 'capacity', 'version']) {
      expect(check(result, id), OtaCheckStatus.pass);
    }
  });
  test('wrong chip blocks', () async {
    response['icType'] = 6;
    expect(check(await inspect(), 'chip'), OtaCheckStatus.block);
  });
  test('oversized image blocks', () async {
    response['images'] = [{'imageId': 1, 'offset': 0, 'size': 101, 'version': 3}];
    expect(check(await inspect(), 'capacity'), OtaCheckStatus.block);
  });
  for (final version in [2, 1]) {
    test('same or older version $version blocks', () async {
      response['version'] = version;
      response['images'] = [{'imageId': 1, 'offset': 0, 'size': 80, 'version': version}];
      expect(check(await inspect(), 'version'), OtaCheckStatus.block);
    });
  }
  test('SDK error blocks', () async {
    response = {'status': 4112, 'errorCode': 4112};
    expect(check(await inspect(), 'format'), OtaCheckStatus.block);
  });
  test('missing SDK fields do not authorize writing', () async {
    response.remove('images');
    expect((await inspect()).report.canStart, isFalse);
    expect(check(await inspect(), 'compatibility'), OtaCheckStatus.unknown);
  });
  test('unconfirmed device does not authorize writing', () async {
    expect((await inspect(const DeviceCapabilities())).report.canStart, isFalse);
  });
  test('unconfirmed layout does not authorize writing', () async {
    final result = await inspect(const DeviceCapabilities(confirmed: true,
        icType: 5, currentVersion: 2, capacity: 100, imageId: 1));
    expect(check(result, 'compatibility'), OtaCheckStatus.unknown);
    expect(result.report.canStart, isFalse);
  });
  test('empty file blocks before parsing', () async {
    await file.writeAsBytes([]);
    expect((await inspect()).report.canStart, isFalse);
  });
  test('truncated file reported by SDK blocks', () async {
    await file.writeAsBytes([1, 2]);
    response = {'status': 4100, 'errorCode': 4100};
    expect((await inspect()).report.canStart, isFalse);
  });
}
