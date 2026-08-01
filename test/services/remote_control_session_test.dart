import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_cmd_registry.dart';
import 'package:honeybox/services/remote_control_protocol.dart';
import 'package:honeybox/services/remote_control_session.dart';

class _Recorder {
  final List<Uint8List> sent = [];
  int? send(Uint8List frame) {
    sent.add(Uint8List.fromList(frame));
    return sent.length - 1; // fake seq
  }
}

void main() {
  group('RemoteControlSession', () {
    late StreamController<Uint8List> notifs;
    late _Recorder rec;
    late RemoteControlSession session;

    setUp(() {
      notifs = StreamController<Uint8List>.broadcast();
      rec = _Recorder();
      session = RemoteControlSession(
        commandAvailable: () => true,
        sendCommand: rec.send,
        notifications: notifs.stream,
      );
    });

    tearDown(() async {
      await session.dispose();
      await notifs.close();
    });

    test('ignores non-0x0F frames', () async {
      notifs.add(Uint8List.fromList([0x0D, 0x00, 0x01, 0x00, 0x00]));
      await Future<void>.delayed(Duration.zero);
      expect(rec.sent, isEmpty);
    });

    test('replies CTRL_RESULT UNSUPPORTED when no capture handler registered',
        () async {
      notifs.add(RemoteControlProtocol.buildCapture());
      await Future<void>.delayed(Duration.zero);
      expect(rec.sent, hasLength(1));
      final parsed = RemoteControlProtocol.parse(rec.sent.single)!;
      expect(parsed.key, BleCmdRemoteControlKey.ctrlResult);
      final result = RemoteControlProtocol.parseCtrlResult(parsed.value)!;
      expect(result.echoedKey, BleCmdRemoteControlKey.capture);
      expect(result.status, RemoteControlProtocol.resultUnsupported);
    });

    test(
        'CAPTURE with a handler → STATE_REPORT + LAST_SHOT_READY, no CTRL_RESULT',
        () async {
      session.registerHandlers(
        capture: () async {
          final id = session.allocateShotId();
          session.reportCaptureDone(id);
          return id;
        },
      );

      notifs.add(RemoteControlProtocol.buildCapture());
      await Future<void>.delayed(Duration.zero);

      // spec §5.2:成功不发 CTRL_RESULT。期望 outbound 只有 handler push 的两条:
      // STATE_REPORT + LAST_SHOT_READY。
      expect(rec.sent, hasLength(2));

      final stateFrame = RemoteControlProtocol.parse(rec.sent[0])!;
      expect(stateFrame.key, BleCmdRemoteControlKey.stateReport);
      final state = RemoteControlProtocol.parseStateReport(stateFrame.value)!;
      expect(state.hasLastShot, true);
      expect(state.lastShotId, 1);

      final readyFrame = RemoteControlProtocol.parse(rec.sent[1])!;
      expect(readyFrame.key, BleCmdRemoteControlKey.lastShotReady);
      expect(
        RemoteControlProtocol.parseLastShotReady(readyFrame.value),
        1,
      );
    });

    test('CAPTURE handler returning null → BUSY', () async {
      session.registerHandlers(capture: () async => null);

      notifs.add(RemoteControlProtocol.buildCapture());
      await Future<void>.delayed(Duration.zero);

      expect(rec.sent, hasLength(1));
      final ack = RemoteControlProtocol.parseCtrlResult(
        RemoteControlProtocol.parse(rec.sent.single)!.value,
      )!;
      expect(ack.echoedKey, BleCmdRemoteControlKey.capture);
      expect(ack.status, RemoteControlProtocol.resultBusy);
    });

    test('SET_ZOOM applies via handler, no CTRL_RESULT on success', () async {
      double? seen;
      session.registerHandlers(
        zoom: (z) async {
          seen = z;
          return true;
        },
      );

      notifs.add(RemoteControlProtocol.buildSetZoom(1.5));
      await Future<void>.delayed(Duration.zero);

      expect(seen, closeTo(1.5, 0.005));
      // spec §5.2:成功不发 CTRL_RESULT;handler 自己没 push 时 outbound 为空。
      expect(rec.sent, isEmpty);
    });

    test('SET_ZOOM handler returning false → OUT_OF_RANGE', () async {
      session.registerHandlers(
        zoom: (z) async => false, // 模拟越界
      );

      notifs.add(RemoteControlProtocol.buildSetZoom(99.0));
      await Future<void>.delayed(Duration.zero);

      final ack = RemoteControlProtocol.parseCtrlResult(
        RemoteControlProtocol.parse(rec.sent.single)!.value,
      )!;
      expect(ack.status, RemoteControlProtocol.resultOutOfRange);
    });

    test('SET_ZOOM with malformed payload (< 2 bytes) → OUT_OF_RANGE',
        () async {
      session.registerHandlers(zoom: (z) async => true);

      // 手工发一个 vlen=1 的 SET_ZOOM
      notifs.add(Uint8List.fromList([
        0x0F,
        0x00,
        BleCmdRemoteControlKey.setZoom,
        0x00,
        0x01,
        0xAA,
      ]));
      await Future<void>.delayed(Duration.zero);

      final ack = RemoteControlProtocol.parseCtrlResult(
        RemoteControlProtocol.parse(rec.sent.single)!.value,
      )!;
      expect(ack.status, RemoteControlProtocol.resultOutOfRange);
    });

    test('SET_ZOOM without a registered handler → UNSUPPORTED', () async {
      notifs.add(RemoteControlProtocol.buildSetZoom(2.0));
      await Future<void>.delayed(Duration.zero);

      final ack = RemoteControlProtocol.parseCtrlResult(
        RemoteControlProtocol.parse(rec.sent.single)!.value,
      )!;
      expect(ack.status, RemoteControlProtocol.resultUnsupported);
    });

    test('non-P0 sub-commands (RECORD_START/FLIP/etc.) reply UNSUPPORTED',
        () async {
      const outOfScopeKeys = [
        BleCmdRemoteControlKey.recordStart,
        BleCmdRemoteControlKey.recordStop,
        BleCmdRemoteControlKey.focusPoint,
        BleCmdRemoteControlKey.setEv,
        BleCmdRemoteControlKey.setFlash,
        BleCmdRemoteControlKey.setTimer,
        BleCmdRemoteControlKey.setMode,
        BleCmdRemoteControlKey.flipCamera,
        BleCmdRemoteControlKey.previewReq,
      ];

      for (final key in outOfScopeKeys) {
        rec.sent.clear();
        notifs.add(Uint8List.fromList([0x0F, 0x00, key, 0x00, 0x00]));
        await Future<void>.delayed(Duration.zero);
        expect(rec.sent, hasLength(1),
            reason: 'key=0x${key.toRadixString(16)}');
        final ack = RemoteControlProtocol.parseCtrlResult(
          RemoteControlProtocol.parse(rec.sent.single)!.value,
        )!;
        expect(ack.echoedKey, key);
        expect(ack.status, RemoteControlProtocol.resultUnsupported);
      }
    });

    test('reportSnapshot pushes all five P0 tags', () {
      session.reportSnapshot(
        recording: false,
        facing: 1,
        zoom: 2.0,
        hasLastShot: false,
        lastShotId: 0,
      );
      final state = RemoteControlProtocol.parseStateReport(
        RemoteControlProtocol.parse(rec.sent.single)!.value,
      )!;
      expect(state.recording, false);
      expect(state.facing, 1);
      expect(state.zoom, closeTo(2.0, 0.005));
      expect(state.hasLastShot, false);
      expect(state.lastShotId, 0);
    });

    test('reportZoom pushes STATE_REPORT with only zoom tag', () {
      session.reportZoom(1.5);
      final state = RemoteControlProtocol.parseStateReport(
        RemoteControlProtocol.parse(rec.sent.single)!.value,
      )!;
      expect(state.zoom, closeTo(1.5, 0.005));
      expect(state.recording, isNull);
      expect(state.facing, isNull);
      expect(state.hasLastShot, isNull);
      expect(state.lastShotId, isNull);
    });

    test('reportFacing pushes STATE_REPORT with only facing tag', () {
      session.reportFacing(1);
      final state = RemoteControlProtocol.parseStateReport(
        RemoteControlProtocol.parse(rec.sent.single)!.value,
      )!;
      expect(state.facing, 1);
      expect(state.zoom, isNull);
    });

    test('report methods no-op when commandAvailable() returns false',
        () async {
      final offlineRec = _Recorder();
      final offline = RemoteControlSession(
        commandAvailable: () => false,
        sendCommand: offlineRec.send,
        notifications: const Stream.empty(),
      );
      offline.reportZoom(1.5);
      offline.reportFacing(1);
      offline.reportSnapshot(
        recording: false,
        facing: 0,
        zoom: 1.0,
        hasLastShot: false,
        lastShotId: 0,
      );
      offline.reportCaptureDone(1);
      expect(offlineRec.sent, isEmpty);
      await offline.dispose();
    });
  });
}
