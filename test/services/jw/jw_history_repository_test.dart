import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/jw/jw_codec.dart';
import 'package:honeybox/services/jw/jw_device_repository.dart';
import 'package:honeybox/services/jw/jw_identity_store.dart';
import 'package:honeybox/services/jw/jw_models.dart';
import 'package:honeybox/services/jw/jw_session.dart';
import 'package:honeybox/services/jw/history/jw_history_models.dart';
import 'package:honeybox/services/jw/history/jw_history_store.dart';
import '../../helpers/fake_jw_transport.dart';
import '../../helpers/jw_device_script.dart';
import '../../helpers/jw_fixture.dart';

void main() {
  late Directory root;
  late FakeJwTransport t;
  late JwDeviceRepository repo;
  int opens = 0;
  bool hold = false;
  Future<void> create(
      {int login = 0,
      String firmware = 'T005',
      Future<JwHistoryStore> Function()? factory}) async {
    t = FakeJwTransport();
    installJwDeviceScript(t, loginResult: login);
    t.readValues['2a26'] = Uint8List.fromList(firmware.codeUnits);
    final ordinary = t.onWrite!;
    t.onWrite = (raw) {
      final frame = JwFrameDecoder().add(raw).single;
      if (frame.ack) return;
      final msg = JwCodec.decodeL2(frame.payload);
      final field = msg.fields.single;
      if (msg.command == 5 && field.key == 1) {
        t.emitAck(frame.seq);
        t.emitMessage(5, 7, jwHex('000000010001020000030000040000050000060000'),
            noAck: true);
        if (!hold) {
          t.emitMessage(5, 3, jwHex('3544000105460002'), noAck: true);
          t.emitMessage(5, 8, jwHex(''), noAck: true);
          for (final key in [0x5b, 0x60, 0x64]) {
            t.emitMessage(5, key, jwHex('6f7665726f766572'), noAck: true);
          }
        }
      } else if (msg.command == 5 && field.key == 0x1c) {
        t.emitAck(frame.seq);
      } else {
        ordinary(raw);
      }
    };
    repo = JwDeviceRepository(
        session: JwSession(t,
            ackTimeout: const Duration(milliseconds: 100),
            replyTimeout: const Duration(milliseconds: 200)),
        identityStore: JwIdentityStore(File('${root.path}/identity.json')),
        transport: t,
        historyStoreFactory: factory ??
            () async {
              opens++;
              final store =
                  FileJwHistoryStore(Directory('${root.path}/history'));
              await store.open();
              return store;
            });
    await repo.initialize();
  }

  List<JwMessage> requests() => t.sent
      .where((f) => !f.ack)
      .map((f) => JwCodec.decodeL2(f.payload))
      .toList();
  Future<void> started(Future<JwHistoryResult> result) async {
    var finished = false;
    result.then<void>((_) {
      finished = true;
    }, onError: (Object _, StackTrace __) {
      finished = true;
    });
    for (var i = 0; i < 1000; i++) {
      if (requests().any((m) => m.command == 5 && m.fields.single.key == 1)) {
        return;
      }
      if (finished) break;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(requests().any((m) => m.command == 5 && m.fields.single.key == 1),
        isTrue,
        reason: 'Production history request must be issued');
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jw-history-repo-');
    opens = 0;
    hold = false;
  });
  tearDown(() async {
    await repo.dispose();
    await t.dispose();
    await root.delete(recursive: true);
  });
  test(
      'history storage is lazy and real durable progress/result reach repository state',
      () async {
    await create();
    expect(opens, 0);
    final result = await repo.syncHistory();
    expect(opens, 1);
    expect(result.localCommitComplete, isTrue);
    expect(repo.state.historyProgress!.phase, JwHistoryPhase.completed);
    expect(
        repo.state.lastHistoryResult!.applicationAckTransportDelivered, isTrue);
    expect((await repo.historyInventory()).recordCount, 1);
    expect(repo.state.operationInProgress, isFalse);
  });
  test('T009 history reaches durable commit and application ACK', () async {
    await create(firmware: 'T009');
    final result = await repo.syncHistory();
    expect(result.localCommitComplete, isTrue);
    expect(result.applicationAckTransportDelivered, isTrue);
    expect((await repo.historyInventory()).recordCount, 1);
  });
  test(
      'measurement is verified stopped before history begins under one operation lock',
      () async {
    await create();
    await repo.setHeartRateStreaming(true);
    await repo.syncHistory();
    final commands = requests();
    final stop = commands.indexWhere((m) =>
        m.command == 5 &&
        m.fields.single.key == 0x19 &&
        m.fields.single.value.single == 0);
    final start =
        commands.indexWhere((m) => m.command == 5 && m.fields.single.key == 1);
    expect(stop, greaterThanOrEqualTo(0));
    expect(stop, lessThan(start));
    expect(repo.state.heartRateStreaming, isFalse);
  });
  test(
      'busy history rejects settings and exposes cancellation to its SDK caller',
      () async {
    hold = true;
    await create();
    final f = repo.syncHistory();
    final check = expectLater(
        f,
        throwsA(isA<JwHistoryException>()
            .having((e) => e.stage, 'stage', 'cancelled')));
    await started(f);
    await expectLater(repo.setLanguageVerified(1), throwsStateError);
    await repo.cancelHistory();
    await check;
    expect(repo.state.lastHistoryResult!.phase, JwHistoryPhase.cancelled);
    expect(repo.state.operationError, isNotNull);
  });
  test('logged-out history does not open storage or send device commands',
      () async {
    await create(login: 1);
    await expectLater(repo.syncHistory(), throwsStateError);
    expect(opens, 0);
    expect(requests().where((m) => m.command == 5 && m.fields.single.key == 1),
        isEmpty);
  });
  test('history directory failure does not damage phase-one login or language',
      () async {
    await create(factory: () async {
      throw const FileSystemException('History directory unavailable');
    });
    expect(repo.state.phase, JwDevicePhase.loggedIn);
    await expectLater(repo.syncHistory(), throwsA(isA<FileSystemException>()));
    await repo.setLanguageVerified(1);
    expect(repo.state.language, 1);
  });
  test('disposing active history releases the store lock after cancellation',
      () async {
    hold = true;
    await create();
    final f = repo.syncHistory();
    final check = expectLater(f, throwsA(isA<JwHistoryException>()));
    await started(f);
    await repo.dispose();
    await check;
    final next = FileJwHistoryStore(Directory('${root.path}/history'));
    await next.open();
    await next.close();
  });
  test(
      'cancelling before store initialization latches and cannot start history later',
      () async {
    final gate = Completer<JwHistoryStore>(), entered = Completer<void>();
    await create(factory: () {
      entered.complete();
      return gate.future;
    });
    final running = repo.syncHistory();
    final check = expectLater(
        running,
        throwsA(isA<JwHistoryException>()
            .having((e) => e.stage, 'stage', 'cancelled')));
    await entered.future;
    await repo.cancelHistory();
    final opened = FileJwHistoryStore(Directory('${root.path}/history'));
    await opened.open();
    addTearDown(opened.close);
    gate.complete(opened);
    await check;
    expect(
        requests().where(
            (m) => m.command == 5 && [1, 0x1c].contains(m.fields.single.key)),
        isEmpty);
    expect(repo.state.lastHistoryResult!.phase, JwHistoryPhase.cancelled);
  });
  test(
      'initialization cancellation and disposal finish before store factory resolves',
      () async {
    final gate = Completer<JwHistoryStore>(), entered = Completer<void>();
    await create(factory: () {
      entered.complete();
      return gate.future;
    });
    final running = repo.syncHistory();
    final check = expectLater(
        running,
        throwsA(isA<JwHistoryException>()
            .having((e) => e.stage, 'stage', 'cancelled')));
    await entered.future;
    expect(repo.state.historyProgress!.phase, JwHistoryPhase.starting);
    await repo.cancelHistory().timeout(const Duration(seconds: 1));
    await check.timeout(const Duration(seconds: 1));
    await repo.dispose().timeout(const Duration(seconds: 1));
    final opened = FileJwHistoryStore(Directory('${root.path}/history'));
    await opened.open();
    addTearDown(opened.close);
    gate.complete(opened);
    for (var i = 0; i < 100; i++) {
      try {
        final next = FileJwHistoryStore(Directory('${root.path}/history'));
        await next.open();
        await next.close();
        return;
      } on StateError {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
    fail('Late owned factory must release its writer lock');
  });
  test('disposing during a delayed store factory cannot leak its writer lock',
      () async {
    final gate = Completer<JwHistoryStore>();
    await create(factory: () => gate.future);
    final f = repo.syncHistory();
    final check = expectLater(f, throwsStateError);
    final disposing = repo.dispose();
    final opened = FileJwHistoryStore(Directory('${root.path}/history'));
    await opened.open();
    addTearDown(opened.close);
    gate.complete(opened);
    await disposing;
    await check;
    final next = FileJwHistoryStore(Directory('${root.path}/history'));
    await next.open();
    await next.close();
  });
}
