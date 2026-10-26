import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/capture/capture_page.dart';
import 'package:honeybox/services/capture/capture_store.dart';
import 'package:honeybox/services/capture/capture_models.dart';

void main() {
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
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: CapturePage(store: store)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    // Pinned overview row plus the device card.
    expect(find.text('我的手表'), findsNWidgets(2));
    expect(find.text('新传感器'), findsNWidgets(2));
    final overview = find.byKey(const Key('capture-overview'));
    expect(find.descendant(of: overview, matching: find.text('2 台 · 采集中 0')),
        findsOneWidget);
    expect(find.descendant(of: overview, matching: find.text('未采集')),
        findsNWidgets(2));
    expect(find.textContaining('e0ff / ffe1'), findsOneWidget);
    expect(find.textContaining('180d / 2a37'), findsOneWidget);
    expect(find.text('全部开始'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
