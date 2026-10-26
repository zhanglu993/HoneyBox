import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/qiniu/qiniu_storage_service.dart';
import 'package:honeybox/services/qiniu/qiniu_transfer.dart';
import 'qiniu_signer_test.dart' show config;

void main() {
  test('local filenames fit Android byte limits without splitting Unicode', () {
    final name = QiniuStorageService.safeFilename('${'中' * 160}.jsonl');
    expect(utf8.encode(name).length, lessThanOrEqualTo(180));
    expect(name, endsWith('.jsonl'));
    expect(name, isNot(contains('\ufffd')));
  });
  late HttpServer server;
  late Directory temp;
  late QiniuStorageService service;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    temp = await Directory.systemTemp.createTemp('qiniu_test_');
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    service = QiniuStorageService(
        endpoints: QiniuEndpoints(endpoint, endpoint),
        downloadResolver: (_, key) => endpoint.replace(path: '/$key'));
  });
  tearDown(() async {
    await server.close(force: true);
    await temp.delete(recursive: true);
  });
  test('requests uncompressed representation for JSON and object checksums',
      () async {
    String? encoding;
    server.listen((req) async {
      encoding = req.headers.value('accept-encoding');
      req.response.write('{"items":[]}');
      await req.response.close();
    });
    expect((await service.list(config)).items, isEmpty);
    expect(encoding, 'identity');
  });
  test('empty file uploads through the form API with an empty-file hash',
      () async {
    final file = await File('${temp.path}/empty').create();
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      expect(req.headers.contentType?.mimeType, 'multipart/form-data');
      expect(body, contains('name="key"\r\n\r\nempty'));
      req.response
          .write('{"key":"empty","hash":"Fto5o-5ea0sNMlW_75VgGJCv2AcJ"}');
      await req.response.close();
    });
    await service.upload(config, file, 'empty', QiniuTransfer());
  });
  test('changed upload source is rejected before multipart completion',
      () async {
    final file = await File('${temp.path}/changing').writeAsString('data');
    var completed = false;
    server.listen((req) async {
      await req.drain<void>();
      if (req.method == 'DELETE') {
        req.response.write('{}');
      } else if (req.method == 'PUT') {
        await file.writeAsString('changed source');
        req.response.write('{"etag":"part"}');
      } else if (req.uri.path.endsWith('/uploads')) {
        req.response.write('{"uploadId":"upload1"}');
      } else {
        completed = true;
        req.response.write('{}');
      }
      await req.response.close();
    });
    await expectLater(service.upload(config, file, 'changing', QiniuTransfer()),
        throwsA(predicate((e) => e.toString().contains('源文件已变化'))));
    expect(completed, isFalse);
  });
  test('cancelled upload does not wait for a stalled cleanup request',
      () async {
    final file = await File('${temp.path}/small').writeAsString('data');
    final transfer = QiniuTransfer();
    server.listen((req) async {
      await req.drain<void>();
      if (req.method == 'DELETE') return;
      if (req.method == 'PUT') {
        transfer.cancel();
      } else {
        req.response.write('{"uploadId":"upload1"}');
      }
      await req.response.close();
    });
    await expectLater(service.upload(config, file, 'small', transfer),
            throwsA(isA<QiniuCancelled>()))
        .timeout(const Duration(seconds: 3));
  });
  test('list preserves prefix/marker and reads management authorization',
      () async {
    server.listen((req) async {
      expect(req.uri.queryParameters['prefix'], '中 +/');
      expect(req.uri.queryParameters['marker'], 'next+/=');
      expect(req.headers.value('authorization'), startsWith('Qiniu test-ak:'));
      req.response.write(jsonEncode({
        'marker': 'page2',
        'items': [
          {
            'key': '中 +/a.bin',
            'fsize': 3,
            'putTime': 17000000000000000,
            'hash': 'etag'
          }
        ]
      }));
      await req.response.close();
    });
    final page = await service.list(config, prefix: '中 +/', marker: 'next+/=');
    expect(page.marker, 'page2');
    expect(page.items.single.key, '中 +/a.bin');
  });
  test('server errors are safe and do not echo credentials or URLs', () async {
    server.listen((req) async {
      req.response.statusCode = 403;
      req.response.write('test-secret https://test/?token=test-ak');
      await req.response.close();
    });
    await expectLater(
        service.list(config),
        throwsA(predicate((e) =>
            e.toString().contains('403') &&
            !e.toString().contains('test-secret') &&
            !e.toString().contains('token='))));
  });
  test('verified download uses generated path and checks size and etag',
      () async {
    server.listen((req) async {
      req.response.add(utf8.encode('hello'));
      await req.response.close();
    });
    final file = await service.download(
        config,
        const QiniuObject(
            key: '../../a.bin', size: 5, hash: 'Fqr0xh3cxeii2r7eDztILNmuqUNN'),
        temp,
        QiniuTransfer());
    expect(await file.readAsString(), 'hello');
    expect(file.parent.parent.path, temp.path);
  });
  test('hash mismatch and truncated data remove partial downloads', () async {
    server.listen((req) async {
      req.response.add([1, 2]);
      await req.response.close();
    });
    for (final size in [2, 3]) {
      await expectLater(
          service.download(
              config,
              QiniuObject(key: 'a', size: size, hash: 'bad-hash'),
              temp,
              QiniuTransfer()),
          throwsA(isA<QiniuException>()));
    }
    expect(await temp.list().toList(), isEmpty);
  });
  test(
      'cancel interrupts a stalled response and cleans its temporary directory',
      () async {
    final transfer = QiniuTransfer();
    server.listen((req) async {
      req.response.bufferOutput = false;
      req.response.add([1]);
      await req.response.flush();
      transfer.cancel();
    });
    await expectLater(
        service.download(
            config, const QiniuObject(key: 'a', size: 100), temp, transfer),
        throwsA(isA<QiniuCancelled>()));
    expect(await temp.list().toList(), isEmpty);
  });
  test(
      'multipart sends bounded pieces, retries same part and verifies final hash',
      () async {
    final file = await File('${temp.path}/source')
        .writeAsBytes(List.filled(4 * 1024 * 1024 + 3, 42));
    final requests = <String>[];
    var attempts = 0;
    server.listen((req) async {
      requests.add('${req.method} ${req.uri.path}');
      final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(
          req.headers.value('authorization'), startsWith('UpToken test-ak:'));
      if (req.method == 'PUT') {
        expect(bytes.length, lessThanOrEqualTo(4 * 1024 * 1024));
        if (req.uri.path.endsWith('/1') && attempts++ == 0) {
          req.response.statusCode = 503;
        } else {
          req.response.write(
              jsonEncode({'etag': 'part${req.uri.path.split('/').last}'}));
        }
      } else if (req.uri.path.endsWith('/uploads')) {
        req.response.write('{"uploadId":"upload1"}');
      } else {
        final body = jsonDecode(utf8.decode(bytes));
        expect((body['parts'] as List).length, 2);
        final hash = QiniuEtag()..add(await file.readAsBytes());
        req.response
            .write(jsonEncode({'key': 'capture/a', 'hash': hash.finish()}));
      }
      await req.response.close();
    });
    await service.upload(config, file, 'capture/a', QiniuTransfer());
    expect(requests.where((r) => r.startsWith('PUT')).length, 3);
  });
}
