import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// RTL8762 transport encryption uses AES-256 ECB on complete blocks.
class Rtl8762Cipher {
  final Uint8List _key;
  Rtl8762Cipher(Uint8List key) : _key = Uint8List.fromList(key) {
    if (key.length != 32) throw ArgumentError('AES-256 key must have 32 bytes');
  }

  Uint8List encrypt(Uint8List data) {
    final result = Uint8List.fromList(data);
    final cipher = AESEngine()..init(true, KeyParameter(_key));
    for (var offset = 0; offset + 16 <= data.length; offset += 16) {
      cipher.processBlock(data, offset, result, offset);
    }
    return result;
  }
}
