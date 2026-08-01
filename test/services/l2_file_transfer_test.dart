import 'dart:typed_data';

import 'package:honeybox/services/ble_cmd_registry.dart';
import 'package:honeybox/services/l2_file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTimerProvider implements TimerProvider {
  TimerCallback? callback;

  @override
  void start(Duration duration, TimerCallback callback) {
    this.callback = callback;
  }

  @override
  void cancel() {
    callback = null;
  }

  void fire() {
    final cb = callback;
    callback = null;
    cb?.call();
  }
}

void main() {
  test('buildBeginReq includes filename length and utf8 filename', () {
    final frame = buildBeginReq(TYPE.image, 0x01020304, 0x0800, '图.png');
    final parsed = parseL2Frame(frame)!;

    expect(parsed.key, BleCmdFileTransferKey.beginReq);
    expect(parsed.value.sublist(0, 8), [
      TYPE.image,
      0x01,
      0x02,
      0x03,
      0x04,
      0x08,
      0x00,
      7,
    ]);
    expect(parsed.value.sublist(8), [0xE5, 0x9B, 0xBE, 0x2E, 0x70, 0x6E, 0x67]);
  });

  test('BEGIN_RSP reads status byte and chunk size from value[1..2]', () {
    final sent = <Uint8List>[];
    final session = FileTransferSession(sendL2: (frame) {
      sent.add(frame);
      return sent.length - 1;
    });
    session.send(TYPE.raw, Uint8List.fromList([1, 2, 3, 4]), 'a.bin');

    session.onL2Frame(buildL2Frame(BleCmdFileTransferKey.beginRsp,
        Uint8List.fromList([0x00, 0x08, 0x00])));

    expect(session.chunkSize, 2048);
    expect(session.state, L2State.transferring);
  });

  test('BEGIN_RSP nonzero status reports an error and sends ABORT', () {
    final sent = <Uint8List>[];
    String? error;
    final session = FileTransferSession(
      sendL2: (frame) {
        sent.add(frame);
        return sent.length - 1;
      },
      onError: (reason) => error = reason,
    );
    session.send(TYPE.raw, Uint8List.fromList([1]), 'a.bin');

    session.onL2Frame(buildL2Frame(BleCmdFileTransferKey.beginRsp,
        Uint8List.fromList([0x01, 0x08, 0x00])));

    expect(error, contains('设备忙'));
    expect(parseL2Frame(sent.last)!.key, BleCmdFileTransferKey.abort);
    expect(session.state, L2State.idle);
  });

  test('DATA progress advances only after matching L1 ACK', () {
    final sent = <Uint8List>[];
    final progress = <int>[];
    final session = FileTransferSession(
      sendL2: (frame) {
        sent.add(frame);
        return sent.length - 1;
      },
      onProgress: (sentBytes, total) => progress.add(sentBytes),
    );
    session.send(TYPE.raw, Uint8List.fromList([1, 2, 3]), 'a.bin');
    session.onL2Frame(buildL2Frame(BleCmdFileTransferKey.beginRsp,
        Uint8List.fromList([0x00, 0x08, 0x00])));

    expect(progress, isEmpty);
    session.onL1Ack(1, true);

    expect(progress, [3]);
  });

  test('DATA ACK timeout reports error and sends ABORT', () {
    final timer = FakeTimerProvider();
    final sent = <Uint8List>[];
    String? error;
    final session = FileTransferSession(
      sendL2: (frame) {
        sent.add(frame);
        return sent.length - 1;
      },
      onError: (reason) => error = reason,
      timerProvider: timer,
    );
    session.send(TYPE.raw, Uint8List.fromList([1, 2, 3]), 'a.bin');
    session.onL2Frame(buildL2Frame(BleCmdFileTransferKey.beginRsp,
        Uint8List.fromList([0x00, 0x08, 0x00])));

    timer.fire();

    expect(error, contains('DATA ACK'));
    expect(parseL2Frame(sent.last)!.key, BleCmdFileTransferKey.abort);
    expect(session.state, L2State.idle);
  });
}
