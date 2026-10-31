import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/ota/realtek_ota_page.dart';
import 'package:honeybox/providers/ble_provider.dart';
import '../../helpers/ota_fake_platform.dart';
import 'package:honeybox/services/ota/device_probe.dart';

void main() {
  testWidgets('failed upgrade retains error details and offers reconnect',
      (tester) async {
    final platform = OtaFakePlatform();
    await tester.pumpWidget(ProviderScope(
        overrides: [otaPlatformProvider.overrideWithValue(platform)],
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
    await tester.tap(find.text('重新连接'));
    await tester.pumpAndSettle();
    expect(platform.prepares, 2);
    await tester.pumpWidget(const SizedBox());
    await platform.controller.close();
  });
  testWidgets('prepare failure suggests charging only with supporting evidence', (tester) async {
    final platform = OtaFakePlatform()..prepareError = StateError('connection');
    await tester.pumpWidget(ProviderScope(overrides: [
      otaPlatformProvider.overrideWithValue(platform),
      otaDeviceProbeProvider.overrideWithValue(OtaFakeProbe(platform.calls, result: const DeviceProbeResult(batteryPercent: 20, charging: false))),
    ], child: MaterialApp(home: RealtekOtaPage(device: ScanDevice(deviceId: 'opaque', name: 'test', rssi: -40)))));
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
    testWidgets('prepare failure does not guess cause without evidence: $probe', (tester) async {
      final platform = OtaFakePlatform()..prepareError = StateError('connection');
      await tester.pumpWidget(ProviderScope(overrides: [
        otaPlatformProvider.overrideWithValue(platform),
        otaDeviceProbeProvider.overrideWithValue(OtaFakeProbe(platform.calls, result: probe)),
      ], child: MaterialApp(home: RealtekOtaPage(device: ScanDevice(deviceId: 'opaque', name: 'test', rssi: -40)))));
      await tester.pumpAndSettle();
      expect(find.textContaining('设备可能因电量低于'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await platform.controller.close();
    });
  }
  testWidgets('stale events do not change the current session', (tester) async {
    final platform = OtaFakePlatform();
    await tester.pumpWidget(ProviderScope(
        overrides: [otaPlatformProvider.overrideWithValue(platform)],
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
        overrides: [otaPlatformProvider.overrideWithValue(platform)],
        child: MaterialApp(
            home: RealtekOtaPage(
                device:
                    ScanDevice(deviceId: 'opaque', name: 'test', rssi: -40)))));
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
}
