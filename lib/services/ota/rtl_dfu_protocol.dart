import 'dart:typed_data';

/// Capabilities returned by the RTL OTA service's FFF1 characteristic.
class RtlDfuCapabilities {
  final int icType;
  final int protocolVersion;
  final int secureVersion;
  final int flags;
  final int bufferSize;
  final int temporaryCapacity;
  final int imageIndicator;

  const RtlDfuCapabilities._(
      this.icType,
      this.protocolVersion,
      this.secureVersion,
      this.flags,
      this.bufferSize,
      this.temporaryCapacity,
      this.imageIndicator);

  bool get aes => flags & 2 != 0;
  bool get bufferCheck => flags & 1 != 0;

  static RtlDfuCapabilities parse(Uint8List data) {
    if (data.length < 12) {
      throw const FormatException('OTA capability response is truncated');
    }
    final bytes = ByteData.sublistView(data);
    return RtlDfuCapabilities._(
        data[0],
        data[1],
        data[2],
        data[3],
        bytes.getUint16(4, Endian.little),
        data[6] * 4096,
        bytes.getUint32(8, Endian.little));
  }
}

/// Decoding helpers for the RTL DFU control point and block checksums.
class RtlDfuProtocol {
  static ByteData _response(Uint8List data, int opcode, int length) {
    if (data.length != length ||
        data[0] != 0x10 ||
        data[1] != opcode ||
        data[2] != 1) {
      throw FormatException('Invalid or rejected DFU response for $opcode');
    }
    return ByteData.sublistView(data);
  }

  static ({int version, int offset}) targetInfo(Uint8List data) {
    final bytes = _response(data, 0x06, 11);
    return (
      version: bytes.getUint32(3, Endian.little),
      offset: bytes.getUint32(7, Endian.little)
    );
  }

  static ({int size, int mtu}) bufferInfo(Uint8List data) {
    final bytes = _response(data, 0x09, 7);
    return (
      size: bytes.getUint16(3, Endian.little),
      mtu: bytes.getUint16(5, Endian.little)
    );
  }

  static int blockChecksum(Uint8List data) {
    if (data.length.isOdd) {
      throw const FormatException('DFU block length must be even');
    }
    var crc = 0;
    for (var i = 0; i < data.length; i += 2) {
      crc ^= (data[i] << 8) | data[i + 1];
    }
    return crc;
  }
}
