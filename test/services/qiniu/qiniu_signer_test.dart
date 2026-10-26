import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/qiniu/qiniu_config.dart';
import 'package:honeybox/services/qiniu/qiniu_signer.dart';

const config = QiniuConfig(
    accessKey: 'test-ak',
    secretKey: 'test-secret',
    bucket: 'test',
    downloadDomain: 'https://files.example.com');

void main() {
  test('management signature matches independent .NET HMAC vector', () {
    expect(
        QiniuSigner(config).managementToken('GET',
            Uri.parse('https://rsf.qiniuapi.com/list?bucket=test&limit=1')),
        'Qiniu test-ak:PvAdjHtrH9FNRYfkuIoW_Vx2-EM=');
  });
  test(
      'scoped insert-only upload policy has independently calculated signature',
      () {
    final token =
        QiniuSigner(config).uploadToken('a b/中.txt', 123, deadline: 1700000600);
    expect(token, startsWith('test-ak:1_PrsN6GDdiMs-zBIJFHtBVwwEE=:'));
    final policy =
        jsonDecode(utf8.decode(base64Url.decode(token.split(':').last)));
    expect(policy, {
      'scope': 'test:a b/中.txt',
      'deadline': 1700000600,
      'insertOnly': 1,
      'fsizeLimit': 123
    });
  });
  test('private download encodes key exactly once and signs final URL', () {
    expect(
        QiniuSigner(config)
            .downloadUri('a b/中.txt', deadline: 1700000600)
            .toString(),
        'https://files.example.com/a%20b/%E4%B8%AD.txt?e=1700000600&token=test-ak:33bsJpzFeELIgkOPr0feRuQgYXI=');
    final uri = QiniuSigner(config).downloadUri('x%20+#?.bin', deadline: 1);
    expect(uri.pathSegments.last, 'x%20+#?.bin');
  });
  test('configuration rejects insecure/query domains and unsupported regions',
      () {
    expect(config.validationError(), isNull);
    for (final domain in [
      'http://files.test',
      'https://files.test/?token=secret',
      'https://user:password@files.test',
      'https://files.test/path'
    ]) {
      expect(
          QiniuConfig(
                  accessKey: 'ak',
                  secretKey: 'sk',
                  bucket: 'test',
                  downloadDomain: domain)
              .validationError(),
          isNotNull);
    }
    expect(
        const QiniuConfig(
                accessKey: 'ak',
                secretKey: 'sk',
                bucket: 'test',
                region: 'unknown')
            .validationError(),
        isNotNull);
    expect(config.publicJson().toString(), isNot(contains('test-secret')));
    expect(config.publicJson().toString(), isNot(contains('test-ak')));
    expect(config.toString(), isNot(contains('test-secret')));
  });
}
