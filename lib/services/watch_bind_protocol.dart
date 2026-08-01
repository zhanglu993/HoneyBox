import 'dart:math';
import 'dart:typed_data';

import 'ble_cmd_registry.dart';

enum WatchBindResult { success, failed }

class WatchBindProtocol {
  WatchBindProtocol._();

  // CMD / key 值集中在 `ble_cmd_registry.dart`:CMD 字节走 [BleCmd.watchBind],
  // 子命令 key 走 [BleCmdWatchBindKey]。
  static const int userIdLength = 32;

  static final Uint8List processUserId = generateUserId();

  static Uint8List generateUserId() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(userIdLength, (_) => random.nextInt(256)),
    );
  }

  static Uint8List buildRequest(Uint8List userId) {
    if (userId.length != userIdLength) {
      throw ArgumentError.value(
        userId.length,
        'userId.length',
        'Watch bind user ID must be exactly $userIdLength bytes',
      );
    }

    final frame = Uint8List(5 + userIdLength);
    frame[0] = BleCmd.watchBind;
    frame[1] = 0x00;
    frame[2] = BleCmdWatchBindKey.bindRequest;
    frame[3] = 0x00;
    frame[4] = userIdLength;
    frame.setRange(5, frame.length, userId);
    return frame;
  }

  static WatchBindResult? parseResponse(Uint8List frame) {
    if (frame.length != 6 ||
        frame[0] != BleCmd.watchBind ||
        frame[1] != 0x00 ||
        frame[2] != BleCmdWatchBindKey.bindResponse ||
        frame[3] != 0x00 ||
        frame[4] != 0x01) {
      return null;
    }
    return frame[5] == 0x00 ? WatchBindResult.success : WatchBindResult.failed;
  }

  static String toHex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
