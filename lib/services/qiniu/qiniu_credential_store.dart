import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'qiniu_config.dart';

class QiniuCredentialStore {
  static const storageKey = 'honeybox.qiniu.config.v1';
  final FlutterSecureStorage storage;
  const QiniuCredentialStore(
      {this.storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(
          keyCipherAlgorithm:
              KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
          storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
        ),
      )});

  Future<QiniuConfig?> load() async {
    try {
      final value = await storage.read(key: storageKey);
      if (value == null) return null;
      final json = jsonDecode(value) as Map<String, dynamic>;
      if (json['version'] != 1) throw const FormatException();
      final config = QiniuConfig.fromJson(json);
      if (config.validationError() != null) throw const FormatException();
      return config;
    } catch (_) {
      throw StateError('无法读取本机七牛配置，请重试或清除后重新配置');
    }
  }

  Future<void> save(QiniuConfig config) async {
    final error = config.validationError();
    if (error != null) throw FormatException(error);
    try {
      await storage.write(
          key: storageKey, value: jsonEncode(config.secureJson()));
    } catch (_) {
      throw StateError('安全存储写入失败，配置未保存');
    }
  }

  Future<void> clear() async {
    try {
      await storage.delete(key: storageKey);
    } catch (_) {
      throw StateError('安全存储清除失败，请重试');
    }
  }
}
