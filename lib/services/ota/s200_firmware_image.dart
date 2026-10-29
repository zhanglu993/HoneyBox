import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// An S200 APP image whose structure matches the 400 KiB flash layout.
/// Structural checks do not prove a device's compatibility or image signature.
class S200FirmwareImage {
  static const _headerSize = 1024;
  static const _packHeaderSize = 512;
  static const _appAddress = 0x82c000;
  static const _capacity = 0x64000;

  final Uint8List imageBytes;
  final int version;
  final bool wasPackaged;
  final String sha256;
  final String sourceSha256;

  S200FirmwareImage._(this.imageBytes, this.version, this.wasPackaged,
      this.sha256, this.sourceSha256);

  static S200FirmwareImage parse(Uint8List source) {
    const marker = [1, 0, 2, 0, 3, 2, 0, 4];
    const part = [82, 84, 76, 56, 55, 54, 50, 68]; // RTL8762D
    final packaged = source.length >= _packHeaderSize &&
        _matches(source, 0, marker) &&
        _matches(source, 15, part);
    final offset = packaged ? _packHeaderSize : 0;
    final length = source.length - offset;
    if (length < _headerSize || length > _capacity || length % 4 != 0) {
      throw const FormatException('APP 固件长度不符合 S200 布局');
    }
    final data = ByteData.sublistView(source, offset);
    final flags = data.getUint16(2, Endian.little);
    if (data.getUint8(0) != 9 ||
        data.getUint16(4, Endian.little) != 0x2793 ||
        flags >> 13 != 0 ||
        data.getUint32(8, Endian.little) + _headerSize != length ||
        data.getUint32(40, Endian.little) != _appAddress) {
      throw const FormatException('不是受支持的 S200 APP 固件');
    }
    final version = data.getUint32(96, Endian.little);
    if (packaged &&
        ByteData.sublistView(source).getUint32(8, Endian.little) != version) {
      throw const FormatException('固件包版本与 APP 镜像不一致');
    }
    final image =
        Uint8List.fromList(source.sublist(offset)).asUnmodifiableView();
    return S200FirmwareImage._(
        image,
        version,
        packaged,
        crypto.sha256.convert(image).toString(),
        crypto.sha256.convert(source).toString());
  }

  static bool _matches(Uint8List data, int offset, List<int> expected) {
    for (var i = 0; i < expected.length; i++) {
      if (data[offset + i] != expected[i]) return false;
    }
    return true;
  }
}
