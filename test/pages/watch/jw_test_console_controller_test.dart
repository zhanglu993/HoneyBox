import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/watch/jw_test_console_controller.dart';
import 'package:honeybox/services/jw/jw_codec.dart';
import 'package:honeybox/services/jw/jw_device_repository.dart';
import 'package:honeybox/services/jw/jw_identity_store.dart';
import 'package:honeybox/services/jw/jw_session.dart';
import 'package:honeybox/services/jw/jw_transport.dart';
import '../../helpers/fake_jw_transport.dart';
import '../../helpers/jw_device_script.dart';

void main() {
  late FakeJwTransport t;
  late JwDeviceRepository repo;
  late JwTestConsoleController c;
  Future<void> connect({String firmware = 'T005'}) async {
    final dir = await Directory.systemTemp.createTemp('console_ctl_');
    final identity =
        await JwIdentityStore(File('${dir.path}/id')).loadOrCreate();
    await dir.delete(recursive: true);
    t = FakeJwTransport();
    installJwDeviceScript(t);
    t.readValues['2a26'] = Uint8List.fromList(firmware.codeUnits);
    repo = JwDeviceRepository(
        session: JwSession(t),
        identityStore: _Identity(identity),
        transport: t);
    await repo.initialize();
    c = JwTestConsoleController(repo);
  }

  setUp(connect);
  tearDown(() async {
    c.dispose();
    await repo.dispose();
    await t.dispose();
  });
  test('T009 enables normal history and capability-supported operations',
      () async {
    c.dispose();
    await repo.dispose();
    await t.dispose();
    await connect(firmware: 'T009');
    for (final id in [
      'history-sync',
      'photo-start',
      'config-screenBrightness-read'
    ]) {
      expect(c.disabledReason(id), isNull, reason: id);
    }
    expect(c.disabledReason('history-reset'), contains('重置'));
  });
  test('owned camera stop remains available after console dispose and reopen',
      () async {
    await c.run('photo-start', {});
    expect(c.results['photo-start']!.success, true);
    c.dispose();
    c = JwTestConsoleController(repo);
    expect(c.disabledReason('photo-stop'), isNull);
    await c.run('photo-stop', {});
    expect(c.results['photo-stop']!.success, true);
    expect(c.disabledReason('photo-stop'), isNotNull);
  });
  test(
      'camera start finishing after route dispose is owned by reopened console',
      () async {
    final original = t.onWrite!;
    JwFrame? pending;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (!f.ack && JwCodec.decodeL2(f.payload).command == 7) {
        pending = f;
        return;
      }
      original(bytes);
    };
    final started = c.run('photo-start', {});
    await Future<void>.delayed(Duration.zero);
    expect(pending, isNotNull);
    c.dispose();
    c = JwTestConsoleController(repo);
    t.emitAck(pending!.seq);
    await started;
    t.onWrite = original;
    expect(c.disabledReason('photo-stop'), isNull);
    await c.run('photo-stop', {});
    expect(c.results['photo-stop']!.success, true);
    t.emitDisconnect();
    expect(c.disabledReason('photo-stop'), isNotNull);
    expect(c.results, isEmpty);
  });
  test('reset ACK timeout retains explicit failure and never repeats mutation',
      () async {
    c.dispose();
    final identity = repo.identityStore;
    await repo.dispose();
    await t.dispose();
    t = FakeJwTransport();
    installJwDeviceScript(t);
    final original = t.onWrite!;
    var resets = 0;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (!f.ack && JwCodec.decodeL2(f.payload).fields.single.key == 0xfa) {
        resets++;
        return;
      }
      original(bytes);
    };
    repo = JwDeviceRepository(
        session: JwSession(t, ackTimeout: const Duration(milliseconds: 25)),
        identityStore: identity,
        transport: t);
    await repo.initialize();
    c = JwTestConsoleController(repo);
    await c.run('history-reset', {});
    expect(resets, 1);
    expect(c.results['history-reset'], isNotNull);
    expect(c.results['history-reset']!.success, false);
    expect(c.results['history-reset']!.message, contains('未确认'));
    expect(c.logs.join('\n'), contains('history-reset'));
    t.emitDisconnect();
    expect(c.results, isEmpty);
    expect(c.logs, isEmpty);
  });
  test('invalid profile and scalar boundaries send no BLE frames', () async {
    final count = t.writes.length;
    for (final height in ['0', '256', '170.1', 'NaN']) {
      await c.run('profile', {
        'gender': '0',
        'age': '40',
        'height': height,
        'weight': '65',
        'steps': '',
        'sleep': ''
      });
      expect(c.results['profile']!.success, false);
    }
    await c.run('config-screenBrightness-set', {'value': '19'});
    await c.run('config-screenLightTime-set', {'value': '31'});
    expect(t.writes.length, count);
  });
  test(
      'manual BP capability and three risk writes stay blocked with zero transmission',
      () async {
    final count = t.writes.length;
    for (final op in [
      'manual-bp-start',
      'risk-notification',
      'risk-disturb',
      'risk-highHr'
    ]) {
      expect(c.disabledReason(op), isNotNull);
      await c.run(op, {});
      expect(c.results[op]!.success, false);
    }
    expect(t.writes.length, count);
  });
  test(
      'fresh read then setting shows independent before request and observed values',
      () async {
    _settings(t);
    await c.run('config-screenBrightness-read', {});
    await c.run('config-screenBrightness-set', {'value': '80'});
    expect(c.results['config-screenBrightness-set']!.success, true);
    expect(c.results['config-screenBrightness-set']!.message, contains('原值'));
    expect(c.results['config-screenBrightness-set']!.message, contains('请求值'));
    expect(c.results['config-screenBrightness-set']!.message, contains('读回值'));
    expect(c.results['config-screenBrightness-set']!.message, contains('80'));
  });
  test(
      'one failed fresh battery read does not hide independent language result',
      () async {
    t.failRead = true;
    await c.run('battery', {});
    t.failRead = false;
    await c.run('language-read', {});
    expect(c.results['battery']!.success, false);
    expect(c.results['language-read']!.success, true);
  });
  test(
      'pending command locks every category then disconnect clears late result and logs',
      () async {
    final original = t.onWrite!;
    JwFrame? pending;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (!f.ack && JwCodec.decodeL2(f.payload).fields.single.key == 0x4f) {
        pending = f;
        return;
      }
      original(bytes);
    };
    final request = c.run('language-read', {});
    await Future<void>.delayed(Duration.zero);
    expect(pending, isNotNull);
    final count = t.writes.length;
    expect(c.disabledReason('battery'), contains('执行'));
    await c.run('battery', {});
    expect(t.writes.length, count);
    t.emitDisconnect();
    await request;
    expect(c.results, isEmpty);
    expect(c.logs, isEmpty);
  });
  test('profile ACK result suppresses full personal data in diagnostic log',
      () async {
    await c.run('profile', {
      'gender': '0',
      'age': '40',
      'height': '170.5',
      'weight': '65.5',
      'steps': '10000',
      'sleep': '480'
    });
    expect(c.results['profile']!.success, true);
    expect(c.results['profile']!.message, contains('ACK'));
    expect(c.logs.join('\n'), isNot(contains('170.5')));
    expect(c.logs.join('\n'), isNot(contains('65.5')));
  });
  test('helper stop and sport actions require this session ownership',
      () async {
    for (final op in [
      'photo-stop',
      'find-stop',
      'sport-pause',
      'sport-resume',
      'sport-stop',
      'manual-hr-stop'
    ]) {
      expect(c.disabledReason(op), contains('本会话'));
    }
  });
  test('heat all-day gate and dormant long-sit bytes display precise semantics',
      () async {
    final original = t.onWrite!;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (f.ack) return;
      final m = JwCodec.decodeL2(f.payload);
      if (m.command == 2 && m.fields.single.key == 0x87) {
        t.emitAck(f.seq);
        t.emitMessage(2, 0x88, Uint8List.fromList([0, 0, 0]));
      } else if (m.command == 2 && m.fields.single.key == 0x26) {
        t.emitAck(f.seq);
        t.emitMessage(
            2, 0x27, Uint8List.fromList([42, 0, 255, 255, 60, 255, 255, 99]));
      } else {
        original(bytes);
      }
    };
    await c.run('heat-read', {});
    expect(c.results['heat-read']!.message, contains('全天允许'));
    await c.run('longSit-read', {});
    expect(c.results['longSit-read']!.message, contains('无效'));
    final count = t.writes.length;
    await c.run('longSit-set', {
      'enabled': '1',
      'startHour': '24',
      'startMinute': '0',
      'endHour': '20',
      'endMinute': '0',
      'interval': '60'
    });
    expect(t.writes.length, count);
  });
  test(
      'uncertain live IAS submission still offers this session stop through SDK guard',
      () async {
    c.dispose();
    final identity = repo.identityStore;
    await repo.dispose();
    await t.dispose();
    final alert = _AlertTransport();
    t = alert;
    installJwDeviceScript(t);
    repo = JwDeviceRepository(
        session: JwSession(t), identityStore: identity, transport: t);
    await repo.initialize();
    c = JwTestConsoleController(repo);
    alert.failAlert = true;
    await c.run('find-start', {});
    alert.failAlert = false;
    expect(c.results['find-start']!.success, false);
    expect(c.disabledReason('find-stop'), isNull);
    await c.run('find-stop', {});
    expect(c.results['find-stop']!.success, true);
    expect(alert.levels, [false]);
  });
  test(
      'manual measurement returns ACK only and stops through this session ownership',
      () async {
    final original = t.onWrite!;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (f.ack) return;
      final m = JwCodec.decodeL2(f.payload);
      if (m.command == 5 && m.fields.single.key == 0x3a) {
        t.emitAck(f.seq);
        t.emitMessage(5, 0x3b, Uint8List(8));
      } else {
        original(bytes);
      }
    };
    await c.run('manual-spo2-start', {});
    expect(c.results['manual-spo2-start']!.success, true);
    expect(c.results['manual-spo2-start']!.message, contains('ACK'));
    expect(c.results['manual-spo2-start']!.message, isNot(contains('%')));
    expect(c.disabledReason('manual-spo2-stop'), isNull);
    await c.run('manual-spo2-stop', {});
    expect(c.disabledReason('manual-spo2-stop'), contains('本会话'));
  });
  test(
      'actual UK sports list permits owned lifecycle and rejects invented types with zero TX',
      () async {
    final original = t.onWrite!;
    var status = 0, type = 255;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (f.ack) return;
      final m = JwCodec.decodeL2(f.payload), field = m.fields.single;
      if (m.command == 2 && field.key == 0x3b) {
        t.emitAck(f.seq);
        t.emitMessage(5, 0x17, Uint8List.fromList([0, 0, 0, 2]));
      } else if (m.command == 5 && field.key == 0x5c) {
        final action = field.value.first;
        if (action == 1) {
          status = 1;
          type = field.value[1];
        }
        if (action == 2) status = 2;
        if (action == 3) status = 1;
        if (action == 4) {
          status = 0;
          type = 255;
        }
        t.emitAck(f.seq);
        t.emitMessage(5, 0x5d, Uint8List.fromList([0, status, type]));
      } else {
        original(bytes);
      }
    };
    await c.run('sport-read', {});
    expect(c.results['sport-read']!.message, contains('UK 类型代码：1'));
    final count = t.writes.length;
    await c.run('sport-start', {'type': '27'});
    expect(t.writes.length, count);
    await c.run('sport-start', {'type': '1'});
    expect(c.disabledReason('sport-pause'), isNull);
    await c.run('sport-pause', {});
    await c.run('sport-resume', {});
    await c.run('sport-stop', {});
    expect(c.results['sport-stop']!.success, true);
    expect(c.disabledReason('sport-stop'), contains('本会话'));
  });
  test(
      'alarm read add modify delete preserves whole table and independently reads back',
      () async {
    final original = t.onWrite!;
    var table = <int>[];
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (f.ack) return;
      final m = JwCodec.decodeL2(f.payload), field = m.fields.single;
      if (m.command == 2 && field.key == 3) {
        t.emitAck(f.seq);
        t.emitMessage(2, 4, Uint8List.fromList(table));
      } else if (m.command == 2 && field.key == 2) {
        table = field.value.toList();
        t.emitAck(f.seq);
      } else {
        original(bytes);
      }
    };
    await c.run('alarm-read', {});
    final fields = {
      'date': '2026-10-05',
      'hour': '8',
      'minute': '30',
      'id': '2',
      'repeat': '127'
    };
    await c.run('alarm-add', fields);
    expect(c.results['alarm-add']!.success, true);
    expect(table.length, 5);
    await c.run('alarm-modify', {...fields, 'index': '0', 'hour': '9'});
    expect(c.results['alarm-modify']!.message, contains('读回值'));
    await c.run('alarm-delete', {'index': '0'});
    expect(c.results['alarm-delete']!.success, true);
    expect(table, isEmpty);
  });
  test('cursor reset emits only empty global command and labels ACK submission',
      () async {
    final count = t.writes.length;
    await c.run('history-reset', {});
    final frames = t.writes
        .skip(count)
        .map((w) => JwFrameDecoder().add(w).single)
        .where((f) => !f.ack)
        .toList();
    expect(frames.length, 1);
    final m = JwCodec.decodeL2(frames.single.payload);
    expect(m.command, 5);
    expect(m.fields.single.key, 0xfa);
    expect(m.fields.single.value, isEmpty);
    expect(c.results['history-reset']!.message, contains('仅提交'));
  });
  test(
      'disposing a controller before held reply produces no result or callbacks',
      () async {
    final original = t.onWrite!;
    JwFrame? pending;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (!f.ack && JwCodec.decodeL2(f.payload).fields.single.key == 0x4f) {
        pending = f;
        return;
      }
      original(bytes);
    };
    final request = c.run('language-read', {});
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    t.emitAck(pending!.seq);
    t.emitMessage(2, 0x50, Uint8List.fromList([1]));
    await request;
    expect(c.results, isEmpty);
  });
  test(
      'independent setting mismatch invalidates only its cache and remains a visible failure',
      () async {
    final original = t.onWrite!;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (f.ack) return;
      final m = JwCodec.decodeL2(f.payload), k = m.fields.single.key;
      if (m.command == 2 && k == 0x54) {
        t.emitAck(f.seq);
        t.emitMessage(2, 0x55, Uint8List.fromList([50, 50]));
      } else if (m.command == 2 && k == 0x53) {
        t.emitAck(f.seq);
      } else if (m.command == 5 && k == 0x2a) {
        t.emitAck(f.seq);
        t.emitMessage(5, 0x2b, Uint8List(4));
      } else if (m.command == 5 && k == 0x3a) {
        t.emitAck(f.seq);
        t.emitMessage(5, 0x3b, Uint8List(8));
      } else {
        original(bytes);
      }
    };
    await c.run('config-screenBrightness-read', {});
    await c.run('config-screenBrightness-set', {'value': '80'});
    expect(c.results['config-screenBrightness-set']!.success, false);
    expect(c.results['config-screenBrightness-set']!.message,
        contains('verificationFailed'));
    expect(c.disabledReason('config-screenBrightness-set'), contains('读取'));
    await c.run('language-read', {});
    expect(c.results['language-read']!.success, true);
  });
  test(
      'diagnostic entries bound both count and each parameter/result text length',
      () async {
    for (var i = 0; i < 45; i++) {
      await c.run('battery', {'unused': 'x' * 10000});
    }
    expect(c.logs.length, 80);
    expect(c.logs.every((line) => line.length <= 2048), true);
  });

  test(
      'partial profile ACK failure stays explicitly partial without personal data or restored claim',
      () async {
    final original = t.onWrite!;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (f.ack) return;
      final m = JwCodec.decodeL2(f.payload);
      original(bytes);
      if (m.command == 2 && m.fields.single.key == 0x10) t.failWrite = true;
    };
    await c.run('profile', {
      'gender': '0',
      'age': '40',
      'height': '170.5',
      'weight': '65.5',
      'steps': '10000',
      'sleep': '480'
    });
    expect(c.results['profile'], isNotNull);
    expect(c.results['profile']!.success, false);
    expect(c.results['profile']!.message, contains('部分提交：1'));
    expect(c.logs.join('\n'), isNot(contains('170.5')));
    expect(c.logs.join('\n'), isNot(contains('65.5')));
  });
  test(
      'temperature mode mismatch retains only safe same-session owned stop and no fabricated sensor value',
      () async {
    final original = t.onWrite!;
    t.onWrite = (bytes) {
      final f = JwFrameDecoder().add(bytes).single;
      if (f.ack) return;
      final m = JwCodec.decodeL2(f.payload);
      if (m.command == 5 && m.fields.single.key == 0x3a) {
        t.emitAck(f.seq);
        t.emitMessage(5, 0x3b, Uint8List(8));
      } else if (m.command == 5 && m.fields.single.key == 0x20) {
        t.emitAck(f.seq);
        t.emitMessage(5, 0x21, Uint8List.fromList([0]));
      } else {
        original(bytes);
      }
    };
    await c.run('manual-temperature-start', {});
    expect(c.results['manual-temperature-start']!.success, false);
    expect(c.disabledReason('manual-temperature-stop'), isNull);
    await c.run('manual-temperature-stop', {});
    expect(c.results['manual-temperature-stop']!.success, true);
  });
}

void _settings(FakeJwTransport t) {
  final original = t.onWrite!;
  var brightness = 50;
  t.onWrite = (bytes) {
    final f = JwFrameDecoder().add(bytes).single;
    if (f.ack) return;
    final m = JwCodec.decodeL2(f.payload), k = m.fields.single.key;
    List<int>? value;
    int? key;
    if (m.command == 2 && k == 0x54) {
      value = [brightness, 50];
      key = 0x55;
    }
    if (m.command == 5 && k == 0x2a) {
      value = [0, 0, 0, 0];
      key = 0x2b;
    }
    if (m.command == 5 && k == 0x3a) {
      value = List.filled(8, 0);
      key = 0x3b;
    }
    if (m.command == 2 && k == 0x53) {
      brightness = m.fields.single.value.first;
      t.emitAck(f.seq);
      return;
    }
    if (value != null) {
      t.emitAck(f.seq);
      t.emitMessage(m.command, key!, Uint8List.fromList(value));
      return;
    }
    original(bytes);
  };
}

class _Identity extends JwIdentityStore {
  final JwIdentityRecord record;
  _Identity(this.record) : super(File('unused'));
  @override
  Future<JwIdentityRecord> loadOrCreate() async => record;
}

class _AlertTransport extends FakeJwTransport
    implements JwImmediateAlertTransport {
  bool failAlert = false;
  final levels = <bool>[];
  @override
  bool get immediateAlertAvailable => true;
  @override
  Stream<JwImmediateAlertAttempt> get immediateAlertAttempts =>
      const Stream.empty();
  @override
  Future<void> writeImmediateAlert(bool enabled) async {
    if (failAlert) throw StateError('uncertain IAS submission');
    levels.add(enabled);
  }
}
