import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/android_realtek_firmware_parser.dart';
import 'package:honeybox/services/ota/firmware_inspection.dart';
import 'package:honeybox/services/ota/ota_preflight.dart';
import 'package:honeybox/services/ota/device_probe.dart';
import 'package:honeybox/services/ota/ota_device_profile.dart';

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
  test('unverified reported APP capacity is ignored', () async {
    final result = await inspect(const DeviceCapabilities(
        confirmed: true,
        expectedIcType: 9,
        currentVersion: 2,
        batteryPercent: 50,
        deviceReportedCapacity: 1039));
    expect(check(result, 'capacity'), OtaCheckStatus.pass);
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
  test('FFF1 chip mismatch blocks compatibility and multi capacity is enforced', () async {
    DeviceCapabilities device(int ic, int mode, int? size) => DeviceCapabilities(
      confirmed: true, currentVersion: 2, batteryPercent: 50,
      otaDeviceInfo: OtaDeviceInfoRecord(icType: ic, otaVersion: 1, secureVersion: 0,
        modeBits: mode, maxBuffer: 2048, tempBankSizeBytes: size, imgIndicator: 0));
    expect(check(await inspect(device(8, 0, null)), 'compatibility'), OtaCheckStatus.block);
    expect(check(await inspect(device(9, 16, 1039)), 'capacity'), OtaCheckStatus.block);
    expect(check(await inspect(device(9, 16, 1040)), 'capacity'), OtaCheckStatus.pass);
    expect(check(await inspect(device(9, 0, 1)), 'capacity'), OtaCheckStatus.pass);
    expect(check(await inspect(), 'capacity'), OtaCheckStatus.pass);
  });
  test('battery policy depends on profile source', () async {
    Future<OtaCheckStatus> battery(BatterySource source, int? value, bool? charging) async {
      final base = OtaProfileRegistry.defaultProfileById('s200');
      final profile = OtaDeviceProfile(id: 'other', displayName: 'other', icType: 9,
          imageId: 0x2793, customerName: base.customerName, appBankSize: base.appBankSize,
          batteryMinPercent: 30, batterySource: source, evidence: 'test');
      final result = await FirmwareInspection.inspect(file.path,
          DeviceCapabilities(confirmed: true, currentVersion: 2, batteryPercent: value, charging: charging),
          AndroidRealtekFirmwareParser(channel: channel, registry: OtaProfileRegistry([profile])));
      return check(result, 'battery');
    }
    expect(await battery(BatterySource.none, null, null), OtaCheckStatus.pass);
    expect(await battery(BatterySource.bas, 30, null), OtaCheckStatus.pass);
    expect(await battery(BatterySource.bas, 29, false), OtaCheckStatus.unknown);
    expect(await battery(BatterySource.basAndBwps, 29, false), OtaCheckStatus.block);
    expect(await battery(BatterySource.basAndBwps, 29, true), OtaCheckStatus.pass);
    expect(await battery(BatterySource.basAndBwps, 29, null), OtaCheckStatus.unknown);
    expect(await battery(BatterySource.bwps, null, true), OtaCheckStatus.unknown);
  });

}
