import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/android_realtek_firmware_parser.dart';
import 'package:honeybox/services/ota/firmware_inspection.dart';
import 'package:honeybox/services/ota/ota_preflight.dart';

import 'realtek_image_header_test.dart' show makeRealtekImage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/realtek-firmware');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late File file;
  late Map<String, Object?> response;
  const caps = DeviceCapabilities(
      confirmed: true,
      expectedIcType: 9,
      currentVersion: 2,
      batteryPercent: 50,
      charging: false);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('firmware_test');
    file = File('${directory.path}/firmware.bin');
    await file.writeAsBytes(makeRealtekImage());
    response = {
      'status': 4096,
      'updateEnabled': true,
      'icType': 3,
      'images': [
        {
          'imageId': 0x2793,
          'binId': 0x300,
          'offset': 0,
          'size': 1028,
          'version': 3
        }
      ]
    };
    messenger.setMockMethodCallHandler(channel, (call) async => response);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });
  Future<FirmwareInspection> inspect([DeviceCapabilities device = caps]) =>
      FirmwareInspection.inspect(
          file.path, device, AndroidRealtekFirmwareParser(channel: channel));
  OtaCheckStatus check(FirmwareInspection result, String id) =>
      result.report.checks.firstWhere((c) => c.id == id).status;

  test(
      'confirmed matching upgrade passes all checks despite SDK default icType',
      () async {
    final result = await inspect();
    expect(result.report.canStart, isTrue);
    for (final id in [
      'format',
      'compatibility',
      'chip',
      'capacity',
      'version'
    ]) {
      expect(check(result, id), OtaCheckStatus.pass);
    }
  });
  test('wrong configured chip blocks', () async {
    final result = await inspect(const DeviceCapabilities(expectedIcType: 5));
    expect(check(result, 'chip'), OtaCheckStatus.block);
  });
  test('SDK and header mismatch blocks', () async {
    response['images'] = [
      {'imageId': 1, 'binId': 0x300, 'size': 1028, 'version': 3}
    ];
    expect(check(await inspect(), 'format'), OtaCheckStatus.block);
  });
  test('oversized image blocks', () async {
    final result = await inspect(const DeviceCapabilities(
        confirmed: true,
        expectedIcType: 9,
        currentVersion: 2,
        batteryPercent: 50,
        deviceReportedCapacity: 1039));
    expect(check(result, 'capacity'), OtaCheckStatus.block);
  });
  for (final current in [3, 4]) {
    test('same or older version blocks for device version $current', () async {
      final result = await inspect(DeviceCapabilities(
          confirmed: true,
          expectedIcType: 9,
          currentVersion: current,
          batteryPercent: 50));
      expect(check(result, 'version'), OtaCheckStatus.block);
    });
  }
  test('SDK error blocks', () async {
    response = {'status': 4112, 'errorCode': 4112};
    expect(check(await inspect(), 'format'), OtaCheckStatus.block);
  });
  test('missing SDK fields do not authorize writing', () async {
    response.remove('images');
    final result = await inspect();
    expect(result.report.canStart, isFalse);
    expect(check(result, 'format'), OtaCheckStatus.unknown);
    expect(check(result, 'compatibility'), OtaCheckStatus.unknown);
  });
  test('missing device evidence does not authorize writing', () async {
    final result = await inspect(const DeviceCapabilities(expectedIcType: 9));
    expect(check(result, 'chip'), OtaCheckStatus.pass);
    expect(check(result, 'version'), OtaCheckStatus.unknown);
    expect(result.report.canStart, isFalse);
  });
  test('unconfirmed layout does not authorize writing', () async {
    final result = await inspect(const DeviceCapabilities(
        confirmed: true,
        expectedIcType: 9,
        currentVersion: 2,
        capacity: 1040,
        imageId: 0x2793));
    expect(result.report.canStart, isFalse);
  });
  test('empty file blocks before parsing', () async {
    await file.writeAsBytes([]);
    expect((await inspect()).report.canStart, isFalse);
  });
}
