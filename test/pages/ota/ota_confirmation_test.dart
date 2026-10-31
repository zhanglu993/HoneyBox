import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/ota/ota_confirmation.dart';
import 'package:honeybox/services/ota/ota_preflight.dart';

void main() {
  for (final status in OtaCheckStatus.values) {
    testWidgets('confirmation $status fits large text and gates action',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      bool? result;
      final data = OtaConfirmationData(
          deviceName: '设备',
          deviceId: 'id',
          fileName: 'firmware.bin',
          fileSize: 123,
          sha256: 'abcdef0123456789',
          checks: [OtaCheck('format', status, '检查结果')]);
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: const MediaQueryData(
                  size: Size(360, 640), textScaler: TextScaler.linear(2)),
              child: Builder(
                  builder: (context) => TextButton(
                      onPressed: () async {
                        result = await showOtaConfirmation(context, data);
                      },
                      child: const Text('open'))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (status == OtaCheckStatus.block || status == OtaCheckStatus.unknown) {
        expect(find.text('确认升级'), findsNothing);
        await tester.scrollUntilVisible(find.text('取消'), 150, scrollable: _sheetScrollable());
        await tester.tap(find.text('取消'));
      } else {
        await tester.scrollUntilVisible(find.text('确认升级'), 150, scrollable: _sheetScrollable());
        if (status == OtaCheckStatus.warn) {
          expect(
              tester
                  .widget<FilledButton>(
                      find.widgetWithText(FilledButton, '确认升级'))
                  .onPressed,
              isNull);
          await tester.tap(find.text('我已了解风险'));
          await tester.pump();
        }
        await tester.tap(find.text('确认升级'));
      }
      await tester.pumpAndSettle();
      expect(result,
          status == OtaCheckStatus.pass || status == OtaCheckStatus.warn);
      expect(tester.takeException(), isNull);
    });
  }
}

Finder _sheetScrollable() => find
    .descendant(
        of: find.byType(OtaConfirmationSheet),
        matching: find.byType(Scrollable))
    .first;
