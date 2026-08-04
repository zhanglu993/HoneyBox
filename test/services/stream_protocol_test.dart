import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_cmd_registry.dart';
import 'package:honeybox/services/stream_protocol.dart';

int _sidFromOpen(Uint8List l2) => l2[5];

Uint8List _ack({required int sid, required int result, int credits = 0xffff}) {
  return buildL2Cmd(BleCmd.stream, BleCmdStreamKey.ack, [
    sid,
    result,
    (credits >> 8) & 0xff,
    credits & 0xff,
  ]);
}

Uint8List _credit(int sid, int credits) => buildL2Cmd(
      BleCmd.stream,
      BleCmdStreamKey.credit,
      [sid, (credits >> 8) & 0xff, credits & 0xff],
    );

Uint8List _report(int sid, int seq, List<List<int>> gaps) {
  final value = <int>[sid, (seq >> 8) & 0xff, seq & 0xff, gaps.length];
  for (final gap in gaps) {
    final start = gap[0];
    final end = gap[1];
    value.addAll([
      (start >> 16) & 0xff,
      (start >> 8) & 0xff,
      start & 0xff,
      (end >> 16) & 0xff,
      (end >> 8) & 0xff,
      end & 0xff,
    ]);
  }
  return buildL2Cmd(BleCmd.stream, BleCmdStreamKey.report, value);
}

Future<void> _openUnlimited(StreamSession session, List<Uint8List> sent) async {
  final opening = session.open(StreamCodec.h264, 368, 368, 15);
  session.onNotify(_ack(sid: _sidFromOpen(sent.single), result: 0));
  expect(await opening, isTrue);
}

void main() {
  group('StreamSession', () {
    late List<Uint8List> sent;
    late StreamSession session;

    setUp(() {
      sent = <Uint8List>[];
      session = StreamSession(
        send: (l2) async => sent.add(Uint8List.fromList(l2)),
        chunkSize: () => 4,
        openTimeout: const Duration(milliseconds: 20),
        creditTimeout: const Duration(milliseconds: 20),
      );
    });

    test('matching ACK opens and mismatched or truncated ACK is ignored', () async {
      final opening = session.open(StreamCodec.h264, 368, 368, 15);
      session.onNotify(
        Uint8List.fromList([BleCmd.stream, 0, BleCmdStreamKey.ack, 0, 1, 0xff]),
      );
      expect(session.state, StreamState.opening);
      session.onNotify(_ack(sid: _sidFromOpen(sent.single), result: 0, credits: 2));
      expect(await opening, isTrue);
      expect(session.credits, 2);
    });

    test('close and disconnect complete pending waits and stale ACK cannot reopen',
        () async {
      final opening = session.open(StreamCodec.h264, 368, 368, 15);
      final sid = _sidFromOpen(sent.single);
      session.close();
      expect(await opening, isFalse);
      session.onNotify(_ack(sid: sid, result: 0, credits: 2));
      expect(session.state, StreamState.idle);

      final reopening = session.open(StreamCodec.h264, 368, 368, 15);
      session.onDisconnect();
      expect(await reopening, isFalse);
      session.onNotify(_ack(sid: _sidFromOpen(sent.last), result: 0, credits: 2));
      expect(session.state, StreamState.idle);
    });

    test('open timeout classifies the failure', () async {
      expect(await session.open(StreamCodec.h264, 368, 368, 15), isFalse);
      expect(session.lastOpenFailure, StreamOpenFailure.timeout);
      expect(session.state, StreamState.idle);
    });

    test('nonzero ACK result rejects the open and records the result', () async {
      final opening = session.open(StreamCodec.h264, 368, 368, 15);
      session.onNotify(_ack(sid: _sidFromOpen(sent.single), result: 7));
      expect(await opening, isFalse);
      expect(session.lastOpenFailure, StreamOpenFailure.rejected);
      expect(session.lastAckResult, 7);
    });

    test('foreign CREDIT is ignored for the active session', () async {
      final opening = session.open(StreamCodec.h264, 368, 368, 15);
      final sid = _sidFromOpen(sent.single);
      session.onNotify(_ack(sid: sid, result: 0, credits: 1));
      expect(await opening, isTrue);
      session.onNotify(_credit((sid + 1) & 0xff, 5));
      expect(session.credits, 1);
    });

    test('credit timeout drops a frame when no credits arrive', () async {
      final opening = session.open(StreamCodec.h264, 368, 368, 15);
      session.onNotify(_ack(sid: _sidFromOpen(sent.single), result: 0, credits: 0));
      expect(await opening, isTrue);
      expect(await session.sendFrame(Uint8List(4)), isFalse);
    });

    test('REPORT retransmits every buffered chunk intersecting a gap', () async {
      await _openUnlimited(session, sent);
      expect(await session.sendFrame(Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7])), isTrue);
      final countBeforeReport = sent.length;
      session.onNotify(_report(_sidFromOpen(sent.first), 0, [
        [3, 5],
      ]));
      await Future<void>.delayed(Duration.zero);
      expect(sent, hasLength(countBeforeReport + 2));
      expect(sent.sublist(countBeforeReport).map((l2) => l2.sublist(5, 10)), [
        [0, 0, 0, 0, 0],
        [0, 0, 0, 0, 4],
      ]);
    });

    test('retransmit cache evicts a frame after three newer frames', () async {
      await _openUnlimited(session, sent);
      for (var i = 0; i < 4; i++) {
        expect(await session.sendFrame(Uint8List.fromList([i])), isTrue);
      }
      final countBeforeReport = sent.length;
      session.onNotify(_report(_sidFromOpen(sent.first), 0, [
        [0, 1],
      ]));
      await Future<void>.delayed(Duration.zero);
      expect(sent, hasLength(countBeforeReport));
    });

    test('malformed declared lengths are ignored without state changes', () async {
      final opening = session.open(StreamCodec.h264, 368, 368, 15);
      final sid = _sidFromOpen(sent.single);
      session.onNotify(Uint8List.fromList([
        BleCmd.stream,
        0,
        BleCmdStreamKey.ack,
        0,
        4,
        sid,
        0,
      ]));
      expect(session.state, StreamState.opening);
      session.onNotify(_ack(sid: sid, result: 0, credits: 1));
      expect(await opening, isTrue);
      session.onNotify(Uint8List.fromList([
        BleCmd.stream,
        0,
        BleCmdStreamKey.credit,
        0,
        3,
        sid,
        0,
      ]));
      expect(session.credits, 1);
    });

    test('sendFrame observes every queued write failure', () async {
      final sent = <Uint8List>[];
      var write = 0;
      var failFrameWrites = false;
      final failing = StreamSession(
        send: (l2) {
          sent.add(Uint8List.fromList(l2));
          if (failFrameWrites && ++write == 1) {
            return Future<void>.error(StateError('first'));
          }
          return Future<void>.value();
        },
        chunkSize: () => 2,
      );
      final opening = failing.open(StreamCodec.h264, 368, 368, 15);
      failing.onNotify(_ack(sid: _sidFromOpen(sent.single), result: 0));
      expect(await opening, isTrue);
      failFrameWrites = true;
      expect(await failing.sendFrame(Uint8List(6)), isFalse);
    });
  });
}
