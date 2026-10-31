import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/capture/capture_page.dart';
import 'package:honeybox/services/capture/capture_store.dart';
import 'package:honeybox/services/capture/capture_models.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import '../../helpers/capture_ble_platform.dart';

void main() {
  final platform = CaptureTestPlatform();
  setUpAll(() => FlutterBluePlusPlatform.instance = platform);
  tearDownAll(platform.close);
  testWidgets('device selection overview fits a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('capture_narrow')))!;
    final store = CaptureStore(dir);
    await tester.runAsync(() async {
      await store.saveProfiles([
        for (final id in ['A', 'B', 'C', 'D'])
          CaptureProfile(id: 'AA:BB:CC:DD:EE:0$id', name: '设备$id', channels: [
            const CaptureChannel(service: 'e0ff', characteristic: 'ffe1')
          ])
      ]);
      await tester.pumpWidget(MaterialApp(home: CapturePage(store: store)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('capture-select-AA:BB:CC:DD:EE:0B')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  testWidgets('batch start records only the three selected devices out of four',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('capture_selected')))!;
    final store = CaptureStore(dir);
    await tester.runAsync(() async {
      await store.saveProfiles([
        for (final id in ['A', 'B', 'C', 'D'])
          CaptureProfile(id: id, name: '设备$id', channels: [
            const CaptureChannel(service: 'e0ff', characteristic: 'ffe1')
          ])
      ]);
      await tester.pumpWidget(MaterialApp(home: CapturePage(store: store)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capture-select-A')));
    await tester.pump();
    expect(find.text('开始选中（3）'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('capture-start-selected')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    final files = (await tester.runAsync(store.listRecordings))!;
    expect(files, hasLength(3));
    final ids = await tester.runAsync(() async => [
          for (final file in files)
            (jsonDecode(await File('${file.parent.path}/device.json')
                .readAsString()) as Map)['id']
        ]);
    expect(ids, unorderedEquals(['B', 'C', 'D']));
    await tester.runAsync(() async {
      await tester.tap(find.text('全部停止'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.tap(find.byKey(const Key('capture-toggle-selection')));
    await tester.pump(); // partial selection -> all selected
    await tester.tap(find.byKey(const Key('capture-toggle-selection')));
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('capture-start-selected')))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  testWidgets('restores device names and channel choices after reopening page',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('capture_ui')))!;
    final store = CaptureStore(dir);
    await tester.runAsync(() => store.saveProfiles([
          CaptureProfile(id: 'A', name: '我的手表', channels: [
            const CaptureChannel(service: 'e0ff', characteristic: 'ffe1'),
          ]),
          CaptureProfile(id: 'B', name: '新传感器', channels: [
            const CaptureChannel(service: '180d', characteristic: '2a37'),
          ]),
        ]));
    await tester.runAsync(() => store.saveReconnectNotifications({'B'}));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: CapturePage(store: store)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    // Pinned overview row plus the device card.
    expect(find.text('我的手表'), findsNWidgets(2));
    expect(find.text('新传感器'), findsWidgets);
    final overview = find.byKey(const Key('capture-overview'));
    expect(find.descendant(of: overview, matching: find.text('2 台 · 采集中 0')),
        findsOneWidget);
    expect(find.descendant(of: overview, matching: find.text('未采集')),
        findsNWidgets(2));
    expect(find.textContaining('e0ff / ffe1'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('capture-reconnect-notify-A')))
            .value,
        false);
    expect(find.text('开始选中（2）'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('180d / 2a37'), 200,
        scrollable: find
            .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable))
            .first);
    expect(find.textContaining('180d / 2a37'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('capture-reconnect-notify-B')))
            .value,
        true);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });

  testWidgets('leaving while recording asks before stopping', (tester) async {
    CaptureLeaveChoice? choice;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async => choice = await confirmLeaveCapture(
                    context,
                    recording: 2,
                    canBackground: true),
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('还有 2 台设备在采集'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture-leave-background')));
    await tester.pumpAndSettle();
    expect(choice, CaptureLeaveChoice.background);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(choice, CaptureLeaveChoice.stay);
  });

  testWidgets('interrupted files offer resume or new file', (tester) async {
    final file = File('${Directory.systemTemp.path}/missing_raw.jsonl');
    bool? choice = false;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async => choice =
                    await confirmResumeCapture(context, {'S100': file}),
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('· S100（0 KB）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture-start-resume')));
    await tester.pumpAndSettle();
    expect(choice, isTrue);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(choice, isNull);
  });
}
