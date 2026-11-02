import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// An immutable-by-convention private copy. Its digest identifies bytes; it
/// does not authenticate firmware origin or prove device compatibility.
class FirmwareSnapshot {
  final File file;
  final int sizeBytes;
  final String sha256;
  final Directory _ownedDirectory;

  FirmwareSnapshot._(
      this.file, this.sizeBytes, this.sha256, this._ownedDirectory);

  /// Copies a bounded stream into a uniquely owned private directory.
  /// The caller chooses a platform-appropriate application-private directory.
  static Future<FirmwareSnapshot> importFile({
    required File source,
    required Directory cacheDirectory,
    required int maxBytes,
  }) async {
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    await cacheDirectory.create(recursive: true);
    final owned = await cacheDirectory.createTemp('ota_firmware_');
    final snapshot = File('${owned.path}/firmware.bin');
    IOSink? output;
    try {
      var length = 0;
      output = snapshot.openWrite();
      await for (final chunk in source.openRead()) {
        length += chunk.length;
        if (length > maxBytes) throw const FormatException('固件文件超过大小上限');
        output.add(chunk);
      }
      if (length == 0) throw const FormatException('固件文件为空');
      await output.flush();
      await output.close();
      output = null;
      final digest = await crypto.sha256.bind(snapshot.openRead()).first;
      return FirmwareSnapshot._(snapshot, length, digest.toString(), owned);
    } catch (_) {
      try {
        await output?.close();
      } catch (_) {}
      if (await owned.exists()) await owned.delete(recursive: true);
      rethrow;
    }
  }

  /// Recheck immediately before use; later modification still requires the
  /// caller to control access to the snapshot while SDK reads it.
  Future<bool> verifyUnchanged() async {
    try {
      if (await file.length() != sizeBytes) return false;
      final digest = await crypto.sha256.bind(file.openRead()).first;
      return digest.toString() == sha256;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> delete() async {
    if (await _ownedDirectory.exists()) {
      await _ownedDirectory.delete(recursive: true);
    }
  }
}
