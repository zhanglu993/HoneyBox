import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/qiniu/qiniu_files_page.dart';
import 'package:honeybox/services/qiniu/qiniu_config.dart';
import 'package:honeybox/services/qiniu/qiniu_controller.dart';
import 'package:honeybox/services/qiniu/qiniu_credential_store.dart';
import 'package:honeybox/services/qiniu/qiniu_storage_service.dart';
import 'package:honeybox/services/qiniu/qiniu_transfer.dart';
import 'package:honeybox/theme/app_theme.dart';

class MemoryStore extends QiniuCredentialStore {
  const MemoryStore();
  @override
  Future<QiniuConfig?> load() async => const QiniuConfig(
      accessKey: 'ak',
      secretKey: 'sk',
      bucket: 'test',
      downloadDomain: 'https://files.example.com',
      privateBucket: false);
}

class MemoryService extends QiniuStorageService {
  final keys = <String>['first.txt', 'second.txt'];
  bool failSecond = false;
  @override
  Future<QiniuPage> list(QiniuConfig config,
          {String prefix = '',
          String marker = '',
          int limit = 100,
          QiniuTransfer? transfer}) async =>
      QiniuPage(keys.map((key) => QiniuObject(key: key, size: 1)).toList(), '');
  @override
  Future<void> delete(
      QiniuConfig config, String key, QiniuTransfer transfer) async {
    if (failSecond && key == 'second.txt') throw const QiniuException('失败');
    keys.remove(key);
  }
}

void main() {
  testWidgets('复制地址及批量删除需确认', (tester) async {
    final service = MemoryService();
    final controller =
        QiniuController(store: const MemoryStore(), service: service);
    String? clipboard;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(ProviderScope(
        overrides: [qiniuControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
            theme: AppTheme.lightTheme, home: const QiniuFilesPage())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('qiniu-copy-first.txt')));
    await tester.pumpAndSettle();
    expect(clipboard, 'https://files.example.com/first.txt');
    await tester.tap(find.byKey(const ValueKey('qiniu-select-first.txt')));
    await tester.tap(find.byKey(const ValueKey('qiniu-select-second.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('qiniu-delete-selected')));
    await tester.pumpAndSettle();
    expect(service.keys.length, 2);
    await tester.tap(find.byKey(const ValueKey('qiniu-delete-confirm')));
    await tester.pumpAndSettle();
    expect(service.keys, isEmpty);
    expect(find.text('已加载 0 个文件'), findsOneWidget);
  });
  testWidgets('部分删除失败保留失败项并提示', (tester) async {
    final service = MemoryService()..failSecond = true;
    final controller =
        QiniuController(store: const MemoryStore(), service: service);
    await tester.pumpWidget(ProviderScope(
      overrides: [qiniuControllerProvider.overrideWith((ref) => controller)],
      child:
          MaterialApp(theme: AppTheme.lightTheme, home: const QiniuFilesPage()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('qiniu-select-first.txt')));
    await tester.tap(find.byKey(const ValueKey('qiniu-select-second.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('qiniu-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('qiniu-delete-confirm')));
    await tester.pumpAndSettle();
    expect(service.keys, ['second.txt']);
    expect(find.textContaining('1 个未确认删除'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('qiniu-select-second.txt')), findsOneWidget);
  });
}
