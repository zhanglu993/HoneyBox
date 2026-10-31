import '../../helpers/memory_ota_repository.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/ota/realtek_ota_page.dart';
import 'package:honeybox/providers/ble_provider.dart';
import '../../helpers/ota_fake_platform.dart';
import 'package:honeybox/services/ota/device_probe.dart';
import 'package:honeybox/services/ota/ota_ownership.dart';
import 'package:honeybox/services/ota/ota_repository.dart';
import 'package:honeybox/services/ota/ota_session.dart';
import 'package:honeybox/pages/ota/ota_failure_card.dart';

void main() {
  testWidgets('failed upgrade retains error details and offers reconnect',
      (tester) async {
    final platform = OtaFakePlatform();
    await tester.pumpWidget(ProviderScope(
        overrides: [
        otaRepositoryProvider.overrideWith((ref) async => MemoryOtaRepository()),
          otaPlatformProvider.overrideWithValue(platform),
          otaBlePermissionProvider.overrideWithValue(() async => true)
        ],
        child: MaterialApp(
            home: RealtekOtaPage(
                device:
                    ScanDevice(deviceId: 'opaque', name: 'test', rssi: -40)))));
    await tester.pump();
    platform.controller.add({
      'sessionId': platform.sessionId,
      'done': true,
      'outcome': 'failed',
      'message': '升级失败',
      'errorType': 3,
      'errorCode': 517
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('517'), findsOneWidget);
    expect(find.byType(OtaFailureCard), findsOneWidget);
    await tester.tap(find.text('重新连接'));
    await tester.pumpAndSettle();
    expect(platform.prepares, 2);
    await tester.pumpWidget(const SizedBox());
    await platform.controller.close();
  });
  testWidgets('prepare failure suggests charging only with supporting evidence',
      (tester) async {
    final platform = OtaFakePlatform()..prepareError = StateError('connection');
    await tester.pumpWidget(ProviderScope(
        overrides: [
        otaRepositoryProvider.overrideWith((ref) async => MemoryOtaRepository()),
          otaPlatformProvider.overrideWithValue(platform),
          otaBlePermissionProvider.overrideWithValue(() async => true),
          otaDeviceProbeProvider.overrideWithValue(OtaFakeProbe(platform.calls,
              result: const DeviceProbeResult(
                  batteryPercent: 20, charging: false))),
        ],
        child: MaterialApp(
            home: RealtekOtaPage(
                device:
                    ScanDevice(deviceId: 'opaque', name: 'test', rssi: -40)))));
    await tester.pumpAndSettle();
    expect(find.textContaining('设备可能因电量低于 30% 且未充电而拒绝进入升级模式'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await platform.controller.close();
  });
  for (final probe in [
    const DeviceProbeResult(batteryPercent: 20),
    const DeviceProbeResult(batteryPercent: 80, charging: false),
    const DeviceProbeResult(batteryPercent: 20, charging: true),
  ]) {
    testWidgets('prepare failure does not guess cause without evidence: $probe',
        (tester) async {
      final platform = OtaFakePlatform()
        ..prepareError = StateError('connection');
      await tester.pumpWidget(ProviderScope(
          overrides: [
        otaRepositoryProvider.overrideWith((ref) async => MemoryOtaRepository()),
            otaPlatformProvider.overrideWithValue(platform),
            otaBlePermissionProvider.overrideWithValue(() async => true),
            otaDeviceProbeProvider
                .overrideWithValue(OtaFakeProbe(platform.calls, result: probe)),
          ],
          child: MaterialApp(
              home: RealtekOtaPage(
                  device: ScanDevice(
                      deviceId: 'opaque', name: 'test', rssi: -40)))));
      await tester.pumpAndSettle();
      expect(find.textContaining('设备可能因电量低于'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await platform.controller.close();
    });
  }
  testWidgets('stale events do not change the current session', (tester) async {
    final platform = OtaFakePlatform();
    await tester.pumpWidget(ProviderScope(
        overrides: [
        otaRepositoryProvider.overrideWith((ref) async => MemoryOtaRepository()),
          otaPlatformProvider.overrideWithValue(platform),
          otaBlePermissionProvider.overrideWithValue(() async => true)
        ],
        child: MaterialApp(
            home: RealtekOtaPage(
                device:
                    ScanDevice(deviceId: 'opaque', name: 'test', rssi: -40)))));
    await tester.pump();
    platform.controller.add({
      'sessionId': 'stale',
      'done': true,
      'outcome': 'failed',
      'message': 'stale error'
    });
    await tester.pump();
    expect(find.text('stale error'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await platform.controller.close();
  });
  testWidgets('SDK completion is explicitly pending verification',
      (tester) async {
    final platform = OtaFakePlatform();
    await tester.pumpWidget(ProviderScope(
        overrides: [
        otaRepositoryProvider.overrideWith((ref) async => MemoryOtaRepository()),
          otaPlatformProvider.overrideWithValue(platform),
          otaBlePermissionProvider.overrideWithValue(() async => true)
        ],
        child: MaterialApp(
            home: RealtekOtaPage(
                device:
                    ScanDevice(deviceId: 'opaque', name: 'test', rssi: -40)))));
    await tester.pump();
    platform.controller.add({
      'sessionId': platform.sessionId,
      'done': true,
      'outcome': 'pendingVerification',
      'message': 'SDK报告完成',
      'progress': 100
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('结果待核验'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await platform.controller.close();
  });
  for (final capture in [true, false]) {
    testWidgets('existing BLE use blocks preparation: capture=$capture',
        (tester) async {
      final platform = OtaFakePlatform();
      final container = ProviderContainer(overrides: [
        otaRepositoryProvider.overrideWith((ref) async => MemoryOtaRepository()),
        otaPlatformProvider.overrideWithValue(platform),
        otaBlePermissionProvider.overrideWithValue(() async => true),
      ]);
      if (capture) {
        container.read(otaOwnershipProvider.notifier).acquire(OtaOwner.capture);
      } else {
        container.read(connectedDeviceProvider.notifier).state =
            ConnectedDeviceInfo(deviceId: 'other', name: 'watch', mtu: 23);
      }
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
              home: RealtekOtaPage(
                  device: ScanDevice(
                      deviceId: 'target', name: 'test', rssi: -40)))));
      await tester.pump();
      expect(platform.calls, isNot(contains('probe')));
      expect(platform.calls, isNot(contains('prepare')));
      expect(platform.calls, isNot(contains('start')));
      expect(
          find.textContaining(capture ? '采集正在占用' : '普通连接正在占用'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await platform.controller.close();
    });
  }
  testWidgets('recent saved record is shown on a new page', (tester) async {
    final directory = Directory.systemTemp.createTempSync('ota_page_history');
    addTearDown(() => directory.deleteSync(recursive: true));
    final repository = OtaRepository(directory);
    final now = DateTime.utc(2026, 10, 31);
    await tester.runAsync(() => repository.save(OtaSessionRecord(
        sessionId: 'old', startedAt: now,
        updatedAt: now, phase: OtaPhase.finished, outcome: OtaOutcome.failed,
        deviceIdMasked: 'device-1234', firmwareName: 'firmware.bin',
        firmwareSha256: '', phaseHistory: const [])));
    final platform = OtaFakePlatform()..isSupported = false;
    await tester.pumpWidget(ProviderScope(overrides: [
      otaPlatformProvider.overrideWithValue(platform),
      otaRepositoryProvider.overrideWith((ref) async => repository),
    ], child: MaterialApp(home: RealtekOtaPage(
        device: ScanDevice(deviceId: 'device-1234', name: 'test', rssi: -40)))));
    for (var i = 0; i < 20 && find.textContaining('上次升级记录').evaluate().isEmpty; i++) {
      await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 50)); });
      await tester.pump();
    }
    expect(find.textContaining('上次升级记录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await platform.controller.close();
  });

}
