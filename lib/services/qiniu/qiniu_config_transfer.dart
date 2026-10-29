import 'dart:convert';
import 'dart:typed_data';

import 'qiniu_config.dart';

/// Portable configuration files contain credentials and must be protected.
class QiniuConfigTransfer {
  static const maxBytes = 64 * 1024;

  static Uint8List encode(QiniuConfig config) {
    final error = config.validationError();
    if (error != null) throw FormatException(error);
    return Uint8List.fromList(utf8.encode(
        const JsonEncoder.withIndent('  ').convert(config.secureJson())));
  }

  static QiniuConfig decode(List<int> bytes) {
    if (bytes.length > maxBytes) throw const FormatException('配置文件过大');
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic> || json['version'] != 1) {
        throw const FormatException('不支持的配置文件');
      }
      final config = QiniuConfig.fromJson(json);
      final error = config.validationError();
      if (error != null) throw FormatException(error);
      return config;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('配置文件格式无效');
    }
  }
}
