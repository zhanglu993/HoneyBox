import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/launcher/app_launcher_page.dart';
import 'package:honeybox/pages/launcher/app_catalog.dart';
import 'package:honeybox/pages/launcher/widgets/app_card.dart';

void main() {
  Widget wrap(Widget child) => ProviderScope(
        child: MaterialApp(home: child),
      );

  testWidgets('renders one AppCard per kAppCatalog entry', (tester) async {
    await tester.pumpWidget(wrap(const AppLauncherPage()));
    expect(find.byType(AppCard), findsNWidgets(kAppCatalog.length));
  });

  testWidgets('每个应用的 title 都出现在页面上', (tester) async {
    await tester.pumpWidget(wrap(const AppLauncherPage()));
    for (final e in kAppCatalog) {
      expect(find.text(e.title), findsOneWidget,
          reason: '${e.title} not rendered');
    }
  });

  testWidgets('入口应用不显示"预览"角标', (tester) async {
    await tester.pumpWidget(wrap(const AppLauncherPage()));
    expect(find.text('预览'), findsNothing);
  });

  testWidgets('AppBar 标题为"选择应用"', (tester) async {
    await tester.pumpWidget(wrap(const AppLauncherPage()));
    expect(find.widgetWithText(AppBar, '选择应用'), findsOneWidget);
  });

  testWidgets('OTA 入口在数据采集下方，打开后选择芯片', (tester) async {
    await tester.pumpWidget(wrap(const AppLauncherPage()));
    final capture = find.text('数据采集');
    final ota = find.text('OTA');
    await tester.ensureVisible(ota);
    expect(
        tester.getTopLeft(ota).dy, greaterThan(tester.getTopLeft(capture).dy));
    await tester.tap(ota);
    await tester.pumpAndSettle();
    expect(find.text('选择芯片类型'), findsOneWidget);
    expect(find.text('RTL8762D'), findsOneWidget);
  });

  testWidgets('主页面菜单只显示全局功能', (tester) async {
    await tester.pumpWidget(wrap(const AppLauncherPage()));

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    expect(find.text('芯片配置'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('设置'), findsNothing);
    expect(find.text('缓存管理'), findsNothing);
  });
}
