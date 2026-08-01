import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/ble_provider.dart';
import '../../providers/current_app_provider.dart';
import '../../providers/transfer_provider.dart';
import '../scan/scan_page.dart';
import '../device/device_page.dart';
import '../shared/disconnect_dialog.dart';

/// eBadge 应用根:Launcher 之上的第一个页面,作为连接状态门。
/// - 未连接 → [ScanPage](过滤 eBadge 设备名前缀)
/// - 已连接 → [DevicePage]
///
/// 断连时通过 `popUntil((r) => r.settings.name == '/ebadge-root')`
/// 弹回自己,而不弹到 Launcher。
///
/// 返回键行为:
/// - **已连接**:拦截返回键,弹「断开连接?」对话框(和 DevicePage 右上角
///   「断开」按钮同一份 UI),用户点「断开」后 disconnect(root gate 自动
///   切回 ScanPage),点「取消」则原地不动。
/// - **未连接**(在 ScanPage):正常 pop,返回 Launcher;此时通过
///   post-frame 延迟执行 stopScan/reset/清 currentApp,避免 ScanPage
///   在 deactivated 状态下被 riverpod notify 触发 markNeedsBuild 断言。
class EBadgeAppRoot extends ConsumerWidget {
  const EBadgeAppRoot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<ConnectedDeviceInfo?>(connectedDeviceProvider, (prev, next) {
      if (prev != null && next == null) {
        ref.read(transferProgressProvider.notifier).reset();
        Navigator.of(context)
            .popUntil((r) => r.settings.name == '/ebadge-root');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设备已断开')),
        );
      }
    });

    final connected = ref.watch(connectedDeviceProvider);
    final child = connected != null
        ? DevicePage(
            deviceName: connected.name,
            deviceId: connected.deviceId,
          )
        : const ScanPage(
            defaultDeviceFilter: 'eBadge',
            appTitle: 'eBadge',
          );

    // 已连接时拦截返回:弹对话框走"断开"确认流程,不允许直接 pop 到
    // Launcher(否则会跳过对话框、丢失用户对断开动作的确认)。
    final blockPopForDisconnect = connected != null;

    return PopScope(
      canPop: !blockPopForDisconnect,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          // 未连接分支:pop 已完成,回到 Launcher。清理动作延到下一 frame,
          // 避免同步改 provider 时 subtree 已 deactivated 引发
          // markNeedsBuild-on-defunct 断言。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(bleNotifierProvider.notifier).stopScan();
            ref.read(bleNotifierProvider.notifier).disconnect();
            ref.read(transferProgressProvider.notifier).reset();
            ref.read(currentAppProvider.notifier).state = null;
          });
          return;
        }
        // 已连接分支:pop 被拦截。弹「确认断开」对话框,确认则 disconnect,
        // root gate 会自动把 child 切回 ScanPage;取消则什么也不做。
        final confirmed = await showDisconnectConfirmDialog(context);
        if (!confirmed) return;
        ref.read(bleNotifierProvider.notifier).disconnect();
      },
      child: child,
    );
  }
}
