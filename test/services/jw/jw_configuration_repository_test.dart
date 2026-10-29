import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/jw/jw_configuration.dart';
import 'package:honeybox/services/jw/jw_device_repository.dart';
import 'package:honeybox/services/jw/jw_identity_store.dart';
import 'package:honeybox/services/jw/jw_session.dart';
import 'package:honeybox/services/jw/history/jw_history_store.dart';
import '../../helpers/fake_jw_transport.dart';
import '../../helpers/jw_device_script.dart';
import '../../helpers/jw_configuration_script.dart';
import '../../helpers/jw_fixture.dart';

void main() {
  const contract = JwConfigurationContract.v101S200;
  late Directory dir;
  late FakeJwTransport t;
  late JwDeviceRepository repo;
  late JwConfigurationScript script;
  Future<void> create(
      {String functions = '4dd17dfce34ad83d',
      String firmware = 'T005',
      int login = 0,
      Future<JwHistoryStore> Function()? historyFactory}) async {
    t = FakeJwTransport();
    installJwDeviceScript(t, functions: functions, loginResult: login);
    t.readValues['2a26'] = Uint8List.fromList(firmware.codeUnits);
    script = JwConfigurationScript(t);
    repo = JwDeviceRepository(
        session: JwSession(t,
            ackTimeout: const Duration(milliseconds: 100),
            replyTimeout: const Duration(milliseconds: 300)),
        identityStore: JwIdentityStore(File('${dir.path}/identity.json')),
        transport: t,
        historyStoreFactory: historyFactory);
    addTearDown(() async {
      await repo.dispose();
      await t.dispose();
    });
    await repo.initialize();
  }

  Future<JwConfigurationValue> read(JwConfigurationDomain d) =>
      repo.readConfiguration(d, contract: contract);
  Future<JwConfigurationWriteResult> set(
          JwConfigurationChange c, JwConfigurationValue before) =>
      repo.setConfigurationVerified(c,
          contract: contract, expectedCurrent: before);
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jw_config_repo_');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  test('lazy initialization adds no configuration queries', () async {
    await create();
    expect(script.requests, isEmpty);
    expect(repo.state.configuration, isEmpty);
  });
  test(
      'writes require exact contract login and per-operation capability including healthStatus bit17',
      () async {
    await create(firmware: 'UNKNOWN');
    await expectLater(
        read(JwConfigurationDomain.hourSystem),
        throwsA(isA<JwConfigurationException>()
            .having((e) => e.stage, 'stage', 'unsupported')));
    expect(script.sets, isEmpty);
  });
  test('T100 allows configuration reads but keeps writes locked', () async {
    await create(firmware: 'T100');
    final before = await read(JwConfigurationDomain.hourSystem);
    await expectLater(
      set(JwConfigurationChange.scalar(before.domain, before.scalarValue!),
          before),
      throwsA(isA<JwConfigurationException>()
          .having((e) => e.stage, 'stage', 'unsupported')),
    );
    expect(script.sets, isEmpty);
  });
  final bits = {
    JwConfigurationDomain.hourSystem: 44,
    JwConfigurationDomain.distanceUnit: 45,
    JwConfigurationDomain.screenLightTime: 39,
    JwConfigurationDomain.screenBrightness: 55,
    JwConfigurationDomain.heartRateAuto: 34,
    JwConfigurationDomain.bloodOxygenAuto: 19,
    JwConfigurationDomain.bloodPressureAuto: 14,
    JwConfigurationDomain.temperatureConfig: 29
  };
  for (final entry in bits.entries) {
    test('missing ${entry.key.name} bit rejects zero SET', () async {
      final mask = BigInt.parse('4dd17dfce34ad83d', radix: 16) &
          ~(BigInt.one << entry.value);
      await create(functions: mask.toRadixString(16).padLeft(16, '0'));
      await expectLater(
          read(entry.key), throwsA(isA<JwConfigurationException>()));
      expect(script.sets, isEmpty);
    });
  }
  test('health status capability required before writing', () async {
    await create(
        functions:
            (BigInt.parse('4dd17dfce34ad83d', radix: 16) & ~(BigInt.one << 17))
                .toRadixString(16)
                .padLeft(16, '0'));
    final before = await read(JwConfigurationDomain.hourSystem);
    await expectLater(
        set(JwConfigurationChange.scalar(before.domain, 1), before),
        throwsA(isA<JwConfigurationException>()));
    expect(script.sets, isEmpty);
  });
  test('login refusal cannot write configuration', () async {
    await create(login: 1);
    final before = await read(JwConfigurationDomain.hourSystem);
    await expectLater(
        set(JwConfigurationChange.scalar(before.domain, 1), before),
        throwsA(isA<JwConfigurationException>()
            .having((e) => e.writeSubmitted, 'no write submitted', false)));
    expect(script.sets, isEmpty);
  });
  test('bit14 permits BP auto with bit33 false', () async {
    await create();
    expect(repo.state.capabilities!.bloodPressure, false);
    final before = await read(JwConfigurationDomain.bloodPressureAuto);
    final result =
        await set(JwConfigurationChange.monitor(before.domain, true), before);
    expect(result.observed.raw, jwHex('0100'));
    expect(result.observed.intervalMinutes, isNull);
  });
  test('set compares fresh current value before transport write', () async {
    await create();
    final before = await read(JwConfigurationDomain.screenLightTime);
    script.values[before.domain] = jwHex('1405');
    await expectLater(
        set(JwConfigurationChange.scalar(before.domain, 15), before),
        throwsA(isA<JwConfigurationException>()
            .having((e) => e.stage, 'stage', 'conflict')
            .having((e) => e.writeSubmitted, 'no write submitted', false)));
    expect(script.sets, isEmpty);
    expect(repo.state.configuration[before.domain]!.raw, jwHex('1405'));
  });
  test('screen default-only change rejects SET with explicit zero submission',
      () async {
    await create();
    final before = await read(JwConfigurationDomain.screenLightTime);
    script.values[before.domain] = jwHex('0a06');
    await expectLater(
        set(JwConfigurationChange.scalar(before.domain, 15), before),
        throwsA(isA<JwConfigurationException>()
            .having((e) => e.stage, 'stage', 'conflict')
            .having((e) => e.writeSubmitted, 'no SET', false)));
    expect(script.sets, isEmpty);
    expect(repo.state.configuration[before.domain]!.raw, jwHex('0a06'));
  });
  test('BP echo is consumed before independent read', () async {
    await create();
    final before = await read(JwConfigurationDomain.bloodPressureAuto);
    script.replyDelay = const Duration(milliseconds: 5);
    script.requests.clear();
    final result =
        await set(JwConfigurationChange.monitor(before.domain, true), before);
    final keys = script.requests.map((m) => m.fields.single.key).toList();
    final i = keys.indexOf(0x3d);
    expect(keys.sublist(i), [0x3d, 0x26, 0x25, 0x3e, 0x26]);
    expect(result.observed.companionRaw, jwHex('00000000'));
  });
  for (final e in [0, 1]) {
    for (final d in [0, 1]) {
      test('BP main SET preserves display baseline $e $d', () async {
        await create();
        script.values[JwConfigurationDomain.bloodPressureAuto] =
            jwHex(e == 1 ? '0100' : '0000');
        script.bpDisplay = jwHex(d == 1 ? '80000000' : '00000000');
        final before = await read(JwConfigurationDomain.bloodPressureAuto);
        final changed = await set(
            JwConfigurationChange.monitor(before.domain, e == 0), before);
        expect(changed.observed.bloodPressureDisplay, d == 1);
        final restored = await set(
            JwConfigurationChange.monitor(before.domain, e == 1,
                bloodPressureDisplay: d == 1),
            changed.observed);
        expect(restored.observed.sameValue(before), true);
      });
    }
  }
  test('BP companion timeout cannot report restored', () async {
    await create();
    final before = await read(JwConfigurationDomain.bloodPressureAuto);
    script.onRequest = (m) {
      if (m.fields.single.key == 0x3d) script.dropKey = 0x26;
    };
    await expectLater(
        set(JwConfigurationChange.monitor(before.domain, true), before),
        throwsA(isA<JwConfigurationException>()
            .having((e) => e.stage, 'stage', 'deliveryUnknown')
            .having((e) => e.writeSubmitted, 'write may be delivered', true)));
    expect(repo.session.isOpen, false);
    expect(repo.state.configuration.containsKey(before.domain), false);
  });
  test('timeout invalidates old session and state', () async {
    await create();
    final before = await read(JwConfigurationDomain.hourSystem);
    script.dropKey = 0x42;
    await expectLater(
        read(before.domain), throwsA(isA<JwConfigurationException>()));
    expect(repo.session.isOpen, false);
    expect(repo.state.configuration, isEmpty);
    t.emitMessage(2, 0x43, jwHex('01'));
    await Future<void>.delayed(Duration.zero);
    expect(repo.state.configuration, isEmpty);
  });
  test('history heart and concurrent configuration cannot overlap', () async {
    await create();
    final before = await read(JwConfigurationDomain.hourSystem);
    await repo.setHeartRateStreaming(true);
    await expectLater(
        set(JwConfigurationChange.scalar(before.domain, 1), before),
        throwsA(isA<JwConfigurationException>()));
    expect(script.sets, isEmpty);
    await repo.setHeartRateStreaming(false);
    script.replyDelay = const Duration(milliseconds: 5);
    final pending = read(before.domain);
    await expectLater(read(before.domain), throwsStateError);
    await pending;
  });
  test('history initialization lock excludes configuration', () async {
    final gate = Completer<JwHistoryStore>();
    await create(historyFactory: () => gate.future);
    final before = await read(JwConfigurationDomain.hourSystem);
    final history = repo.syncHistory();
    final caught = expectLater(history, throwsA(anything));
    await expectLater(
        set(JwConfigurationChange.scalar(before.domain, 1), before),
        throwsA(isA<JwConfigurationException>()
            .having((e) => e.writeSubmitted, 'no write submitted', false)));
    await repo.cancelHistory();
    await caught;
    gate.completeError(StateError('test stop'));
    await Future<void>.delayed(Duration.zero);
    expect(script.sets, isEmpty);
  });
  test('unknown raw blocks writes', () async {
    await create();
    script.values[JwConfigurationDomain.temperatureConfig] = jwHex('80000001');
    final before = await read(JwConfigurationDomain.temperatureConfig);
    expect(before.writable, false);
    await expectLater(
        set(JwConfigurationChange.temperature(celsius: false), before),
        throwsA(isA<JwConfigurationException>()));
    expect(script.sets, isEmpty);
  });
  test('temperature convenience retains compensation', () async {
    await create();
    final before = await read(JwConfigurationDomain.temperatureConfig);
    final result = await repo.setTemperatureUnitVerified(false,
        contract: contract, expectedCurrent: before);
    expect(result.observed.raw, jwHex('00000005'));
    expect(result.observed.compensate, false);
  });
  test('snapshot fails rather than returning partial success', () async {
    await create();
    script.values[JwConfigurationDomain.screenBrightness] = jwHex('00');
    await expectLater(repo.readConfigurationSnapshot(contract: contract),
        throwsA(isA<JwConfigurationException>()));
    expect(
        repo.state.configuration
            .containsKey(JwConfigurationDomain.screenBrightness),
        false);
  });
  test('actual mismatch retained with error rather than target success',
      () async {
    await create();
    final before = await read(JwConfigurationDomain.hourSystem);
    script.ignoreWrites = true;
    await expectLater(
        set(JwConfigurationChange.scalar(before.domain, 1), before),
        throwsA(isA<JwConfigurationException>()
            .having((e) => e.stage, 'stage', 'verificationFailed')));
    expect(repo.state.configuration[before.domain]!.raw, jwHex('00'));
    expect(repo.state.operationError, contains('verificationFailed'));
  });
  for (final mask in [
    '0000000000000001',
    '0000000000000100',
    '8000000000000000'
  ]) {
    test('preflight $mask rejects zero SET', () async {
      await create();
      final before = await read(JwConfigurationDomain.hourSystem);
      script.health = jwHex(mask);
      await expectLater(
          set(JwConfigurationChange.scalar(before.domain, 1), before),
          throwsA(isA<JwConfigurationException>()));
      expect(script.sets, isEmpty);
    });
  }
  test('power save and malformed preflight refuse writes', () async {
    await create();
    final before = await read(JwConfigurationDomain.hourSystem);
    script.powerSave = jwHex('00000001');
    await expectLater(
        set(JwConfigurationChange.scalar(before.domain, 1), before),
        throwsA(isA<JwConfigurationException>()));
    script.powerSave = jwHex('00');
    await expectLater(
        set(JwConfigurationChange.scalar(before.domain, 1), before),
        throwsA(isA<JwConfigurationException>()));
    expect(script.sets, isEmpty);
  });
  test('fresh no-op avoids SET and state maps cannot be modified', () async {
    await create();
    final snapshot = await repo.readConfigurationSnapshot(contract: contract);
    expect(snapshot.values, hasLength(8));
    final before = snapshot.values[JwConfigurationDomain.hourSystem]!;
    final result =
        await set(JwConfigurationChange.scalar(before.domain, 0), before);
    expect(result.observed.sameValue(before), true);
    expect(script.sets, isEmpty);
    expect(() => repo.state.configuration.clear(), throwsUnsupportedError);
    t.emitDisconnect();
    expect(repo.state.configuration, isEmpty);
  });
}
