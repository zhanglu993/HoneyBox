import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/qiniu/qiniu_config_page.dart';
import 'package:honeybox/services/qiniu/qiniu_config.dart';
import 'package:honeybox/services/qiniu/qiniu_controller.dart';
import 'package:honeybox/services/qiniu/qiniu_credential_store.dart';

class MemoryStore extends QiniuCredentialStore {
  const MemoryStore();
  @override
  Future<QiniuConfig?> load() async => const QiniuConfig(
      accessKey: 'ak', secretKey: 'sk', bucket: 'test-bucket');
}

void main() {
  testWidgets('分享和保存均可用且分享前提示密钥', (tester) async {
    final controller = QiniuController(store: const MemoryStore());
    await tester.pumpWidget(ProviderScope(
      overrides: [qiniuControllerProvider.overrideWith((ref) => controller)],
      child: const MaterialApp(home: QiniuConfigPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('分享配置'), findsOneWidget);
    expect(find.text('保存配置文件'), findsOneWidget);
    await tester.tap(find.text('分享配置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SecretKey'), findsWidgets);
    expect(find.text('继续分享'), findsOneWidget);
  });
}
