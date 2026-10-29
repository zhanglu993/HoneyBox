import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/qiniu/qiniu_config.dart';
import 'package:honeybox/services/qiniu/qiniu_signer.dart';
import 'package:honeybox/services/qiniu/qiniu_storage_service.dart';
import 'package:honeybox/services/qiniu/qiniu_transfer.dart';

void main() {
  test('删除请求对 bucket 和文件名编码并使用管理凭证', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    const config =
        QiniuConfig(accessKey: 'ak', secretKey: 'sk', bucket: 'test');
    final service = QiniuStorageService(managementEndpoint: endpoint);
    final requests = server.first.then((request) async {
      final uri = endpoint.replace(path: request.uri.path);
      expect(request.method, 'POST');
      expect(request.uri.path,
          '/delete/${base64Url.encode(utf8.encode('test:资料/a b.txt'))}');
      final date = request.headers.value('x-qiniu-date');
      expect(date, isNotNull);
      expect(request.headers.value('authorization'),
          QiniuSigner(config).managementToken('POST', uri, timestamp: date));
      await request.drain<void>();
      request.response.statusCode = 200;
      await request.response.close();
    });
    await service.delete(config, '资料/a b.txt', QiniuTransfer());
    await requests;
  });

  test('远端拒绝删除时返回错误', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final service = QiniuStorageService(
        managementEndpoint: Uri.parse('http://127.0.0.1:${server.port}'));
    final request = server.first.then((request) async {
      await request.drain<void>();
      request.response.statusCode = 403;
      await request.response.close();
    });
    await expectLater(
        service.delete(
            const QiniuConfig(accessKey: 'ak', secretKey: 'sk', bucket: 'test'),
            'a',
            QiniuTransfer()),
        throwsA(isA<QiniuException>()));
    await request;
  });
}
