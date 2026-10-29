import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/jw/jw_codec.dart';
import 'package:honeybox/services/jw/jw_models.dart';
import 'package:honeybox/services/jw/jw_session.dart';
import 'package:honeybox/services/jw/history/jw_history_coordinator.dart';
import 'package:honeybox/services/jw/history/jw_history_models.dart';
import 'package:honeybox/services/jw/history/jw_history_store.dart';
import '../../helpers/fake_jw_transport.dart';
import '../../helpers/jw_fixture.dart';

class GateStore extends FileJwHistoryStore {
  bool holdCommit = false;
  bool failDeliveredNote = false;
  final entered = Completer<void>(), release = Completer<void>();
  GateStore(super.root, {super.journalIo});
  @override
  Future<void> noteAck(String batchId, String status) async {
    if (failDeliveredNote && status == 'transportDelivered') {
      throw const FileSystemException('ACK metadata flush failed');
    }
    await super.noteAck(batchId, status);
  }

  @override
  Future<void> commit(JwHistoryBatchCommit batch) async {
    if (holdCommit) {
      entered.complete();
      await release.future;
    }
    await super.commit(batch);
  }
}

class ToggleIo implements JwHistoryJournalIo {
  bool fail = false;
  final delegate = FileJwHistoryJournalIo();
  @override
  Future<void> append(File file, String line) => delegate.append(file, line);
  @override
  Future<void> flush() async {
    if (fail) {
      throw const FileSystemException('History flush failed');
    }
    await delegate.flush();
  }

  @override
  Future<void> close() => delegate.close();
}

Future<void> waitUntil(bool Function() predicate) async {
  for (var i = 0; i < 2000; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('bounded wait expired');
}

void main() {
  late Directory root;
  late GateStore store;
  late FakeJwTransport t;
  late JwSession session;
  late JwHistoryCoordinator coordinator;
  late Uint8List start;
  int seq = 0;
  bool commitBeforeAck = false;
  void feed(int key, String hex, {int command = 5}) {
    t.rx.add(JwCodec.encode(
        seq: ++seq & 0xffff,
        noAck: true,
        payload: JwCodec.encodeL2(command, [JwField(key, jwHex(hex))])));
  }

  int acks() => t.sent
      .where((f) =>
          !f.ack &&
          JwCodec.decodeL2(f.payload).command == 5 &&
          JwCodec.decodeL2(f.payload).fields.any((v) => v.key == 0x1c))
      .length;
  void finish({bool end = true, bool modern = true}) {
    if (end) feed(8, '');
    if (modern) {
      for (final key in [0x5b, 0x60, 0x64]) {
        feed(key, '6f7665726f766572');
      }
    }
  }

  Future<JwHistoryResult> begin(
      {JwHistoryOptions options = const JwHistoryOptions()}) {
    return coordinator.synchronize(options: options);
  }

  Future<void> started() => waitUntil(() => t.sent.any((f) =>
      !f.ack && JwCodec.decodeL2(f.payload).fields.any((v) => v.key == 1)));
  Matcher fails(String stage) =>
      throwsA(isA<JwHistoryException>().having((e) => e.stage, 'stage', stage));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jw-history-coord-');
    store = GateStore(root);
    await store.open();
    t = FakeJwTransport();
    seq = 100;
    commitBeforeAck = false;
    start = jwHex('000000010000020000030000040000050000060000');
    session = JwSession(t,
        ackTimeout: const Duration(milliseconds: 200),
        replyTimeout: const Duration(milliseconds: 500));
    t.onWrite = (raw) {
      final frame = JwFrameDecoder().add(raw).single;
      if (frame.ack) return;
      final msg = JwCodec.decodeL2(frame.payload);
      t.emitAck(frame.seq);
      if (msg.command == 5 && msg.fields.single.key == 1) {
        feed(7, start.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
      }
      if (msg.command == 5 && msg.fields.single.key == 0x1c) {
        commitBeforeAck = root
            .listSync(recursive: true)
            .any((e) => e.path.endsWith('.committed.json'));
      }
    };
    await session.open();
    coordinator = JwHistoryCoordinator(
        session: session,
        store: store,
        deviceKey: 'jw:test',
        capabilities:
            JwCapabilities.fromWire(jwHex('4dd17dfce34ad83d'), jwHex('03')));
  });
  tearDown(() async {
    await coordinator.dispose();
    await session.close();
    await t.dispose();
    await store.close();
    await root.delete(recursive: true);
  });
  test(
      'END waits for modern markers and durable commit before one app confirmation',
      () async {
    store.holdCommit = true;
    final future = begin();
    await started();
    finish(modern: false);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(acks(), 0);
    finish(end: false);
    await store.entered.future;
    expect(acks(), 0);
    store.release.complete();
    final result = await future;
    expect(commitBeforeAck, isTrue);
    expect(acks(), 1);
    expect(result.wireRoundComplete, isTrue);
    expect(result.localCommitComplete, isTrue);
    expect(result.applicationAckTransportDelivered, isTrue);
    expect(result.deviceDatasetExhaustive, isFalse);
    expect(result.observedMarkers, {0x5b, 0x60, 0x64});
  });
  test('unknown history key during blocked commit fails and never confirms',
      () async {
    store.holdCommit = true;
    final running = begin();
    await started();
    finish();
    await store.entered.future;
    feed(0x65, '0102');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    store.release.complete();
    await expectLater(running, fails('lateData'));
    expect(acks(), 0);
    final diagnostics = await root
        .list(recursive: true)
        .where((e) => e is File && e.path.contains('quarantine'))
        .toList();
    expect(diagnostics, isNotEmpty);
    expect(await (diagnostics.single as File).readAsString(),
        contains('lateData'));
  });
  test('all modern data is saved after END before their distinct markers',
      () async {
    final f = begin();
    await started();
    feed(8, '');
    feed(0x5b, 'a4e3543239000000');
    feed(0x5b, '6f7665726f766572');
    feed(0x60,
        '8053543203378403e00137332f0026003d003c00625e0246f1ff0c00a4015a001e004100393000004101500027010100');
    feed(0x60, '6f7665726f766572');
    feed(0x64, 'ea070a04000352fe030937002f00a40103000000');
    feed(0x64, '6f7665726f766572');
    final result = await f;
    expect((await store.inventory('jw:test')).recordCount, 3);
    expect(result.counts[JwHistoryType.metabolism]!.newlyPersisted, 1);
    expect(acks(), 1);
  });
  test('START declares counts for modern history types', () async {
    start =
        jwHex('0000000100000200000300000400000500000600000e00010f0001100001');
    final resultFuture = begin();
    await started();
    feed(0x5b, 'a4e3543239000000');
    feed(0x5b, '6f7665726f766572');
    feed(0x60,
        '8053543203378403e00137332f0026003d003c00625e0246f1ff0c00a4015a001e004100393000004101500027010100');
    feed(0x60, '6f7665726f766572');
    feed(0x64, 'ea070a04000352fe030937002f00a40103000000');
    feed(0x64, '6f7665726f766572');
    finish(modern: false);
    final result = await resultFuture;
    expect(result.counts[JwHistoryType.pressure]!.expectedCount, 1);
    expect(result.counts[JwHistoryType.metabolism]!.expectedCount, 1);
    expect(result.counts[JwHistoryType.readiness]!.expectedCount, 1);
    expect(acks(), 1);
  });
  test('missing announced modern records prevents confirmation', () async {
    start =
        jwHex('0000000100000200000300000400000500000600000e00010f0000100000');
    final future = begin();
    final check = expectLater(future, fails('countMismatch'));
    await started();
    finish();
    await check;
    expect(acks(), 0);
  });
  test('conflicting same sequence is rejected despite valid CRC', () async {
    final f = begin();
    final check = expectLater(f, fails('sequenceConflict'));
    await started();
    t.rx.add(JwCodec.encode(
        seq: seq,
        noAck: true,
        payload: JwCodec.encodeL2(2, [JwField(0x50, jwHex('01'))])));
    await check;
    expect(acks(), 0);
  });
  test('malformed L2 never reaches health values or application confirmation',
      () async {
    final f = begin();
    final check = expectLater(f, fails('parse'));
    await started();
    t.rx.add(JwCodec.encode(seq: ++seq, noAck: true, payload: jwHex('0500ff')));
    await check;
    expect(acks(), 0);
    expect((await store.inventory('jw:test')).recordCount, 0);
  });
  test('duplicate announced START type fails rather than overwriting its count',
      () async {
    start[3] = 0;
    final f = begin();
    await expectLater(f, fails('parse'));
    expect(acks(), 0);
    final files = await root
        .list(recursive: true)
        .where((e) => e is File && e.path.contains('quarantine'))
        .toList();
    expect(files, isNotEmpty);
    expect(await (files.single as File).readAsString(), contains('050007'));
  });
  test('total budget ends a stream that keeps producing valid progress',
      () async {
    final f = begin(
        options: const JwHistoryOptions(
            // Real filesystem I/O and parallel isolates can delay heartbeats.
            // Allow scheduling margin while verified progress keeps idle alive.
            idleTimeout: Duration(seconds: 1),
            totalTimeout: Duration(seconds: 2)));
    final check = expectLater(
        f,
        throwsA(isA<JwHistoryException>()
            .having((e) => e.stage, 'stage', 'totalTimeout')
            .having(
                (e) => e.result.counts.values
                    .fold<int>(0, (sum, count) => sum + count.received),
                'verified records before absolute timeout',
                greaterThan(0))));
    await started();
    var distance = 1;
    final timer = Timer.periodic(const Duration(milliseconds: 15), (_) {
      if (t.connected) {
        final raw = jwHex('3544000104726960b26e0315');
        raw[11] = distance++ & 255;
        feed(2, raw.map((n) => n.toRadixString(16).padLeft(2, '0')).join());
      }
    });
    try {
      await check;
    } finally {
      timer.cancel();
    }
    expect(acks(), 0);
  });
  test('record flush failure keeps confirmation disabled', () async {
    await coordinator.dispose();
    await store.close();
    final io = ToggleIo();
    store = GateStore(root, journalIo: io);
    await store.open();
    coordinator = JwHistoryCoordinator(
        session: session,
        store: store,
        deviceKey: 'jw:test',
        capabilities:
            JwCapabilities.fromWire(jwHex('4dd17dfce34ad83d'), jwHex('03')));
    final f = begin();
    final check = expectLater(f, fails('storage'));
    await started();
    io.fail = true;
    feed(2, '3544000104726960b26e0315');
    finish();
    await check;
    expect(acks(), 0);
  });
  test(
      'failure after transport ACK reports its known side effect without resending',
      () async {
    store.failDeliveredNote = true;
    final f = begin();
    final check = expectLater(
        f,
        throwsA(isA<JwHistoryException>()
            .having((e) => e.stage, 'stage', 'storageAfterAck')
            .having((e) => e.result.applicationAckTransportDelivered,
                'ACK actually delivered', isTrue)));
    await started();
    finish();
    await check;
    expect(acks(), 1);
    expect((await store.inventory('jw:test')).ackByBatch.values, ['unknown']);
  });
  test('failed round reason is available after reopening the durable store',
      () async {
    start[5] = 1;
    final f = begin();
    final check = expectLater(f, fails('countMismatch'));
    await started();
    finish();
    await check;
    await store.close();
    store = GateStore(root);
    await store.open();
    expect((await store.inventory('jw:test')).batchFailures.values,
        ['countMismatch']);
  });
  test(
      'late data during commit is retained as diagnostic and invalidates round provenance',
      () async {
    store.holdCommit = true;
    final f = begin();
    final check = expectLater(f, fails('lateData'));
    await started();
    feed(2, '3544000104726960b26e0315');
    finish();
    await store.entered.future;
    feed(0x5b, 'a4e3543239000000');
    store.release.complete();
    await check;
    expect(acks(), 0);
    final page =
        await store.query('jw:test', JwHistoryType.steps, day: '2026-10-04');
    expect(page.partialRecordIds, hasLength(1));
    final diagnostics = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.contains('quarantine'))
        .toList();
    expect(diagnostics, isNotEmpty);
    expect(
        diagnostics
            .any((f) => f.readAsStringSync().contains('a4e3543239000000')),
        isTrue);
  });
  test('heart and temperature share one START count and raw storage', () async {
    start[8] = 1;
    final f = begin();
    await started();
    feed(0x29, '354400010003816f02671748');
    finish();
    final result = await f;
    expect(result.counts[JwHistoryType.heartTemperature]!.uniqueInBatch, 1);
    expect((await store.inventory('jw:test')).recordCount, 1);
  });
  test('new-sequence retransmission cannot fill a missing START record',
      () async {
    start[5] = 2;
    final f = begin();
    final check = expectLater(f, fails('countMismatch'));
    await started();
    feed(3, '3544000105460002');
    feed(3, '3544000105460002');
    finish();
    await check;
    expect(acks(), 0);
    expect((await store.inventory('jw:test')).recordCount, 1);
  });
  test('extra current-quarter rows and saturated counts are explicitly allowed',
      () async {
    start[4] = 255;
    start[5] = 255;
    final f = begin();
    await started();
    feed(2, '3544000104726960b26e0315');
    finish();
    final result = await f;
    expect(result.countValidation, 'saturatedLowerBound');
    expect(acks(), 1);
  });
  test('sequence wrap is valid and unrelated legal frames participate',
      () async {
    seq = 0xfffe;
    final f = begin();
    await started();
    feed(0x50, '01', command: 2);
    finish();
    expect((await f).wireRoundComplete, isTrue);
  });
  test('sequence gap fails without application confirmation', () async {
    final f = begin();
    final check = expectLater(f, fails('sequenceGap'));
    await started();
    seq++;
    finish();
    await check;
    expect(acks(), 0);
  });
  test(
      'same-sequence same-payload transport repeat has no application duplication',
      () async {
    final f = begin();
    await started();
    feed(3, '3544000105460002');
    final raw = JwCodec.encode(
        seq: seq,
        noAck: true,
        payload: JwCodec.encodeL2(5, [JwField(3, jwHex('3544000105460002'))]));
    t.rx.add(raw);
    finish();
    final result = await f;
    expect(result.counts[JwHistoryType.sleep]!.received, 1);
  });
  test('unknown record version is quarantined and does not confirm', () async {
    final f = begin();
    final check = expectLater(f, fails('parse'));
    await started();
    feed(100, 'ea070a04000352fe030937002f00a40104000000');
    finish();
    await check;
    expect(acks(), 0);
    expect(
        root
            .listSync(recursive: true)
            .any((e) => e.path.contains('quarantine')),
        isTrue);
  });
  test(
      'data after the modern marker fails while validated partial records remain',
      () async {
    final f = begin();
    final check = expectLater(f, fails('lateData'));
    await started();
    feed(3, '3544000105460002');
    feed(0x5b, '6f7665726f766572');
    feed(0x5b, 'a4e3543239000000');
    finish();
    await check;
    expect(acks(), 0);
    expect((await store.inventory('jw:test')).recordCount,
        greaterThanOrEqualTo(1));
  });
  test('missing modern marker times out and never confirms', () async {
    final f = begin(
        options: const JwHistoryOptions(
            idleTimeout: Duration(milliseconds: 80),
            totalTimeout: Duration(seconds: 2)));
    final check = expectLater(f, fails('idleTimeout'));
    await started();
    finish(modern: false);
    await check;
    expect(acks(), 0);
  });
  test(
      'cancel while committing stops confirmation after the pending write finishes',
      () async {
    store.holdCommit = true;
    final f = begin();
    final check = expectLater(f, fails('cancelled'));
    await started();
    finish();
    await store.entered.future;
    final cancel = coordinator.cancel();
    try {
      await waitUntil(() => !t.connected);
    } finally {
      store.release.complete();
    }
    await cancel;
    await check;
    expect(acks(), 0);
  });
  test('disconnect aborts and retains already decoded data without app ACK',
      () async {
    final f = begin();
    final check = expectLater(f, fails('disconnected'));
    await started();
    feed(3, '3544000105460002');
    await waitUntil(() => root
        .listSync(recursive: true)
        .any((e) => e.path.endsWith('2026-10-04.jsonl')));
    t.emitDisconnect();
    await check;
    expect(acks(), 0);
    expect((await store.inventory('jw:test')).recordCount, 1);
  });
  test(
      'bounded admission overflow fails instead of growing the queue indefinitely',
      () async {
    final f = begin(options: const JwHistoryOptions(maxQueuedBytes: 244));
    final check = expectLater(f, fails('queueOverflow'));
    await started();
    for (var i = 0; i < 50; i++) {
      feed(3, '3544000105460002');
    }
    await check;
    expect(acks(), 0);
  });
  test('parallel rounds are rejected without sending a second history request',
      () async {
    final f = begin();
    final check = expectLater(f, fails('cancelled'));
    await started();
    await expectLater(begin(), throwsStateError);
    await coordinator.cancel();
    await check;
    expect(acks(), 0);
  });
}
