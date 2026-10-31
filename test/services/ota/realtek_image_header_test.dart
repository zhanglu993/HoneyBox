import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/realtek_image_header.dart';

Uint8List makeRealtekImage() {
  final bytes = Uint8List(512 + 1024 + 16);
  final d = ByteData.sublistView(bytes);
  var p = 0;
  void tlv(int id, List<int> value) {
    d.setUint16(p, id, Endian.little);
    bytes[p + 2] = value.length;
    bytes.setRange(p + 3, p + 3 + value.length, value);
    p += 3 + value.length;
  }

  List<int> u16(int v) => [v & 255, (v >> 8) & 255];
  List<int> u32(int v) =>
      [v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255];
  tlv(1, u16(0x300));
  tlv(2, u32(3));
  tlv(3, [...'RTL8762D'.codeUnits, ...List.filled(24, 0)]);
  tlv(4, u32(1040));
  tlv(0xfe, [1]);
  tlv(0x11, [1]);
  tlv(0x12, u16(0x2793));
  tlv(0x13, u32(0x82c000));
  tlv(0x14, u32(1040));
  tlv(0x15, [0]);
  tlv(0x16, u32(3));
  tlv(0x22, [2]);
  const o = 512;
  bytes[o] = 9;
  d.setUint16(o + 2, 0x901, Endian.little);
  d.setUint16(o + 4, 0x2793, Endian.little);
  d.setUint32(o + 8, 16, Endian.little);
  bytes.setRange(o + 12, o + 28, [
    0x1d,
    0x6a,
    0x69,
    0xf1,
    0x2f,
    0x38,
    0xea,
    0x11,
    0x82,
    0xa7,
    0x67,
    0x37,
    0x0a,
    0x3c,
    0xa3,
    0x2e
  ]);
  d.setUint32(o + 0x60, 3, Endian.little);
  d.setUint32(o + 0x64, 0xded9c2aa, Endian.little);
  bytes.setRange(o + 0x68, o + 0x70, 'S200_62#'.codeUnits);
  for (var i = 0; i < 16; i++) {
    bytes[o + 1024 + i] = i;
  }
  final digest = sha256.convert([
    ...bytes.sublist(o + 12, o + 372),
    ...bytes.sublist(o + 404, o + 752),
    ...bytes.sublist(o + 1008)
  ]).bytes;
  bytes.setRange(o + 372, o + 404, digest);
  return bytes;
}

void main() {
  test('valid image', () {
    final r = RealtekImageHeader.parse(makeRealtekImage());
    expect(r.status, RealtekHeaderStatus.pass);
    expect(r.imageId, 0x2793);
    expect(r.unknownTlvs[0x22], [2]);
  });
  for (final entry in <String, void Function(Uint8List)>{
    'sha mismatch': (b) => b.last ^= 1,
    'length mismatch': (b) =>
        ByteData.sublistView(b).setUint32(512 + 8, 15, Endian.little),
    'part number mismatch': (b) => b[512] = 5,
    'image id mismatch': (b) => b[512 + 4] ^= 1,
  }.entries) {
    test(entry.key, () {
      final b = makeRealtekImage();
      entry.value(b);
      expect(RealtekImageHeader.parse(b).status, RealtekHeaderStatus.block);
    });
  }
  test('empty, truncated and unknown', () {
    expect(RealtekImageHeader.parse(Uint8List(0)).status,
        RealtekHeaderStatus.unknown);
    expect(RealtekImageHeader.parse(makeRealtekImage().sublist(0, 600)).status,
        RealtekHeaderStatus.block);
    expect(RealtekImageHeader.parse(Uint8List(1600)).status,
        RealtekHeaderStatus.unknown);
  });
  test('CRC16 mode is unknown', () {
    final b = makeRealtekImage();
    b[518] = 1;
    expect(RealtekImageHeader.parse(b).status, RealtekHeaderStatus.unknown);
  });
  final real = File('output/ota-real-fw/real.bin');
  test('real firmware', () async {
    final bytes = await real.readAsBytes();
    final r = RealtekImageHeader.parse(bytes);
    expect(r.status, RealtekHeaderStatus.pass);
    expect(r.icType, 9);
    expect(r.imageId, 0x2793);
    expect(r.version, 0x30000010);
    expect(r.flashAddress, 0x82c000);
    expect(r.imageSize, 0x50ec8);
    expect(r.sha256Valid, isTrue);
    expect(sha256.convert(bytes).toString(),
        '6c0e2a72ba170866ce31ba9cd3b62eeee2cb852b7720f73275ea7d7e4bb50e28');
  }, skip: !real.existsSync() ? 'real firmware not available' : false);
}
