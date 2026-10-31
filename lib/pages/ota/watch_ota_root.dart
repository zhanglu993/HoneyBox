import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/ble_provider.dart';
import '../../providers/rtl8762_ota_provider.dart';
import '../scan/scan_page.dart';
import 'realtek_ota_page.dart';

/// Scan for a candidate before opening the RTL8762D upgrade page.
class WatchOtaRoot extends ConsumerStatefulWidget {
  const WatchOtaRoot({super.key});

  @override
  ConsumerState<WatchOtaRoot> createState() => _WatchOtaRootState();
}

class _WatchOtaRootState extends ConsumerState<WatchOtaRoot> {
  ScanDevice? _selected;

  @override
  Widget build(BuildContext context) {
    final upgrading = ref.watch(rtl8762OtaInProgressProvider);
    return PopScope(
      canPop: !upgrading,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        ref.read(bleNotifierProvider.notifier).disconnect();
      },
      child: _selected != null
          ? RealtekOtaPage(device: _selected!)
          : ScanPage(
              defaultDeviceFilter: '',
              appTitle: 'OTA',
              acceptJwCandidates: true,
              defaultOnlyNamed: true,
              defaultOnlyConnectable: true,
              defaultSortBySignal: true,
              onDeviceSelected: (device) => setState(() => _selected = device),
            ),
    );
  }
}
