import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/capture/capture_records_page.dart';
import 'package:honeybox/services/capture/capture_store.dart';
import 'package:honeybox/services/qiniu/qiniu_controller.dart';
import 'package:honeybox/services/qiniu/qiniu_credential_store.dart';
import 'package:honeybox/services/qiniu/qiniu_config.dart';
import 'package:honeybox/services/qiniu/qiniu_storage_service.dart';
import 'package:honeybox/services/qiniu/qiniu_transfer.dart';

class MemoryStore extends QiniuCredentialStore {
  final QiniuConfig? value;
  const MemoryStore(this.value);
  @override
  Future<QiniuConfig?> load() async => value;
}

class FakeService extends QiniuStorageService {
  String? key;
  @override
  Future<void> upload(
      QiniuConfig config, File file, String key, QiniuTransfer transfer) async {
    this.key = key;
  }
}

void main() {
  testWidgets('latest batch is preselected, uploaded and its link copied',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('records_ui')))!;
    final service = FakeService();
    final controller = QiniuController(
        store: const MemoryStore(QiniuConfig(
            accessKey: 'ak',
            secretKey: 'sk',
            bucket: 'test',
            downloadDomain: 'https://files.example.com')),
        service: service);
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.runAsync(() async {
      for (final (folder, name, id, at) in [
        ('a', 'Polar H10', 'EE:6A:57:F3:9E:00', '2026-10-26T09:39:55Z'),
        ('b', 'S100', '79:DC:53:AB:1B:31', '2026-10-26T09:39:40Z'),
        ('c', 'S200', '69:36:6B:6A:00:45', '2026-10-25T09:00:00Z'),
      ]) {
        final d = await Directory('${dir.path}/captures/$folder')
            .create(recursive: true);
        await File('${d.path}/device.json').writeAsString(
            jsonEncode({'name': name, 'id': id, 'startedAt': at}));
        await File('${d.path}/raw.jsonl').writeAsString('{}\n');
      }
      await tester.pumpWidget(ProviderScope(
          overrides: [
            qiniuControllerProvider.overrideWith((ref) => controller)
          ],
          child: MaterialApp(
              home: CaptureRecordsPage(
                  store: CaptureStore(dir),
                  onExport: (_) async {},
                  tempDirectory: () async => dir))));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.text('Polar-H10_EE6A57F39E00'), findsOneWidget);
    expect(find.text('S200_69366B6A0045'), findsOneWidget);
    expect(find.text('上传（2）并复制链接'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('capture-upload')));
      for (var i = 0; i < 50 && copied == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(service.key, contains('Polar-H10_EE6A57F39E00+S100_79DC53AB1B31'));
    expect(copied, startsWith('https://files.example.com/'));
    expect(copied, contains('token=ak:'));
    expect(find.byIcon(Icons.link), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  testWidgets('select all then delete removes local records after confirm',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('records_del')))!;
    final controller = QiniuController(store: const MemoryStore(null));
    await tester.runAsync(() async {
      for (final folder in ['a', 'b']) {
        final d = await Directory('${dir.path}/captures/$folder')
            .create(recursive: true);
        await File('${d.path}/device.json').writeAsString(jsonEncode({
          'name': 'S100',
          'id': '79:DC:53:AB:1B:3$folder',
          // Only the newer record is preselected as the latest batch.
          'startedAt':
              folder == 'a' ? '2026-10-26T09:39:55Z' : '2026-10-26T08:00:00Z'
        }));
        await File('${d.path}/raw.jsonl').writeAsString('{}\n');
      }
      await tester.pumpWidget(ProviderScope(
          overrides: [
            qiniuControllerProvider.overrideWith((ref) => controller)
          ],
          child: MaterialApp(
              home: CaptureRecordsPage(
                  store: CaptureStore(dir), onExport: (_) async {}))));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.tap(find.byKey(const Key('capture-select-all')));
    await tester.pump();
    expect(find.byTooltip('全不选'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture-delete')));
    await tester.pumpAndSettle();
    expect(find.text('其中 2 条尚未上传，删除后无法找回。\n只删除本机文件，七牛上已上传的文件不受影响。'),
        findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('capture-delete-confirm')));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('暂无采集记录。'), findsOneWidget);
    expect(Directory('${dir.path}/captures/a').existsSync(), isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  testWidgets('recording in progress is listed but never deleted',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('records_live')))!;
    final controller = QiniuController(store: const MemoryStore(null));
    late String livePath;
    await tester.runAsync(() async {
      final d =
          await Directory('${dir.path}/captures/a').create(recursive: true);
      await File('${d.path}/device.json').writeAsString(jsonEncode({
        'name': 'S100',
        'id': '79:DC:53:AB:1B:31',
        'startedAt': '2026-10-26T09:39:55Z'
      }));
      livePath = '${d.path}/raw.jsonl';
      await File(livePath).writeAsString('{}\n');
      await tester.pumpWidget(ProviderScope(
          overrides: [
            qiniuControllerProvider.overrideWith((ref) => controller)
          ],
          child: MaterialApp(
              home: CaptureRecordsPage(
                  store: CaptureStore(dir),
                  activePaths: {File(livePath).path},
                  onExport: (_) async {}))));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.textContaining('采集中 · '), findsOneWidget);
    expect(find.text('上传（1）并复制链接'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('capture-delete-confirm')), findsNothing);
    expect(find.text('采集中的记录不能删除，请先停止'), findsOneWidget);
    expect(File(livePath).existsSync(), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
