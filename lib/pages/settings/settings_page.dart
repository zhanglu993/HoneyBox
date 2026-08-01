import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/current_app_provider.dart';
import '../../services/app_settings.dart';
import '../../services/file_cache.dart';
import '../launcher/app_catalog.dart';
import '../shared/file_send_layout.dart';

/// 设置 — application preferences. Currently the local send-cache: a size cap
/// (adjustable 5–50 MB) and an entry into the cache-management list.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  Future<int> _usage = Future.value(0);

  @override
  void initState() {
    super.initState();
    _refreshUsage();
  }

  void _refreshUsage() {
    setState(() {
      _usage = ref.read(fileCacheProvider).totalSize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final currentApp = ref.watch(currentAppProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('存储',
                style: theme.textTheme.titleSmall?.copyWith(color: cs.primary)),
          ),
          _cacheLimitCard(theme, cs, settings),
          const SizedBox(height: 12),
          _manageCard(theme, cs),
          if (currentApp == AppId.ebadge) ...[
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text('调试',
                  style:
                      theme.textTheme.titleSmall?.copyWith(color: cs.primary)),
            ),
            _debugModeCard(theme, cs, settings),
          ],
        ],
      ),
    );
  }

  Widget _cacheLimitCard(
      ThemeData theme, ColorScheme cs, AppSettings settings) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sd_storage_outlined,
                    size: 20, color: cs.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('本地缓存上限', style: theme.textTheme.titleMedium),
                ),
                Text('${settings.cacheLimitMB} MB',
                    style: theme.textTheme.titleMedium?.copyWith(
                        color: cs.primary, fontWeight: FontWeight.w600)),
              ],
            ),
            _CacheLimitSlider(
              value: settings.cacheLimitMB,
              onCommitted: (mb) async {
                ref.read(appSettingsProvider.notifier).setCacheLimitMB(mb);
                // Lowering the cap may put us over budget — prune immediately.
                await ref.read(fileCacheProvider).enforceLimit();
                if (mounted) _refreshUsage();
              },
            ),
            _usageRow(theme, cs, settings.cacheLimitMB),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _usageRow(ThemeData theme, ColorScheme cs, int limitMB) {
    return FutureBuilder<int>(
      future: _usage,
      builder: (context, snap) {
        final used = snap.data ?? 0;
        final limitBytes = limitMB * 1024 * 1024;
        final frac = limitBytes > 0 ? (used / limitBytes).clamp(0.0, 1.0) : 0.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 6,
                backgroundColor: cs.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 6),
            Text('已用 ${formatFileSize(used)} / $limitMB MB',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ],
        );
      },
    );
  }

  Widget _manageCard(ThemeData theme, ColorScheme cs) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.folder_outlined),
        title: const Text('管理本地缓存'),
        subtitle: FutureBuilder<int>(
          future: _usage,
          builder: (context, snap) => Text(
            snap.hasData ? '当前已用 ${formatFileSize(snap.data!)}' : '查看并删除已缓存的文件',
            style:
                theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).pushNamed('/cache');
          _refreshUsage(); // deletions there change usage
        },
      ),
    );
  }

  /// 「调试模式」开关卡片。打开后扫描列表首行注入虚拟 eBadge-debug 设备,
  /// 便于无实物调试 UI/交互;虚拟连接不会发送任何真实数据。
  Widget _debugModeCard(ThemeData theme, ColorScheme cs, AppSettings settings) {
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        secondary: const Icon(Icons.bug_report_outlined),
        title: const Text('调试模式'),
        subtitle: Text(
          '扫描列表首行会出现虚拟设备 eBadge-debug,用于无实物调试 UI 及交互。'
          '虚拟连接不会发送任何真实数据。',
          style:
              theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        value: settings.debugMode,
        onChanged: (v) =>
            ref.read(appSettingsProvider.notifier).setDebugMode(v),
      ),
    );
  }
}

/// Slider that reports its value continuously while dragging (for a live label)
/// but only commits — persisting + pruning — on release, avoiding a disk write
/// per drag tick.
class _CacheLimitSlider extends StatefulWidget {
  final int value;
  final ValueChanged<int> onCommitted;
  const _CacheLimitSlider({required this.value, required this.onCommitted});

  @override
  State<_CacheLimitSlider> createState() => _CacheLimitSliderState();
}

class _CacheLimitSliderState extends State<_CacheLimitSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final v = (_dragValue ?? widget.value.toDouble())
        .clamp(kMinCacheLimitMB.toDouble(), kMaxCacheLimitMB.toDouble());
    return Slider(
      value: v,
      min: kMinCacheLimitMB.toDouble(),
      max: kMaxCacheLimitMB.toDouble(),
      divisions: kMaxCacheLimitMB - kMinCacheLimitMB,
      label: '${v.round()} MB',
      onChanged: (nv) => setState(() => _dragValue = nv),
      onChangeEnd: (nv) {
        setState(() => _dragValue = null);
        widget.onCommitted(nv.round());
      },
    );
  }
}
