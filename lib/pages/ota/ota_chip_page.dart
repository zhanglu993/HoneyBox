import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/current_app_provider.dart';
import 'watch_ota_root.dart';

class OtaChipPage extends ConsumerWidget {
  const OtaChipPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) ref.read(currentAppProvider.notifier).state = null;
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('选择芯片类型')),
        body: ListView(children: [
          ListTile(
            leading: const Icon(Icons.memory),
            title: const Text('RTL8762D'),
            subtitle: const Text('Realtek 蓝牙固件升级'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const WatchOtaRoot(),
            )),
          ),
        ]),
      ),
    );
  }
}
