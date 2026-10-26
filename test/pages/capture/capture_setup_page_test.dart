import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/capture/capture_setup_page.dart';
import 'package:honeybox/theme/app_theme.dart';
import 'dart:io';
import 'package:honeybox/services/capture/capture_store.dart';
import 'package:honeybox/services/capture/capture_scan_settings.dart';
import 'package:honeybox/services/capture/capture_models.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import '../../helpers/capture_ble_platform.dart';

void main() {
  for (final width in [320.0, 500.0]) {
    testWidgets(
        'scan and signal controls render with production theme at width $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = (await tester
          .runAsync(() => Directory.systemTemp.createTemp('scan_ui')))!;
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme,
          home:
              CaptureSetupPage(existingIds: const {}, store: CaptureStore(dir)),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      final scan = find.widgetWithText(FilledButton, '扫描设备');
      expect(scan, findsOneWidget);
      final button = tester.getRect(scan);
      expect(button.width.isFinite && button.height > 0, isTrue);
      expect(button.right, lessThanOrEqualTo(width));
      expect(find.byKey(const Key('capture-rssi-sort')), findsOneWidget);
      expect(find.byKey(const Key('capture-rssi-minimum')), findsOneWidget);
      final unnamed = find.byKey(const Key('capture-hide-unnamed'));
      expect(tester.widget<CheckboxListTile>(unnamed).value, isFalse);
      await tester.tap(unnamed);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(unnamed).value, isTrue);
      expect(find.widgetWithText(TextField, '按设备名称或地址筛选'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await dir.delete(recursive: true);
      });
    });
  }
  testWidgets(
      'restores all saved scan conditions and autosaves checkbox change',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('scan_restore')))!;
    final store = CaptureStore(dir);
    await tester.runAsync(() => store.saveScanSettings(
        const CaptureScanSettings(
            strongestFirst: false, minimumRssi: -60, hideUnnamed: true)));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme,
          home: CaptureSetupPage(existingIds: const {}, store: store)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<DropdownButtonFormField<bool>>(
                find.byKey(const Key('capture-rssi-sort')))
            .initialValue,
        isFalse);
    expect(
        tester
            .widget<DropdownButtonFormField<int>>(
                find.byKey(const Key('capture-rssi-minimum')))
            .initialValue,
        -60);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('capture-hide-unnamed')))
            .value,
        isTrue);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('capture-hide-unnamed')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('capture-rssi-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('信号强 → 弱').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-rssi-minimum')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('≥ -70 dBm').last);
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    final restored =
        await tester.runAsync(() => CaptureStore(dir).loadScanSettings());
    expect(restored!.hideUnnamed, isFalse);
    expect(restored.minimumRssi, -70);
    expect(restored.strongestFirst, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  testWidgets('connected services stay collapsed until explicitly opened',
      (tester) async {
    final platform = CaptureTestPlatform();
    FlutterBluePlusPlatform.instance = platform;
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('service_collapse')))!;
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.lightTheme,
          home: CaptureSetupPage(
              existingIds: const {},
              store: CaptureStore(dir),
              profile: CaptureProfile(
                  id: 'collapse-device',
                  name: 'Watch',
                  channels: [
                    const CaptureChannel(
                        service: 'e0ff', characteristic: 'ff03', instance: 1),
                  ]))));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    final first = find.byType(ExpansionTile).first;
    final save = find.byKey(const Key('capture-save-bottom'));
    expect(save.hitTestable(), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(find.text('ff03').hitTestable(), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.ensureVisible(first);
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(find.text('ff03').hitTestable(), findsOneWidget);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await platform.close();
      await dir.delete(recursive: true);
    });
  });
}
