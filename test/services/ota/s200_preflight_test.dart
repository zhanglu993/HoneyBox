import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/android_realtek_firmware_parser.dart';
import 'package:honeybox/services/ota/firmware_inspection.dart';
import 'package:honeybox/services/ota/ota_preflight.dart';
import 'package:honeybox/services/ota/ota_device_profile.dart';

import 'realtek_image_header_test.dart' show makeRealtekImage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/s200-preflight');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  late File file;
  late Map<String, Object?> sdk;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('s200_preflight');
    file = File('${dir.path}/image.bin');
    final bytes = makeRealtekImage();
    final data = ByteData.sublistView(bytes);
    data.setUint32(512 + 0x64, 0xded9c2aa, Endian.little);
    bytes.setRange(512 + 0x68, 512 + 0x70, 'S200_62#'.codeUnits);
    void digest() => bytes.setRange(
        512 + 372,
        512 + 404,
        sha256.convert([
          ...bytes.sublist(512 + 12, 512 + 372),
          ...bytes.sublist(512 + 404, 512 + 752),
          ...bytes.sublist(512 + 1008),
        ]).bytes);
    digest();
    await file.writeAsBytes(bytes);
    sdk = {
      'status': 4096,
      'images': [
        {'imageId': 0x2793, 'binId': 0x300, 'size': 1028, 'version': 3}
      ]
    };
    messenger.setMockMethodCallHandler(channel, (_) async => sdk);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });
  Future<FirmwareInspection> inspect(
          {int? version = 2,
          int? battery = 50,
          bool? charging = false,
          OtaProfileRegistry registry = const OtaProfileRegistry(),
          int? reportedCapacity,
          int? expectedIcType = 9}) =>
      FirmwareInspection.inspect(
          file.path,
          DeviceCapabilities(
              confirmed: true,
              currentVersion: version,
              expectedIcType: expectedIcType,
              deviceReportedCapacity: reportedCapacity,
              batteryPercent: battery,
              charging: charging),
          AndroidRealtekFirmwareParser(channel: channel, registry: registry));
  OtaCheckStatus status(FirmwareInspection r, String id) =>
      r.report.checks.firstWhere((c) => c.id == id).status;
  Future<void> mutate(int offset, int value, {bool fixHash = true}) async {
    final bytes = await file.readAsBytes();
    bytes[offset] = value;
    if (fixHash) {
      bytes.setRange(
          512 + 372,
          512 + 404,
          sha256.convert([
            ...bytes.sublist(512 + 12, 512 + 372),
            ...bytes.sublist(512 + 404, 512 + 752),
            ...bytes.sublist(512 + 1008),
          ]).bytes);
    }
    await file.writeAsBytes(bytes);
  }

  test('matching upgrade passes',
      () async => expect((await inspect()).report.canStart, isTrue));
  for (final v in [3, 4]) {
    test(
        'same or downgrade $v warns',
        () async => expect(status(await inspect(version: v), 'version'),
            OtaCheckStatus.warn));
  }
  test(
      'unreadable version warns',
      () async => expect(status(await inspect(version: null), 'version'),
          OtaCheckStatus.warn));
  test('profile can forbid same version and downgrade', () async {
    const profile = OtaDeviceProfile(id: 'strict', displayName: 'strict', icType: 9, imageId: 0x2793, customerName: 'S200_62#', appBankSize: 0x64000, allowDowngrade: false, evidence: 'test');
    for (final version in [3, 4]) {
      expect(status(await inspect(version: version, registry: const OtaProfileRegistry([profile])), 'version'), OtaCheckStatus.block);
    }
  });
  test('downgrade description includes raw and decoded versions', () async {
    final result = await inspect(version: 0x30000010);
    expect(result.report.canStart, isTrue);
    final message = result.report.checks.firstWhere((c) => c.id == 'version').explanation;
    expect(message, contains('降级'));
    expect(message, contains('0x30000010 (0.1.0)'));
    expect(message, contains('目标 0x00000003 (3.0.0)'));
  });
  test('missing version and battery warn without blocking', () async {
    final result = await inspect(version: null, battery: null);
    expect(status(result, 'version'), OtaCheckStatus.warn);
    expect(status(result, 'battery'), OtaCheckStatus.warn);
    expect(result.report.canStart, isTrue);
  });
  for (final entry in {
    'commit': 512 + 0x64,
    'ic': 512,
    'image id': 512 + 4,
    'payload': 512 + 8
  }.entries) {
    test('${entry.key} mismatch blocks', () async {
      await mutate(entry.value, 0, fixHash: entry.key != 'payload');
      expect((await inspect()).report.canStart, isFalse);
      expect(
          (await inspect())
              .report
              .checks
              .any((c) => c.status == OtaCheckStatus.block),
          isTrue);
    });
  }
  test('synthetic image exceeding 0x64000 blocks', () async {
    const size = 0x64001;
    final original = await file.readAsBytes();
    final bytes = Uint8List(512 + size)..setRange(0, original.length, original);
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    while (true) {
      final id = data.getUint16(offset, Endian.little);
      if (id == 0) break;
      final length = bytes[offset + 2];
      if (id == 4 || id == 0x14)
        data.setUint32(offset + 3, size, Endian.little);
      offset += 3 + length;
    }
    data.setUint32(512 + 8, size - 1024, Endian.little);
    bytes.setRange(
        512 + 372,
        512 + 404,
        sha256.convert([
          ...bytes.sublist(512 + 12, 512 + 372),
          ...bytes.sublist(512 + 404, 512 + 752),
          ...bytes.sublist(512 + 1008),
        ]).bytes);
    await file.writeAsBytes(bytes);
    sdk['images'] = [
      {'imageId': 0x2793, 'binId': 0x300, 'size': size - 12, 'version': 3}
    ];
    expect(status(await inspect(), 'capacity'), OtaCheckStatus.block);
    expect(status(await inspect(registry: const OtaProfileRegistry([])), 'capacity'), OtaCheckStatus.block);
  });
  test('empty registry uses generic checks', () async {
    final result = await inspect(registry: const OtaProfileRegistry([]));
    expect(status(result, 'compatibility'), OtaCheckStatus.pass);
    expect(status(result, 'capacity'), OtaCheckStatus.pass);
    expect(result.report.canStart, isTrue);
    expect(result.report.checks.firstWhere((c) => c.id == 'compatibility').explanation,
        isNot(contains('档案注册表')));
  });
  test('ambiguous profiles use generic checks', () async {
    final profile = OtaProfileRegistry.defaultProfileById('s200');
    final result = await inspect(registry: OtaProfileRegistry([profile, profile]));
    expect(status(result, 'compatibility'), OtaCheckStatus.pass);
    expect(status(result, 'capacity'), OtaCheckStatus.pass);
    expect(result.report.canStart, isTrue);
  });
  test('S100-like customer uses generic checks', () async {
    for (var i = 0; i < 'S100_62#'.length; i++) {
      await mutate(512 + 0x68 + i, 'S100_62#'.codeUnitAt(i));
    }
    final result = await inspect();
    expect(result.report.canStart, isTrue);
    expect(result.report.checks.any((c) => c.status == OtaCheckStatus.block), isFalse);
  });
  test('generic chip mismatch blocks', () async {
    final result = await inspect(registry: const OtaProfileRegistry([]), expectedIcType: 8);
    expect(status(result, 'chip'), OtaCheckStatus.block);
    expect(status(result, 'compatibility'), OtaCheckStatus.block);
  });
  test('unconfirmed chip uses header default with warning', () async {
    final result = await inspect(registry: const OtaProfileRegistry([]), expectedIcType: null);
    expect(status(result, 'chip'), OtaCheckStatus.unknown);
    expect(status(result, 'compatibility'), OtaCheckStatus.warn);
    expect(status(result, 'capacity'), OtaCheckStatus.warn);
  });
  test('reported capacity blocks oversized image without profile', () async {
    final result = await inspect(registry: const OtaProfileRegistry([]), reportedCapacity: 1039);
    expect(status(result, 'capacity'), OtaCheckStatus.block);
  });
  test('generic low battery warns and charging passes', () async {
    const registry = OtaProfileRegistry([]);
    final low = await inspect(registry: registry, battery: 20);
    expect(status(low, 'battery'), OtaCheckStatus.warn);
    expect(low.report.canStart, isTrue);
    expect(low.report.checks.firstWhere((c) => c.id == 'battery').explanation, contains('30%'));
    expect(status(await inspect(registry: registry, battery: 20, charging: true), 'battery'), OtaCheckStatus.pass);
  });
  test('APP bank capacity comes from the matched profile', () async {
    const size = 0x90000;
    const large = OtaDeviceProfile(
        id: 'large',
        displayName: 'large',
        icType: 9,
        imageId: 0x2793,
        customerName: 'S200_62#',
        appBankSize: 0x100000,
        batteryMinPercent: 70,
        batterySource: BatterySource.basAndBwps,
        evidence: 'synthetic test');
    final original = await file.readAsBytes();
    final bytes = Uint8List(512 + size)..setRange(0, original.length, original);
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    while (data.getUint16(offset, Endian.little) != 0) {
      final id = data.getUint16(offset, Endian.little);
      if (id == 4 || id == 0x14)
        data.setUint32(offset + 3, size, Endian.little);
      offset += 3 + bytes[offset + 2];
    }
    data.setUint32(512 + 8, size - 1024, Endian.little);
    bytes.setRange(
        512 + 372,
        512 + 404,
        sha256.convert([
          ...bytes.sublist(512 + 12, 512 + 372),
          ...bytes.sublist(512 + 404, 512 + 752),
          ...bytes.sublist(512 + 1008),
        ]).bytes);
    await file.writeAsBytes(bytes);
    sdk['images'] = [
      {'imageId': 0x2793, 'binId': 0x300, 'size': size - 12, 'version': 3}
    ];
    const registry = OtaProfileRegistry([large]);
    expect(status(await inspect(registry: registry, battery: 80), 'capacity'),
        OtaCheckStatus.pass);
    expect(status(await inspect(), 'capacity'), OtaCheckStatus.block);
    expect(
        status(await inspect(registry: registry, reportedCapacity: 0x80000),
            'capacity'),
        OtaCheckStatus.pass);
    expect(status(await inspect(reportedCapacity: 0x100000), 'capacity'),
        OtaCheckStatus.block);
    expect(status(await inspect(registry: registry, battery: 50), 'battery'),
        OtaCheckStatus.warn);
    expect(status(await inspect(battery: 50), 'battery'), OtaCheckStatus.pass);
  });
  test(
      'low battery warns',
      () async => expect(
          status(await inspect(battery: 29), 'battery'), OtaCheckStatus.warn));
  test(
      'unknown battery warns',
      () async => expect(status(await inspect(battery: null), 'battery'),
          OtaCheckStatus.warn));
  test('SDK disagreement blocks', () async {
    sdk['images'] = [
      {'imageId': 1, 'binId': 0x300, 'size': 1028, 'version': 3}
    ];
    expect(status(await inspect(), 'format'), OtaCheckStatus.block);
  });
  final real = File('output/ota-real-fw/real.bin');
  test('real S200 image with lower version and known safe battery', () async {
    await file.writeAsBytes(await real.readAsBytes());
    sdk['images'] = [
      {
        'imageId': 0x2793,
        'binId': 0x300,
        'size': 0x50ec8 - 12,
        'version': 0x30000010
      }
    ];
    expect((await inspect(version: 0x3000000f, battery: 30, charging: null)).report.canStart, isTrue);
    final same = await inspect(version: 0x30000010, battery: 30);
    expect(same.report.canStart, isTrue);
    expect(status(same, 'version'), OtaCheckStatus.warn);
  }, skip: !real.existsSync() ? 'real firmware not available' : false);
}
