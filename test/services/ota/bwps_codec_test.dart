import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/bwps_codec.dart';

void main() {
  Uint8List bytes(List<int> v) => Uint8List.fromList(v);
  test('CRC and complete request vectors', () {
    expect(crc16Arc(bytes(ascii.encode('123456789'))), 0xbb3d);
    expect(buildBatteryRequest(), orderedEquals([0xab, 0, 0, 5, 0xca, 0xa1, 0, 0, 0x58, 0, 0x18, 0, 0]));
  });
  test('responses, ACK and invalid frames', () {
    Uint8List frame(int status, int percent) {
      final payload = bytes([0x58, 0, 0x19, 0, 2, status, percent]);
      final crc = crc16Arc(payload);
      return bytes([0xab, 0x40, 0, 7, crc >> 8, crc & 255, 0, 1, ...payload]);
    }
    final first = frame(1, 85);
    expect(first, orderedEquals([0xab, 0x40, 0, 7, 0x68, 0xa4, 0, 1, 0x58, 0, 0x19, 0, 2, 1, 85]));
    for (final pair in [[1, 85], [2, 100]]) {
      final parsed = parseFrame(frame(pair[0], pair[1]));
      expect(parsed.version, 0x40); expect(parsed.seq, 1);
      final battery = parseBatteryResponse(parsed.payload)!;
      expect(battery.chargerStatus, pair[0]); expect(battery.percent, pair[1]);
    }
    expect(parseBatteryResponse(parseFrame(bytes([0xab, 0x10, 0, 0, 0, 0, 0, 0])).payload), isNull);
    expect(parseBatteryResponse(parseFrame(frame(3, 10)).payload), isNull);
    expect(parseBatteryResponse(parseFrame(frame(1, 101)).payload), isNull);
    final full = parseBatteryResponse(parseFrame(frame(2, 100)).payload)!;
    expect(full.chargerStatus, 2);
    first[4] ^= 1;
    expect(() => parseFrame(first), throwsFormatException);
    expect(() => parseFrame(bytes([0xab])), throwsFormatException);
  });
}
