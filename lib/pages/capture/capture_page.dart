import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/capture/capture_ble_transport.dart';
import '../../services/capture/capture_models.dart';
import '../../services/capture/capture_session.dart';
import '../../services/capture/capture_store.dart';
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
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

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
    try {
      final files = await _store!.listRecordings();
      final active =
          _sessions.where((s) => s.busy).map((s) => s.file?.path).toSet();
      final entries = <(File, String)>[];
      for (final file in files) {
        if (active.contains(file.path)) continue;
        var name = file.parent.path;
        try {
          final metadata = jsonDecode(
                  await File('${file.parent.path}/device.json').readAsString())
              as Map;
          name = '${metadata['name']} · ${metadata['startedAt']}';
        } catch (_) {/* Raw file remains accessible if metadata is damaged. */}
        entries.add((file, name));
      }
      if (!mounted) return;
      final selected = await showDialog<File>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: const Text('已保存的采集记录'),
                content: SizedBox(
                    width: 560,
                    height: 360,
                    child: entries.isEmpty
                        ? const Text('暂无已停止的采集记录。')
                        : ListView(children: [
                            for (final entry in entries)
                              ListTile(
                                title: Text(entry.$2),
                                subtitle: Text(entry.$1.parent.path),
                                trailing:
                                    const Icon(Icons.file_download_outlined),
                                onTap: () => Navigator.pop(ctx, entry.$1),
                              )
                          ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭'))
                ],
              ));
      if (selected != null) await _exportFile(selected);
    } catch (e) {
      _message('读取采集记录失败：$e');
    }
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
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                children: [
                  const Text('多设备独立采集 · 配置自动保存在本机',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('采集期间请保持应用在前台。设备断连后可手动重新开始；需厂商启动命令的设备请先开启数据输出。'),
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
              ),
      ),
    );
  }

  Widget _card(CaptureSession s, bool available) {
    const labels = {
      CapturePhase.idle: '未采集',
      CapturePhase.starting: '连接及订阅中',
      CapturePhase.recording: '采集中',
      CapturePhase.stopping: '正在停止',
      CapturePhase.failed: '采集失败'
    };
    return Card(
        margin: const EdgeInsets.only(top: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.profile.name,
                style: Theme.of(context).textTheme.titleMedium),
            SelectableText(s.profile.id),
            Text('${labels[s.phase]} · ${s.packetCount} 包 · ${s.byteCount} 字节'),
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
