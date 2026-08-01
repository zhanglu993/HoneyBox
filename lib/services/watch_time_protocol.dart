import 'dart:typed_data';

import 'ble_cmd_registry.dart';

/// Watch time sync (CMD 0x02) frame builder.
///
/// CMD / key 值集中在 `ble_cmd_registry.dart`:CMD 字节走 [BleCmd.watchTime],
/// 子命令 key 走 [BleCmdWatchTimeKey]。
class WatchTimeProtocol {
  WatchTimeProtocol._();

  static const int minimumYear = 2000;
  static const int maximumYear = 2063;

  static Uint8List buildSetTime(DateTime localTime) {
    if (localTime.year < minimumYear || localTime.year > maximumYear) {
      throw ArgumentError.value(
        localTime.year,
        'localTime.year',
        'Watch time year must be between $minimumYear and $maximumYear',
      );
    }

    final packed = ((localTime.year - minimumYear) << 26) |
        (localTime.month << 22) |
        (localTime.day << 17) |
        (localTime.hour << 12) |
        (localTime.minute << 6) |
        localTime.second;

    return Uint8List.fromList([
      BleCmd.watchTime,
      0x00,
      BleCmdWatchTimeKey.setTime,
      0x00,
      0x04,
      (packed >> 24) & 0xFF,
      (packed >> 16) & 0xFF,
      (packed >> 8) & 0xFF,
      packed & 0xFF,
    ]);
  }
}
