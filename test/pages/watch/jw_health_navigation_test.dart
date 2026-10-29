import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/watch/watch_app_root.dart';
import 'package:honeybox/pages/watch/jw_history_page.dart';
import 'package:honeybox/pages/watch/jw_test_console.dart';
import 'package:honeybox/pages/watch/health/jw_health_page.dart';
import 'package:honeybox/pages/watch/health/jw_health_sport_page.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/providers/jw_device_provider.dart';
import 'package:honeybox/services/ble_manager.dart' as manager;
import 'package:honeybox/services/jw/history/jw_history_store.dart';
import 'package:honeybox/services/jw/history/jw_history_models.dart';
import 'package:honeybox/services/jw/health/jw_health_goals.dart';
import '../../services/jw/jw_health_aggregator_test.dart' show healthRow;
import 'package:honeybox/services/jw/jw_device_repository.dart';
import 'package:honeybox/services/jw/jw_identity_store.dart';
import 'package:honeybox/services/jw/jw_session.dart';
import '../../helpers/fake_jw_transport.dart';
import '../../helpers/jw_device_script.dart';
import 'jw_health_page_test.dart' show settleIo;

class _Manager implements manager.BleManager {
  @override
  Stream<manager.BleState> get onStateChanged => const Stream.empty();
  @override
  void dispose() {}
  @override
  void stopScan() {}
  @override
  Future<void> startScan(void Function(ScanResult) callback,
      {String? serviceUuid}) async {}
  @override
  Future<void> disconnect() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late FileJwHistoryStore store;
  Future<void> prepare(WidgetTester tester, Widget home,
      {bool connected = false}) async {
    JwDeviceRepository? repository;
    FakeJwTransport? transport;
    JwDeviceNotifier? notifier;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('jw-health-nav-');
      store = FileJwHistoryStore(Directory('${dir.path}/records'));
      await store.open();
      await store.append('20261005-001', [
        healthRow(JwHistoryType.exercise, {
          'mode': 1,
          'durationMinutes': 30,
          'durationSeconds': 5,
          'steps': 100,
          'distanceMeters': 500,
          'energyCalories': 2500
        })
      ]);
      if (connected) {
        transport = FakeJwTransport();
        installJwDeviceScript(transport!, functions: '0000000000000000');
        transport!.readValues['2a25'] = Uint8List.fromList(utf8.encode('test'));
        repository = JwDeviceRepository(
            session: JwSession(transport!),
            transport: transport!,
            platformDeviceKey: 'test',
            identityStore: JwIdentityStore(File('${dir.path}/identity.json')),
            historyStoreFactory: () async => store,
            ownsHistoryStore: false);
        notifier = JwDeviceNotifier(repository: repository);
        await notifier!.initialize();
      }
      await tester.pumpWidget(ProviderScope(overrides: [
        bleManagerProvider.overrideWith((ref) => _Manager()),
        connectedDeviceProvider.overrideWith((ref) => connected
            ? ConnectedDeviceInfo(
                deviceId: 'test', name: 'S200', mtu: 23, isJw: true)
            : null),
        jwRepositoryProvider.overrideWith((ref) async => repository),
        jwDeviceProvider.overrideWith(
            (ref) => notifier ?? JwDeviceNotifier(repository: null)),
        jwHistoryStoreProvider.overrideWith((ref) async => store),
        jwHealthGoalStoreProvider.overrideWith(
            (ref) async => JwHealthGoalStore(File('${dir.path}/goals.json'))),
      ], child: MaterialApp(home: home)));
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await repository?.dispose();
        await transport?.dispose();
        await store.close();
        await dir.delete(recursive: true);
      });
    });
    await settleIo(tester);
  }

  testWidgets('device overview and sport stay on stack after disconnect',
      (tester) async {
    await prepare(
        tester,
        Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(ctx).push(
                        MaterialPageRoute<void>(
                            settings: const RouteSettings(name: '/watch-root'),
                            builder: (_) => const WatchAppRoot())),
                    child: const Text('Launcher')))),
        connected: true);
    await tester.tap(find.text('Launcher'));
    await tester.pumpAndSettle();
    expect(find.text('SDK 调试'), findsOneWidget);
    for (var visit = 0; visit < 2; visit++) {
      await tester.tap(find.byKey(const Key('jw-test-console')));
      await tester.pumpAndSettle();
      expect(find.byType(JwSdkTestConsole), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('jw-health-entry')), findsOneWidget);
    }
    final scope =
        ProviderScope.containerOf(tester.element(find.byType(WatchAppRoot)));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-health-entry')));
      await tester.pump();
    });
    await settleIo(tester);
    expect(find.byType(JwHealthPage), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-sport-section')), 350);
    await tester.tap(find.text('运动记录 · 登山'));
    await tester.pumpAndSettle();
    expect(find.byType(JwHealthSportPage), findsOneWidget);
    expect(find.text('30分5秒'), findsOneWidget);
    expect(find.text('2.5 kcal'), findsOneWidget);
    scope.read(connectedDeviceProvider.notifier).state = null;
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(JwHealthSportPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(JwHealthPage), findsOneWidget);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
    });
    await tester.pumpAndSettle();
  });
  testWidgets(
      'saved device offers offline health overview alongside raw records',
      (tester) async {
    await prepare(tester, const JwSavedHistoryDevicesPage());
    expect(find.byKey(const Key('jw-saved-health-jw:test')), findsOneWidget);
    expect(find.byKey(const Key('jw-saved-raw-jw:test')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-saved-health-jw:test')));
      await tester.pump();
    });
    await settleIo(tester);
    expect(find.byType(JwHealthPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-saved-raw-jw:test')));
      await tester.pump();
    });
    await settleIo(tester);
    expect(find.byType(JwHistoryRecordsPage), findsOneWidget);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
    });
    await tester.pumpAndSettle();
  });
}
