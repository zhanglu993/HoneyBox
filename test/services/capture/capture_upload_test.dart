import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/capture/capture_upload.dart';
import 'package:honeybox/services/qiniu/qiniu_config.dart';
import 'package:honeybox/services/qiniu/qiniu_storage_service.dart';
import 'package:honeybox/services/qiniu/qiniu_transfer.dart';

const config = QiniuConfig(
    accessKey: 'test-ak',
    secretKey: 'test-secret',
    bucket: 'test',
    prefix: 'logs',
    downloadDomain: 'https://files.example.com');

class FakeService extends QiniuStorageService {
  String? key;
  List<int>? bytes;
  @override
  Future<void> upload(
      QiniuConfig config, File file, String key, QiniuTransfer transfer) async {
    this.key = key;
    bytes = await file.readAsBytes();
  }
}

void main() {
  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('cap_up_'));
  tearDown(() => temp.delete(recursive: true));

  Future<CaptureRecord> record(
      String dir, String name, String id, String startedAt, String raw) async {
    final folder =
        await Directory('${temp.path}/captures/$dir').create(recursive: true);
    await File('${folder.path}/device.json').writeAsString(
        jsonEncode({'name': name, 'id': id, 'startedAt': startedAt}));
    await File('${folder.path}/raw.jsonl').writeAsString(raw);
    return CaptureRecord.load(File('${folder.path}/raw.jsonl'));
  }

  test('label is device name plus MAC without separators', () {
    expect(captureLabel('Polar H10 790A8026', 'EE:6A:57:F3:9E:00'),
        'Polar-H10-790A8026_EE6A57F39E00');
    expect(captureLabel('手环', 'aa:bb:cc:dd:ee:ff'), 'AABBCCDDEEFF');
    expect(captureLabel('', ''), 'device');
  });

  test('batch key names every device and the earliest start', () async {
    final a = await record(
        'a', 'Polar H10', 'EE:6A:57:F3:9E:00', '2026-10-26T09:39:55Z', '{}\n');
    final b = await record(
        'b', 'S100', '79:DC:53:AB:1B:31', '2026-10-26T09:39:40Z', '{}\n');
    final key = captureBatchKey(config, [a, b], random: Random(1));
    final local = DateTime.utc(2026, 10, 26, 9, 39, 40).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    expect(
        key,
        startsWith(
            'logs/captures/${local.year}${two(local.month)}${two(local.day)}-'
            '${two(local.hour)}${two(local.minute)}40_Polar-H10_EE6A57F39E00+S100_79DC53AB1B31_'));
    expect(key, endsWith('.zip'));
  });

  test('latest batch groups records started together', () async {
    final a = await record('a', 'A', '01', '2026-10-26T09:39:55Z', '');
    final b = await record('b', 'B', '02', '2026-10-26T09:38:30Z', '');
    final c = await record('c', 'C', '03', '2026-10-26T08:00:00Z', '');
    expect(latestCaptureBatch([a, b, c]), {a, b});
  });

  test('upload zips manifest and each record under Name_MAC, then marks it',
      () async {
    final a = await record('a', 'S100', '79:DC:53:AB:1B:31',
        '2026-10-26T09:39:55Z', '{"hex":"01"}\n');
    final b = await record('b', 'S100', '79:DC:53:AB:1B:31',
        '2026-10-26T10:00:00Z', '{"hex":"02"}\n');
    final service = FakeService();
    final key = await uploadCaptureBatch(
        service, config, [a, b], QiniuTransfer(), temp);
    expect(service.key, key);
    final zip = ZipDecoder().decodeBytes(service.bytes!);
    final names = zip.files.map((f) => f.name).toSet();
    final first = captureEntryFolders([a, b]);
    expect(first[0], isNot(first[1]));
    expect(first[0], startsWith('S100_79DC53AB1B31_'));
    expect(names, {
      'manifest.json',
      '${first[0]}/raw.jsonl',
      '${first[0]}/device.json',
      '${first[1]}/raw.jsonl',
      '${first[1]}/device.json',
    });
    expect(utf8.decode(zip.findFile('${first[1]}/raw.jsonl')!.content),
        '{"hex":"02"}\n');
    final manifest =
        jsonDecode(utf8.decode(zip.findFile('manifest.json')!.content));
    expect(manifest['records'][0]['id'], '79:DC:53:AB:1B:31');
    expect((await CaptureRecord.load(a.raw)).uploadedKey, key);
    expect(temp.listSync().whereType<File>(), isEmpty);
  });

  test('live record is uploaded up to its last complete line', () async {
    final a = await record('a', 'S100', '79:DC:53:AB:1B:31',
        '2026-10-26T09:39:55Z', '{"hex":"01"}\n{"hex":');
    final service = FakeService();
    final key = await uploadCaptureBatch(
        service, config, [a], QiniuTransfer(), temp,
        live: {a.raw.path});
    expect(key, contains('S100_79DC53AB1B31_live_'));
    final zip = ZipDecoder().decodeBytes(service.bytes!);
    expect(utf8.decode(zip.findFile('S100_79DC53AB1B31/raw.jsonl')!.content),
        '{"hex":"01"}\n');
    final manifest =
        jsonDecode(utf8.decode(zip.findFile('manifest.json')!.content));
    expect(manifest['records'][0]['live'], isTrue);
    expect(manifest['records'][0]['rawBytes'], 13);
    expect((await CaptureRecord.load(a.raw)).upload!['live'], isTrue);
    expect(await a.raw.length(), greaterThan(13));
  });
  test('share link is signed for seven days', () {
    final now = DateTime.utc(2026, 10, 26);
    final link = captureShareLink(config, 'logs/captures/x.zip', now: now);
    expect(link.host, 'files.example.com');
    expect(link.queryParameters['e'],
        '${now.add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000}');
    expect(link.queryParameters['token'], startsWith('test-ak:'));
  });
}
