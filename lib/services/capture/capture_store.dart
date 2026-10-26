import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'capture_models.dart';
import 'capture_scan_settings.dart';

abstract interface class CaptureRecording {
  File get file;
  Future<void> append(CapturePacket packet);
  Future<void> flush();
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
      if (![1, 2].contains(data['version'])) {
        throw const FormatException('配置版本不支持');
      }
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
          'version': 2,
          'devices': profiles.map((p) => p.toJson()).toList()
        }),
        flush: true);
    await temp.rename(_profiles.path);
  }

  /// [resume] appends to an interrupted recording instead of a new folder.
  Future<CaptureRecording> openRecording(CaptureProfile profile,
      {File? resume}) async {
    if (resume != null) return _resume(resume);
    final folder =
        await Directory('${directory.path}/captures').create(recursive: true);
    // A unique directory avoids unsafe device names and collisions between sessions.
    final session = await folder.createTemp('capture_');
    final file = File('${session.path}/raw.jsonl');
    final info = File('${session.path}/device.json');
    final meta = {
      ...profile.toJson(),
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'open': true,
    };
    await info.writeAsString(jsonEncode(meta), flush: true);
    return _FileRecording(file, await file.open(mode: FileMode.write), info);
  }

  Future<CaptureRecording> _resume(File file) async {
    final info = File('${file.parent.path}/device.json');
    final meta = jsonDecode(await info.readAsString()) as Map<String, dynamic>;
    final handle = await file.open(mode: FileMode.append);
    // The app died mid-write: drop the partial last line before appending.
    await handle.truncate(await _completeLength(handle));
    await handle.setPosition(await handle.length());
    meta['open'] = true;
    meta['resumedAt'] = [
      ...?(meta['resumedAt'] as List?),
      DateTime.now().toUtc().toIso8601String(),
    ];
    await info.writeAsString(jsonEncode(meta), flush: true);
    return _FileRecording(file, handle, info);
  }

  static Future<int> _completeLength(RandomAccessFile handle) async {
    var end = await handle.length();
    const chunk = 4096;
    while (end > 0) {
      final start = end > chunk ? end - chunk : 0;
      await handle.setPosition(start);
      final nl = (await handle.read(end - start)).lastIndexOf(10);
      if (nl >= 0) return start + nl + 1;
      end = start;
    }
    return 0;
  }

  /// Newest recording of [profile] that was never closed (app killed or crashed).
  Future<File?> findInterrupted(CaptureProfile profile) async {
    File? found;
    DateTime? newest;
    for (final raw in await listRecordings()) {
      try {
        final meta = jsonDecode(
                await File('${raw.parent.path}/device.json').readAsString())
            as Map<String, dynamic>;
        if (meta['id'] != profile.id) continue;
        final at = DateTime.tryParse(meta['startedAt'] as String? ?? '');
        if (at == null || (newest != null && !at.isAfter(newest))) continue;
        newest = at;
        found = meta['open'] == true ? raw : null;
      } catch (_) {}
    }
    return found;
  }

  /// Removes one recording folder; refuses paths outside the captures folder.
  Future<void> deleteRecording(File raw) async {
    final folder = raw.parent;
    final root = Directory('${directory.path}/captures').absolute.path;
    if (folder.parent.absolute.path != root) {
      throw StateError('拒绝删除采集目录以外的文件：${folder.path}');
    }
    if (await folder.exists()) await folder.delete(recursive: true);
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
  final File _info;
  bool _closed = false;
  _FileRecording(this.file, this._handle, this._info);
  @override
  Future<void> append(CapturePacket packet) async {
    if (_closed) throw StateError('采集文件已关闭');
    await _handle.writeString('${jsonEncode(packet.toJson())}\n');
  }

  @override
  Future<void> flush() async {
    await _handle.flush();
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
    try {
      final meta =
          jsonDecode(await _info.readAsString()) as Map<String, dynamic>;
      meta['open'] = false;
      meta['stoppedAt'] = DateTime.now().toUtc().toIso8601String();
      await _info.writeAsString(jsonEncode(meta), flush: true);
    } catch (_) {}
  }
}
