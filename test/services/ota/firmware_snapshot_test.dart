import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/firmware_snapshot.dart';

void main() {
  late Directory directory;
  setUp(() async =>
      directory = await Directory.systemTemp.createTemp('ota_snapshot_test'));
  tearDown(() async => directory.delete(recursive: true));
  test('copies firmware into private cache and verifies the exact digest',
      () async {
    final source = File('${directory.path}/source.bin');
    await source.writeAsBytes([1, 2, 3]);
    final snapshot = await FirmwareSnapshot.importFile(
        source: source,
        cacheDirectory: Directory('${directory.path}/cache'),
        maxBytes: 10);
    expect(snapshot.sizeBytes, 3);
    expect(snapshot.sha256,
        '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81');
    expect(await snapshot.verifyUnchanged(), isTrue);
    await source.writeAsBytes([4]);
    expect(await snapshot.verifyUnchanged(), isTrue);
    await snapshot.file.writeAsBytes([1, 2, 4]);
    expect(await snapshot.verifyUnchanged(), isFalse);
    await snapshot.delete();
    expect(await snapshot.verifyUnchanged(), isFalse);
  });
  test('empty and oversized files fail and leave no cached snapshot', () async {
    final source = File('${directory.path}/source.bin');
    final cache = Directory('${directory.path}/cache');
    await source.writeAsBytes([]);
    await expectLater(
        FirmwareSnapshot.importFile(
            source: source, cacheDirectory: cache, maxBytes: 2),
        throwsFormatException);
    await source.writeAsBytes([1, 2, 3]);
    await expectLater(
        FirmwareSnapshot.importFile(
            source: source, cacheDirectory: cache, maxBytes: 2),
        throwsFormatException);
    expect(await cache.list().toList(), isEmpty);
  });
  test('missing firmware fails, invalid size limit rejected', () async {
    final file = File('${directory.path}/missing');
    final cache = Directory('${directory.path}/cache');
    await expectLater(
        FirmwareSnapshot.importFile(
            source: file, cacheDirectory: cache, maxBytes: 2),
        throwsA(isA<FileSystemException>()));
    await expectLater(
        FirmwareSnapshot.importFile(
            source: file, cacheDirectory: cache, maxBytes: 0),
        throwsArgumentError);
  });
}
