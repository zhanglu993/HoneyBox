import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/ota/ota_failure_card.dart';
import 'package:honeybox/services/ota/ota_failure.dart';

void main() {
  testWidgets(
      'retry limit, copy callback and accessible code fit narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var copied = false;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
                body: SingleChildScrollView(
                    child: OtaFailureCard(
                        failure: OtaFailure.classify(rawType: 3, rawCode: 517),
                        retryCount: 2,
                        onRetry: () {},
                        onCopy: () async {
                          copied = true;
                        }))))));
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '重试'))
            .onPressed,
        isNull);
    await tester.tap(find.text('复制诊断日志'));
    expect(copied, isTrue);
    expect(find.bySemanticsLabel(RegExp('517')), findsWidgets);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
