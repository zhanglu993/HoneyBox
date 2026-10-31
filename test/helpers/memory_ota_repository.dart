import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:honeybox/services/ota/ota_repository.dart';

/// In-memory repository for widget tests: no real IO, so it works inside the
/// fake-async zone. Never used by production code.
class MemoryOtaRepository extends OtaRepository {
  MemoryOtaRepository() : super(Directory.systemTemp);
  final Map<String, OtaSessionRecord> records = {};
  OtaSessionRecord? active;
  @override
  Future<void> saveActive(OtaSessionRecord record) async => active = record;
  @override
  Future<OtaSessionRecord?> loadActive() async => active;
  @override
  Future<void> clearActive() async => active = null;
  @override
  Future<void> save(OtaSessionRecord record) async =>
      records[record.sessionId] = record;
  @override
  Future<List<OtaSessionRecord>> list() async => records.values.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  @override
  Future<String?> exportSanitized(String sessionId) async {
    final record = records[sessionId];
    if (record == null) return null;
    final json = record.toJson();
    json['sessionId'] = sha256.convert(utf8.encode(sessionId)).toString();
    return const JsonEncoder.withIndent('  ').convert(json);
  }
}
