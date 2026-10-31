import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/ota_repository.dart';
import 'package:honeybox/services/ota/ota_session.dart';

void main() {
  test('active survives restart, tolerates corruption and clears', () async {
    final dir = Directory.systemTemp.createTempSync('ota_active');
    addTearDown(() => dir.deleteSync(recursive: true));
    final now = DateTime.utc(2026);
    final record = OtaSessionRecord(
        sessionId: 'one',
        startedAt: now,
        updatedAt: now,
        phase: null,
        outcome: null,
        deviceIdMasked: 'device',
        firmwareName: 'fw.bin',
        firmwareSha256: '',
        phaseHistory: const [],
        targetVersion: 2,
        expectedIcType: 9);
    await OtaRepository(dir).saveActive(record);
    final repo = OtaRepository(dir);
    expect((await repo.loadActive())?.targetVersion, 2);
    expect(await repo.list(), isEmpty);
    await File('${dir.path}/active.json').writeAsString('{');
    expect(await repo.loadActive(), isNull);
    await repo.clearActive();
    expect(await repo.loadActive(), isNull);
    final old = record.toJson()
      ..remove('targetVersion')
      ..remove('expectedIcType');
    old['phase'] = OtaPhase.finished.name;
    old['outcome'] = OtaOutcome.failed.name;
    expect(OtaSessionRecord.fromJson(old).targetVersion, isNull);
  });
}
