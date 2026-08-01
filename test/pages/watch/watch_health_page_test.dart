import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/watch/health/watch_health_data.dart';
import 'package:honeybox/pages/watch/health/watch_health_provider.dart';
import 'package:honeybox/pages/watch/pages/watch_health_page.dart';
import 'package:honeybox/theme/app_theme.dart';

import '../../helpers/watch_health_fixture.dart';

class _ImmediateRepository implements WatchHealthRepository {
  @override
  Future<WatchHealthSnapshot> sync(String deviceId) async {
    return watchHealthFixture();
  }
}

Widget buildPage() {
  return ProviderScope(
    overrides: [
      watchHealthRepositoryProvider.overrideWithValue(_ImmediateRepository()),
    ],
    child: MaterialApp(
      theme: AppTheme.lightTheme,
      home: const WatchHealthPage(
        deviceName: 'HoneyBox Watch S1',
        deviceId: 'watch-test',
      ),
    ),
  );
}

void main() {
  testWidgets('starts with an explicit unsynchronized state', (tester) async {
    await tester.pumpWidget(buildPage());

    expect(find.text('HoneyBox Watch S1'), findsOneWidget);
    expect(find.text('尚未同步健康数据'), findsOneWidget);
    expect(find.text('同步手表后即可查看'), findsOneWidget);
    expect(find.text('1,000'), findsNothing);
  });

  testWidgets('synchronizes and renders the health dashboard', (tester) async {
    await tester.pumpWidget(buildPage());

    await tester.tap(find.byKey(const Key('watch-health-sync')));
    await tester.pumpAndSettle();

    expect(find.text('1,000'), findsOneWidget);
    expect(find.text('78'), findsOneWidget);
    expect(find.text('4:00'), findsOneWidget);
    expect(find.text('最近同步：12:00'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.textContaining('10:10:00'), findsOneWidget);
  });

  testWidgets('switches to the weekly trend without another sync',
      (tester) async {
    await tester.pumpWidget(buildPage());
    await tester.tap(find.byKey(const Key('watch-health-sync')));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pumpAndSettle();
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();

    expect(find.text('日均 143 步'), findsOneWidget);
  });

  testWidgets('fits a narrow Android-sized viewport', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildPage());
    await tester.tap(find.byKey(const Key('watch-health-sync')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
