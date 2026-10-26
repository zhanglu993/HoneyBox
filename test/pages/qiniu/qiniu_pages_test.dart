import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/qiniu/qiniu_config_page.dart';
import 'package:honeybox/pages/qiniu/qiniu_files_page.dart';
import 'package:honeybox/services/qiniu/qiniu_config.dart';
import 'package:honeybox/services/qiniu/qiniu_controller.dart';
import 'package:honeybox/services/qiniu/qiniu_credential_store.dart';
import 'package:honeybox/services/qiniu/qiniu_storage_service.dart';
import 'package:honeybox/services/qiniu/qiniu_transfer.dart';

class ListingService extends QiniuStorageService {
  final requests = <String>[];
  @override
  Future<QiniuPage> list(QiniuConfig config,
      {String prefix = '',
      String marker = '',
      int limit = 100,
      QiniuTransfer? transfer}) async {
    requests.add('$prefix|$marker');
    return marker.isEmpty
        ? const QiniuPage(
            [QiniuObject(key: 'capture/中文.bin', size: 120)], 'next')
        : const QiniuPage(
            [QiniuObject(key: 'capture/next.bin', size: 240)], '');
  }
}

class MemoryStore extends QiniuCredentialStore {
  QiniuConfig? value;
  bool fail = false;
  MemoryStore(this.value);
  @override
  Future<QiniuConfig?> load() async => value;
  @override
  Future<void> save(QiniuConfig config) async {
    if (fail) throw StateError('test-secret');
    value = config;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class PendingService extends QiniuStorageService {
  final pending = Completer<QiniuPage>();
  @override
  Future<QiniuPage> list(QiniuConfig config,
      {String prefix = '',
      String marker = '',
      int limit = 100,
      QiniuTransfer? transfer}) {
    transfer?.attach(() {
      if (!pending.isCompleted) pending.completeError(const QiniuCancelled());
    });
    return pending.future;
  }
}

const saved =
    QiniuConfig(accessKey: 'my-ak', secretKey: 'my-sk', bucket: 'my-bucket');

void main() {
  Future<PendingService> startTest(WidgetTester tester) async {
    final service = PendingService();
    final controller =
        QiniuController(store: MemoryStore(saved), service: service);
    await tester.pumpWidget(ProviderScope(
        overrides: [qiniuControllerProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: QiniuConfigPage())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('测试连接'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('测试连接'));
    await tester.pump();
    return service;
  }

  testWidgets(
      'connection test shows pending state then prominent success feedback',
      (tester) async {
    final service = await startTest(tester);
    expect(find.text('测试中…'), findsOneWidget);
    expect(find.text('取消测试'), findsOneWidget);
    service.pending.complete(const QiniuPage([], ''));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('连接成功'), findsWidgets);
  });
  testWidgets('connection test reports a failure and enables retry',
      (tester) async {
    final service = await startTest(tester);
    service.pending.completeError(const QiniuException('鉴权失败（401）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('测试失败'), findsWidgets);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);
  });
  testWidgets('connection test has a total timeout and cancels network work',
      (tester) async {
    final service = await startTest(tester);
    await tester.pump(const Duration(seconds: 21));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('20 秒'), findsWidgets);
    expect(service.pending.isCompleted, isTrue);
    expect(find.text('测试连接'), findsOneWidget);
  });
  testWidgets('file page browses metadata and loads the next page',
      (tester) async {
    final service = ListingService();
    final controller =
        QiniuController(store: MemoryStore(saved), service: service);
    await tester.pumpWidget(ProviderScope(
        overrides: [qiniuControllerProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: QiniuFilesPage())));
    await tester.pumpAndSettle();
    expect(find.text('capture/中文.bin'), findsOneWidget);
    await tester.tap(find.text('capture/中文.bin'));
    await tester.pumpAndSettle();
    expect(find.textContaining('大小：120 字节'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('capture/next.bin'), findsOneWidget);
    expect(service.requests, ['|', '|next']);
  });
  testWidgets(
      'unconfigured file page offers its independent configuration entry',
      (tester) async {
    final controller = QiniuController(store: MemoryStore(null));
    await tester.pumpWidget(ProviderScope(
        overrides: [qiniuControllerProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: QiniuFilesPage())));
    await tester.pumpAndSettle();
    expect(find.text('前往配置'), findsOneWidget);
    await tester.tap(find.text('前往配置'));
    await tester.pumpAndSettle();
    expect(find.byType(QiniuConfigPage), findsOneWidget);
  });
  Future<QiniuController> show(WidgetTester tester, MemoryStore store) async {
    final controller = QiniuController(store: store);
    await tester.pumpWidget(ProviderScope(
        overrides: [qiniuControllerProvider.overrideWith((ref) => controller)],
        child: const MaterialApp(home: QiniuConfigPage())));
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('restores personal config and masks SecretKey', (tester) async {
    await show(tester, MemoryStore(saved));
    expect(find.text('my-ak'), findsOneWidget);
    final secret = tester.widget<TextField>(find.descendant(
        of: find.byKey(const Key('qiniu-secret')),
        matching: find.byType(TextField)));
    expect(secret.obscureText, isTrue);
    await tester.tap(find.byTooltip('显示 SecretKey'));
    await tester.pump();
    expect(
        tester
            .widget<TextField>(find.descendant(
                of: find.byKey(const Key('qiniu-secret')),
                matching: find.byType(TextField)))
            .obscureText,
        isFalse);
  });
  testWidgets('save failure stays visible and does not disclose plugin error',
      (tester) async {
    final store = MemoryStore(saved)..fail = true;
    await show(tester, store);
    await tester.scrollUntilVisible(find.text('保存配置'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('操作失败'), findsWidgets);
    expect(find.textContaining('test-secret'), findsNothing);
    expect(store.value, saved);
  });
  testWidgets('clear removes local account and resets form', (tester) async {
    final store = MemoryStore(saved);
    await show(tester, store);
    await tester.scrollUntilVisible(find.text('清除本机配置'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('清除本机配置'));
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(find.text('my-ak'), findsNothing);
  });
  test('busy operation rejects credential switch until task ends', () async {
    final controller = QiniuController(store: MemoryStore(saved));
    await controller.ensureLoaded();
    final future = controller.run('测试', (task) async {
      await expectLater(controller.clear(), throwsA(isA<StateError>()));
      expect(controller.config, saved);
    });
    await future;
    expect(controller.busy, isFalse);
    controller.dispose();
  });
}
