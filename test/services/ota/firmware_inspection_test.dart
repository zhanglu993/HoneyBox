import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/firmware_inspection.dart';
import 'package:honeybox/services/ota/ota_preflight.dart';

class Parser implements FirmwareParser {
  @override
  Future<FirmwareParseResult> parse(
      String path, DeviceCapabilities capabilities) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 4 || bytes.first != 42) {
      return FirmwareParseResult(
          rawStatus: 'invalid',
          checks: [const OtaCheck('format', OtaCheckStatus.block, 'invalid')]);
    }
    return FirmwareParseResult(rawStatus: 'ok', type: 'test', images: const [
      'app',
      'data'
    ], checks: [
      const OtaCheck('format', OtaCheckStatus.pass, 'ok'),
      OtaCheck(
          'compatibility',
          capabilities.confirmed ? OtaCheckStatus.pass : OtaCheckStatus.unknown,
          'evidence'),
    ]);
  }
}

void main() {
  test('invalid, inaccessible, unknown and replaced files never reach write',
      () async {
    final dir = await Directory.systemTemp.createTemp('inspection_test');
    addTearDown(() => dir.delete(recursive: true));
    var writes = 0;
    Future<void> attempt(String path, bool confirmed,
        {bool replace = false}) async {
      final inspection = await FirmwareInspection.inspect(
          path, DeviceCapabilities(confirmed: confirmed), Parser());
      if (replace) await File(path).writeAsBytes([42, 9, 9, 9]);
      await inspection.startIfSafe(() async {
        writes++;
      });
    }

    for (final bytes in <List<int>>[
      [],
      [1, 2, 3, 4],
      [42]
    ]) {
      final file = File('${dir.path}/firmware')..writeAsBytesSync(bytes);
      await attempt(file.path, true);
    }
    await attempt('${dir.path}/missing', true);
    final file = File('${dir.path}/firmware')..writeAsBytesSync([42, 1, 2, 3]);
    await attempt(file.path, false);
    await attempt(file.path, true, replace: true);
    expect(writes, 0);
  });
  test('retains parser data and digest for explicit passing checks', () async {
    final dir = await Directory.systemTemp.createTemp('inspection_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/firmware')..writeAsBytesSync([42, 1, 2, 3]);
    final result = await FirmwareInspection.inspect(
        file.path, const DeviceCapabilities(confirmed: true), Parser());
    expect(result.sha256, hasLength(64));
    expect(result.rawStatus, 'ok');
    expect(result.images, ['app', 'data']);
    expect(result.type, 'test');
    expect(await result.verifyUnchanged(), isTrue);
    var writes = 0;
    expect(
        await result.startIfSafe(() async {
          writes++;
        }),
        isTrue);
    expect(writes, 1);
  });
}
