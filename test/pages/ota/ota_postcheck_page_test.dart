import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/ota/realtek_ota_page.dart';
import 'package:honeybox/pages/ota/ota_confirmation.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/services/ota/device_probe.dart';
import 'package:honeybox/services/ota/firmware_inspection.dart';
import 'package:honeybox/services/ota/ota_device_profile.dart';
import 'package:honeybox/services/ota/ota_postcheck.dart';
import 'package:honeybox/services/ota/ota_preflight.dart';
import 'package:honeybox/services/ota/ota_repository.dart';
import 'package:honeybox/services/ota/ota_session.dart';
import '../../helpers/ota_fake_platform.dart';

class Picker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles(
          {String? dialogTitle,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Function(FilePickerStatus)? onFileLoading,
          bool allowCompression = true,
          int compressionQuality = 30,
          bool allowMultiple = false,
          bool withData = false,
          bool withReadStream = false,
          bool lockParentWindow = false,
          bool readSequential = false}) async =>
      FilePickerResult(
          [PlatformFile(name: 'pubspec.yaml', path: 'pubspec.yaml', size: 1)]);
}

class Parser implements FirmwareParser {
  Parser(this.target);
  final int? target;
  @override
  Future<FirmwareParseResult> parse(
          String path, DeviceCapabilities capabilities) async =>
      FirmwareParseResult(type: 'test', images: [
        'image'
      ], rawStatus: {
        'images': [
          if (target != null) {'version': target}
        ]
      }, checks: [
        const OtaCheck('format', OtaCheckStatus.pass, 'format ok'),
        const OtaCheck('compatibility', OtaCheckStatus.pass, 'compatible')
      ]);
}

const info = OtaDeviceInfoRecord(
    icType: 9,
    otaVersion: 1,
    secureVersion: 0,
    modeBits: 0,
    maxBuffer: 0,
    tempBankSizeBytes: null,
    imgIndicator: 0);

class WaitingProbe implements DeviceProbe {
  final completer = Completer<DeviceProbeResult>();
  int calls = 0;
  @override
  Future<DeviceProbeResult> probe(String id, {OtaDeviceProfile? profile}) {
    calls++;
    return completer.future;
  }
}

void main() {
  for (final scenario in [
    (2, PostcheckStatus.verified, OtaOutcome.verified, '已核验：设备身份与版本'),
    (1, PostcheckStatus.mismatch, OtaOutcome.failed, '核验失败'),
    (
      null,
      PostcheckStatus.unavailable,
      OtaOutcome.pendingVerification,
      '结果待核验'
    ),
  ]) {
    testWidgets('postcheck ${scenario.$2} persists and is single flight',
        (tester) async {
      FilePicker.platform = Picker();
      final platform = OtaFakePlatform();
      final probe = WaitingProbe();
      final directory = await tester.runAsync(
          () async => Directory.systemTemp.createTempSync('postcheck'));
      final repository = OtaRepository(directory!);
      addTearDown(() async {
        await platform.controller.close();
        directory.deleteSync(recursive: true);
      });
      await tester.pumpWidget(ProviderScope(
          overrides: [
            otaPlatformProvider.overrideWithValue(platform),
            otaBlePermissionProvider.overrideWithValue(() async => true),
            otaDeviceProbeProvider.overrideWithValue(OtaFakeProbe([],
                result: const DeviceProbeResult(
                    currentVersion: 1, otaDeviceInfo: info))),
            otaPostcheckerProvider
                .overrideWithValue(OtaPostchecker(probe, attempts: 1)),
            firmwareParserProvider.overrideWithValue(Parser(2)),
            otaRepositoryProvider.overrideWith((ref) async => repository),
          ],
          child: MaterialApp(
              home: RealtekOtaPage(
                  device: ScanDevice(
                      deviceId: 'device', name: 'test', rssi: -40)))));
      await tester.pump();
      platform.controller.add({'sessionId': platform.sessionId, 'ready': true});
      await tester.pump();
      await tester.tap(find.text('选择固件'));
      await tester.pump();
      await tester.tap(find.text('开始升级'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 && find.byType(OtaConfirmationSheet).evaluate().isEmpty;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump(const Duration(milliseconds: 100));
        }
      });
      await tester.pump(const Duration(seconds: 1));
      final scrollable = find
          .descendant(
              of: find.byType(OtaConfirmationSheet),
              matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(find.text('确认升级'), 150,
          scrollable: scrollable);
      await tester.tap(find.text('确认升级'));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && platform.starts == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump(const Duration(milliseconds: 100));
        }
      });
      platform.controller.add({
        'sessionId': platform.sessionId,
        'done': true,
        'outcome': 'pendingVerification',
        'message': '升级成功'
      });
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('升级成功'), findsNothing);
      expect(find.textContaining('结果待核验'), findsOneWidget);
      await tester.ensureVisible(find.text('核验升级结果'));
      await tester.tap(find.text('核验升级结果'));
      await tester.pump();
      expect(probe.calls, 1);
      expect(
          tester
              .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, '核验升级结果'))
              .onPressed,
          isNull);
      expect(platform.starts, 1);
      probe.completer.complete(
          DeviceProbeResult(currentVersion: scenario.$1, otaDeviceInfo: info));
      await tester.pump();
      expect(find.textContaining(scenario.$4), findsOneWidget);
      List<OtaSessionRecord> saved = [];
      for (var i = 0; i < 60; i++) {
        saved = await tester.runAsync(repository.list) ?? [];
        if (saved.isNotEmpty && saved.first.outcome == scenario.$3) break;
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(saved.first.outcome, scenario.$3);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('unknown target remains pending without probing or starting',
      (tester) async {
    final platform = OtaFakePlatform();
    final probe = WaitingProbe();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          otaPlatformProvider.overrideWithValue(platform),
          otaBlePermissionProvider.overrideWithValue(() async => true),
          otaDeviceProbeProvider.overrideWithValue(OtaFakeProbe([])),
          otaPostcheckerProvider.overrideWithValue(OtaPostchecker(probe)),
        ],
        child: MaterialApp(
            home: RealtekOtaPage(
                device:
                    ScanDevice(deviceId: 'device', name: 'test', rssi: -40)))));
    await tester.pump();
    platform.controller
        .add({'sessionId': platform.sessionId, 'done': true, 'message': '完成'});
    await tester.pump();
    await tester.tap(find.text('核验升级结果'));
    await tester.pump();
    expect(find.textContaining('目标版本未知'), findsOneWidget);
    expect(probe.calls, 0);
    expect(platform.starts, 0);
    expect(platform.prepares, 1);
    await tester.pumpWidget(const SizedBox());
    await platform.controller.close();
  });
}
