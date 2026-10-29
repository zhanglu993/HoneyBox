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

void main() {
  const contract = JwConfigurationContract.v101S200;
  final vectors = jsonDecode(
      File('test/fixtures/jw_observation_vectors_v1.json')
          .readAsStringSync()) as Map<String, dynamic>;
  final requests = vectors['requests'] as Map<String, dynamic>;
  late FakeJwTransport t;
  late JwDeviceRepository repository;
  dynamic repo;
  Map<String, dynamic>? response;
  Future<void> create(
      {String functions = '4dd17dfce34ad83d',
      String firmware = 'T005',
      int login = 0}) async {
    final dir = await Directory.systemTemp.createTemp('jw_remaining_');
    t = FakeJwTransport();
    installJwDeviceScript(t, functions: functions, loginResult: login);
    t.readValues['2a26'] = Uint8List.fromList(firmware.codeUnits);
    final original = t.onWrite!;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (f.ack) return;
      final m = JwCodec.decodeL2(f.payload);
      if (response != null) {
        final spec = requests[response!['operation']] as Map<String, dynamic>;
        if (m.command == spec['command'] &&
            m.fields.single.key == spec['key']) {
          expect(m.fields.single.value, jwHex(spec['value'] as String));
          t.emitAck(f.seq);
          t.emitMessage(spec['replyCommand'] as int, spec['replyKey'] as int,
              jwHex(response!['responseRawHex'] as String? ?? ''));
          return;
        }
      }
      original(bytes);
    };
    repository = JwDeviceRepository(
        session: JwSession(t,
            ackTimeout: const Duration(milliseconds: 50),
            replyTimeout: const Duration(milliseconds: 80)),
        identityStore: JwIdentityStore(File('${dir.path}/id.json')),
        transport: t);
    repo = repository;
    addTearDown(() async {
      await repository.dispose();
      await t.dispose();
      await dir.delete(recursive: true);
    });
    await repository.initialize();
    t.writes.clear();
  }

  Future<dynamic> read(String op) async => switch (op) {
        'readAlarm' => await repo.readAlarm(contract: contract),
        'readSupportDeviceSport' =>
          await repo.readSupportDeviceSport(contract: contract),
        'checkSpO2MeasureEnable' =>
          await repo.checkSpO2MeasureEnable(contract: contract),
        'queryDeviceSportStatus' =>
          await repo.queryDeviceSportStatus(contract: contract),
        _ => throw StateError(op)
      };
  dynamic field(dynamic value, String key) => switch (key) {
        'records' => value.records.length,
        'mask' => value.mask,
        'ukTypes' => value.ukTypes,
        'availableReported' => value.availableReported,
        'result' => value.result,
        'state' => value.state,
        'sportType' => value.sportType,
        'operationAccepted' => value.operationAccepted,
        _ => throw StateError(key)
      };
  for (final item in vectors['cases'] as List) {
    final v = item as Map<String, dynamic>;
    test('strict vector ${v['id']}', () async {
      response = v;
      await create();
      final expected = v['expected'] as Map<String, dynamic>;
      if (expected['stage'] == 'invalid') {
        await expectLater(
            read(v['operation'] as String),
            throwsA(isA<JwConfigurationException>()
                .having((e) => e.stage, 'stage', 'invalid')));
      } else {
        final result = await read(v['operation'] as String);
        for (final e in (expected['fields'] as Map<String, dynamic>).entries) {
          expect(field(result, e.key), e.value);
        }
        expect(() => result.raw[0] = 99, throwsA(anything));
      }
    });
  }
  test('sport cache unknown/known empty/immutable and cleared on disconnect',
      () async {
    response = {
      'operation': 'readSupportDeviceSport',
      'responseRawHex': '00000000'
    };
    await create();
    expect(repo.getCachedSupportedUkSportTypes(), isNull);
    expect(t.writes, isEmpty);
    await read('readSupportDeviceSport');
    expect(repo.getCachedSupportedUkSportTypes(), isEmpty);
    expect(() => repo.getCachedSupportedUkSportTypes().add(5),
        throwsUnsupportedError);
    t.emitDisconnect();
    expect(repo.getCachedSupportedUkSportTypes(), isNull);
  });
  for (final entry in {
    'readAlarm': 58,
    'readSupportDeviceSport': 48,
    'checkSpO2MeasureEnable': 24,
    'queryDeviceSportStatus': 3
  }.entries) {
    test('${entry.key} capability missing zero TX', () async {
      response = {'operation': entry.key, 'responseRawHex': ''};
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
  for (final entry in {
    'readAlarm': '',
    'readSupportDeviceSport': '00000000',
    'checkSpO2MeasureEnable': '02',
    'queryDeviceSportStatus': '0000ff',
  }.entries) {
    test('T100/H001 supports ${entry.key} read only', () async {
      response = {'operation': entry.key, 'responseRawHex': entry.value};
      await create(firmware: 'T100');
      await read(entry.key);
      expect(t.writes, isNotEmpty);
    });
  }
  test('unknown profile zero TX', () async {
    await create(firmware: 'Other');
    await expectLater(
        read('readAlarm'), throwsA(isA<JwConfigurationException>()));
    expect(t.writes, isEmpty);
  });
  test('sport query requires existing JW login zero TX', () async {
    await create(login: 1);
    await expectLater(read('queryDeviceSportStatus'), throwsStateError);
    expect(t.writes, isEmpty);
  });
}
