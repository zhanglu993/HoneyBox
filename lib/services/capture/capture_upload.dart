import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:archive/archive_io.dart';
import '../qiniu/qiniu_config.dart';
import '../qiniu/qiniu_signer.dart';
import '../qiniu/qiniu_storage_service.dart';
import '../qiniu/qiniu_transfer.dart';

const captureLinkValidity = Duration(days: 7);

/// "Name_MAC" with characters safe for object keys, zip paths and shell URLs.
String captureLabel(String name, String id) {
  final cleanName = name
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final mac = id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  final label = [cleanName, mac].where((p) => p.isNotEmpty).join('_');
  return label.isEmpty ? 'device' : label;
}

class CaptureRecord {
  final File raw;
  final Map<String, dynamic> device;
  final Map<String, dynamic>? upload;
  const CaptureRecord(this.raw, this.device, this.upload);
  Directory get folder => raw.parent;
  String get name => device['name'] as String? ?? '';
  String get id => device['id'] as String? ?? '';
  DateTime? get startedAt =>
      DateTime.tryParse(device['startedAt'] as String? ?? '');
  String get label => captureLabel(name, id);
  String? get uploadedKey => upload?['key'] as String?;
  File get uploadFile => File('${folder.path}/upload.json');

  static Future<Map<String, dynamic>?> _json(File file) async {
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<CaptureRecord> load(File raw) async => CaptureRecord(
      raw,
      await _json(File('${raw.parent.path}/device.json')) ?? const {},
      await _json(File('${raw.parent.path}/upload.json')));
}

/// Records started within [window] of the newest one: one multi-device session.
Set<CaptureRecord> latestCaptureBatch(List<CaptureRecord> records,
    {Duration window = const Duration(minutes: 2)}) {
  final dated = records.where((r) => r.startedAt != null).toList();
  if (dated.isEmpty) return records.isEmpty ? {} : {records.first};
  final newest =
      dated.map((r) => r.startedAt!).reduce((a, b) => a.isAfter(b) ? a : b);
  return dated.where((r) => newest.difference(r.startedAt!) <= window).toSet();
}

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

String captureBatchKey(QiniuConfig config, List<CaptureRecord> records,
    {DateTime? now, Random? random, bool live = false}) {
  final starts = records.map((r) => r.startedAt).whereType<DateTime>();
  final time = (starts.isEmpty
          ? (now ?? DateTime.now())
          : starts.reduce((a, b) => a.isBefore(b) ? a : b))
      .toLocal();
  final labels = {for (final r in records) r.label}.toList();
  var devices = labels.take(4).join('+');
  if (labels.length > 4) devices += '+${labels.length - 4}more';
  final rnd = random ?? Random.secure();
  final tag = List.generate(
      2, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  final prefix = config.prefix.isEmpty || config.prefix.endsWith('/')
      ? config.prefix
      : '${config.prefix}/';
  return '${prefix}captures/${_stamp(time)}_$devices${live ? '_live' : ''}_$tag.zip';
}

/// Zip entry folder per record; same device recorded twice gets its start time.
List<String> captureEntryFolders(List<CaptureRecord> records) {
  final counts = <String, int>{};
  for (final r in records) {
    counts[r.label] = (counts[r.label] ?? 0) + 1;
  }
  final used = <String>{};
  return [
    for (final r in records)
      () {
        var base = counts[r.label]! > 1 && r.startedAt != null
            ? '${r.label}_${_stamp(r.startedAt!.toLocal())}'
            : r.label;
        var name = base;
        for (var i = 2; !used.add(name); i++) {
          name = '${base}_$i';
        }
        return name;
      }()
  ];
}

/// Copies [source] up to its last complete line; a capture still being
/// written may end mid-line.
int _snapshotLines(String source, String target) {
  final input = File(source).openSync();
  final output = File(target).openSync(mode: FileMode.write);
  try {
    var end = input.lengthSync();
    const chunk = 64 * 1024;
    while (end > 0) {
      final start = end > chunk ? end - chunk : 0;
      input.setPositionSync(start);
      final tail = input.readSync(end - start);
      final nl = tail.lastIndexOf(10);
      if (nl >= 0) {
        end = start + nl + 1;
        break;
      }
      end = start;
    }
    input.setPositionSync(0);
    for (var done = 0; done < end;) {
      final bytes = input.readSync(end - done > chunk ? chunk : end - done);
      if (bytes.isEmpty) break;
      output.writeFromSync(bytes);
      done += bytes.length;
    }
    return end;
  } finally {
    input.closeSync();
    output.closeSync();
  }
}

/// Records listed in [live] are still recording and get a "live" flag.
Future<File> packCaptureBatch(List<CaptureRecord> records, File target,
    {Set<String> live = const {}}) async {
  final folders = captureEntryFolders(records);
  final items = [
    for (var i = 0; i < records.length; i++)
      (
        raw: records[i].raw.path,
        device: File('${records[i].folder.path}/device.json').existsSync()
            ? '${records[i].folder.path}/device.json'
            : null,
        folder: folders[i],
        meta: {
          'folder': folders[i],
          'name': records[i].name,
          'id': records[i].id,
          'startedAt': records[i].device['startedAt'],
          if (live.contains(records[i].raw.path)) 'live': true,
        },
      )
  ];
  final path = target.path;
  // Deflating an overnight capture takes seconds; keep it off the UI isolate.
  await Isolate.run(() {
    final zip = ZipFileEncoder()..create(path);
    final snapshots = <File>[];
    final meta = <Map<String, Object?>>[];
    void add(String source, String name) {
      // addFileSync leaves the input open, which locks the file on Windows.
      final input = InputFileStream(source);
      zip.addArchiveFile(ArchiveFile.stream(name, input)
        ..lastModTime =
            File(source).lastModifiedSync().millisecondsSinceEpoch ~/ 1000);
      input.closeSync();
    }

    try {
      for (final (i, item) in items.indexed) {
        final snap = File('$path.$i.jsonl');
        snapshots.add(snap);
        final bytes = _snapshotLines(item.raw, snap.path);
        meta.add({...item.meta, 'rawBytes': bytes});
        add(snap.path, '${item.folder}/raw.jsonl');
        if (item.device != null) {
          add(item.device!, '${item.folder}/device.json');
        }
      }
      zip.addArchiveFile(ArchiveFile.string(
          'manifest.json',
          jsonEncode({
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'records': meta,
          })));
      zip.closeSync();
    } finally {
      for (final f in snapshots) {
        if (f.existsSync()) f.deleteSync();
      }
    }
  });
  return target;
}

Uri captureShareLink(QiniuConfig config, String key, {DateTime? now}) =>
    QiniuSigner(config).downloadUri(key,
        deadline: (now ?? DateTime.now())
                .add(captureLinkValidity)
                .millisecondsSinceEpoch ~/
            1000);

/// Packs, uploads and marks each record; returns the object key.
Future<String> uploadCaptureBatch(
    QiniuStorageService service,
    QiniuConfig config,
    List<CaptureRecord> records,
    QiniuTransfer transfer,
    Directory temp,
    {Set<String> live = const {}}) async {
  if (records.isEmpty) throw const QiniuException('请选择要上传的采集记录');
  final key = captureBatchKey(config, records,
      live: records.any((r) => live.contains(r.raw.path)));
  final zip = File('${temp.path}/${key.split('/').last}');
  try {
    await packCaptureBatch(records, zip, live: live);
    transfer.check();
    await service.upload(config, zip, key, transfer);
  } finally {
    if (await zip.exists()) await zip.delete();
  }
  final uploadedAt = DateTime.now().toUtc().toIso8601String();
  for (final r in records) {
    await r.uploadFile.writeAsString(
        jsonEncode({
          'key': key,
          'bucket': config.bucket,
          'uploadedAt': uploadedAt,
          if (live.contains(r.raw.path)) 'live': true,
        }),
        flush: true);
  }
  return key;
}
