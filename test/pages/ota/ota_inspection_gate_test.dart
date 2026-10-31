import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/ota/realtek_ota_page.dart';
import 'package:honeybox/pages/ota/ota_confirmation.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/services/ota/firmware_inspection.dart';
import 'package:honeybox/services/ota/device_probe.dart';
import '../../helpers/ota_fake_platform.dart';
import 'package:honeybox/services/ota/ota_preflight.dart';

class _Picker extends FilePicker {
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

class _Parser implements FirmwareParser {
  _Parser(this.status);
  final OtaCheckStatus status;
  DeviceCapabilities? received;
  @override
  Future<FirmwareParseResult> parse(
      String path, DeviceCapabilities capabilities) async {
    received = capabilities;
    return FirmwareParseResult(type: 'test', images: [
      'image'
    ], checks: [
      OtaCheck('format', status, '检查未通过：${status.name}'),
      const OtaCheck('compatibility', OtaCheckStatus.pass, 'ok'),
    ]);
  }
}

void main() {
  for (final confirm in [true, false]) {
    testWidgets('warning requires explicit confirmation: $confirm',
        (tester) async {
      FilePicker.platform = _Picker();
      final platform = OtaFakePlatform();
      await tester.pumpWidget(ProviderScope(
          overrides: [
            otaPlatformProvider.overrideWithValue(platform),
            otaBlePermissionProvider.overrideWithValue(() async => true),
            firmwareParserProvider
                .overrideWithValue(_Parser(OtaCheckStatus.warn)),
            otaDeviceProbeProvider.overrideWithValue(OtaFakeProbe(
                platform.calls,
                result: const DeviceProbeResult(currentVersion: 2))),
          ],
          child: MaterialApp(
              home: RealtekOtaPage(
                  device: ScanDevice(
                      deviceId: 'device', name: 'test', rssi: -40)))));
      await tester.pump(const Duration(milliseconds: 100));
      platform.controller.add({'sessionId': platform.sessionId, 'ready': true});
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('选择固件'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('开始升级'));
      await tester.runAsync(() async {
        for (var i = 0;
            i < 100 && find.byType(OtaConfirmationSheet).evaluate().isEmpty;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump(const Duration(milliseconds: 100));
        }
      });
      expect(platform.starts, 0);
      expect(find.textContaining('检查未通过：warn'), findsWidgets);
      if (confirm) {
        await tester.pump(const Duration(seconds: 1));
        await tester.scrollUntilVisible(find.text('我已了解风险'), 150,
            scrollable: _sheetScrollable());
        await tester.tap(find.text('我已了解风险'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(seconds: 1));
        await tester.scrollUntilVisible(find.text('确认升级'), 150,
            scrollable: _sheetScrollable());
      } else {
        await tester.pump(const Duration(seconds: 1));
        await tester.scrollUntilVisible(find.text('取消'), 150,
            scrollable: _sheetScrollable());
      }
      await tester.tap(find.text(confirm ? '确认升级' : '取消'));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && confirm && platform.starts == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump(const Duration(milliseconds: 100));
        }
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.starts, confirm ? 1 : 0);
      await tester.pumpWidget(const SizedBox());
      await platform.controller.close();
    });
  }
  for (final status in [
    OtaCheckStatus.block,
    OtaCheckStatus.unknown,
    OtaCheckStatus.pass
  ]) {
    testWidgets('inspection ${status.name} gates start', (tester) async {
      FilePicker.platform = _Picker();
      final platform = OtaFakePlatform();
      final parser = _Parser(status);
      addTearDown(() async {
        await platform.controller.close();
      });
      await tester.pumpWidget(ProviderScope(
          overrides: [
            otaPlatformProvider.overrideWithValue(platform),
            otaBlePermissionProvider.overrideWithValue(() async => true),
            firmwareParserProvider.overrideWithValue(parser),
            otaDeviceProbeProvider.overrideWithValue(OtaFakeProbe(
                platform.calls,
                result: const DeviceProbeResult(
                    currentVersion: 2,
                    otaDeviceInfo: OtaDeviceInfoRecord(
                        icType: 9,
                        otaVersion: 1,
                        secureVersion: 0,
                        modeBits: 0,
                        maxBuffer: 2048,
                        tempBankSizeBytes: null,
                        imgIndicator: 0)))),
            otaDeviceCapabilitiesProvider
                .overrideWithValue(const DeviceCapabilities(confirmed: true)),
          ],
          child: MaterialApp(
              home: RealtekOtaPage(
                  device: ScanDevice(
                      deviceId: 'device', name: 'test', rssi: -40)))));
      await tester.pump(const Duration(milliseconds: 100));
      platform.controller.add({'sessionId': platform.sessionId, 'ready': true});
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('选择固件'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('开始升级'));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && platform.starts == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(OtaConfirmationSheet).evaluate().isNotEmpty) {
            break;
          }
        }
      });
      await tester.pump(const Duration(milliseconds: 100));
      if (status == OtaCheckStatus.pass) {
        await tester.pump(const Duration(seconds: 1));
        await tester.scrollUntilVisible(find.text('确认升级'), 150,
            scrollable: _sheetScrollable());
        await tester.tap(find.text('确认升级'));
        await tester.runAsync(() async {
          for (var i = 0; i < 100 && platform.starts == 0; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump(const Duration(milliseconds: 100));
          }
        });
      }
      expect(platform.calls.take(2).toList(), ['probe', 'prepare']);
      expect(parser.received?.currentVersion, 2);
      expect(parser.received?.icType, 9);
      expect(platform.starts, status == OtaCheckStatus.pass ? 1 : 0);
      if (status != OtaCheckStatus.pass) {
        expect(find.textContaining('检查未通过：${status.name}'), findsWidgets);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Finder _sheetScrollable() => find
    .descendant(
        of: find.byType(OtaConfirmationSheet),
        matching: find.byType(Scrollable))
    .first;
