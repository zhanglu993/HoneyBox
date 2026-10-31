import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/ble_provider.dart';
import '../../providers/jw_device_provider.dart';
import '../../services/jw/jw_models.dart';
import '../../services/jw/jw_device_repository.dart';
import 'jw_history_page.dart';
import 'health/jw_health_page.dart';
import 'jw_test_console.dart';
import 'jw_observation_panel.dart';

class JwDevicePage extends ConsumerWidget {
  final String deviceId;
  final String deviceName;
  const JwDevicePage(
      {super.key, required this.deviceId, required this.deviceName});
  static const _phases = {
    JwDevicePhase.loading: '正在读取设备',
    JwDevicePhase.readOnly: '只读',
    JwDevicePhase.identityUnavailable: '本地标识不可用，仅可读取',
    JwDevicePhase.loggingIn: '正在登录',
    JwDevicePhase.loggedIn: '协议登录成功',
    JwDevicePhase.loginRejected: '设备拒绝登录',
    JwDevicePhase.failed: '通信失败，请断开重试',
    JwDevicePhase.disconnected: '设备已断开',
  };
  JwDeviceRepository? _resolvedHealthRepository(WidgetRef ref) {
    final current = ref.read(jwRepositoryProvider);
    // AsyncLoading can retain the previous connection's repository.
    if (current.isLoading || current.hasError) return null;
    final repository = current.valueOrNull;
    if (repository == null ||
        repository.platformDeviceKey != deviceId ||
        repository.state.info == null) {
      return null;
    }
    return repository;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(jwDeviceProvider);
    final actions = ref.read(jwDeviceProvider.notifier);
    final caps = state.capabilities;
    ref.watch(jwRepositoryProvider);
    final healthReady = _resolvedHealthRepository(ref) != null;
    final ready = state.canWrite;
    final canLogin = !state.operationInProgress &&
        [
          JwDevicePhase.readOnly,
          JwDevicePhase.loginRejected,
          JwDevicePhase.loggedIn
        ].contains(state.phase);
    final canBind = !state.operationInProgress &&
        [JwDevicePhase.readOnly, JwDevicePhase.loginRejected]
            .contains(state.phase);
    final languageSupported = caps?.languages == true &&
        state.language != null &&
        state.language! <= 2;
    return Scaffold(
        appBar: AppBar(
            title: Text(deviceName.isEmpty ? 'JW Watch' : deviceName),
            actions: [
              TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.onPrimary),
                  onPressed: () =>
                      ref.read(bleNotifierProvider.notifier).disconnect(),
                  child: const Text('断开'))
            ]),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(_phases[state.phase]!,
              style: Theme.of(context).textTheme.titleLarge),
          if (state.operationInProgress) const LinearProgressIndicator(),
          if (state.operationError != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(state.operationError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton.icon(
                key: const Key('jw-health-entry'),
                icon: const Icon(Icons.favorite_outline),
                onPressed: healthReady
                    ? () {
                        // Recheck at invocation; a queued press may outlive the
                        // frame in which this connection was ready.
                        final repository = _resolvedHealthRepository(ref);
                        if (repository == null) return;
                        final healthKey = repository.historyDeviceKey;
                        Navigator.of(context).push(MaterialPageRoute<void>(
                            settings: const RouteSettings(name: '/jw-health'),
                            builder: (_) => JwHealthPage(
                                deviceKey: healthKey, deviceName: deviceName)));
                      }
                    : null,
                label: const Text('健康概览')),
            OutlinedButton(
                key: const Key('jw-test-console'),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        settings:
                            const RouteSettings(name: '/jw-sdk-test-console'),
                        builder: (_) => JwSdkTestConsole(deviceId: deviceId))),
                child: const Text('SDK 调试')),
            TextButton(
                key: const Key('jw-health-saved-devices'),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        settings:
                            const RouteSettings(name: '/jw-history-devices'),
                        builder: (_) => const JwSavedHistoryDevicesPage())),
                child: const Text('已保存设备'))
          ]),
          Text('设备：${state.info?.name ?? deviceName}'),
          Text(
              '序列号：${state.info?.deviceKey.isNotEmpty == true ? state.info!.deviceKey : "未提供"}'),
          Text(
              '固件：${state.info?.firmware ?? "未提供"} · 硬件：${state.info?.hardware ?? "未提供"}'),
          Text(
              '电量：${state.info?.battery == null ? "未读取" : "${state.info!.battery}%"}'),
          if (caps != null) ...[
            Text(
                '能力：${caps.rawHex} · 工厂开关：0x${caps.factorySwitchRaw.toRadixString(16)}'),
            Text(
                '心率：${caps.heartRate ? "支持" : "不支持"} · 语言：${caps.languages ? "支持" : "不支持"}'),
            Text(
                'HRV：${caps.hrv ? "支持" : "不支持"} · 温度：${caps.temperature ? "支持" : "不支持"}'),
          ],
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 8, children: [
            OutlinedButton(
                key: const Key('jw-login'),
                onPressed: canLogin ? actions.login : null,
                child: const Text('登录')),
            OutlinedButton(
                key: const Key('jw-bind'),
                onPressed: canBind
                    ? () async {
                        final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                                    title: const Text('首次绑定'),
                                    content: const Text(
                                        '仅用于确认需要首次绑定的设备。绑定会清除 readiness 夜间摘要，并重置设备时间和计步状态；当前操作不可恢复。已能登录时无需绑定。'),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('取消')),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('确认首次绑定'))
                                    ]));
                        if (confirmed == true && context.mounted) {
                          await actions.bind(confirmedFirstBind: true);
                        }
                      }
                    : null,
                child: const Text('首次绑定')),
          ]),
          const Divider(height: 32),
          FilledButton(
              key: const Key('jw-time'),
              onPressed: ready ? () => actions.syncTime(DateTime.now()) : null,
              child: const Text('同步当前时间')),
          if (state.timeSubmitted) const Text('时间请求已送达，设备时钟待验证'),
          const SizedBox(height: 16),
          Text('设备语言：${state.language ?? "未读取"}'),
          Wrap(
              spacing: 8,
              children: List.generate(
                  3,
                  (i) => OutlinedButton(
                      key: Key('jw-language-$i'),
                      onPressed: ready && languageSupported
                          ? () => actions.setLanguage(i)
                          : null,
                      child: Text(['English', '简体中文', '繁體中文'][i])))),
          if (caps != null && !languageSupported) const Text('当前语言能力或原始值不支持修改'),
          const Divider(height: 32),
          Text(
              state.lastHeartRate == null
                  ? '等待有效心率样本'
                  : '${state.lastHeartRate!.bpm} BPM',
              style: Theme.of(context).textTheme.headlineMedium),
          if (state.lastHeartRate != null)
            Text(
                '设备日期 ${state.lastHeartRate!.date.toIso8601String().substring(0, 10)} · 收到 ${state.lastHeartRate!.receivedAt.toLocal()}'),
          FilledButton(
              key: const Key('jw-heart'),
              onPressed: ready && caps?.heartRate == true
                  ? () =>
                      actions.setHeartRateStreaming(!state.heartRateStreaming)
                  : null,
              child: Text(state.heartRateStreaming ? '停止实时心率' : '开启实时心率')),
          if (caps != null && !caps.heartRate) const Text('设备不支持心率'),
          const Divider(height: 32),
          JwObservationPanel(key: ObjectKey(actions.repository)),
          const Divider(height: 32),
          JwHistoryOverview(
              state: state,
              onSync: () async {
                try {
                  await actions.syncHistory();
                } catch (_) {/* Repository publishes the error. */}
              },
              onCancel: () async {
                await actions.cancelHistory();
              },
              onBrowse: () {
                final serial = state.info?.deviceKey.trim();
                final key =
                    'jw:${serial != null && serial.isNotEmpty ? serial : deviceId}';
                Navigator.of(context).push(MaterialPageRoute<void>(
                    settings: const RouteSettings(name: '/jw-history-records'),
                    builder: (_) => JwHistoryRecordsPage(deviceKey: key)));
              }),
        ]));
  }
}
