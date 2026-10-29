import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/qiniu/qiniu_config.dart';
import 'package:honeybox/services/qiniu/qiniu_config_transfer.dart';

void main() {
  const config = QiniuConfig(
    accessKey: 'access',
    secretKey: 'secret',
    bucket: 'my-bucket',
    region: 'z2',
    downloadDomain: 'https://files.example.com',
    prefix: 'captures/',
    privateBucket: false,
  );

  test('exported configuration imports all fields', () {
    final decoded =
        QiniuConfigTransfer.decode(QiniuConfigTransfer.encode(config));
    expect(decoded.secureJson(), config.secureJson());
  });

  test('rejects unsupported versions and invalid fields', () {
    final json = config.secureJson();
    expect(
        () => QiniuConfigTransfer.decode(
            utf8.encode(jsonEncode({...json, 'version': 2}))),
        throwsFormatException);
    expect(
        () => QiniuConfigTransfer.decode(
            utf8.encode(jsonEncode({...json, 'bucket': ''}))),
        throwsFormatException);
    expect(() => QiniuConfigTransfer.decode(utf8.encode('{invalid')),
        throwsFormatException);
  });
}
