import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/ota/realtek_ota_page.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/services/ota/ota_platform.dart';

class FakeOta implements OtaPlatform {
  final controller =
      StreamController<Map<String, Object?>>.broadcast(sync: true);
  int prepares = 0;
  @override
  bool get supported => true;
  @override
  Stream<Map<String, Object?>> get events => controller.stream;
  @override
  Future<void> prepare(String deviceId) async {
    prepares++;
  }

  @override
  Future<void> start(String path) async {}
  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('failed upgrade retains error details and offers reconnect',
      (tester) async {
    final platform = FakeOta();
    await tester.pumpWidget(ProviderScope(
        overrides: [otaPlatformProvider.overrideWithValue(platform)],
        child: MaterialApp(
            home: RealtekOtaPage(
                device:
                    ScanDevice(deviceId: 'opaque', name: 'test', rssi: -40)))));
    await tester.pump();
    platform.controller.add({
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
  testWidgets('SDK completion is explicitly pending verification',
      (tester) async {
    final platform = FakeOta();
    await tester.pumpWidget(ProviderScope(
        overrides: [otaPlatformProvider.overrideWithValue(platform)],
        child: MaterialApp(
            home: RealtekOtaPage(
                device:
                    ScanDevice(deviceId: 'opaque', name: 'test', rssi: -40)))));
    platform.controller.add({
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
