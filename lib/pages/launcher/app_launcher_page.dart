import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/current_app_provider.dart';
import '../dashboard/dashboard_app_root.dart';
import '../ebadge/ebadge_app_root.dart';
import '../shared/update_flow.dart';
import '../watch/watch_app_root.dart';
import '../capture/capture_page.dart';
import 'app_catalog.dart';
import 'widgets/app_card.dart';

/// Sentinel value for the overflow-menu entry that is an *action* rather than a
/// route push (all other values are route names).
const String _kUpdateAction = '#check-update';

/// APK 打开时首先看到的页面。
/// 从 [kAppCatalog] 读取应用清单，展示为卡片列表。点击后 push 对应
/// `<App>AppRoot`（带 route name，供断连回退 popUntil 匹配）。
class AppLauncherPage extends ConsumerWidget {
  const AppLauncherPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择应用'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              // '检查更新' runs in place; every other entry is a route name.
              if (v == _kUpdateAction) {
                runUpdateCheck(context);
                return;
              }
              Navigator.pushNamed(context, v);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: '/qiniu-files', child: Text('七牛云文件')),
              PopupMenuItem(value: '/qiniu-config', child: Text('七牛云配置')),
              PopupMenuItem(value: '/chip-config', child: Text('芯片配置')),
              PopupMenuItem(value: _kUpdateAction, child: Text('检查更新')),
            ],
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: kAppCatalog.length,
        itemBuilder: (_, i) {
          final entry = kAppCatalog[i];
          return AppCard(
            entry: entry,
            onTap: () => _launch(context, ref, entry),
          );
        },
      ),
    );
  }

  Future<void> _launch(
    BuildContext context,
    WidgetRef ref,
    AppEntry entry,
  ) async {
    if (entry.id == AppId.dashboard) {
      try {
        await const MethodChannel('honeybox/map').invokeMethod<void>('open');
      } on PlatformException catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error.message ?? '无法打开地图功能')),
          );
        }
      } on MissingPluginException {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('当前平台不支持地图功能')),
          );
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('无法打开地图功能：$error')),
          );
        }
      }
      return;
    }

    ref.read(currentAppProvider.notifier).state = entry.id;
    final name = routeNameFor(entry.id);
    Navigator.of(context).push(MaterialPageRoute(
      settings: RouteSettings(name: name),
      builder: (_) => _rootFor(entry),
    ));
  }

  Widget _rootFor(AppEntry entry) {
    switch (entry.id) {
      case AppId.ebadge:
        return const EBadgeAppRoot();
      case AppId.watch:
        return const WatchAppRoot();
      case AppId.dashboard:
        return const DashboardAppRoot();
      case AppId.capture:
        return const CapturePage();
    }
  }
}
