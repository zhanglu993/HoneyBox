import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../services/capture/capture_ble_transport.dart';
import '../../services/capture/capture_models.dart';
import '../../services/capture/capture_session.dart';
import '../../services/capture/capture_store.dart';
import 'capture_records_page.dart';
import 'capture_setup_page.dart';

class CapturePage extends StatefulWidget {
  final CaptureStore? store;
  const CapturePage({super.key, this.store});
  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  CaptureStore? _store;
  final _sessions = <CaptureSession>[];
  bool _loading = true, _saving = false, _leaving = false, _canPop = false;
  String? _error;
  bool _awake = false, _askedBackground = false;
  String? _notified;
  final _cardKeys = <CaptureSession, GlobalKey>{};
  // Refreshes "seconds since last packet" even when no packets arrive.
  late final Timer _clock = Timer.periodic(const Duration(seconds: 1), (_) {
    if (mounted && _sessions.any((s) => s.busy)) {
      setState(() {});
      _keepAlive();
    }
  });
  static const staleAfter = Duration(seconds: 15);
  @override
  void initState() {
    super.initState();
    _clock;
    unawaited(_load());
  }

  void _changed() {
    final awake = _sessions.any((s) => s.busy);
    if (Platform.isAndroid && awake != _awake) {
      _awake = awake;
      unawaited(const MethodChannel('honeybox/capture-power')
          .invokeMethod<void>('keepAwake', awake)
          .catchError((Object e) {
        _message('保持唤醒失败：$e');
      }));
      if (awake) unawaited(_askBackground());
    }
    _keepAlive();
    if (mounted) setState(() {});
  }

  /// Notification permission and battery whitelist, asked once per page.
  Future<void> _askBackground() async {
    if (_askedBackground) return;
    _askedBackground = true;
    try {
      await Permission.notification.request();
      if (!await Permission.ignoreBatteryOptimizations.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (_) {}
  }

  /// Foreground service with an ongoing notification while anything records.
  void _keepAlive() {
    if (!Platform.isAndroid || !mounted) return;
    final text = _sessions.any((s) => s.busy) ? _summary() : null;
    if (text == _notified) return;
    _notified = text;
    unawaited(const MethodChannel('honeybox/capture-power')
        .invokeMethod<void>('keepAlive', {'text': text}).catchError((Object e) {
      _message('后台保活启动失败：$e');
    }));
  }

  String _summary() {
    final recording =
        _sessions.where((s) => s.phase == CapturePhase.recording).length;
    final bad = [
      for (final s in _sessions)
        if (_abnormal(s)) '${s.profile.name} ${_status(s).$2.split(' ').first}'
    ];
    return [
      '${_sessions.length} 台 · 采集中 $recording',
      if (bad.isNotEmpty) '异常：${bad.join('，')}',
    ].join(' · ');
  }

  bool _abnormal(CaptureSession s) =>
      s.phase == CapturePhase.failed ||
      s.phase == CapturePhase.reconnecting ||
      _status(s).$2.startsWith('无数据');

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = widget.store ?? await CaptureStore.create();
      final profiles = await store.loadProfiles();
      if (!mounted) return;
      _store = store;
      for (final p in profiles) {
        _sessions.add(_makeSession(p));
      }
    } catch (e) {
      _error = '配置加载失败：$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  CaptureSession _makeSession(CaptureProfile profile) => CaptureSession(
        profile: profile,
        createConnection: () => CaptureBleConnection(profile.id),
        openRecording: _store!.openRecording,
      )..addListener(_changed);
  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> _edit([CaptureSession? old]) async {
    setState(() => _saving = true);
    try {
      final profile = await Navigator.push<CaptureProfile>(
          context,
          MaterialPageRoute(
            builder: (_) => CaptureSetupPage(
                store: _store,
                profile: old?.profile,
                existingIds: _sessions.map((s) => s.profile.id).toSet()),
          ));
      if (profile == null || !mounted) return;
      final profiles = [
        for (final s in _sessions)
          if (s != old) s.profile,
        profile
      ];
      await _store!.saveProfiles(profiles);
      if (!mounted) return;
      if (old != null) {
        _sessions.remove(old);
        _cardKeys.remove(old);
        old.dispose();
      }
      _sessions.add(_makeSession(profile));
    } catch (e) {
      _message('配置保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove(CaptureSession session) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('删除设备配置？'),
              content: Text('删除“${session.profile.name}”的配置，已采集文件会保留。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除'))
              ],
            ));
    if (confirmed != true || !mounted || session.busy) return;
    setState(() => _saving = true);
    try {
      await _store!.saveProfiles([
        for (final s in _sessions)
          if (s != session) s.profile
      ]);
      _sessions.remove(session);
      _cardKeys.remove(session);
      session.dispose();
    } catch (e) {
      _message('删除失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _export(CaptureSession session) async {
    final file = session.file;
    if (file == null || session.busy) return;
    await _exportFile(file);
  }

  Future<void> _exportFile(File file) async {
    try {
      if (Platform.isAndroid) {
        final path = await const MethodChannel('honeybox/capture-export')
            .invokeMethod<String>('export', {'path': file.path});
        if (path != null) _message('原始数据已导出：$path');
        return;
      }
      if (Platform.isIOS) {
        if (await file.length() > 16 * 1024 * 1024) {
          throw StateError('当前平台单次导出上限为 16 MiB，请从自动保存目录提取文件');
        }
        final path = await FilePicker.platform.saveFile(
          dialogTitle: '导出 BLE 原始数据',
          fileName:
              'ble_${file.parent.uri.pathSegments.where((p) => p.isNotEmpty).last}.jsonl',
          bytes: await file.readAsBytes(),
        );
        if (path != null) _message('原始数据已导出：$path');
        return;
      }
      final path =
          await FilePicker.platform.getDirectoryPath(dialogTitle: '选择原始数据导出目录');
      if (path == null) return;
      final target = await Directory(path).createTemp('ble_capture_');
      await file.copy('${target.path}/raw.jsonl');
      await File('${file.parent.path}/device.json')
          .copy('${target.path}/device.json');
      _message('已导出到 ${target.path}');
    } catch (e) {
      _message('导出失败：$e');
    }
  }

  Future<void> _history() async {
    final active = _sessions
        .where((s) => s.busy)
        .map((s) => s.file?.path)
        .whereType<String>()
        .toSet();
    await Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => CaptureRecordsPage(
                store: _store!, activePaths: active, onExport: _exportFile)));
  }

  Future<void> _stopAll() async => Future.wait(_sessions.map((s) => s.stop()));
  Future<void> _leave() async {
    if (_leaving || _saving) return;
    setState(() => _leaving = true);
    await _stopAll();
    if (mounted) {
      setState(() => _canPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid && _awake) {
      unawaited(const MethodChannel('honeybox/capture-power')
          .invokeMethod<void>('keepAwake', false)
          .catchError((Object _) {}));
    }
    if (Platform.isAndroid && _notified != null) {
      unawaited(const MethodChannel('honeybox/capture-power')
          .invokeMethod<void>(
              'keepAlive', {'text': null}).catchError((Object _) {}));
    }
    _clock.cancel();
    for (final s in _sessions) {
      s.removeListener(_changed);
      s.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final available = !_loading && !_saving && !_leaving && _store != null;
    return PopScope(
      canPop: _canPop || (!_sessions.any((s) => s.busy) && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('数据采集')),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: available ? _edit : null,
            icon: const Icon(Icons.add),
            label: const Text('添加设备')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(children: [
                if (_sessions.isNotEmpty) _overview(),
                Expanded(
                    child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  children: [
                    const Text('多设备独立采集 · 配置自动保存在本机',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text(
                        '采集期间请保持应用在前台。断连将自动重试并继续同一文件；Android 采集时保持屏幕唤醒。'),
                    if (_error != null) ...[
                      SelectableText(_error!),
                      TextButton(onPressed: _load, child: const Text('重新加载配置'))
                    ],
                    if (_leaving || _saving) const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.icon(
                          onPressed: available && _sessions.any((s) => !s.busy)
                              ? () {
                                  for (final s in _sessions) {
                                    if (!s.busy) unawaited(s.start());
                                  }
                                }
                              : null,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('全部开始')),
                      OutlinedButton.icon(
                          onPressed: available && _sessions.any((s) => s.busy)
                              ? _stopAll
                              : null,
                          icon: const Icon(Icons.stop),
                          label: const Text('全部停止')),
                      OutlinedButton.icon(
                          onPressed: available ? _history : null,
                          icon: const Icon(Icons.history),
                          label: const Text('采集记录')),
                    ]),
                    if (_sessions.isEmpty && _error == null)
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 48),
                          child: Text('还没有采集设备。添加设备并选择服务、通知特征后，下次即可直接复用。')),
                    for (final s in _sessions) _card(s, available),
                    if (_store != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: SelectableText(
                              '自动保存目录：${_store!.directory.path}/captures\n'
                              '每次采集独立保存 raw.jsonl 和 device.json；停止后可导出。')),
                  ],
                )),
              ]),
      ),
    );
  }

  (Color, String) _status(CaptureSession s) {
    final scheme = Theme.of(context).colorScheme;
    final last = s.lastActivity;
    final age = last == null ? Duration.zero : DateTime.now().difference(last);
    return switch (s.phase) {
      CapturePhase.recording when age > staleAfter => (
          Colors.amber.shade700,
          '无数据 ${age.inSeconds}s'
        ),
      CapturePhase.recording => (Colors.green.shade600, '采集中'),
      CapturePhase.starting => (scheme.primary, '连接中'),
      CapturePhase.reconnecting => (Colors.deepOrange, '掉线，重连中'),
      CapturePhase.stopping => (scheme.outline, '停止中'),
      CapturePhase.failed => (scheme.error, '失败'),
      CapturePhase.idle => (scheme.outline, '未采集'),
    };
  }

  String _age(CaptureSession s) {
    final last = s.lastPacketAt;
    if (last == null || !s.busy) return '';
    final seconds = DateTime.now().difference(last).inSeconds;
    return seconds < 60 ? '${seconds}s 前' : '${seconds ~/ 60}min 前';
  }

  Widget _overview() {
    final theme = Theme.of(context);
    final abnormal = _sessions.where(_abnormal).length;
    final recording =
        _sessions.where((s) => s.phase == CapturePhase.recording).length;
    return Material(
      key: const Key('capture-overview'),
      color: theme.colorScheme.surfaceContainerHigh,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.35),
        child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            children: [
              Text(
                  '${_sessions.length} 台 · 采集中 $recording'
                  '${abnormal > 0 ? ' · 异常 $abnormal' : ''}',
                  style: theme.textTheme.labelLarge?.copyWith(
                      color: abnormal > 0 ? theme.colorScheme.error : null)),
              for (final s in _sessions)
                InkWell(
                  onTap: () {
                    final card = _cardKeys[s]?.currentContext;
                    if (card != null) {
                      Scrollable.ensureVisible(card,
                          duration: const Duration(milliseconds: 250));
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Icon(Icons.circle, size: 12, color: _status(s).$1),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(s.profile.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Text(
                          s.profile.id.length > 5
                              ? s.profile.id.substring(s.profile.id.length - 5)
                              : s.profile.id,
                          style: theme.textTheme.bodySmall),
                      const SizedBox(width: 8),
                      SizedBox(
                          width: 96,
                          child: Text(_status(s).$2,
                              style: TextStyle(color: _status(s).$1))),
                      SizedBox(
                          width: 92,
                          child: Text('${s.packetCount} 包 ${_age(s)}',
                              textAlign: TextAlign.end,
                              style: theme.textTheme.bodySmall)),
                    ]),
                  ),
                ),
            ]),
      ),
    );
  }

  Widget _card(CaptureSession s, bool available) {
    const labels = {
      CapturePhase.idle: '未采集',
      CapturePhase.starting: '连接及订阅中',
      CapturePhase.recording: '采集中',
      CapturePhase.reconnecting: '等待重连',
      CapturePhase.stopping: '正在停止',
      CapturePhase.failed: '采集失败'
    };
    return Card(
        key: _cardKeys.putIfAbsent(s, GlobalKey.new),
        margin: const EdgeInsets.only(top: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.profile.name,
                style: Theme.of(context).textTheme.titleMedium),
            SelectableText(s.profile.id),
            Text(
                '${labels[s.phase]} · ${s.packetCount} 包 · ${s.byteCount} 字节 · 重连 ${s.reconnectCount} 次'),
            for (final c in s.profile.channels)
              Text('${c.service} / ${c.characteristic} · 实例 ${c.instance}'),
            if (s.error != null)
              SelectableText(s.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            Wrap(spacing: 8, children: [
              TextButton.icon(
                  onPressed: available && !s.busy ? s.start : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('开始')),
              TextButton.icon(
                  onPressed: available && s.busy ? s.stop : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('停止')),
              TextButton(
                  onPressed: available && !s.busy ? () => _edit(s) : null,
                  child: const Text('配置')),
              TextButton(
                  onPressed: available && !s.busy ? () => _remove(s) : null,
                  child: const Text('删除')),
              TextButton(
                  onPressed: available && !s.busy && s.file != null
                      ? () => _export(s)
                      : null,
                  child: const Text('导出')),
            ]),
            if (s.file != null) SelectableText('文件：${s.file!.path}'),
            if (s.recent.isNotEmpty)
              ExpansionTile(title: const Text('近期原始数据（HEX）'), children: [
                for (final p in s.recent.reversed.take(10))
                  ListTile(
                      dense: true,
                      title: SelectableText(p.hex.length > 160
                          ? '${p.hex.substring(0, 160)}…'
                          : p.hex),
                      subtitle: Text(
                          '#${p.sequence} ${p.time.toLocal().toIso8601String()} · ${p.channel.characteristic}')),
                const Text('预览最多显示 10 包，完整原始数据保存在文件中。'),
              ]),
          ]),
        ));
  }
}
