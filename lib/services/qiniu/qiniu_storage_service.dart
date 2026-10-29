import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'qiniu_config.dart';
import 'qiniu_signer.dart';
import 'qiniu_transfer.dart';

class QiniuObject {
  final String key, hash, mimeType;
  final int size;
  final DateTime? uploadedAt;
  const QiniuObject(
      {required this.key,
      required this.size,
      this.hash = '',
      this.mimeType = '',
      this.uploadedAt});
  factory QiniuObject.fromJson(Map<String, dynamic> json) => QiniuObject(
      key: json['key'] as String,
      size: (json['fsize'] as num).toInt(),
      hash: json['hash'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? '',
      uploadedAt: json['putTime'] == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(
              (json['putTime'] as num).toInt() ~/ 10,
              isUtc: true));
}

class QiniuPage {
  final List<QiniuObject> items;
  final String marker;
  const QiniuPage(this.items, this.marker);
}

class QiniuEndpoints {
  final Uri upload, list;
  const QiniuEndpoints(this.upload, this.list);
}

/// Qiniu REST API; no Android/iOS/Windows-specific code or Qiniu SDK.
class QiniuStorageService {
  final QiniuEndpoints? endpoints;
  final Uri? discoveryEndpoint;
  final Uri? managementEndpoint;
  final Uri Function(QiniuConfig, String)? downloadResolver;
  QiniuStorageService(
      {this.endpoints,
      this.discoveryEndpoint,
      this.downloadResolver,
      this.managementEndpoint});
  static const timeout = Duration(seconds: 30);

  QiniuException _status(int code) => QiniuException(
      switch (code) {
        401 => '鉴权失败（401），请检查 Key 和设备时间',
        403 => '无操作权限（403），请检查 Key、Bucket 和访问类型',
        612 => '空间、文件或上传任务不存在（612）',
        614 => '同名文件已存在（614），请更换文件路径',
        631 => '空间不存在（631），请检查 Bucket 和区域',
        _ => '七牛请求失败（$code），请检查空间、区域和域名配置',
      },
      retryable: code == 429 || code >= 500 && code < 600);

  Future<T> _response<T>(String method, Uri uri, QiniuTransfer transfer,
      Future<T> Function(HttpClientResponse) read,
      {Map<String, String> headers = const {},
      List<int>? body,
      void Function(int)? sent,
      bool anyStatus = false}) async {
    transfer.check();
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = false;
    void abort() => client.close(force: true);
    transfer.attach(abort);
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      transfer.check();
      request.followRedirects =
          false; // Never forward credentials to another host.
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      headers.forEach(request.headers.set);
      if (body != null) {
        request.contentLength = body.length;
        for (var start = 0; start < body.length; start += 64 * 1024) {
          transfer.check();
          final end = min(start + 64 * 1024, body.length);
          request.add(body.sublist(start, end));
          await request.flush().timeout(timeout);
          sent?.call(end);
        }
      }
      final response = await request.close().timeout(timeout);
      transfer.check();
      if (!anyStatus && response.statusCode != 200) {
        throw _status(response.statusCode);
      }
      final result = await read(response);
      transfer.check();
      return result;
    } on QiniuException {
      rethrow;
    } on TimeoutException {
      throw const QiniuException('网络请求超时，请重试', retryable: true);
    } on SocketException {
      transfer.check();
      throw const QiniuException('网络连接失败，请检查网络和域名', retryable: true);
    } on HttpException {
      transfer.check();
      throw const QiniuException('连接中断或响应不完整，请重试', retryable: true);
    } on HandshakeException {
      throw const QiniuException('HTTPS 证书验证失败，请检查域名');
    } on FileSystemException {
      throw const QiniuException('本机文件读写失败，请检查空间和文件权限');
    } on FormatException {
      throw const QiniuException('七牛返回数据格式无效');
    } finally {
      transfer.detach(abort);
      client.close(force: true);
    }
  }

  Future<T> _retry<T>(
      QiniuTransfer transfer, Future<T> Function() action) async {
    for (var attempt = 0;; attempt++) {
      transfer.check();
      try {
        return await action();
      } on QiniuException catch (e) {
        transfer.check();
        if (!e.retryable || attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
  }

  Future<Map<String, dynamic>> _json(
      String method, Uri uri, QiniuTransfer transfer,
      {Map<String, String> headers = const {},
      List<int>? body,
      bool retry = false,
      void Function(int)? sent}) async {
    Future<Map<String, dynamic>> action() =>
        _response(method, uri, transfer, (response) async {
          final bytes = <int>[];
          await for (final chunk in response.timeout(timeout)) {
            transfer.check();
            bytes.addAll(chunk);
            if (bytes.length > 2 * 1024 * 1024) {
              throw const QiniuException('七牛响应超出大小限制');
            }
          }
          final json = jsonDecode(utf8.decode(bytes));
          if (json is! Map<String, dynamic>) throw const FormatException();
          return json;
        }, headers: headers, body: body, sent: sent);
    return retry ? _retry(transfer, action) : action();
  }

  Future<QiniuEndpoints> _endpoints(
      QiniuConfig config, QiniuTransfer transfer) async {
    if (endpoints != null) return endpoints!;
    if (config.region.isNotEmpty) {
      final suffix = config.region == 'z0' ? '' : '-${config.region}';
      return QiniuEndpoints(Uri.https('up$suffix.qiniup.com'),
          Uri.https('rsf$suffix.qiniuapi.com'));
    }
    final query = (discoveryEndpoint ??
            Uri.https('uc.qiniuapi.com', '/v4/query'))
        .replace(
            queryParameters: {'ak': config.accessKey, 'bucket': config.bucket});
    final json = await _json('GET', query, transfer, retry: true);
    try {
      final hosts = (json['hosts'] as List).first as Map;
      Uri endpoint(String name) {
        final domains = (hosts[name] as Map)['domains'] as List;
        final host = domains.first as String;
        // Trust only official discovery hosts, never a response-supplied URL/path.
        if (!RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(host) ||
            !['.qiniup.com', '.qiniuapi.com', '.qbox.me'].any(host.endsWith)) {
          throw const FormatException();
        }
        return Uri.https(host);
      }

      return QiniuEndpoints(endpoint('up'), endpoint('rsf'));
    } catch (_) {
      throw const QiniuException('无法解析空间区域，请在配置中手动选择区域');
    }
  }

  Future<QiniuPage> list(QiniuConfig config,
      {String prefix = '',
      String marker = '',
      int limit = 100,
      QiniuTransfer? transfer}) async {
    final error = config.validationError();
    if (error != null) throw QiniuException(error);
    final task = transfer ?? QiniuTransfer();
    final hosts = await _endpoints(config, task);
    final uri = hosts.list.replace(path: '/list', queryParameters: {
      'bucket': config.bucket,
      'prefix': prefix,
      'limit': '$limit',
      if (marker.isNotEmpty) 'marker': marker
    });
    final date =
        '${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp('[-:]'), '').substring(0, 15)}Z';
    const type = 'application/x-www-form-urlencoded';
    final json = await _json('GET', uri, task,
        headers: {
          'Content-Type': type,
          'X-Qiniu-Date': date,
          'Authorization':
              QiniuSigner(config).managementToken('GET', uri, timestamp: date)
        },
        retry: true);
    try {
      final items = (json['items'] as List? ?? [])
          .map((item) => QiniuObject.fromJson(item as Map<String, dynamic>))
          .toList();
      if (items.any((item) => item.size < 0)) throw const FormatException();
      return QiniuPage(items, json['marker'] as String? ?? '');
    } catch (_) {
      throw const QiniuException('七牛文件列表格式无效');
    }
  }

  Future<void> upload(
      QiniuConfig config, File file, String key, QiniuTransfer transfer) async {
    final error = config.validationError();
    if (error != null) throw QiniuException(error);
    final stat = await file.stat();
    final size = stat.size;
    if (stat.type != FileSystemEntityType.file) {
      throw const QiniuException('请选择可读取的本地文件');
    }
    if (size > QiniuEtag.blockSize * 10000) {
      throw const QiniuException('文件过大，超出首版分片限制');
    }
    final hosts = await _endpoints(config, transfer);
    final token = QiniuSigner(config).uploadToken(key, size);
    final hash = QiniuEtag();
    Map<String, dynamic> result;
    if (size == 0) {
      // A zero-byte object cannot have a multipart part. Use the form API.
      final boundary = 'HoneyBox${DateTime.now().microsecondsSinceEpoch}';
      final body = utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; name="token"\r\n\r\n$token\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="key"\r\n\r\n$key\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="empty"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--$boundary--\r\n');
      result = await _json('POST', hosts.upload, transfer,
          headers: {'Content-Type': 'multipart/form-data; boundary=$boundary'},
          body: body);
    } else {
      final encoded = base64Url.encode(utf8.encode(key));
      final root = '/buckets/${config.bucket}/objects/$encoded/uploads';
      final auth = {'Authorization': 'UpToken $token'};
      final init = await _json(
          'POST', hosts.upload.replace(path: root), transfer,
          headers: auth);
      final id = init['uploadId'];
      if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
        throw const QiniuException('七牛上传任务信息无效');
      }
      final taskPath = '$root/$id';
      RandomAccessFile? handle;
      var completed = false;
      try {
        handle = await file.open();
        final parts = <Map<String, Object>>[];
        var offset = 0;
        for (var number = 1; offset < size; number++) {
          transfer.check();
          final bytes =
              await handle.read(min(QiniuEtag.blockSize, size - offset));
          if (bytes.isEmpty) throw const QiniuException('上传源文件已变化，请重新选择');
          hash.add(bytes);
          final current = offset;
          final part = await _json(
              'PUT', hosts.upload.replace(path: '$taskPath/$number'), transfer,
              headers: {
                ...auth,
                'Content-Type': 'application/octet-stream',
                'Content-MD5': md5.convert(bytes).toString()
              },
              body: bytes,
              retry: true,
              sent: (n) => transfer.onProgress?.call(current + n, size));
          if (part['etag'] is! String) throw const QiniuException('七牛分片校验信息缺失');
          parts.add({'partNumber': number, 'etag': part['etag'] as String});
          offset += bytes.length;
        }
        final after = await file.stat();
        if (after.size != stat.size || after.modified != stat.modified) {
          throw const QiniuException('上传源文件已变化，请重新选择');
        }
        result = await _json(
            'POST', hosts.upload.replace(path: taskPath), transfer,
            headers: {...auth, 'Content-Type': 'application/json'},
            body: utf8.encode(jsonEncode({'parts': parts})));
        completed = true;
      } finally {
        await handle?.close();
        if (!completed) {
          // Best-effort cleanup uses its own token because the transfer may be cancelled.
          final cleanup = QiniuTransfer();
          final deadline = Timer(const Duration(seconds: 1), cleanup.cancel);
          try {
            await _json('DELETE', hosts.upload.replace(path: taskPath), cleanup,
                headers: auth);
          } catch (_) {
            /* Seven-day expiry also removes abandoned server parts. */
          } finally {
            deadline.cancel();
          }
        }
      }
    }
    if (result['key'] != key || result['hash'] != hash.finish()) {
      throw const QiniuException('上传响应校验失败，请刷新列表核对云端文件');
    }
    transfer.onProgress?.call(size, size);
  }

  /// Delete exactly one object. Failed or ambiguous requests are not retried.
  Future<void> delete(
      QiniuConfig config, String key, QiniuTransfer transfer) async {
    final error = config.validationError();
    if (error != null) throw QiniuException(error);
    if (key.isEmpty ||
        key.contains('\u0000') ||
        utf8Length('${config.bucket}:$key') > 750) {
      throw const QiniuException('文件路径无效');
    }
    final entry = base64Url.encode(utf8.encode('${config.bucket}:$key'));
    final uri = (managementEndpoint ?? Uri.parse('https://rs.qiniuapi.com'))
        .replace(path: '/delete/$entry');
    final date =
        '${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp('[-:]'), '').substring(0, 15)}Z';
    const type = 'application/x-www-form-urlencoded';
    final auth = QiniuSigner(config)
        .managementToken('POST', uri, contentType: type, timestamp: date);
    await _response('POST', uri, transfer, (response) async {
      await response.drain<void>();
    }, headers: {
      'Authorization': auth,
      'Content-Type': type,
      'X-Qiniu-Date': date
    }, body: const []);
  }

  /// HEADs [key] (or a missing probe key) through the download domain, so DNS,
  /// certificate and bucket binding problems show up before a link is shared.
  Future<void> checkDownload(QiniuConfig config, QiniuTransfer transfer,
      {String? key}) async {
    final error = config.validationError(forDownload: true);
    if (error != null) throw QiniuException(error);
    final target =
        key ?? '.honeybox-check-${DateTime.now().microsecondsSinceEpoch}';
    final uri = downloadResolver?.call(config, target) ??
        QiniuSigner(config).downloadUri(target);
    final int code;
    try {
      code = await _response('HEAD', uri, transfer, (r) async {
        await r.drain<void>();
        return r.statusCode;
      }, anyStatus: true);
    } on QiniuCancelled {
      rethrow;
    } on QiniuException catch (e) {
      throw QiniuException('下载域名不可用：${e.message}');
    }
    if (code == 200 || (key == null && code == 404)) return;
    throw QiniuException(switch (code) {
      401 || 403 => '下载域名可访问，但签名被拒（$code）：请确认域名绑定在此空间，且「私有空间」与实际一致',
      404 => '下载域名可访问，但找不到已有文件（404）：请确认域名绑定在此空间',
      _ => '下载域名返回 $code，请检查七牛域名配置',
    });
  }

  Future<File> download(QiniuConfig config, QiniuObject object,
      Directory directory, QiniuTransfer transfer) async {
    final uri = downloadResolver?.call(config, object.key) ??
        QiniuSigner(config).downloadUri(object.key);
    await directory.create(recursive: true);
    final folder = await directory.createTemp('qiniu_');
    final file = File('${folder.path}/${safeFilename(object.key)}');
    var completed = false;
    try {
      await _retry(
          transfer,
          () => _response('GET', uri, transfer, (response) async {
                final sink = file.openWrite();
                final hash = QiniuEtag();
                var received = 0;
                try {
                  await for (final bytes in response.timeout(timeout)) {
                    transfer.check();
                    received += bytes.length;
                    if (received > object.size) {
                      throw const QiniuException('下载大小与云端元信息不一致，请刷新列表');
                    }
                    sink.add(bytes);
                    hash.add(bytes);
                    await sink
                        .flush(); // Apply disk backpressure instead of queuing the entire download.
                    transfer.onProgress?.call(received, object.size);
                  }
                } finally {
                  await sink.close();
                }
                if (received != object.size ||
                    response.contentLength >= 0 &&
                        received != response.contentLength) {
                  throw const QiniuException('下载不完整，请重试', retryable: true);
                }
                if (object.hash.isNotEmpty && hash.finish() != object.hash) {
                  throw const QiniuException('下载校验失败，请刷新列表或检查域名是否属于该空间');
                }
              }));
      completed = true;
      return file;
    } finally {
      if (!completed) await folder.delete(recursive: true);
    }
  }

  static String safeFilename(String key) {
    var name = key
        .split('/')
        .last
        .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
        .trim();
    name = name.replaceAll(RegExp(r'[. ]+$'), '');
    if (name.isEmpty ||
        RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
                caseSensitive: false)
            .hasMatch(name)) {
      name = 'file_$name';
    }
    // Keep a short extension and stay below Android's UTF-8 filename limit.
    final dot = name.lastIndexOf('.');
    final extension =
        dot > 0 && name.length - dot <= 16 ? name.substring(dot) : '';
    final stem = extension.isEmpty ? name : name.substring(0, dot);
    final result = StringBuffer();
    var bytes = utf8.encode(extension).length;
    for (final rune in stem.runes) {
      final character = String.fromCharCode(rune);
      final count = utf8.encode(character).length;
      if (bytes + count > 180) break;
      result.write(character);
      bytes += count;
    }
    return '$result$extension';
  }
}
