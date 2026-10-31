import 'dart:typed_data';

// 出处：固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核。
int crc16Arc(Uint8List bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xa001 : crc >> 1;
    }
  }
  return crc;
}

Uint8List buildBatteryRequest({int seq = 0}) {
  if (seq < 0 || seq > 0xffff) throw RangeError.range(seq, 0, 0xffff, 'seq');
  final payload = Uint8List.fromList([0x58, 0, 0x18, 0, 0]);
  final crc = crc16Arc(payload);
  return Uint8List.fromList([0xab, 0, 0, payload.length, crc >> 8, crc & 255, seq >> 8, seq & 255, ...payload]);
}

({int version, int seq, Uint8List payload}) parseFrame(Uint8List bytes) {
  if (bytes.length < 8 || bytes[0] != 0xab) throw const FormatException('无效 BWPS 帧头');
  final length = (bytes[2] << 8) | bytes[3];
  if (bytes.length != 8 + length) throw const FormatException('无效 BWPS 帧长度');
  final payload = Uint8List.sublistView(bytes, 8);
  if (crc16Arc(payload) != ((bytes[4] << 8) | bytes[5])) throw const FormatException('BWPS CRC 错误');
  return (version: bytes[1], seq: (bytes[6] << 8) | bytes[7], payload: payload);
}

({int chargerStatus, int percent})? parseBatteryResponse(Uint8List payload) {
  if (payload.length != 7 || payload[0] != 0x58 || payload[1] != 0 ||
      payload[2] != 0x19 || payload[3] != 0 || payload[4] != 2 ||
      payload[5] > 2 || payload[6] > 100) return null;
  return (chargerStatus: payload[5], percent: payload[6]);
}
