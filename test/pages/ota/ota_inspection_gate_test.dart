import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/ota/realtek_ota_page.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/services/ota/firmware_inspection.dart';
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
      FilePickerResult([PlatformFile(name: 'pubspec.yaml', path: 'pubspec.yaml', size: 1)]);
}

class _Parser implements FirmwareParser {
  _Parser(this.status);
  final OtaCheckStatus status;
  @override
  Future<FirmwareParseResult> parse(String path, DeviceCapabilities capabilities) async =>
      FirmwareParseResult(type: 'test', images: ['image'], checks: [
        OtaCheck('format', status, '检查未通过：${status.name}'),
        const OtaCheck('compatibility', OtaCheckStatus.pass, 'ok'),
      ]);
}

void main() {
  for (final status in [OtaCheckStatus.block, OtaCheckStatus.unknown, OtaCheckStatus.pass]) {
    testWidgets('inspection ${status.name} gates start', (tester) async {
      FilePicker.platform = _Picker();
      final platform = OtaFakePlatform();
      addTearDown(() async {
        await platform.controller.close();
      });
      await tester.pumpWidget(ProviderScope(overrides: [
        otaPlatformProvider.overrideWithValue(platform),
        firmwareParserProvider.overrideWithValue(_Parser(status)),
        otaDeviceCapabilitiesProvider.overrideWithValue(const DeviceCapabilities(confirmed: true)),
      ], child: MaterialApp(home: RealtekOtaPage(
          device: ScanDevice(deviceId: 'device', name: 'test', rssi: -40)))));
      await tester.pump();
      platform.controller.add({'sessionId': platform.sessionId, 'ready': true});
      await tester.pump();
      await tester.tap(find.text('选择固件'));
      await tester.pump();
      await tester.tap(find.text('开始升级'));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && platform.starts == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
          if (find.textContaining('检查未通过').evaluate().isNotEmpty) break;
        }
      });
      await tester.pump();
      expect(platform.starts, status == OtaCheckStatus.pass ? 1 : 0);
      if (status != OtaCheckStatus.pass) {
        expect(find.textContaining('检查未通过：${status.name}'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
