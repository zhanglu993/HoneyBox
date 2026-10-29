import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/jw/jw_codec.dart';
import 'package:honeybox/services/jw/jw_configuration.dart';
import 'package:honeybox/services/jw/jw_device_repository.dart';
import 'package:honeybox/services/jw/jw_identity_store.dart';
import 'package:honeybox/services/jw/jw_session.dart';
import '../../helpers/fake_jw_transport.dart';
import '../../helpers/jw_device_script.dart';
import '../../helpers/jw_fixture.dart';

class ReadTransport extends FakeJwTransport {
  final reads = <String>[];
  Completer<Uint8List?>? gate;
  @override
  Future<Uint8List?> read(String uuid) async {
    reads.add(uuid);
    if (gate != null && uuid == '2a19') return gate!.future;
    return super.read(uuid);
  }
}

void main() {
  const contract = JwConfigurationContract.v101S200;
  final fixture = jsonDecode(
          File('test/fixtures/jw_readonly_vectors_v1.json').readAsStringSync())
      as Map<String, dynamic>;
  final operations = fixture['operations'] as Map<String, dynamic>;
  late Directory dir;
  late ReadTransport t;
  late JwDeviceRepository repository;
  dynamic repo;
  Map<String, dynamic>? response;
  final calls = <JwMessage>[];
  Future<void> create(
      {String functions = '4dd17dfce34ad83d',
      String firmware = 'T005',
      int login = 0}) async {
    dir = await Directory.systemTemp.createTemp('jw_read_');
    t = ReadTransport();
    installJwDeviceScript(t, functions: functions, loginResult: login);
    t.readValues['2a26'] = Uint8List.fromList(firmware.codeUnits);
    final original = t.onWrite!;
    t.onWrite = (bytes) {
      final frame = JwFrameDecoder().add(bytes).single;
      if (frame.ack) return;
      final message = JwCodec.decodeL2(frame.payload);
      if (response != null) {
        final op = operations[response!['operation']] as Map<String, dynamic>;
        if (message.command == op['requestCommand'] &&
            message.fields.single.key == op['requestKey']) {
          calls.add(message);
          t.emitAck(frame.seq);
          final value = jwHex(response!['responseRawHex'] as String);
          final cmd = response!['responseCommand'] as int? ??
              op['requestCommand'] as int;
          final key =
              response!['responseKey'] as int? ?? op['responseKey'] as int;
          if (response!['responseFieldCount'] == 2) {
            t.rx.add(JwCodec.encode(
                seq: 77,
                payload: JwCodec.encodeL2(
                    cmd, [JwField(key, value), JwField(key, value)])));
          } else {
            t.emitMessage(cmd, key, value);
          }
          return;
        }
      }
      original(bytes);
    };
    repository = JwDeviceRepository(
        session: JwSession(t,
            ackTimeout: const Duration(milliseconds: 50),
            replyTimeout: const Duration(milliseconds: 80)),
        identityStore: JwIdentityStore(File('${dir.path}/identity.json')),
        transport: t);
    repo = repository;
    addTearDown(() async {
      await repository.dispose();
      await t.dispose();
      await dir.delete(recursive: true);
    });
    await repository.initialize();
    t.reads.clear();
    calls.clear();
    t.writes.clear();
  }

  Future<dynamic> read(String op) async => switch (op) {
        'language' => await repo.queryLanguage(),
        'battery' => await repo.readBatteryLevel(),
        'health' => await repo.readHealthStatus(contract: contract),
        'wrist' => await repo.readTurnOverWrist(contract: contract),
        'dnd' => await repo.readDisturb(contract: contract),
        'heatWindow' => await repo.queryHeatStressReminder(contract: contract),
        'highHrDiagnostic' =>
          await repo.readHeartRateReminderDiagnostic(contract: contract),
        _ => throw StateError(op),
      };
  Map<String, Object?> fields(String op, dynamic value) => switch (op) {
        'language' || 'battery' => {'value': value},
        'health' => {
            'reportedBits': value.reportedBits,
            'hrManualReported': value.hrManualReported,
            'bpManualReported': value.bpManualReported,
            'spo2ManualReported': value.spo2ManualReported,
            'stressManualReported': value.stressManualReported,
            'exerciseReported': value.exerciseReported,
            'ecgReported': value.ecgReported
          },
        'wrist' => {'savedEnabled': value.savedEnabled},
        'dnd' => {
            'enabled': value.enabled,
            'startMinutes': value.startMinutes,
            'endMinutes': value.endMinutes,
            'active': value.active
          },
        'heatWindow' => {
            'timeWindowEnabled': value.timeWindowEnabled,
            'startMinutes': value.startMinutes,
            'endMinutes': value.endMinutes,
            'allDayAllowedByTimeGate': value.allDayAllowedByTimeGate
          },
        'highHrDiagnostic' => {
            'reportedFlag': value.reportedFlag,
            'threshold': value.threshold
          },
        _ => {},
      };
  setUp(() {
    response = null;
    calls.clear();
  });
  for (final op in [
    'health',
    'wrist',
    'dnd',
    'heatWindow',
    'highHrDiagnostic'
  ]) {
    test('T100/H001 reads $op with validated reply', () async {
      await create(firmware: 'T100');
      response = Map<String, dynamic>.from((fixture['cases'] as List)
          .firstWhere((c) =>
              c['operation'] == op && c['expected']['fields'] != null) as Map);
      await read(op);
      expect(calls, hasLength(1));
    });
  }
  for (final dynamic item in fixture['cases']) {
    final c = Map<String, dynamic>.from(item as Map);
    test('independent readonly contract ${c['id']}', () async {
      await create();
      response = c;
      final op = c['operation'] as String;
      if (op == 'battery') {
        if (c['responseRawHex'] == null) {
          t.readValues.remove('2a19');
        } else {
          t.readValues['2a19'] = jwHex(c['responseRawHex'] as String);
        }
      }
      final expected = c['expected'] as Map;
      if (expected['stage'] == 'invalid') {
        final matcher =
            (c.containsKey('responseCommand') || c.containsKey('responseKey'))
                ? isA<JwLinkException>()
                : isA<JwConfigurationException>()
                    .having((e) => e.stage, 'stage', 'invalid');
        await expectLater(read(op), throwsA(matcher));
      } else {
        final value = await read(op);
        final actual = fields(op, value);
        for (final entry in (expected['fields'] as Map).entries) {
          expect(actual[entry.key], entry.value);
        }
        if (op != 'language' && op != 'battery') {
          expect(value.raw, jwHex(c['responseRawHex'] as String));
          expect(() => value.raw[0] = 255, throwsUnsupportedError);
        }
        if (op == 'language') expect(repository.state.language, value);
        if (op == 'battery') {
          expect(repository.state.info!.battery, value);
          expect(repository.state.info!.firmware, 'T005');
        }
      }
      if (op == 'battery') {
        expect(t.reads, ['2a19']);
        expect(calls, isEmpty);
      } else {
        expect(calls, hasLength(1));
        expect(calls.single.fields.single.value, isEmpty);
      }
    });
  }
  for (final entry in {
    'language': 43,
    'health': 17,
    'wrist': 42,
    'dnd': 35,
    'heatWindow': 4,
    'highHrDiagnostic': 11
  }.entries) {
    test('${entry.key} missing capability rejects without query', () async {
      final bits = BigInt.parse('4dd17dfce34ad83d', radix: 16) &
          ~(BigInt.one << entry.value);
      await create(functions: bits.toRadixString(16).padLeft(16, '0'));
      await expectLater(
          read(entry.key),
          throwsA(isA<JwConfigurationException>()
              .having((e) => e.stage, 'stage', 'unsupported')));
      expect(t.writes, isEmpty);
    });
  }
  test('reminder capability is independent of health status bit', () async {
    final bits =
        BigInt.parse('4dd17dfce34ad83d', radix: 16) & ~(BigInt.one << 17);
    await create(functions: bits.toRadixString(16).padLeft(16, '0'));
    response = {'operation': 'wrist', 'responseRawHex': '01'};
    expect((await read('wrist')).savedEnabled, true);
  });
  test('unknown target rejects reminder without query', () async {
    await create(firmware: 'OTHER');
    await expectLater(
        read('wrist'),
        throwsA(isA<JwConfigurationException>()
            .having((e) => e.stage, 'stage', 'unsupported')));
    expect(t.writes, isEmpty);
  });
  test(
      'readonly operation allowed after login refusal and lock excludes concurrent reads',
      () async {
    await create(login: 1);
    t.gate = Completer<Uint8List?>();
    final pending = read('battery');
    await expectLater(read('language'), throwsStateError);
    t.gate!.complete(jwHex('64'));
    expect(await pending, 100);
  });
  test('disconnect rejects late GATT result', () async {
    await create();
    t.gate = Completer<Uint8List?>();
    final pending = read('battery');
    final check = expectLater(pending, throwsStateError);
    t.emitDisconnect();
    t.gate!.complete(jwHex('64'));
    await check;
    expect(repository.state.info!.battery, 70);
  });
  test(
      'outgoing frames observe requests and ACK attempts without injecting writes',
      () async {
    await create();
    final frames = <JwFrame>[];
    final Stream<JwFrame> stream =
        (repository.session as dynamic).outgoingFrames;
    final sub = stream.listen(frames.add);
    addTearDown(sub.cancel);
    response = {'operation': 'wrist', 'responseRawHex': '01'};
    await read('wrist');
    await Future<void>.delayed(Duration.zero);
    expect(frames.length, t.sent.length);
    expect(frames.where((f) => !f.ack), hasLength(1));
    expect(frames.any((f) => f.ack), true);
    expect(
        JwCodec.decodeL2(frames.firstWhere((f) => !f.ack).payload)
            .fields
            .single
            .key,
        0x2b);
    expect(() => frames.first.payload[0] = 9, throwsUnsupportedError);
  });
}
