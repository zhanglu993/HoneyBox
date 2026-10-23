import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/providers/ble_provider.dart';
import 'package:honeybox/services/jw/jw_codec.dart';
import 'package:honeybox/services/jw/jw_device_repository.dart';
import 'package:honeybox/services/jw/jw_identity_store.dart';
import 'package:honeybox/services/jw/jw_models.dart';
import 'package:honeybox/services/jw/jw_session.dart';
import 'package:honeybox/services/jw/jw_transport.dart';
import 'package:honeybox/validation/jw_sdk_acceptance.dart';
import 'package:honeybox/validation/jw_remaining_acceptance.dart';
import '../helpers/fake_jw_transport.dart';
import '../helpers/jw_device_script.dart';

class RemainingPort implements JwRemainingAcceptancePort {
  JwDeviceRepository repository;
  JwDeviceRepository Function()? recreate;
  int connections = 0;
  final String digest;
  final wire = StreamController<JwFrame>.broadcast(sync: true);
  final alerts =
      StreamController<JwImmediateAlertAttempt>.broadcast(sync: true);
  StreamSubscription? wireSub, alertSub;
  bool prepared = false;
  final order = <String>[];
  RemainingPort(this.repository, this.digest);
  @override
  JwDeviceRepository get remainingRepository => repository;
  @override
  Stream<JwFrame> get outgoingFrames => wire.stream;
  @override
  Stream<JwImmediateAlertAttempt> get immediateAlertAttempts => alerts.stream;
  @override
  Future<void> prepareReadOnlyIdentity(String expectedDigest) async {
    expect(expectedDigest, digest);
    prepared = true;
    order.add('identity');
  }

  @override
  Future<void> startScan() async {
    order.add('scan');
  }

  @override
  void stopScan() {}
  @override
  List<ScanDevice> get devices => [
        ScanDevice(
            deviceId: '64:1A:B2:B8:00:3A',
            name: 'S200',
            rssi: -40,
            jwCandidate: true)
      ];
  @override
  Future<void> connect(ScanDevice target) async {
    expect(prepared, true);
    order.add('connect');
    if (connections++ > 0 && recreate != null) repository = recreate!();
  }

  @override
  Future<void> bindFirstTime({required bool confirmedFirstBind}) =>
      repository.bindFirstTime(confirmedFirstBind: confirmedFirstBind);

  @override
  Future<void> initialize() async {
    order.add('init');
    wireSub = repository.session.outgoingFrames.listen(wire.add);
    final transport = repository.transport;
    if (transport is JwImmediateAlertTransport) {
      alertSub = (transport as JwImmediateAlertTransport)
          .immediateAlertAttempts
          .listen(alerts.add);
    }
    await repository.initialize(expectedExistingIdentitySha256: digest);
  }

  @override
  JwDeviceState get state => repository.state;
  @override
  Future<String> identityDigest() async => digest;
  @override
  Future<void> disconnect() async {
    await repository.transport.disconnect();
    await repository.dispose();
    await wireSub?.cancel();
    await alertSub?.cancel();
  }

  @override
  Future<void> close() async {
    await repository.dispose();
    await wire.close();
    await alerts.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class AlertTestTransport extends FakeJwTransport
    implements JwImmediateAlertTransport {
  final attempts =
      StreamController<JwImmediateAlertAttempt>.broadcast(sync: true);
  final bool supported;
  final void Function(int) writeAlert;
  AlertTestTransport(this.supported, this.writeAlert);
  @override
  bool get immediateAlertAvailable => supported;
  @override
  Stream<JwImmediateAlertAttempt> get immediateAlertAttempts => attempts.stream;
  @override
  Future<void> writeImmediateAlert(bool enabled) async {
    final level = enabled ? 2 : 0;
    attempts.add(JwImmediateAlertAttempt(level, withResponse: true));
    writeAlert(level);
  }

  @override
  Future<void> dispose() async {
    await attempts.close();
    await super.dispose();
  }
}

Future<Map<String, Object?>> scriptedRun(String mode,
    {bool authorized = false,
    Map<String, Object?>? baseline,
    String? fault}) async {
  final dir = await Directory.systemTemp.createTemp('jw_group_cli_');
  final store = JwIdentityStore(File('${dir.path}/id.json'));
  final identity = await store.loadOrCreate();
  final digest = sha256.convert(identity.wireUserId).toString();
  final transports = <AlertTestTransport>[];
  var wrist = 1;
  var heat = <int>[0x52, 4, 0x80];
  var alarms = <int>[];
  var sit = fault == 'invalidLongSit'
      ? <int>[0, 1, 255, 0, 30, 9, 18, 127]
      : fault == 'dormantLongSit'
          ? <int>[0, 0, 0, 200, 60, 8, 18, 255]
          : <int>[0, 1, 0, 0, 30, 9, 18, 127];
  var sport = <int>[0, 0, 255];
  var alert = 0;
  var faultUsed = false;
  JwDeviceRepository make() {
    final t = AlertTestTransport(fault == 'iasDeliveredFailure', (level) {
      alert = level;
      if (level == 2 && !faultUsed) {
        faultUsed = true;
        throw StateError('IAS delivered before native error');
      }
    });
    transports.add(t);
    installJwDeviceScript(t);
    final original = t.onWrite!;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (f.ack) return;
      final m = JwCodec.decodeL2(f.payload);
      final field = m.fields.single;
      final tag = '${m.command}/${field.key}';
      final reps = <String, (int, int, List<int>)>{
        '2/3': (2, 4, alarms),
        '2/59': (5, 23, [15, 61, 107, 254]),
        '5/45': (5, 46, [3]),
        '2/43': (2, 44, [wrist]),
        '2/135': (2, 136, heat),
        '2/72': (2, 73, [0, 0, 0]),
        '2/38': (2, 39, sit),
        '5/58': (5, 59, [0, 0, 0, 0, 0, 0, 0, 0])
      };
      if (tag == '5/45' && field.value.single != 2) {
        t.emitAck(f.seq);
        return;
      }
      if (reps.containsKey(tag)) {
        final rep = reps[tag]!;
        if (tag == '2/3' &&
            fault == 'alarmModifyLostReply' &&
            alarms.length == 5 &&
            alarms[2] == 0x80 &&
            !faultUsed) {
          faultUsed = true;
          t.emitAck(f.seq);
          return;
        }
        t.emitAck(f.seq);
        t.emitMessage(rep.$1, rep.$2, Uint8List.fromList(rep.$3));
        return;
      }
      if (tag == '2/42') wrist = field.value.single;
      if (tag == '2/134') {
        heat = field.value.toList();
        if (fault == 'heatConflict' && !faultUsed) {
          faultUsed = true;
          heat = [0x56, 4, 0x80];
        }
      }
      if (tag == '2/2') {
        alarms = field.value.toList();
        for (var i = 0; i < alarms.length; i += 5) {
          if ((alarms[i + 4] & 127) == 0) {
            alarms[i + 3] &= 0xf8;
            alarms[i + 4] = 0x80;
          }
        }
        if ((fault == 'alarmLostAck' ||
                fault == 'alarmModifyLostAck' &&
                    alarms.length == 5 &&
                    alarms[2] == 0x80) &&
            !faultUsed) {
          faultUsed = true;
          return;
        }
      }
      if (tag == '2/33') sit = field.value.toList();
      if (tag == '7/17' &&
          field.value.single == 0 &&
          fault == 'cameraLostAck' &&
          !faultUsed) {
        faultUsed = true;
        return;
      }
      if (tag == '5/13' &&
          field.value.single == 1 &&
          fault == 'manualLostAck' &&
          !faultUsed) {
        faultUsed = true;
        return;
      }
      if (tag == '5/32') {
        t.emitAck(f.seq);
        t.emitMessage(5, 33, field.value);
        return;
      }
      if (tag == '5/92') {
        final action = field.value[0];
        if (action == 1) sport = [0, 1, field.value[1]];
        if (action == 2) sport = [0, 2, sport[2]];
        if (action == 3) sport = [0, 1, sport[2]];
        if (action == 4) sport = [0, 0, 255];
        t.emitAck(f.seq);
        if (action == 1 && fault == 'sportLostReply' && !faultUsed) {
          faultUsed = true;
          return;
        }
        t.emitMessage(5, 93, Uint8List.fromList(sport));
        return;
      }
      original(bytes);
    };
    return JwDeviceRepository(
        session: JwSession(t,
            ackTimeout: const Duration(milliseconds: 25),
            replyTimeout: const Duration(milliseconds: 50)),
        identityStore: store,
        transport: t);
  }

  final port = RemainingPort(make(), digest)..recreate = make;
  final events = <Map<String, Object?>>[];
  String? baselinePath;
  if (baseline != null) {
    baselinePath = '${dir.path}/baseline.json';
    final copy = jsonDecode(jsonEncode(baseline)) as Map;
    (copy['remainingDevice'] as Map)['identitySha256'] = digest;
    await File(baselinePath).writeAsString(jsonEncode(copy));
  }
  final config = AcceptanceConfig(
      outputDirectory: dir.path,
      address: '64:1A:B2:B8:00:3A',
      mode: mode,
      expectedIdentitySha256: digest,
      labAuthorized: authorized,
      remainingBaselineFile: baselinePath,
      scanWindow: const Duration(seconds: 1));
  try {
    final result = await AcceptanceRunner(
            port: port,
            config: config,
            record: (e) async {
              events.add(e);
            },
            delay: (_) async {})
        .run();
    result.addAll({
      'testEvents': events,
      'testFinalWrist': wrist,
      'testFinalAlarms': alarms,
      'testFinalAlert': alert
    });
    return result;
  } finally {
    for (final t in transports) {
      await t.dispose();
    }
    await dir.delete(recursive: true);
  }
}

void main() {
  test(
      'lab actual dormant baseline uses valid trial and restores exact disabled bytes',
      () async {
    final result = await scriptedRun('remaining-lab',
        authorized: true, fault: 'dormantLongSit');
    expect(result['status'], 'pass');
    expect(result['restorePending'], false);
    expect(
        (result['remainingStaticRaw'] as Map)['longSit'], '000000c83c0812ff');
    final steps = (result['remainingResults'] as List).cast<Map>();
    expect(
        steps.singleWhere(
            (e) => e['operation'] == 'readLongSit')['scheduleValid'],
        false);
    expect(
        steps.singleWhere((e) => e['operation'] == 'setLongSit')['requested'],
        '000100003c0812ff');
    final restored = (result['testEvents'] as List).cast<Map>().singleWhere(
        (e) => e['type'] == 'restored' && e['operation'] == 'longSit');
    expect(restored['raw'], '000000c83c0812ff');
  });
  test('malformed actual long-sit failure retains raw bytes before any SET',
      () async {
    final result = await scriptedRun('remaining-lab',
        authorized: true, fault: 'invalidLongSit');
    expect(result['status'], 'fail');
    expect(result['restorePending'], false);
    final failure = (result['testEvents'] as List)
        .cast<Map>()
        .singleWhere((e) => e['type'] == 'failure');
    expect(failure['raw'], '0001ff001e09127f');
    expect(
        (result['testEvents'] as List).cast<Map>().where((e) =>
            e['type'] == 'wireAttempt' &&
            e['command'] == 2 &&
            [2, 33, 16, 5, 6].contains(e['key'])),
        isEmpty);
  });
  for (final fault in ['alarmModifyLostAck', 'alarmModifyLostReply']) {
    test('review modified alarm applied and $fault reconciles planned state',
        () async {
      final result =
          await scriptedRun('remaining-lab', authorized: true, fault: fault);
      expect(result['status'], 'fail');
      expect(result['restorePending'], false);
      expect(result['testFinalAlarms'], isEmpty);
    });
  }
  test(
      'review alarm applied/lostACK reconciles intended table and restores after reconnect',
      () async {
    final result = await scriptedRun('remaining-lab',
        authorized: true, fault: 'alarmLostAck');
    expect(result['status'], 'fail');
    expect(result['recoveryUsed'], true);
    expect(result['restorePending'], false);
    expect(result['testFinalAlarms'], isEmpty);
  });
  test(
      'review external heat conflict still permits independent wrist restoration',
      () async {
    final result =
        await scriptedRun('remaining-routine', fault: 'heatConflict');
    expect(result['status'], 'fail');
    expect(result['restorePending'], true);
    expect(result['testFinalWrist'], 1);
  });
  for (final pair in [
    ('remaining-routine', 'cameraLostAck', 'camera'),
    ('remaining-lab', 'manualLostAck', 'measurement.hr'),
    ('remaining-lab', 'sportLostReply', 'sport')
  ]) {
    test(
        'review uncertain ${pair.$3} start remains explicitly unresolved after reconnect',
        () async {
      final result =
          await scriptedRun(pair.$1, authorized: true, fault: pair.$2);
      expect(result['status'], 'fail');
      expect(result['restorePending'], true);
      expect(result['remainingUnresolvedActivities'], contains(pair.$3));
    });
  }
  test(
      'review delivered IAS failure safely closes owned alert in same live session',
      () async {
    final result =
        await scriptedRun('remaining-routine', fault: 'iasDeliveredFailure');
    expect(result['status'], 'fail');
    expect(result['testFinalAlert'], 0);
    expect(result['restorePending'], false);
  });

  test('routine grouped SDK performs bounded changes and restores original raw',
      () async {
    final result = await scriptedRun('remaining-routine');
    expect(result['status'], 'pass', reason: result['error']?.toString());
    expect(result['restorePending'], false);
    final events = result['testEvents'] as List;
    expect(events.where((dynamic e) => e['type'] == 'restored').length, 2);
    expect((result['remainingWireAudit'] as Map)['forbiddenAttempts'], 0);
  });
  test('lab grouped SDK runs public CRUD/manual/sport and preserves backups',
      () async {
    final result = await scriptedRun('remaining-lab', authorized: true);
    expect(result['status'], 'pass', reason: result['error']?.toString());
    expect(result['restorePending'], false);
    final names = (result['remainingResults'] as List)
        .map((dynamic e) => e['operation'])
        .toSet();
    expect(
        names,
        containsAll([
          'addAlarm',
          'modifyAlarm',
          'deleteAlarm',
          'syncUserInfo',
          'setLongSit',
          'pauseDeviceSport',
          'stopDeviceSport'
        ]));
    expect((result['remainingWireAudit'] as Map)['forbiddenAttempts'], 0);
  });
  test(
      'independent lab restart verifies runtime-mutating long-sit only with lab permission',
      () async {
    final first = await scriptedRun('remaining-lab', authorized: true);
    expect(first['status'], 'pass');
    final next = await scriptedRun('remaining-restart',
        authorized: true, baseline: first);
    expect(next['status'], 'pass', reason: next['error']?.toString());
  });
  test('lab missing permission zero outbound attempts', () async {
    final result = await scriptedRun('remaining-lab');
    expect(result['status'], 'fail');
    expect((result['remainingWireAudit'] as Map)['attempts'], 0);
  });
  test('observation audit rejects control variants under identical command/key',
      () {
    for (final value in [
      [0],
      [1]
    ]) {
      final audit = JwRemainingWireAudit('remaining-observe', '0' * 64);
      audit.observe(JwFrameDecoder()
          .add(JwCodec.encode(
              seq: 1,
              payload: JwCodec.encodeL2(
                  5, [JwField(45, Uint8List.fromList(value))])))
          .single);
      expect(audit.summary['forbiddenAttempts'], 1);
    }
    for (final action in [1, 2, 3, 4]) {
      final audit = JwRemainingWireAudit('remaining-observe', '0' * 64);
      audit.observe(JwFrameDecoder()
          .add(JwCodec.encode(
              seq: 1,
              payload: JwCodec.encodeL2(5, [
                JwField(92, Uint8List.fromList([action, 255]))
              ])))
          .single);
      expect(audit.summary['forbiddenAttempts'], 1);
    }
  });
  test('group audit rejects excluded setters and mismatched login identifier',
      () {
    final audit = JwRemainingWireAudit('remaining-lab', '0' * 64);
    for (final key in [45, 71, 117]) {
      expect(() => audit.permit(2, key, [0]), throwsStateError);
    }
    audit.observe(JwFrameDecoder()
        .add(JwCodec.encode(
            seq: 1, payload: JwCodec.encodeL2(3, [JwField(3, Uint8List(32))])))
        .single);
    expect(audit.summary['forbiddenAttempts'], 1);
  });

  test('remaining modes require existing identity before any connection', () {
    for (final mode in [
      'remaining-observe',
      'remaining-routine',
      'remaining-lab',
      'remaining-restart'
    ]) {
      expect(
          () => AcceptanceConfig(
              outputDirectory: 'x', address: '64:1A:B2:B8:00:3A', mode: mode),
          throwsArgumentError);
      final config = AcceptanceConfig.parse([
        '--output',
        'x',
        '--address',
        '64:1A:B2:B8:00:3A',
        '--mode',
        mode,
        '--expected-id-sha256',
        '0' * 64
      ]);
      expect(config.mode, mode);
    }
  });
  test('production runner observations call public SDK and audit values',
      () async {
    final dir = await Directory.systemTemp.createTemp('jw_remaining_cli_');
    final t = FakeJwTransport();
    installJwDeviceScript(t);
    final store = JwIdentityStore(File('${dir.path}/id.json'));
    final identity = await store.loadOrCreate();
    final digest = sha256.convert(identity.wireUserId).toString();
    final original = t.onWrite!;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (f.ack) return;
      final m = JwCodec.decodeL2(f.payload);
      final tag = '${m.command}/${m.fields.single.key}';
      final rep = <String, (int, int, List<int>)>{
        '2/3': (2, 4, []),
        '2/59': (5, 23, [15, 61, 107, 254]),
        '5/45': (5, 46, [3]),
        '5/92': (5, 93, [0, 0, 255])
      }[tag];
      if (rep != null) {
        t.emitAck(f.seq);
        t.emitMessage(rep.$1, rep.$2, Uint8List.fromList(rep.$3));
        return;
      }
      original(bytes);
    };
    final repository = JwDeviceRepository(
        session: JwSession(t), identityStore: store, transport: t);
    final port = RemainingPort(repository, digest);
    final events = <Map<String, Object?>>[];
    addTearDown(() async {
      await t.dispose();
      await dir.delete(recursive: true);
    });
    final config = AcceptanceConfig(
        outputDirectory: dir.path,
        address: '64:1A:B2:B8:00:3A',
        mode: 'remaining-observe',
        expectedIdentitySha256: digest,
        scanWindow: const Duration(seconds: 1));
    final result = await AcceptanceRunner(
            port: port,
            config: config,
            record: (e) async {
              events.add(e);
            },
            delay: (_) async {})
        .run();
    expect(result['status'], 'pass');
    expect((result['remainingResults'] as List).length, 5);
    expect((result['remainingWireAudit'] as Map)['forbiddenAttempts'], 0);
    expect(port.order.take(4), ['identity', 'scan', 'connect', 'init']);
    expect(
        events
            .where((e) =>
                e['type'] == 'wireAttempt' &&
                e['command'] == 5 &&
                e['key'] == 45)
            .single['value'],
        '02');
  });
  test('remaining lab CLI requires explicit lab authorization flag', () {
    final config = AcceptanceConfig.parse([
      '--output',
      'x',
      '--address',
      '64:1A:B2:B8:00:3A',
      '--mode',
      'remaining-lab',
      '--expected-id-sha256',
      '0' * 64,
      '--lab-authorized',
      'true'
    ]);
    expect((config as dynamic).labAuthorized, true);
  });
}
