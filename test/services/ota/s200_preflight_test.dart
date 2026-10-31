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
          bool overrideVersion = false}) =>
      FirmwareInspection.inspect(
          file.path,
          DeviceCapabilities(
              confirmed: version != null,
              currentVersion: version,
              expectedIcType: 9,
              deviceReportedCapacity: reportedCapacity,
              batteryPercent: battery,
              charging: charging,
              allowSameOrOlderVersion: overrideVersion),
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
        'same or downgrade $v blocks',
        () async => expect(status(await inspect(version: v), 'version'),
            OtaCheckStatus.block));
  }
  test(
      'explicit version override',
      () async => expect(
          status(await inspect(version: 3, overrideVersion: true), 'version'),
          OtaCheckStatus.pass));
  test(
      'unreadable version is unknown',
      () async => expect(status(await inspect(version: null), 'version'),
          OtaCheckStatus.unknown));
  for (final entry in {
    'customer': 512 + 0x68,
    'commit': 512 + 0x64,
    'ic': 512,
    'image id': 512 + 4,
    'payload': 512 + 8
  }.entries) {
    test('${entry.key} mismatch blocks', () async {
      await mutate(entry.value, 0, fixHash: entry.key != 'payload');
      expect((await inspect()).report.canStart, isFalse);
      if (entry.key != 'customer') {
        expect(
            (await inspect())
                .report
                .checks
                .any((c) => c.status == OtaCheckStatus.block),
            isTrue);
      } else {
        expect(
            status(await inspect(), 'compatibility'), OtaCheckStatus.unknown);
      }
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
  });
  test('unknown profile is fail closed with guidance', () async {
    final result = await inspect(registry: const OtaProfileRegistry([]));
    expect(status(result, 'compatibility'), OtaCheckStatus.unknown);
    expect(status(result, 'capacity'), OtaCheckStatus.unknown);
    expect(result.report.canStart, isFalse);
    expect(
        result.report.checks
            .firstWhere((c) => c.id == 'compatibility')
            .explanation,
        contains('请在 OTA 档案注册表中添加'));
  });
  test('large profile, S200 limit and device capacity precedence', () async {
    const size = 0x90000;
    const large = OtaDeviceProfile(
        id: 'large',
        displayName: 'large',
        icType: 9,
        imageId: 0x2793,
        customerName: 'S200_62#',
        appBankSize: 0x100000,
        batteryMinPercent: 70,
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
        OtaCheckStatus.block);
    expect(status(await inspect(reportedCapacity: 0x100000), 'capacity'),
        OtaCheckStatus.pass);
    expect(status(await inspect(registry: registry, battery: 50), 'battery'),
        OtaCheckStatus.block);
    expect(status(await inspect(battery: 50), 'battery'), OtaCheckStatus.pass);
  });
  test(
      'low battery blocks',
      () async => expect(
          status(await inspect(battery: 29), 'battery'), OtaCheckStatus.block));
  test(
      'unknown battery warns and blocks',
      () async => expect(status(await inspect(battery: null), 'battery'),
          OtaCheckStatus.unknown));
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
    expect((await inspect(version: 0x3000000f)).report.canStart, isTrue);
  }, skip: !real.existsSync() ? 'real firmware not available' : false);
}
