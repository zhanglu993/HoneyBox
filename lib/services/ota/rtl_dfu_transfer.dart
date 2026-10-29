import 'dart:typed_data';

import 'rtl_dfu_protocol.dart';

/// An established DFU connection. Adapters own discovery, notifications and timeouts.
abstract interface class RtlDfuTransport {
  Future<Uint8List> command(int opcode, Uint8List payload);
  Future<void> sendControl(Uint8List data);
  Future<void> sendData(Uint8List data);
}

/// Sends one already validated image and requires device validation before returning.
/// Encryption is supplied by the caller and must preserve byte length.
class RtlDfuTransfer {
  final RtlDfuTransport transport;
  final Uint8List Function(Uint8List) encrypt;

  RtlDfuTransfer(this.transport, this.encrypt);

  Future<void> transfer({
    required Uint8List image,
    required int imageId,
    required int blockSize,
    required int packetSize,
    void Function(int confirmed, int total)? onProgress,
  }) async {
    if (image.length < 12 ||
        image.length.isOdd ||
        imageId < 0 ||
        imageId > 0xffff ||
        blockSize <= 0 ||
        blockSize > 0xffff ||
        blockSize.isOdd ||
        packetSize <= 0) {
      throw ArgumentError('Invalid DFU image or transport parameters');
    }
    Uint8List encrypted(Uint8List source) {
      final result = encrypt(source);
      if (result.length != source.length) {
        throw StateError('Encryption changed the DFU data length');
      }
      return result;
    }

    final header = Uint8List(16)..setRange(0, 12, image);
    _check(await transport.command(0x01, encrypted(header)), 0x01, 3);
    final receive = Uint8List(7)..[0] = 0x02;
    final receiveData = ByteData.sublistView(receive);
    receiveData.setUint16(1, imageId, Endian.little);
    receiveData.setUint32(3, 12, Endian.little);
    await transport.sendControl(receive);

    var offset = 12;
    while (offset < image.length) {
      final end =
          offset + blockSize < image.length ? offset + blockSize : image.length;
      final block = encrypted(Uint8List.fromList(image.sublist(offset, end)));
      for (var start = 0; start < block.length; start += packetSize) {
        final packetEnd = start + packetSize < block.length
            ? start + packetSize
            : block.length;
        await transport
            .sendData(Uint8List.fromList(block.sublist(start, packetEnd)));
      }
      final check = Uint8List(4);
      final checkData = ByteData.sublistView(check);
      checkData.setUint16(0, block.length, Endian.little);
      checkData.setUint16(
          2, RtlDfuProtocol.blockChecksum(block), Endian.little);
      final response = await transport.command(0x0a, check);
      _check(response, 0x0a, 7);
      final confirmed =
          ByteData.sublistView(response).getUint32(3, Endian.little);
      if (confirmed != end) {
        throw const FormatException('Unexpected DFU confirmed offset');
      }
      offset = confirmed;
      onProgress?.call(offset, image.length);
    }
    final id = Uint8List(2);
    ByteData.sublistView(id).setUint16(0, imageId, Endian.little);
    _check(await transport.command(0x03, id), 0x03, 3);
  }

  static void _check(Uint8List data, int opcode, int length) {
    if (data.length != length ||
        data[0] != 0x10 ||
        data[1] != opcode ||
        data[2] != 1) {
      throw FormatException('Invalid or rejected DFU response for $opcode');
    }
  }
}
