import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/ota_repository.dart';
import 'package:honeybox/services/ota/ota_session.dart';

void main() {
  test('history survives restart, skips corrupt files, limits and sanitizes',
      () async {
    final dir = Directory.systemTemp.createTempSync('ota_repository_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final repo = OtaRepository(dir);
    for (var i = 0; i < 21; i++) {
      final time = DateTime.utc(2026, 1, 1).add(Duration(minutes: i));
      await repo.save(OtaSessionRecord(
          sessionId: i == 20 ? '../escape' : '$i',
          startedAt: time,
          updatedAt: time,
          phase: OtaPhase.finished,
          outcome: OtaOutcome.failed,
          deviceIdMasked: 'AA:BB:CC:DD:EE:FF',
          firmwareName: '/Users/name/secret/fw.bin',
          firmwareSha256: 'abc',
          phaseHistory: const []));
    }
    await File('${dir.path}/bad.json').writeAsString('{');
    final restarted = OtaRepository(dir);
    final records = await restarted.list();
    expect(records.length, 20);
    expect(records.first.sessionId, '../escape');
    final text = (await restarted.exportSanitized('../escape'))!;
    expect(text, isNot(contains('/Users')));
    expect(text, isNot(contains('AA:BB:CC:DD:EE:FF')));
    expect(text, contains('fw.bin'));
    expect(await File('${dir.parent.path}/escape.json').exists(), isFalse);
  });
}
