import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'ota_failure.dart';
import 'ota_session.dart';

String _mask(String value) =>
    value.length <= 4 ? '****' : '****${value.substring(value.length - 4)}';
String _clean(String value) => value
    .replaceAll(RegExp(r'(?:[A-Za-z]:[\\/]|/)[^\s"<>]+'), '<path>')
    .replaceAll(
        RegExp(r'\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b', caseSensitive: false),
        '<device>')
    .replaceAll(RegExp(r'\b[0-9a-fA-F]{16,}\b'), '<redacted>')
    .replaceAll(
        RegExp(r'(token|secret|password|key)\s*[:=]\s*\S+',
            caseSensitive: false),
        r'$1=<redacted>');
String _base(String value) => value.replaceAll('\\', '/').split('/').last;

class OtaPhaseEntry {
  final OtaPhase phase;
  final DateTime at;
  const OtaPhaseEntry(this.phase, this.at);
}

class OtaSessionRecord {
  final String sessionId;
  final DateTime startedAt, updatedAt;
  final OtaPhase? phase;
  final OtaOutcome? outcome;
  final int? targetVersion, expectedIcType;
  final OtaFailure? failure;
  final String deviceIdMasked, firmwareName, firmwareSha256;
  final String _deviceId;
  final List<OtaPhaseEntry> phaseHistory;
  OtaSessionRecord(
      {required this.sessionId,
      required this.startedAt,
      required this.updatedAt,
      required this.phase,
      required this.outcome,
      this.failure,
      this.targetVersion,
      this.expectedIcType,
      required String deviceIdMasked,
      required String firmwareName,
      required this.firmwareSha256,
      required this.phaseHistory})
      : _deviceId = deviceIdMasked,
        deviceIdMasked = deviceIdMasked.startsWith('****')
            ? deviceIdMasked
            : _mask(deviceIdMasked),
        firmwareName = _clean(_base(firmwareName));

  String _safe(String value) => _clean(
      _deviceId.isEmpty ? value : value.replaceAll(_deviceId, deviceIdMasked));

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'startedAt': startedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'phase': phase?.name,
        'outcome': outcome?.name,
        if (targetVersion != null) 'targetVersion': targetVersion,
        if (expectedIcType != null) 'expectedIcType': expectedIcType,
        'deviceIdMasked': deviceIdMasked,
        'firmwareName': firmwareName,
        'firmwareSha256': RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(firmwareSha256)
            ? firmwareSha256
            : '',
        'phaseHistory': phaseHistory
            .map((e) => {'phase': e.phase.name, 'at': e.at.toIso8601String()})
            .toList(),
        if (failure != null)
          'failure': {
            'category': failure!.category.name,
            'phase': failure!.phase?.name,
            'rawType': failure!.rawType,
            'rawCode': failure!.rawCode,
            'rawMessage': _safe(failure!.rawMessage ?? ''),
            'deviceState': _safe(failure!.deviceState ?? ''),
            'canRetry': failure!.canRetry,
            'guidance': _safe(failure!.guidance)
          }
      };
  factory OtaSessionRecord.fromJson(Map<String, dynamic> json) {
    final f = json['failure'] as Map<String, dynamic>?;
    return OtaSessionRecord(
        sessionId: json['sessionId'] as String,
        startedAt: DateTime.parse(json['startedAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        phase: json['phase'] == null ? null : OtaPhase.values.byName(json['phase'] as String),
        outcome: json['outcome'] == null ? null : OtaOutcome.values.byName(json['outcome'] as String),
        targetVersion: json['targetVersion'] as int?,
        expectedIcType: json['expectedIcType'] as int?,
        deviceIdMasked: json['deviceIdMasked'] as String,
        firmwareName: json['firmwareName'] as String,
        firmwareSha256: json['firmwareSha256'] as String,
        phaseHistory: (json['phaseHistory'] as List)
            .map((e) => OtaPhaseEntry(
                OtaPhase.values.byName(e['phase'] as String),
                DateTime.parse(e['at'] as String)))
            .toList(),
        failure: f == null
            ? null
            : OtaFailure(
                category:
                    OtaFailureCategory.values.byName(f['category'] as String),
                phase: f['phase'] == null
                    ? null
                    : OtaPhase.values.byName(f['phase'] as String),
                rawType: f['rawType'] as int?,
                rawCode: f['rawCode'] as int?,
                rawMessage: f['rawMessage'] as String?,
                deviceState: f['deviceState'] as String?,
                canRetry: f['canRetry'] as bool,
                guidance: f['guidance'] as String));
  }
}

class OtaRepository {
  final Directory directory;
  final DateTime Function() now;
  OtaRepository(this.directory, {DateTime Function()? now})
      : now = now ?? DateTime.now;
  File _file(String id) =>
      File('${directory.path}/${sha256.convert(utf8.encode(id))}.json');
  File get _activeFile => File('${directory.path}/active.json');

  Future<void> saveActive(OtaSessionRecord record) async {
    await directory.create(recursive: true);
    final temporary = File('${directory.path}/active.tmp');
    await temporary.writeAsString(jsonEncode(record.toJson()), flush: true);
    await temporary.rename(_activeFile.path);
  }

  Future<OtaSessionRecord?> loadActive() async {
    try {
      return OtaSessionRecord.fromJson(
          jsonDecode(await _activeFile.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearActive() async {
    if (await _activeFile.exists()) await _activeFile.delete();
  }

  Future<void> save(OtaSessionRecord record) async {
    await directory.create(recursive: true);
    await _file(record.sessionId)
        .writeAsString(jsonEncode(record.toJson()), flush: true);
    final records = await list();
    for (final old in records.skip(20)) {
      await _file(old.sessionId).delete();
    }
  }

  Future<List<OtaSessionRecord>> list() async {
    if (!await directory.exists()) return [];
    final result = <OtaSessionRecord>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json') ||
          entity.path == _activeFile.path) continue;
      try {
        result.add(OtaSessionRecord.fromJson(
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>));
      } catch (_) {}
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  Future<String?> exportSanitized(String sessionId) async {
    try {
      final record = OtaSessionRecord.fromJson(
          jsonDecode(await _file(sessionId).readAsString())
              as Map<String, dynamic>);
      final json = record.toJson();
      json['sessionId'] =
          sha256.convert(utf8.encode(record.sessionId)).toString();
      return const JsonEncoder.withIndent('  ').convert(json);
    } catch (_) {
      return null;
    }
  }
}
