import 'dart:typed_data';
import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';

class QiniuException implements Exception {
  final String message;
  final bool retryable;
  const QiniuException(this.message, {this.retryable = false});
  @override
  String toString() => message;
}

class QiniuCancelled extends QiniuException {
  const QiniuCancelled() : super('传输已取消');
}

/// Independent of Flutter and native SDKs. One token per operation.
class QiniuTransfer {
  bool cancelled = false;
  void Function(int done, int total)? onProgress;
  final Set<void Function()> _cancelHooks = {};
  QiniuTransfer({this.onProgress});
  void check() {
    if (cancelled) throw const QiniuCancelled();
  }

  void attach(void Function() hook) {
    check();
    _cancelHooks.add(hook);
  }

  void detach(void Function() hook) => _cancelHooks.remove(hook);
  void cancel() {
    cancelled = true;
    for (final hook in _cancelHooks.toList()) {
      hook();
    }
    _cancelHooks.clear();
  }
}

/// Qiniu etag: SHA-1 per 4 MiB block, bounded memory for any file size.
class QiniuEtag {
  static const blockSize = 4 * 1024 * 1024;
  final _buffer = Uint8List(blockSize);
  final _digests = <int>[];
  int _used = 0;
  void add(List<int> bytes) {
    var offset = 0;
    while (offset < bytes.length) {
      final count = math.min(blockSize - _used, bytes.length - offset);
      _buffer.setRange(_used, _used + count, bytes, offset);
      _used += count;
      offset += count;
      if (_used == blockSize) {
        _digests.addAll(sha1.convert(_buffer).bytes);
        _used = 0;
      }
    }
  }

  String finish() {
    if (_used > 0 || _digests.isEmpty) {
      _digests
          .addAll(sha1.convert(Uint8List.sublistView(_buffer, 0, _used)).bytes);
    }
    return base64Url.encode(_digests.length == 20
        ? [0x16, ..._digests]
        : [0x96, ...sha1.convert(_digests).bytes]);
  }
}
