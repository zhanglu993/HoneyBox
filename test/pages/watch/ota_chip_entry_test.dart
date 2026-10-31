import '../../helpers/memory_ota_repository.dart';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/watch/pages/watch_ota_page.dart';
import 'package:honeybox/pages/ota/realtek_ota_page.dart';
import 'package:honeybox/providers/ble_provider.dart';

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
      bool readSequential = false}) async {
    final data = Uint8List(1024);
    final header = ByteData.sublistView(data);
    data[0] = 9;
    header.setUint16(4, 0x2793, Endian.little);
    header.setUint32(40, 0x82c000, Endian.little);
    return FilePickerResult([
      PlatformFile(
          name: 'firmware.bin',
          path: '/tmp/firmware.bin',
          size: data.length,
          bytes: data)
    ]);
  }
}

void main() {
  testWidgets('通用 OTA 接受固件文件，不预设 400 KiB 布局', (tester) async {
    FilePicker.platform = _Picker();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          otaRepositoryProvider
              .overrideWith((ref) async => MemoryOtaRepository()),
        ],
        child: MaterialApp(
            home: RealtekOtaPage(
      device: ScanDevice(deviceId: 'AA:BB:CC', name: 'V101', rssi: -50),
    ))));
    await tester.pump();
    await tester.tap(find.text('选择固件'));
    await tester.pumpAndSettle();
    expect(find.text('firmware.bin'), findsOneWidget);
  });
  testWidgets('选择有效固件后，V101 设备不因名称被禁止开始升级', (tester) async {
    FilePicker.platform = _Picker();
    await tester.pumpWidget(ProviderScope(overrides: [
        otaRepositoryProvider.overrideWith((ref) async => MemoryOtaRepository()),
      connectedDeviceProvider.overrideWith((ref) =>
          ConnectedDeviceInfo(deviceId: 'test', name: 'V101', mtu: 23)),
    ], child: const MaterialApp(home: WatchOtaPage())));
    await tester.tap(find.text('选择 BIN 固件'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始升级'))
            .onPressed,
        isNotNull);
  });
}
