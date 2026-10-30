import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/watch/health/jw_health_page.dart';
import 'package:honeybox/pages/watch/health/jw_health_charts.dart';
import 'package:honeybox/pages/watch/jw_history_page.dart';
import 'package:honeybox/pages/watch/health/jw_health_sport_page.dart';
import 'package:honeybox/providers/jw_device_provider.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/services/jw/health/jw_health_goals.dart';
import 'package:honeybox/services/jw/history/jw_history_models.dart';
import 'package:honeybox/services/jw/history/jw_history_store.dart';
import '../../services/jw/jw_health_aggregator_test.dart' show healthRow;
import 'package:honeybox/services/jw/jw_device_repository.dart';
import 'package:honeybox/services/jw/jw_codec.dart';
import 'package:honeybox/services/jw/jw_identity_store.dart';
import 'package:honeybox/services/jw/jw_session.dart';
import '../../helpers/fake_jw_transport.dart';
import '../../helpers/jw_device_script.dart';

Future<void> settleIo(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 500; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
    }
  });
  await tester.pumpAndSettle();
}

// The headline is lazy list content; inspect it before restoring controls.
Future<void> expectSteps(WidgetTester tester, String text,
    {bool absent = false}) async {
  final scrollable =
      tester.state<ScrollableState>(find.byType(Scrollable).first);
  final previousOffset = scrollable.position.pixels;
  await tester.scrollUntilVisible(
      find.byKey(const Key('jw-health-activity-card')), 250);
  expect(find.text(text), absent ? findsNothing : findsWidgets);
  scrollable.position.jumpTo(previousOffset);
  await tester.pumpAndSettle();
}

void main() {
  late Directory dir;
  late FileJwHistoryStore store;
  late JwHealthGoalStore goals;
  Future<void> setup(WidgetTester tester,
      {List<JwHistoryRecord> rows = const [],
      double scale = 1,
      StateProvider<String>? selection,
      JwHistoryStore Function(FileJwHistoryStore)? wrapStore,
      FileJwHistoryStore Function(Directory)? createStore,
      Future<JwDeviceNotifier> Function(FileJwHistoryStore, Directory)?
          createNotifier,
      StateProvider<JwDeviceNotifier?>? connection}) async {
    JwDeviceNotifier? notifier;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('jw-health-ui-');
      store = (createStore ??
          FileJwHistoryStore.new)(Directory('${dir.path}/records'));
      await store.open();
      for (final device in rows.map((r) => r.deviceKey).toSet()) {
        await store.append('seed-${device.replaceAll(':', '-')}',
            rows.where((r) => r.deviceKey == device).toList());
      }
      notifier = await createNotifier?.call(store, dir);
      goals = JwHealthGoalStore(File('${dir.path}/goals.json'));
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await store.close();
        await dir.delete(recursive: true);
      });
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
          overrides: [
            jwRepositoryProvider.overrideWith((ref) async => (connection == null
                    ? notifier
                    : ref.watch(connection) ?? notifier)
                ?.repository),
            connectedDeviceProvider.overrideWith((ref) {
              final repository = (connection == null
                      ? notifier
                      : ref.watch(connection) ?? notifier)
                  ?.repository;
              return repository == null
                  ? null
                  : ConnectedDeviceInfo(
                      deviceId: repository.platformDeviceKey!,
                      name: 'S200',
                      mtu: 23,
                      isJw: true);
            }),
            jwHistoryStoreProvider
                .overrideWith((ref) async => wrapStore?.call(store) ?? store),
            jwHealthGoalStoreProvider.overrideWith((ref) async => goals),
            jwDeviceProvider.overrideWith((ref) => connection == null
                ? notifier ?? JwDeviceNotifier(repository: null)
                : ref.watch(connection) ??
                    notifier ??
                    JwDeviceNotifier(repository: null)),
          ],
          child: MaterialApp(
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!),
              home: selection == null
                  ? const JwHealthPage(deviceKey: 'jw:test', deviceName: 'S200')
                  : Consumer(
                      builder: (context, ref, _) => JwHealthPage(
                          deviceKey: ref.watch(selection),
                          deviceName: 'S200')))));
    });
    if (wrapStore == null) await settleIo(tester);
  }

  testWidgets(
      'saved read error still permits source disclosure and raw records',
      (tester) async {
    await setup(tester, wrapStore: (store) => _BrokenInventory());
    await settleIo(tester);
    expect(find.textContaining('无法读取已保存数据'), findsOneWidget);
    expect(find.byKey(const Key('jw-health-source-details')), findsOneWidget);
    await tester.tap(find.byKey(const Key('jw-health-source-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('jw-health-raw')), findsOneWidget);
  });

  testWidgets('empty selected date does not inherit outside record quality',
      (tester) async {
    await setup(tester, rows: [
      healthRow(JwHistoryType.heartTemperature, {'heartRateBpm': 70},
          day: '2026-10-04', validity: {'clockJump': true})
    ]);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-health-next')));
      await tester.pump();
    });
    await settleIo(tester);
    expect(find.text('已保存 0 条 · 本地记录'), findsOneWidget);
    expect(find.text('所选日期的部分记录存在质量或时间标记'), findsNothing);
  });

  testWidgets('empty date labels storage recovery as global', (tester) async {
    await setup(tester, wrapStore: (store) => _StorageWarningStore(store));
    await settleIo(tester);
    expect(find.text('已保存 0 条 · 本地记录'), findsOneWidget);
    expect(find.textContaining('全局存储问题'), findsOneWidget);
    expect(find.text('所选日期的部分记录存在质量或时间标记'), findsNothing);
    await tester.tap(find.byKey(const Key('jw-health-source-details')));
    await tester.pumpAndSettle();
    expect(find.textContaining('全局存储标记：recoveredJournalTail'), findsOneWidget);
  });

  // Break caught: week total used as headline, or zero excluded from mean.
  testWidgets('week headlines use valid day mean and keep totals and coverage',
      (tester) async {
    await setup(tester, rows: [
      healthRow(JwHistoryType.metabolism, {'steps': 10, 'sleepMinutes': 60},
          day: '2026-10-04', validity: {'sleepAvailable': true}),
      healthRow(JwHistoryType.metabolism, {'steps': 0, 'sleepMinutes': 120},
          validity: {'sleepAvailable': true}),
    ]);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-health-week')));
      await tester.pump();
    });
    await settleIo(tester);
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-activity-card')), 250);
    expect(find.text('日均 5 步'), findsOneWidget);
    expect(find.text('周期合计 10 步 · 有效 2/7 天'), findsOneWidget);
    expect(find.byType(JwHealthActivityChart), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-sleep-card')), 250);
    expect(find.text('日均 1小时30分'), findsOneWidget);
    expect(find.text('周期合计 3小时 · 有效 2/7 天'), findsOneWidget);
    expect(find.byType(JwHealthSleepChart), findsOneWidget);
    expect(find.byKey(const Key('jw-health-sleep-plot')), findsOneWidget);
  });

  // Break caught: SDNN median/range mislabeled or synthetic samples/stages.
  testWidgets('summary only keeps median percentiles range and reported onset',
      (tester) async {
    await setup(tester, rows: [
      healthRow(JwHistoryType.metabolism, {
        'sdnnMedianMs': 42,
        'sdnnP25Ms': 30,
        'sdnnP75Ms': 55,
        'sdnnCount': 8,
        'skinTemperatureMeanCelsius': 32.2,
        'skinTemperatureRangeCelsius': 2.1,
        'sleepMinutes': 90,
        'deepSleepMinutes': 30,
        'sleepOnsetMinute': 60,
      }, validity: {
        'hrvValid': true,
        'temperatureValid': true,
        'sleepAvailable': true
      })
    ]);
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-sleep-card')), 250);
    expect(find.text('设备每日摘要'), findsWidgets);
    expect(find.text('深睡时长 30分'), findsOneWidget);
    expect(find.text('报告入睡时间 01:00'), findsOneWidget);
    expect(find.textContaining('起床'), findsNothing);
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-metric-skinTemperature')), 250);
    expect(find.text('皮温范围 2.1 °C'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-metric-hrv')), 250);
    expect(find.text('暂无原始采样'), findsWidgets);
    expect(find.text('SDNN 中位数 42 ms'), findsOneWidget);
    expect(find.text('P25 30 ms · P75 55 ms'), findsOneWidget);
    expect(find.byKey(const Key('jw-health-samples-hrv')), findsNothing);
    expect(find.byKey(const Key('jw-health-sample-plot-hrv')), findsNothing);
  });

  // Break caught: provenance crowds every card, or raw records become unreachable.
  testWidgets(
      'source disclosure keeps raw route reachable and compact goal legend',
      (tester) async {
    await setup(tester, rows: [
      healthRow(JwHistoryType.steps, {'steps': 20})
    ]);
    expect(find.textContaining('不代表设备全部数据'), findsNothing);
    expect(find.byKey(const Key('jw-health-raw')), findsNothing);
    await tester.tap(find.byKey(const Key('jw-health-source-details')));
    await tester.pumpAndSettle();
    expect(find.textContaining('不代表设备全部数据'), findsOneWidget);
    expect(find.byKey(const Key('jw-health-raw')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-health-raw')));
      await tester.pump();
    });
    await settleIo(tester);
    expect(find.byType(JwHistoryRecordsPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-goals-card')), 250);
    for (final name in ['steps', 'energy', 'sleep']) {
      expect(find.byKey(Key('jw-health-goal-legend-$name')), findsOneWidget);
    }
  });

  // Break caught: overview omits energy/duration or treats meter totals as km.
  testWidgets(
      'sport overview shows verified mode and duration kcal km fallback',
      (tester) async {
    await setup(tester, rows: [
      healthRow(JwHistoryType.exercise, {
        'mode': 1,
        'durationMinutes': 30,
        'durationSeconds': 5,
        'energyCalories': 123000,
        'distanceMeters': 2500
      }),
      healthRow(JwHistoryType.exercise,
          {'mode': 255, 'durationMinutes': 10, 'energyCalories': 0},
          minute: 60),
    ]);
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-sport-section')), 400);
    expect(find.text('运动记录 · 登山'), findsOneWidget);
    expect(find.textContaining('30分5秒 · 123 kcal · 2.5 km'), findsOneWidget);
    expect(find.textContaining('10分 · 0 kcal'), findsOneWidget);
    expect(find.text('运动记录 · 模式 255'), findsOneWidget);
  });

  // Break caught: mixed populated content overflows in narrow accessibility layout.
  testWidgets('populated page cards fit 320 pixels at scale two',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await setup(tester, scale: 2, rows: [
      healthRow(JwHistoryType.steps, {'steps': 123456, 'energyCalories': 1000}),
      healthRow(JwHistoryType.heartTemperature, {'heartRateBpm': 72},
          minute: 60),
      healthRow(
          JwHistoryType.metabolism, {'sdnnMedianMs': 42, 'sleepMinutes': 90},
          validity: {'hrvValid': true, 'sleepAvailable': true}),
      healthRow(JwHistoryType.exercise, {
        'mode': 1,
        'durationMinutes': 30,
        'energyCalories': 123000,
        'distanceMeters': 2500
      }),
    ]);
    for (final key in [
      'jw-health-activity-card',
      'jw-health-sleep-card',
      'jw-health-metric-heartRate',
      'jw-health-metric-hrv',
      'jw-health-sport-section'
    ]) {
      await tester.scrollUntilVisible(find.byKey(Key(key)), 300);
      expect(tester.takeException(), isNull, reason: key);
    }
  });

  testWidgets('saved day and preceding six days reload real totals',
      (tester) async {
    await setup(tester, rows: [
      healthRow(JwHistoryType.steps,
          {'steps': 20, 'distanceMeters': 30, 'energyCalories': 1000}),
      healthRow(JwHistoryType.steps, {'steps': 7}, day: '2026-10-01')
    ]);
    await expectSteps(tester, '20 步');
    expect(find.textContaining('未设置目标'), findsWidgets);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-health-week')));
      await tester.pump();
    });
    await settleIo(tester);
    expect(find.text('2026-09-29 — 2026-10-05'), findsOneWidget);
    expect(find.byType(JwHealthGoalRings), findsNWidgets(7));
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-activity-card')), 250);
    expect(find.text('日均 13.5 步'), findsOneWidget);
    expect(find.text('周期合计 27 步 · 有效 2/7 天'), findsOneWidget);
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-health-day')));
      await tester.pump();
    });
    await settleIo(tester);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-health-prev')));
      await tester.pump();
    });
    await settleIo(tester);
    expect(find.text('2026-10-04'), findsWidgets);
    await expectSteps(tester, '20 步', absent: true);
    await tester.runAsync(() async {
      await store.append('refresh-zero', [
        healthRow(
            JwHistoryType.metabolism, {'steps': 0, 'energyKilocalories': 0},
            day: '2026-10-04', batch: 'refresh-zero')
      ]);
      await tester.tap(find.byKey(const Key('jw-health-refresh')));
      await tester.pump();
    });
    await settleIo(tester);
    await expectSteps(tester, '0 步');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-health-date')));
      await tester.pump();
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('5').last);
    await tester.runAsync(() async {
      await tester.tap(find.text('OK'));
      await tester.pump();
    });
    await settleIo(tester);
    await expectSteps(tester, '20 步');
  });
  testWidgets('offline empty data remains explicit at narrow large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await setup(tester, scale: 2);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('jw-health-sync')))
            .onPressed,
        isNull);
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-metric-heartRate')), 250);
    expect(find.text('暂无有效心率数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('goal editor validates and persists user targets without BLE',
      (tester) async {
    await setup(tester, rows: [
      healthRow(JwHistoryType.steps, {'steps': 20})
    ]);
    await tester.ensureVisible(find.byKey(const Key('jw-health-goal-editor')));
    await tester.tap(find.byKey(const Key('jw-health-goal-editor')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('jw-health-goal-steps')), '0');
    await tester.tap(find.byKey(const Key('jw-health-goal-save')));
    await tester.pump();
    expect(find.text('请输入正数，或留空清除目标'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('jw-health-goal-steps')), '40');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-health-goal-save')));
      for (var i = 0; i < 250; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (find.byKey(const Key('jw-health-goal-save')).evaluate().isEmpty) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('50%'), findsWidgets);
    expect((await tester.runAsync(() => goals.read('jw:test')))!.steps, 40);
    expect(find.text('用户设置 · HoneyBox 本地目标'), findsOneWidget);
  });

  // A stale first device load must not overwrite the second device snapshot.
  testWidgets('late first-device load cannot replace new device saved data',
      (tester) async {
    final selected = StateProvider<String>((ref) => 'jw:test');
    late _HeldInventory held;
    await setup(tester,
        selection: selected,
        wrapStore: (store) => held = _HeldInventory(store),
        rows: [
          healthRow(JwHistoryType.steps, {'steps': 20}),
          healthRow(JwHistoryType.steps, {'steps': 50}, device: 'jw:other'),
          healthRow(JwHistoryType.steps, {'steps': 50}, device: 'jw:other')
        ]);
    await tester.pump();
    final scope =
        ProviderScope.containerOf(tester.element(find.byType(JwHealthPage)));
    await tester.runAsync(() async {
      scope.read(selected.notifier).state = 'jw:other';
      await tester.pump();
    });
    await settleIo(tester);
    await expectSteps(tester, '50 步');
    held.release.complete();
    await settleIo(tester);
    await expectSteps(tester, '50 步');
    await expectSteps(tester, '20 步', absent: true);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  // Unit mistakes or fake defaults change these literal raw-sample summaries.
  testWidgets(
      'sparse metric cards show real units and raw values at scaled text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await setup(tester, scale: 1.5, rows: [
      healthRow(JwHistoryType.heartTemperature,
          {'heartRateBpm': 70, 'skinTemperatureCelsius': 31.2},
          minute: 60),
      healthRow(JwHistoryType.heartTemperature,
          {'heartRateBpm': 74, 'skinTemperatureCelsius': 32.2},
          minute: 1380),
      healthRow(JwHistoryType.bloodOxygen, {'percent': 97}, minute: 300),
      healthRow(JwHistoryType.hrv, {'sdnnMilliseconds': 42}, minute: 300),
      healthRow(JwHistoryType.pressure, {'value': 6}, minute: 300),
      healthRow(JwHistoryType.bloodPressure,
          {'systolicMmHg': 120, 'diastolicMmHg': 80},
          minute: 300),
      healthRow(JwHistoryType.sleep, {'mode': 3}, minute: 60),
      healthRow(JwHistoryType.sleep, {'mode': 3}, minute: 120),
    ]);
    for (final pair in {
      'heartRate': '72 bpm',
      'bloodOxygen': '97 %',
      'skinTemperature': '31.7 °C',
      'hrv': '42 ms',
      'pressure': '6 固件值',
      'bloodPressure': '120/80 mmHg'
    }.entries) {
      await tester.scrollUntilVisible(
          find.byKey(Key('jw-health-metric-${pair.key}')), 300);
      expect(find.text(pair.value), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await Scrollable.ensureVisible(
        tester
            .element(find.byKey(const Key('jw-health-samples-bloodPressure'))),
        alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('jw-health-samples-bloodPressure')));
    await tester.pumpAndSettle();
    expect(find.text('2026-10-05 05:00 · 设备本地时间'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  // Decoder sport keys are heartRateAverage/Max/Min, not invented names.
  testWidgets('sport detail shows record-provided heart rate statistics',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: JwHealthSportPage(
            record: healthRow(JwHistoryType.exercise, {
      'mode': 1,
      'durationMinutes': 30,
      'durationSeconds': 5,
      'heartRateAverage': 72,
      'heartRateMax': 90,
      'heartRateMin': 60
    }))));
    expect(find.text('72 bpm'), findsOneWidget);
    expect(find.text('90 bpm'), findsOneWidget);
    expect(find.text('60 bpm'), findsOneWidget);
    expect(find.textContaining('不显示曲线'), findsOneWidget);
  });

  // Authoritative live repository identity, not a stale global state, permits sync.
  testWidgets(
      'matching repository awaits durable sync then reloads and different reconnect cannot sync',
      (tester) async {
    final connection = StateProvider<JwDeviceNotifier?>((ref) => null);
    final selected = StateProvider<String>((ref) => 'jw:test');
    late FakeJwTransport transport;
    late _CommitGateStore gate;
    late JwDeviceNotifier original;
    await setup(tester,
        selection: selected,
        connection: connection,
        createStore: (dir) => gate = _CommitGateStore(dir),
        rows: [
          healthRow(JwHistoryType.steps, {'steps': 20}),
          healthRow(JwHistoryType.steps, {'steps': 50}, device: 'jw:other'),
          healthRow(JwHistoryType.heartTemperature, {'heartRateBpm': 70})
        ],
        createNotifier: (store, dir) async {
          transport = FakeJwTransport();
          installJwDeviceScript(transport, functions: '0000000000000000');
          transport.readValues['2a25'] =
              Uint8List.fromList(utf8.encode('test'));
          original = JwDeviceNotifier(
              repository: JwDeviceRepository(
                  platformDeviceKey: 'test-platform',
                  session: JwSession(transport),
                  transport: transport,
                  identityStore:
                      JwIdentityStore(File('${dir.path}/identity.json')),
                  historyStoreFactory: () async => store,
                  ownsHistoryStore: false));
          await original.initialize();
          final normal = transport.onWrite!;
          transport.onWrite = (bytes) {
            final frame = JwFrameDecoder().add(bytes).single;
            if (frame.ack) return;
            final message = JwCodec.decodeL2(frame.payload);
            if (message.command == 5 && message.fields.single.key == 1) {
              transport.emitAck(frame.seq);
              transport.emitMessage(
                  5,
                  7,
                  Uint8List.fromList([
                    for (var i = 0; i < 6; i++) ...[i, 0, 0]
                  ]),
                  noAck: true);
              transport.emitMessage(5, 8, Uint8List(0), noAck: true);
            } else {
              normal(bytes);
            }
          };
          return original;
        });
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('jw-health-sync')))
            .onPressed,
        isNotNull);
    await tester.scrollUntilVisible(
        find.byKey(const Key('jw-health-metric-heartRate')), 250);
    expect(find.textContaining('仍可查看已保存数据'), findsOneWidget);
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jw-health-sync')));
      await tester.pump();
      await gate.entered.future.timeout(const Duration(seconds: 3),
          onTimeout: () => fail(
              'Sync gate not entered: ${original.repository!.state.historyProgress?.phase} / ${original.repository!.state.operationError}'));
      await store.append('new-data', [
        healthRow(
            JwHistoryType.metabolism, {'steps': 90, 'energyKilocalories': 0},
            batch: 'new-data')
      ]);
    });
    await tester.pump();
    expect(find.text('正在同步'), findsOneWidget);
    await expectSteps(tester, '20 步');
    await expectSteps(tester, '90 步', absent: true);
    final scope =
        ProviderScope.containerOf(tester.element(find.byType(JwHealthPage)));
    await tester.runAsync(() async {
      scope.read(selected.notifier).state = 'jw:other';
      await tester.pump();
    });
    await settleIo(tester);
    await expectSteps(tester, '50 步');
    expect(find.text('正在同步'), findsNothing);
    await tester.runAsync(() async {
      gate.release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
    await settleIo(tester);
    await expectSteps(tester, '50 步');
    await expectSteps(tester, '90 步', absent: true);
    await tester.runAsync(() async {
      scope.read(selected.notifier).state = 'jw:test';
      await tester.pump();
    });
    await settleIo(tester);
    await expectSteps(tester, '90 步');
    late FakeJwTransport secondTransport;
    late JwDeviceNotifier second;
    await tester.runAsync(() async {
      secondTransport = FakeJwTransport();
      installJwDeviceScript(secondTransport, functions: '0000000000000000');
      second = JwDeviceNotifier(
          repository: JwDeviceRepository(
              platformDeviceKey: 'test-platform',
              session: JwSession(secondTransport),
              transport: secondTransport,
              identityStore: original.repository!.identityStore,
              historyStoreFactory: () async => store,
              ownsHistoryStore: false));
      await second.initialize();
    });
    final before = secondTransport.writes.length;
    await tester.runAsync(() async {
      scope.read(connection.notifier).state = second;
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('jw-health-sync')))
            .onPressed,
        isNull);
    await tester.tap(find.byKey(const Key('jw-health-sync')),
        warnIfMissed: false);
    await tester.pump();
    expect(secondTransport.writes.length, before);
    await expectSteps(tester, '90 步');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await transport.dispose();
      await secondTransport.dispose();
    });
  });
  testWidgets('raw sleep tile uses firmware 0 non-worn and 3 awake',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: JwHistoryRecordTile(
                record: healthRow(JwHistoryType.sleep, {'mode': 0}),
                partial: false))));
    expect(find.text('睡眠阶段：未佩戴'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: JwHistoryRecordTile(
                record: healthRow(JwHistoryType.sleep, {'mode': 3}, minute: 1),
                partial: false))));
    expect(find.text('睡眠阶段：清醒'), findsOneWidget);
  });
}

class _HeldInventory implements JwHistoryStore {
  _HeldInventory(this.store);
  final JwHistoryStore store;
  final release = Completer<void>();
  bool _held = false;
  @override
  Future<JwHistoryInventory> inventory(String key) async {
    if (key == 'jw:test' && !_held) {
      _held = true;
      await release.future;
    }
    return store.inventory(key);
  }

  @override
  Future<JwHistoryPage> query(String key, JwHistoryType type,
          {required String day, int offset = 0, int limit = 100}) =>
      store.query(key, type, day: day, offset: offset, limit: limit);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CommitGateStore extends FileJwHistoryStore {
  _CommitGateStore(super.root);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> commit(JwHistoryBatchCommit batch) async {
    entered.complete();
    await release.future;
    await super.commit(batch);
  }
}

class _BrokenInventory implements JwHistoryStore {
  @override
  Future<JwHistoryInventory> inventory(String key) async =>
      throw StateError('saved read failed');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StorageWarningStore implements JwHistoryStore {
  _StorageWarningStore(this.store);
  final JwHistoryStore store;
  @override
  Future<JwHistoryInventory> inventory(String key) async {
    final inventory = await store.inventory(key);
    return JwHistoryInventory(
        recordIds: inventory.recordIds,
        counts: inventory.counts,
        ackByBatch: inventory.ackByBatch,
        daysByType: inventory.daysByType,
        recoveredTails: 1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
