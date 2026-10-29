import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/watch/watch_app_root.dart';
import 'package:honeybox/pages/scan/widgets/device_tile.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/providers/jw_device_provider.dart';
import 'package:honeybox/services/ble_manager.dart' as manager;
import 'package:honeybox/services/jw/jw_models.dart';
import 'package:honeybox/pages/watch/jw_history_page.dart';
import 'package:honeybox/services/jw/history/jw_history_store.dart';
import 'dart:io';

class _Manager implements manager.BleManager {
  final scanFilters = <String?>[];
  void Function(ScanResult)? scanCallback;
  @override
  Stream<manager.BleState> get onStateChanged => const Stream.empty();
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  void stopScan() {}
  @override
  Future<void> startScan(void Function(ScanResult) callback,
      {String? serviceUuid}) async {
    scanFilters.add(serviceUuid);
    scanCallback = callback;
  }

  @override
  Future<void> disconnect() async {}
}

void main() {
  testWidgets(
      'Watch broad scan retains renamed legacy and JW advertisement forms',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final manager = _Manager();
    await tester.pumpWidget(ProviderScope(overrides: [
      bleManagerProvider.overrideWithValue(manager),
    ], child: const MaterialApp(home: WatchAppRoot())));
    await tester.pump(const Duration(milliseconds: 100));
    expect(manager.scanFilters, [null]);

    void advertise(String id, String name, List<String> services,
        Map<int, List<int>> manufacturerData) {
      manager.scanCallback!(ScanResult(
          device: BluetoothDevice.fromId(id),
          advertisementData: AdvertisementData(
              advName: name,
              txPowerLevel: null,
              appearance: null,
              connectable: true,
              manufacturerData: manufacturerData,
              serviceData: {},
              serviceUuids: services.map(Guid.new).toList()),
          rssi: -40,
          timeStamp: DateTime.utc(2026, 10, 8)));
    }

    advertise('legacy', 'Renamed legacy',
        ['000001ff-3c17-d293-8e48-14fe2e4da212'], {});
    advertise('fd50', 'FD50 only', ['FD50'], {});
    advertise('manufacturer', 'Manufacturer only', [], {
      0x07d0: [1, 2, 3, 4, 5, 6]
    });
    advertise('unrelated', 'Unrelated', ['180F'], {});
    await tester.pump();
    expect(
        tester
            .widgetList<DeviceTile>(find.byType(DeviceTile))
            .map((tile) => tile.deviceId),
        ['legacy', 'fd50', 'manufacturer']);

    final refresh =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    final refreshed = refresh.onRefresh();
    await tester.pump(const Duration(seconds: 1));
    await refreshed;
    expect(manager.scanFilters, [null, null]);
    expect(find.text('已保存历史'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Watch cold start exposes saved history without connecting',
      (tester) async {
    await tester.pumpWidget(ProviderScope(overrides: [
      bleManagerProvider.overrideWith((ref) => _Manager()),
      connectedDeviceProvider.overrideWith((ref) => null),
    ], child: const MaterialApp(home: WatchAppRoot())));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已保存历史'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'saved history route survives actual connected-provider disconnect',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late FileJwHistoryStore store;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jw-root-ui-');
      store = FileJwHistoryStore(root);
      await store.open();
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await store.close();
        await root.delete(recursive: true);
      });
    });
    await tester.pumpWidget(ProviderScope(
        overrides: [
          bleManagerProvider.overrideWith((ref) => _Manager()),
          connectedDeviceProvider.overrideWith((ref) => ConnectedDeviceInfo(
              deviceId: 'test', name: 'S200', mtu: 23, isJw: true)),
          jwHistoryStoreProvider.overrideWith((ref) async => store),
          jwDeviceProvider.overrideWith((ref) => JwDeviceNotifier(
              repository: null,
              initialState:
                  const JwDeviceState(phase: JwDevicePhase.loggedIn))),
        ],
        child: MaterialApp(
            home: Builder(
                builder: (ctx) => Scaffold(
                    body: TextButton(
                        onPressed: () => Navigator.of(ctx).push(
                            MaterialPageRoute<void>(
                                settings:
                                    const RouteSettings(name: '/watch-root'),
                                builder: (_) => const WatchAppRoot())),
                        child: const Text('Launcher')))))));
    await tester.tap(find.text('Launcher'));
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(WatchAppRoot)));
    await tester.runAsync(() async {
      await tester.ensureVisible(find.text('查看已保存记录'));
      await tester.tap(find.text('查看已保存记录'));
      await tester.pump(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.byType(JwHistoryRecordsPage), findsOneWidget);
    container.read(connectedDeviceProvider.notifier).state = null;
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(JwHistoryRecordsPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets('leaving Watch cannot pop Launcher on a fast disconnect callback',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
        overrides: [
          bleManagerProvider.overrideWith((ref) => _Manager()),
          connectedDeviceProvider.overrideWith((ref) => ConnectedDeviceInfo(
              deviceId: 'test', name: 'S200', mtu: 23, isJw: true)),
          jwDeviceProvider.overrideWith((ref) => JwDeviceNotifier(
              repository: null,
              initialState:
                  const JwDeviceState(phase: JwDevicePhase.loggedIn))),
        ],
        child: MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                settings:
                                    const RouteSettings(name: '/watch-root'),
                                builder: (_) => const WatchAppRoot())),
                        child: const Text('Launcher')))))));
    await tester.tap(find.text('Launcher'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Launcher'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
