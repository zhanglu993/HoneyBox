import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/ota/realtek_ota_page.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/services/ota/device_probe.dart';
import 'package:honeybox/services/ota/ota_postcheck.dart';
import 'package:honeybox/services/ota/ota_repository.dart';
import 'package:honeybox/services/ota/ota_session.dart';
import '../../helpers/ota_fake_platform.dart';
import 'ota_postcheck_page_test.dart' show info;

void main() {
  for (final version in <int?>[2, null]) {
    testWidgets('interrupted session recheck: $version', (tester) async {
      final dir = (await tester.runAsync(
          () async => Directory.systemTemp.createTempSync('ota_recovery')))!;
      final repo = OtaRepository(dir);
      final now = DateTime.now();
      await tester.runAsync(() => repo.saveActive(OtaSessionRecord(
          sessionId: 'interrupted',
          startedAt: now,
          updatedAt: now,
          phase: null,
          outcome: null,
          deviceIdMasked: 'device',
          firmwareName: 'fw.bin',
          firmwareSha256: '',
          phaseHistory: const [],
          targetVersion: 2,
          expectedIcType: 9)));
      final platform = OtaFakePlatform();
      addTearDown(() async {
        await platform.controller.close();
        dir.deleteSync(recursive: true);
      });
      await tester.pumpWidget(ProviderScope(
          overrides: [
            otaPlatformProvider.overrideWithValue(platform),
            otaRepositoryProvider.overrideWith((ref) async => repo),
            otaPostcheckerProvider.overrideWithValue(OtaPostchecker(
                OtaFakeProbe([],
                    result: DeviceProbeResult(
                        currentVersion: version, otaDeviceInfo: info)),
                attempts: 1)),
          ],
          child: MaterialApp(
              home: RealtekOtaPage(
                  device: ScanDevice(
                      deviceId: 'device', name: 'test', rssi: -40)))));
      for (var i = 0;
          i < 100 && find.textContaining('上次升级被中断').evaluate().isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('上次升级被中断'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '开始升级'))
              .onPressed,
          isNull);
      expect(platform.starts, 0);
      await tester.ensureVisible(find.text('重新检查设备'));
      await tester.tap(find.text('重新检查设备'));
      await tester.pump();
      for (var i = 0;
          i < 100 &&
              find
                  .textContaining(version == null ? '结果待核验' : '已核验：')
                  .evaluate()
                  .isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining(version == null ? '结果待核验' : '已核验：'),
          findsWidgets);
      expect(
          find.text('重新检查设备'), version == null ? findsOneWidget : findsNothing);
      expect(platform.starts, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('lifecycle and size changes retain the prepared session',
      (tester) async {
    final dir = (await tester.runAsync(
        () async => Directory.systemTemp.createTempSync('ota_lifecycle')))!;
    final platform = OtaFakePlatform();
    addTearDown(() async {
      await platform.controller.close();
      dir.deleteSync(recursive: true);
    });
    await tester.pumpWidget(ProviderScope(
        overrides: [
          otaPlatformProvider.overrideWithValue(platform),
          otaRepositoryProvider.overrideWith((ref) async => OtaRepository(dir)),
          otaBlePermissionProvider.overrideWithValue(() async => true),
          otaDeviceProbeProvider.overrideWithValue(OtaFakeProbe([])),
        ],
        child: MaterialApp(
            home: RealtekOtaPage(
                device:
                    ScanDevice(deviceId: 'device', name: 'test', rssi: -40)))));
    for (var i = 0; i < 100 && platform.prepares == 0; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final id = platform.sessionId;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(600, 900);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
    expect(platform.sessionId, id);
    expect(platform.prepares, 1);
    expect(platform.starts, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
