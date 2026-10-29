import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'qiniu_config.dart';

class QiniuSigner {
  final QiniuConfig config;
  QiniuSigner(this.config);
  String _sign(String data) =>
      base64Url.encode(Hmac(sha1, utf8.encode(config.secretKey))
          .convert(utf8.encode(data))
          .bytes);

  String uploadToken(String key, int size, {int? deadline}) {
    if (utf8.encode('${config.bucket}:$key').length > 750 || key.isEmpty) {
      throw const FormatException('文件路径过长或为空');
    }
    final policy = base64Url.encode(utf8.encode(jsonEncode({
      'scope': '${config.bucket}:$key',
      'deadline':
          deadline ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      'insertOnly': 1,
      'fsizeLimit': size,
    })));
    return '${config.accessKey}:${_sign(policy)}:$policy';
  }

  /// Qiniu v2 signing. The caller sends exactly the same Content-Type and headers.
  String managementToken(String method, Uri uri,
      {String contentType = 'application/x-www-form-urlencoded',
      String body = '',
      String? timestamp}) {
    final target =
        '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    var data =
        '$method $target\nHost: ${uri.authority}\nContent-Type: $contentType\n';
    if (timestamp != null) data += 'X-Qiniu-Date: $timestamp\n';
    data += '\n';
    if (contentType != 'application/octet-stream') data += body;
    return 'Qiniu ${config.accessKey}:${_sign(data)}';
  }

  Uri downloadUri(String key, {int? deadline}) {
    final error = config.validationError(forDownload: true);
    if (error != null) throw FormatException(error);
    final domain = Uri.parse(config.downloadDomain);
    final path = key.split('/').map(Uri.encodeComponent).join('/');
    final url = '${domain.scheme}://${domain.authority}/$path';
    if (!config.privateBucket) return Uri.parse(url);
    final signed =
        '$url?e=${deadline ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600}';
    return Uri.parse('$signed&token=${config.accessKey}:${_sign(signed)}');
  }
}
