import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/ble_provider.dart';
import '../../providers/current_app_provider.dart';
import '../../providers/rtl8762_ota_provider.dart';
import '../scan/scan_page.dart';
import 'watch_device_page.dart';
import 'jw_device_page.dart';
import 'jw_history_page.dart';

/// Watch 应用根：结构与 EBadgeAppRoot 一致。
/// [PopScope] 保证返回 Launcher 时 disconnect + 清 currentApp（spec §4.4）。
class WatchAppRoot extends ConsumerStatefulWidget {
  const WatchAppRoot({super.key});

  @override
  ConsumerState<WatchAppRoot> createState() => _WatchAppRootState();
}

class _WatchAppRootState extends ConsumerState<WatchAppRoot> {
  bool _leaving = false;

  @override
  Widget build(BuildContext context) {
    if (_leaving) return const SizedBox.shrink();
    ref.listen<ConnectedDeviceInfo?>(connectedDeviceProvider, (prev, next) {
      // A popped route remains mounted during its exit animation. Its delayed
      // disconnect must not pop the Launcher after this route left the stack.
      if (prev != null &&
          next == null &&
          !_leaving &&
          !ref.read(rtl8762OtaInProgressProvider)) {
        Navigator.of(context).popUntil((r) =>
            r.settings.name == '/watch-root' ||
            (r.settings.name?.startsWith('/jw-history') ?? false) ||
            (r.settings.name?.startsWith('/jw-health') ?? false));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设备已断开')),
        );
      }
    });

    final connected = ref.watch(connectedDeviceProvider);
    final otaInProgress = ref.watch(rtl8762OtaInProgressProvider);
    final child = connected != null
        ? connected.isJw
            ? JwDevicePage(
                deviceName: connected.name, deviceId: connected.deviceId)
            : WatchDevicePage(
                deviceName: connected.name,
                deviceId: connected.deviceId,
              )
        : otaInProgress
            ? const SizedBox.shrink()
            : ScanPage(
                defaultDeviceFilter: 'Watch',
                appTitle: 'Watch',
                // Broad scan preserves FD50/manufacturer-only JW adverts. Shared
                // legacy adverts are candidates too; discovered GATT selects SDK.
                acceptJwCandidates: true,
                onBrowseSavedHistory: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        settings:
                            const RouteSettings(name: '/jw-history-devices'),
                        builder: (_) => const JwSavedHistoryDevicesPage())),
              );

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        _leaving = true;
        ref.read(bleNotifierProvider.notifier).disconnect();
        ref.read(currentAppProvider.notifier).state = null;
      },
      child: child,
    );
  }
}
