import 'dart:typed_data';

import 'ble_cmd_registry.dart';

abstract class WatchHealthKey {
  static const int requestData = BleCmdWatchHealthKey.requestData;
  static const int sportData = BleCmdWatchHealthKey.sportData;
  static const int sleepData = BleCmdWatchHealthKey.sleepData;
  static const int more = BleCmdWatchHealthKey.more;
  static const int syncStart = BleCmdWatchHealthKey.syncStart;
  static const int syncEnd = BleCmdWatchHealthKey.syncEnd;
  static const int heartRateData = BleCmdWatchHealthKey.heartRateData;
}

enum WatchHealthMarker { syncStart, more, syncEnd }

class WatchSportItem {
  const WatchSportItem({
    required this.offset,
    required this.mode,
    required this.steps,
    required this.activeMinutes,
    required this.caloriesMilliKcal,
    required this.distanceMeters,
  });

  final int offset;
  final int mode;
  final int steps;
  final int activeMinutes;
  final int caloriesMilliKcal;
  final int distanceMeters;
}

class WatchSportData {
  const WatchSportData(this.date, this.items);

  final DateTime date;
  final List<WatchSportItem> items;
}

class WatchSleepItem {
  const WatchSleepItem({required this.minutes, required this.mode});

  final int minutes;
  final int mode;
}

class WatchSleepData {
  const WatchSleepData(this.date, this.items);

  final DateTime date;
  final List<WatchSleepItem> items;
}

class WatchHeartRateItem {
  const WatchHeartRateItem({required this.seconds, required this.bpm});

  final int seconds;
  final int bpm;
}

class WatchHeartRateData {
  const WatchHeartRateData(this.date, this.items);

  final DateTime date;
  final List<WatchHeartRateItem> items;
}

class WatchHealthProtocol {
  WatchHealthProtocol._();

  static Uint8List buildRequest() => Uint8List.fromList([
        BleCmd.watchHealth,
        0x00,
        WatchHealthKey.requestData,
        0x00,
        0x00,
      ]);

  static List<Object> parseFrame(Uint8List frame) {
    if (frame.length < 2 ||
        frame[0] != BleCmd.watchHealth ||
        frame[1] != 0x00) {
      return const [];
    }

    final events = <Object>[];
    var offset = 2;
    while (offset < frame.length) {
      if (offset + 3 > frame.length) {
        throw const FormatException('Incomplete health key header');
      }
      final key = frame[offset];
      final valueLength = _readU16(frame, offset + 1);
      offset += 3;
      if (offset + valueLength > frame.length) {
        throw const FormatException('Health key value exceeds frame');
      }
      final value = Uint8List.sublistView(frame, offset, offset + valueLength);
      offset += valueLength;

      final event = switch (key) {
        WatchHealthKey.sportData => _parseSport(value),
        WatchHealthKey.sleepData => _parseSleep(value),
        WatchHealthKey.heartRateData => _parseHeartRate(value),
        WatchHealthKey.syncStart => _emptyMarker(
            value,
            WatchHealthMarker.syncStart,
          ),
        WatchHealthKey.more => _emptyMarker(value, WatchHealthMarker.more),
        WatchHealthKey.syncEnd => _emptyMarker(
            value,
            WatchHealthMarker.syncEnd,
          ),
        _ => null,
      };
      if (event != null) events.add(event);
    }
    return events;
  }

  static WatchSportData _parseSport(Uint8List value) {
    if (value.length < 4) {
      throw const FormatException('Sport data header is incomplete');
    }
    final date = _parseDate(value, 0);
    final count = value[3];
    if (value.length != 4 + count * 8) {
      throw const FormatException('Sport item count does not match length');
    }
    final items = <WatchSportItem>[];
    for (var i = 0; i < count; i++) {
      final packed = _readBigInt(value, 4 + i * 8, 8);
      items.add(WatchSportItem(
        offset: _bits(packed, 53, 11),
        mode: _bits(packed, 51, 2),
        steps: _bits(packed, 39, 12),
        activeMinutes: _bits(packed, 35, 4),
        caloriesMilliKcal: _bits(packed, 16, 19),
        distanceMeters: _bits(packed, 0, 16),
      ));
    }
    return WatchSportData(date, List.unmodifiable(items));
  }

  static WatchSleepData _parseSleep(Uint8List value) {
    if (value.length < 4) {
      throw const FormatException('Sleep data header is incomplete');
    }
    final date = _parseDate(value, 0);
    final count = _readU16(value, 2);
    if (value.length != 4 + count * 4) {
      throw const FormatException('Sleep item count does not match length');
    }
    final items = <WatchSleepItem>[];
    for (var i = 0; i < count; i++) {
      final itemOffset = 4 + i * 4;
      final minutes = _readU16(value, itemOffset);
      if (minutes > 1439) {
        throw const FormatException('Sleep timestamp is invalid');
      }
      items.add(WatchSleepItem(
        minutes: minutes,
        mode: value[itemOffset + 3] & 0x0F,
      ));
    }
    return WatchSleepData(date, List.unmodifiable(items));
  }

  static WatchHeartRateData _parseHeartRate(Uint8List value) {
    if (value.length < 4) {
      throw const FormatException('Heart-rate data header is incomplete');
    }
    final date = _parseDate(value, 0);
    final count = _readU16(value, 2);
    if (value.length != 4 + count * 4) {
      throw const FormatException(
          'Heart-rate item count does not match length');
    }
    final items = <WatchHeartRateItem>[];
    for (var i = 0; i < count; i++) {
      final itemOffset = 4 + i * 4;
      final seconds = (value[itemOffset] << 16) |
          (value[itemOffset + 1] << 8) |
          value[itemOffset + 2];
      if (seconds > 86399) {
        throw const FormatException('Heart-rate timestamp is invalid');
      }
      items.add(WatchHeartRateItem(
        seconds: seconds,
        bpm: value[itemOffset + 3],
      ));
    }
    return WatchHeartRateData(date, List.unmodifiable(items));
  }

  static Object _emptyMarker(Uint8List value, WatchHealthMarker marker) {
    if (value.isNotEmpty) {
      throw const FormatException('Health marker value must be empty');
    }
    return marker;
  }

  static DateTime _parseDate(Uint8List bytes, int offset) {
    final packed = _readU16(bytes, offset);
    final year = 2000 + ((packed >> 9) & 0x3F);
    final month = (packed >> 5) & 0x0F;
    final day = packed & 0x1F;
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      throw const FormatException('Health record date is invalid');
    }
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw const FormatException('Health record date is invalid');
    }
    return date;
  }

  static int _readU16(Uint8List bytes, int offset) =>
      (bytes[offset] << 8) | bytes[offset + 1];

  static BigInt _readBigInt(Uint8List bytes, int offset, int length) {
    var value = BigInt.zero;
    for (var i = 0; i < length; i++) {
      value = (value << 8) | BigInt.from(bytes[offset + i]);
    }
    return value;
  }

  static int _bits(BigInt value, int shift, int width) =>
      ((value >> shift) & ((BigInt.one << width) - BigInt.one)).toInt();
}
