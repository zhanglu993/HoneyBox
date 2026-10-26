import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'capture_models.dart';
import 'capture_scan_settings.dart';

abstract interface class CaptureRecording {
  File get file;
  Future<void> append(CapturePacket packet);
  Future<void> close();
}

class CaptureStore {
  final Directory directory;
  CaptureStore(this.directory);
  static Future<CaptureStore> create() async =>
      CaptureStore(await getApplicationSupportDirectory());
  File get _profiles => File('${directory.path}/capture_profiles.json');
  Future<void> _scanWrites = Future.value();

  Future<CaptureScanSettings> loadScanSettings() async {
    await _scanWrites;
    final file = File('${directory.path}/capture_scan_settings.json');
    if (!await file.exists()) return const CaptureScanSettings();
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (json['version'] != 1) throw const FormatException('筛选条件版本不支持');
      return CaptureScanSettings.fromJson(json);
    } on FileSystemException {
      rethrow;
    } catch (e) {
      throw FormatException('筛选条件无法读取，原文件已保留：$e');
    }
  }

  Future<void> saveScanSettings(CaptureScanSettings settings) {
    final operation = _scanWrites.then((_) async {
      await directory.create(recursive: true);
      final file = File('${directory.path}/capture_scan_settings.json');
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(settings.toJson()), flush: true);
      await temp.rename(file.path);
    });
    // Keep later changes writable after an earlier failure; return errors to UI.
    _scanWrites = operation.catchError((Object _) {});
    return operation;
  }

  Future<List<CaptureProfile>> loadProfiles() async {
    if (!await _profiles.exists()) return [];
    try {
      final data =
          jsonDecode(await _profiles.readAsString()) as Map<String, dynamic>;
      if (data['version'] != 1) throw const FormatException('配置版本不支持');
      final profiles = (data['devices'] as List)
          .map((p) => CaptureProfile.fromJson(p as Map<String, dynamic>))
          .toList();
      if (profiles.map((p) => p.id).toSet().length != profiles.length) {
        throw const FormatException('配置包含重复设备');
      }
      return profiles;
    } on FileSystemException {
      rethrow;
    } catch (e) {
      throw FormatException('采集配置无法读取，原文件已保留：$e');
    }
  }

  Future<void> saveProfiles(List<CaptureProfile> profiles) async {
    if (profiles.map((p) => p.id).toSet().length != profiles.length) {
      throw const FormatException('设备已存在');
    }
    await directory.create(recursive: true);
    final temp = File('${_profiles.path}.tmp');
    await temp.writeAsString(
        jsonEncode({
          'version': 1,
          'devices': profiles.map((p) => p.toJson()).toList()
        }),
        flush: true);
    await temp.rename(_profiles.path);
  }

  Future<CaptureRecording> openRecording(CaptureProfile profile) async {
    final folder =
        await Directory('${directory.path}/captures').create(recursive: true);
    // A unique directory avoids unsafe device names and collisions between sessions.
    final session = await folder.createTemp('capture_');
    final file = File('${session.path}/raw.jsonl');
    await File('${session.path}/device.json').writeAsString(
        jsonEncode({
          ...profile.toJson(),
          'startedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true);
    return _FileRecording(file, await file.open(mode: FileMode.write));
  }

  Future<List<File>> listRecordings() async {
    final folder = Directory('${directory.path}/captures');
    if (!await folder.exists()) return [];
    final files = <File>[];
    await for (final entry in folder.list()) {
      if (entry is Directory) {
        final file = File('${entry.path}/raw.jsonl');
        if (await file.exists()) files.add(file);
      }
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }
}

class _FileRecording implements CaptureRecording {
  @override
  final File file;
  final RandomAccessFile _handle;
  bool _closed = false;
  _FileRecording(this.file, this._handle);
  @override
  Future<void> append(CapturePacket packet) async {
    if (_closed) throw StateError('采集文件已关闭');
    await _handle.writeString('${jsonEncode(packet.toJson())}\n');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _handle.flush();
    } finally {
      await _handle.close();
    }
  }
}
