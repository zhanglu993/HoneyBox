import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/qiniu/qiniu_files_page.dart';
import 'package:honeybox/theme/app_theme.dart';
import 'package:honeybox/services/qiniu/qiniu_config.dart';
import 'package:honeybox/services/qiniu/qiniu_controller.dart';
import 'package:honeybox/services/qiniu/qiniu_credential_store.dart';
import 'package:honeybox/services/qiniu/qiniu_storage_service.dart';
import 'package:honeybox/services/qiniu/qiniu_transfer.dart';

class Store extends QiniuCredentialStore {
  const Store();
  @override
  Future<QiniuConfig?> load() async =>
      const QiniuConfig(accessKey: 'ak', secretKey: 'sk', bucket: 'test');
}

class Service extends QiniuStorageService {
  @override
  Future<QiniuPage> list(QiniuConfig config,
          {String prefix = '',
          String marker = '',
          int limit = 100,
          QiniuTransfer? transfer}) async =>
      const QiniuPage([QiniuObject(key: 'example.json', size: 42)], '');
}

void main() {
  testWidgets('已配置时显示文件列表', (tester) async {
    final controller =
        QiniuController(store: const Store(), service: Service());
    await tester.pumpWidget(ProviderScope(
        overrides: [qiniuControllerProvider.overrideWith((ref) => controller)],
        child: MaterialApp(
            theme: AppTheme.lightTheme, home: const QiniuFilesPage())));
    await tester.pumpAndSettle();
    expect(find.text('example.json'), findsOneWidget);
    expect(find.text('已加载 1 个文件'), findsOneWidget);
  });
}
