import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/shared/update_flow.dart';

void main() {
  testWidgets('macOS does not offer an Android APK update', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
      builder: (context) => TextButton(
        onPressed: () => runUpdateCheck(context),
        child: const Text('检查更新'),
      ),
    ))));
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('macOS 版本请通过原安装渠道更新'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
