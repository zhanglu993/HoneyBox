import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_cmd_registry.dart';
import 'package:honeybox/services/remote_control_protocol.dart';

void main() {
  group('RemoteControlProtocol.parse', () {
    test('recognizes a CMD 0x0F frame and extracts key + value', () {
      final frame = Uint8List.fromList([
        BleCmd.remoteControl,
        0x00,
        BleCmdRemoteControlKey.capture,
        0x00,
        0x00,
      ]);

      final parsed = RemoteControlProtocol.parse(frame);

      expect(parsed, isNotNull);
      expect(parsed!.key, BleCmdRemoteControlKey.capture);
      expect(parsed.value, isEmpty);
    });

    test('returns null for a non-0x0F frame', () {
      final frame = Uint8List.fromList([0x0D, 0x00, 0x01, 0x00, 0x00]);
      expect(RemoteControlProtocol.parse(frame), isNull);
    });

    test('returns null when the frame is shorter than the 5-byte header', () {
      final frame = Uint8List.fromList([0x0F, 0x00]);
      expect(RemoteControlProtocol.parse(frame), isNull);
    });

    test('returns null when declared vlen exceeds remaining bytes', () {
      final frame =
          Uint8List.fromList([0x0F, 0x00, 0x01, 0x00, 0x05, 0x01, 0x02]);
      expect(RemoteControlProtocol.parse(frame), isNull);
    });
  });

  group('RemoteControlProtocol.buildCapture', () {
    test('builds an empty-payload CAPTURE frame', () {
      final frame = RemoteControlProtocol.buildCapture();
      expect(frame, [0x0F, 0x00, 0x01, 0x00, 0x00]);
    });

    test('parses back as a CAPTURE key with empty value', () {
      final parsed = RemoteControlProtocol.parse(
        RemoteControlProtocol.buildCapture(),
      );
      expect(parsed?.key, BleCmdRemoteControlKey.capture);
      expect(parsed?.value, isEmpty);
    });
  });

  group('RemoteControlProtocol.buildSetZoom / parseSetZoom', () {
    test('encodes 1.0 as u16BE 100', () {
      final frame = RemoteControlProtocol.buildSetZoom(1.0);
      expect(frame, [0x0F, 0x00, 0x04, 0x00, 0x02, 0x00, 0x64]);
    });

    test('encodes 2.5 as u16BE 250', () {
      final frame = RemoteControlProtocol.buildSetZoom(2.5);
      expect(frame, [0x0F, 0x00, 0x04, 0x00, 0x02, 0x00, 0xFA]);
    });

    test('parseSetZoom recovers the double (within 0.005)', () {
      final parsed = RemoteControlProtocol.parse(
        RemoteControlProtocol.buildSetZoom(1.75),
      );
      expect(parsed?.key, BleCmdRemoteControlKey.setZoom);
      final zoom = RemoteControlProtocol.parseSetZoom(parsed!.value);
      expect(zoom, closeTo(1.75, 0.005));
    });

    test('parseSetZoom returns null for short payload', () {
      expect(RemoteControlProtocol.parseSetZoom(Uint8List(0)), isNull);
      expect(RemoteControlProtocol.parseSetZoom(Uint8List.fromList([0x00])),
          isNull);
    });

    test('buildSetZoom throws for negative or > 655.35 values', () {
      expect(
          () => RemoteControlProtocol.buildSetZoom(-0.01), throwsArgumentError);
      expect(() => RemoteControlProtocol.buildSetZoom(655.36),
          throwsArgumentError);
    });
  });

  group('RemoteControlProtocol.buildCtrlResult / parseCtrlResult', () {
    test('encodes echoed key + status + reserved detail as [key, status, 0]',
        () {
      final frame = RemoteControlProtocol.buildCtrlResult(
        BleCmdRemoteControlKey.setZoom,
        RemoteControlProtocol.resultUnsupported,
      );
      // 5B header + 3B payload
      expect(frame, [0x0F, 0x00, 0x11, 0x00, 0x03, 0x04, 0x01, 0x00]);
    });

    test('encodes OUT_OF_RANGE for a rejected SET_ZOOM', () {
      final frame = RemoteControlProtocol.buildCtrlResult(
        BleCmdRemoteControlKey.setZoom,
        RemoteControlProtocol.resultOutOfRange,
      );
      expect(frame.sublist(5), [0x04, 0x03, 0x00]);
    });

    test('parses back the echoed key + status(detail ignored)', () {
      final parsed = RemoteControlProtocol.parse(
        RemoteControlProtocol.buildCtrlResult(
          BleCmdRemoteControlKey.capture,
          RemoteControlProtocol.resultUnsupported,
        ),
      );
      final result = RemoteControlProtocol.parseCtrlResult(parsed!.value);
      expect(result?.echoedKey, BleCmdRemoteControlKey.capture);
      expect(result?.status, RemoteControlProtocol.resultUnsupported);
    });

    test('parseCtrlResult returns null for < 3 bytes', () {
      expect(RemoteControlProtocol.parseCtrlResult(Uint8List(0)), isNull);
      expect(
          RemoteControlProtocol.parseCtrlResult(
              Uint8List.fromList([0x01, 0x02])),
          isNull);
    });
  });

  group('RemoteControlProtocol.buildLastShotReady / parseLastShotReady', () {
    test('encodes shot_id 1 as u16BE + reserved 0', () {
      final frame = RemoteControlProtocol.buildLastShotReady(1);
      // 5B header + 3B payload (hi, lo, reserved)
      expect(frame, [0x0F, 0x00, 0x12, 0x00, 0x03, 0x00, 0x01, 0x00]);
    });

    test('encodes shot_id 0x0102 correctly', () {
      final frame = RemoteControlProtocol.buildLastShotReady(0x0102);
      expect(frame.sublist(5), [0x01, 0x02, 0x00]);
    });

    test('parses back the shot_id (reserved byte ignored)', () {
      final parsed = RemoteControlProtocol.parse(
        RemoteControlProtocol.buildLastShotReady(42),
      );
      expect(RemoteControlProtocol.parseLastShotReady(parsed!.value), 42);
    });

    test('parseLastShotReady returns null for < 3 bytes', () {
      expect(RemoteControlProtocol.parseLastShotReady(Uint8List(2)), isNull);
    });

    test('buildLastShotReady rejects negative / > u16 shot_id', () {
      expect(() => RemoteControlProtocol.buildLastShotReady(-1),
          throwsArgumentError);
      expect(() => RemoteControlProtocol.buildLastShotReady(0x10000),
          throwsArgumentError);
    });
  });

  group('RemoteControlProtocol.buildStateReport / parseStateReport', () {
    test('builds an empty report (no tags) as vlen=0', () {
      final frame = RemoteControlProtocol.buildStateReport(const StateReport());
      expect(frame, [0x0F, 0x00, 0x10, 0x00, 0x00]);
    });

    test('builds a full snapshot with all 5 P0 tags', () {
      final frame = RemoteControlProtocol.buildStateReport(const StateReport(
        recording: false,
        facing: 0, // back
        zoom: 1.0,
        hasLastShot: true,
        lastShotId: 7,
      ));
      // payload (17 bytes):
      //   01 01 00        tagRecording   len=1 value=0
      //   03 01 00        tagFacing      len=1 value=0
      //   04 02 00 64     tagZoom_x100   len=2 value=100
      //   0F 01 01        tagHasLastShot len=1 value=1
      //   10 02 00 07     tagLastShotId  len=2 value=7 (u16be)
      expect(frame, [
        0x0F, 0x00, 0x10, 0x00, 0x11, //
        0x01, 0x01, 0x00, //
        0x03, 0x01, 0x00, //
        0x04, 0x02, 0x00, 0x64, //
        0x0F, 0x01, 0x01, //
        0x10, 0x02, 0x00, 0x07,
      ]);
    });

    test('round-trips through parseStateReport', () {
      const original = StateReport(
        recording: true,
        facing: 1,
        zoom: 2.5,
        hasLastShot: true,
        lastShotId: 0x0102,
      );
      final parsed = RemoteControlProtocol.parseStateReport(
        RemoteControlProtocol.parse(
          RemoteControlProtocol.buildStateReport(original),
        )!
            .value,
      );
      expect(parsed?.recording, true);
      expect(parsed?.facing, 1);
      expect(parsed?.zoom, closeTo(2.5, 0.005));
      expect(parsed?.hasLastShot, true);
      expect(parsed?.lastShotId, 0x0102);
    });

    test('parseStateReport skips unknown tags without breaking', () {
      // [unknown 0x99 len=2 payload][zoom 0x04 len=2 value=100]
      final payload = Uint8List.fromList([
        0x99, 0x02, 0xAA, 0xBB, //
        0x04, 0x02, 0x00, 0x64,
      ]);
      final parsed = RemoteControlProtocol.parseStateReport(payload);
      expect(parsed?.zoom, closeTo(1.0, 0.005));
      expect(parsed?.recording, isNull);
    });

    test('parseStateReport returns null when a TLV length overshoots', () {
      final payload =
          Uint8List.fromList([0x03, 0x05, 0x00, 0x64]); // len=5 lies
      expect(RemoteControlProtocol.parseStateReport(payload), isNull);
    });
  });
}
