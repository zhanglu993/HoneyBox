import 'dart:convert';
import 'dart:typed_data';

import 'ble_cmd_registry.dart';

/// BLE protocol for forwarding phone notifications to the watch.
///
/// Frame format (command channel L2):
///   [0x05, 0x00, subCmd, 0x00, len, data...]
///
/// CMD / key 值集中在 `ble_cmd_registry.dart`:CMD 字节走 [BleCmd.watchNotification],
/// 子命令 key 走 [BleCmdWatchNotificationKey]。
///
/// Current sub-commands:
///   0x01 — Push notification (from phone → watch)
///   0x02 — App list / filter config (phone → watch)   ← 尚未实现
///   0x03 — Master enable (phone → watch)              ← 尚未实现
///
/// Notification push frame (subCmd=0x01):
///   Bytes 5+: packed app-name|title|message fields
///   Each field: [len_byte][utf8_data...], 0x00 terminator for empty
class WatchNotificationProtocol {
  WatchNotificationProtocol._();

  /// Build an L2 frame to push a notification to the watch.
  ///
  /// [appName] — display name of the source app (e.g. "WeChat")
  /// [title] — notification title or contact name
  /// [message] — notification body text
  static Uint8List buildNotification({
    required String appName,
    required String title,
    required String message,
  }) {
    final appBytes = _encodeField(appName);
    final titleBytes = _encodeField(title);
    final msgBytes = _encodeField(message);
    final totalLength = appBytes.length + titleBytes.length + msgBytes.length;

    final frame = Uint8List(5 + totalLength);
    frame[0] = BleCmd.watchNotification;
    frame[1] = 0x00;
    frame[2] = BleCmdWatchNotificationKey.pushNotification;
    frame[3] = 0x00;
    frame[4] = totalLength;
    var offset = 5;
    frame.setRange(offset, offset + appBytes.length, appBytes);
    offset += appBytes.length;
    frame.setRange(offset, offset + titleBytes.length, titleBytes);
    offset += titleBytes.length;
    frame.setRange(offset, offset + msgBytes.length, msgBytes);
    return frame;
  }

  /// Encode a text field as [len_byte][utf8...].
  /// Uses proper UTF-8 encoding (not Dart's internal UTF-16 codeUnits).
  static Uint8List _encodeField(String text) {
    if (text.isEmpty) return Uint8List.fromList([0x00]);
    final bytes = utf8.encode(text);
    final clamped = bytes.length > 255 ? bytes.sublist(0, 255) : bytes;
    final result = Uint8List(1 + clamped.length);
    result[0] = clamped.length;
    result.setRange(1, 1 + clamped.length, clamped);
    return result;
  }
}
