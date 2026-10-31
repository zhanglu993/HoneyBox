import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum RealtekHeaderStatus { pass, block, unknown }

/// Parsed MP sub-bin and image header. Unknown TLVs are retained verbatim.
class RealtekImageHeader {
  final RealtekHeaderStatus status;
  final String reason;
  final Map<int, List<int>> tlvs;
  final int? binId, version, imageId, flashAddress, imageSize, dataLength;
  final String? partNumber;
  final int? icType, secureVersion, controlFlags, crc16, payloadLength;
  final int? commitId, exeBase, loadBase, loadLength, imageBase;
  final String? customerName;
  final List<int>? uuid, imageSha256;
  final bool? sha256Valid;

  RealtekImageHeader._(this.status, this.reason,
      {this.tlvs = const {},
      this.binId,
      this.version,
      this.imageId,
      this.flashAddress,
      this.imageSize,
      this.dataLength,
      this.partNumber,
      this.icType,
      this.secureVersion,
      this.controlFlags,
      this.crc16,
      this.payloadLength,
      this.commitId,
      this.customerName,
      this.uuid,
      this.imageSha256,
      this.sha256Valid,
      this.exeBase,
      this.loadBase,
      this.loadLength,
      this.imageBase});

  Map<int, List<int>> get unknownTlvs =>
      Map.unmodifiable(Map.fromEntries(tlvs.entries.where((e) => !{
            1,
            2,
            3,
            4,
            0xfe,
            0x11,
            0x12,
            0x13,
            0x14,
            0x15,
            0x16
          }.contains(e.key))));

  static RealtekImageHeader parse(Uint8List bytes) {
    RealtekImageHeader fail(RealtekHeaderStatus s, String message) =>
        RealtekImageHeader._(s, message);
    if (bytes.length < 2 || bytes[0] != 1 || bytes[1] != 0) {
      return fail(RealtekHeaderStatus.unknown, '未识别的 MP 头');
    }
    if (bytes.length < 512) return fail(RealtekHeaderStatus.block, 'MP 头截断');
    final data = ByteData.sublistView(bytes);
    final entries = <int, List<int>>{};
    var p = 0;
    var terminated = false;
    while (p + 2 <= 512) {
      final id = data.getUint16(p, Endian.little);
      if (id == 0) {
        terminated = true;
        break;
      }
      if (p + 3 > 512) return fail(RealtekHeaderStatus.block, 'TLV 头截断');
      final length = bytes[p + 2];
      if (p + 3 + length > 512 || entries.containsKey(id)) {
        return fail(RealtekHeaderStatus.block, 'TLV 长度越界或字段重复: $id');
      }
      entries[id] = List.unmodifiable(bytes.sublist(p + 3, p + 3 + length));
      p += 3 + length;
    }
    if (!terminated) return fail(RealtekHeaderStatus.block, 'TLV 结束标记缺失');
    const lengths = {
      1: 2,
      2: 4,
      3: 32,
      4: 4,
      0xfe: 1,
      0x11: 1,
      0x12: 2,
      0x13: 4,
      0x14: 4,
      0x15: 1,
      0x16: 4
    };
    for (final e in lengths.entries) {
      if (entries[e.key]?.length != e.value)
        return fail(RealtekHeaderStatus.block, 'TLV 字段缺失或长度错误: ${e.key}');
    }
    int number(int id) {
      var n = 0;
      final v = entries[id]!;
      for (var i = 0; i < v.length; i++) {
        n |= v[i] << (8 * i);
      }
      return n;
    }

    String asciiField(List<int> b) =>
        ascii.decode(b.takeWhile((v) => v != 0).toList(), allowInvalid: true);
    final bin = number(1),
        version = number(2),
        len = number(4),
        imageSize = number(0x14);
    final id = number(0x12),
        flash = number(0x13),
        part = asciiField(entries[3]!);
    if (len != imageSize || imageSize != bytes.length - 512)
      return fail(RealtekHeaderStatus.block, 'DataLength、ImageSize 与文件长度不一致');
    if (imageSize < 1024) return fail(RealtekHeaderStatus.block, '镜像头截断');
    const o = 512;
    final ic = bytes[o],
        secure = bytes[o + 1],
        flags = data.getUint16(o + 2, Endian.little);
    final imageId = data.getUint16(o + 4, Endian.little),
        crc = data.getUint16(o + 6, Endian.little);
    final payload = data.getUint32(o + 8, Endian.little);
    final imageVersion = data.getUint32(o + 0x60, Endian.little);
    final imageUuid = bytes.sublist(o + 12, o + 28);
    if (payload + 1024 != imageSize)
      return fail(RealtekHeaderStatus.block, 'payload_len 与 ImageSize 不一致');
    if (imageId != id) return fail(RealtekHeaderStatus.block, 'ImageID 不一致');
    if (version != number(0x16) || version != imageVersion)
      return fail(RealtekHeaderStatus.block, '镜像版本不一致');
    const uuids = {
      9: [
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
      ],
      5: [
        0x6d,
        0x67,
        0xde,
        0xf1,
        0x3e,
        0x33,
        0xe8,
        0x11,
        0xb1,
        0x02,
        0x4d,
        0x2d,
        0xf4,
        0x0c,
        0xde,
        0x01
      ]
    };
    const parts = {9: 'RTL8762D', 5: 'RTL8762C'};
    if (!parts.containsKey(ic)) {
      return fail(
          parts.containsValue(part)
              ? RealtekHeaderStatus.block
              : RealtekHeaderStatus.unknown,
          parts.containsValue(part)
              ? 'PartNumber 与 ic_type 不一致'
              : '未识别的 ic_type: $ic');
    }
    if (parts[ic] != part)
      return fail(RealtekHeaderStatus.block, 'PartNumber 与 ic_type 不一致');
    if (!ListEquality.equal(imageUuid, uuids[ic]!))
      return fail(RealtekHeaderStatus.block, 'UUID 与 ic_type 不一致');
    // 出处：固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核：
    // 无 RSA；crc16 非零使用 CRC16，否则 SHA-256；真实 S200 构建均为
    // crc16=0、SHA-256。DFU START 仅检查 ic_type=9 和 image_id 范围，
    // RTK DFU 不检查版本或防回滚，secure_version 固定为 0。
    final stored = bytes.sublist(o + 372, o + 404);
    bool? valid;
    if (crc == 0) {
      final digest = sha256.convert([
        ...bytes.sublist(o + 12, o + 372),
        ...bytes.sublist(o + 404, o + 752),
        ...bytes.sublist(o + 1008, o + 1024 + payload)
      ]).bytes;
      valid = ListEquality.equal(stored, digest);
    }
    final status = crc != 0
        ? RealtekHeaderStatus.unknown
        : valid!
            ? RealtekHeaderStatus.pass
            : RealtekHeaderStatus.block;
    return RealtekImageHeader._(
        status,
        crc != 0
            ? 'CRC16 模式暂不支持'
            : valid!
                ? 'SHA-256 校验通过'
                : 'SHA-256 不匹配',
        tlvs: Map.unmodifiable(entries),
        binId: bin,
        version: version,
        imageId: id,
        flashAddress: flash,
        imageSize: imageSize,
        dataLength: len,
        partNumber: part,
        icType: ic,
        secureVersion: secure,
        controlFlags: flags,
        crc16: crc,
        payloadLength: payload,
        commitId: data.getUint32(o + 0x64, Endian.little),
        exeBase: data.getUint32(o + 28, Endian.little),
        loadBase: data.getUint32(o + 32, Endian.little),
        loadLength: data.getUint32(o + 36, Endian.little),
        imageBase: data.getUint32(o + 40, Endian.little),
        customerName: asciiField(bytes.sublist(o + 0x68, o + 0x70)),
        uuid: List.unmodifiable(imageUuid),
        imageSha256: List.unmodifiable(stored),
        sha256Valid: valid);
  }
}

class ListEquality {
  static bool equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
