import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../services/capture/capture_store.dart';
import '../../services/capture/capture_upload.dart';
import '../../services/qiniu/qiniu_controller.dart';

class CaptureRecordsPage extends ConsumerStatefulWidget {
  final CaptureStore store;
  final Set<String> activePaths;
  final Future<void> Function(File raw) onExport;
  final Future<Directory> Function() tempDirectory;
  const CaptureRecordsPage(
      {super.key,
      required this.store,
      required this.onExport,
      this.activePaths = const {},
      this.tempDirectory = getTemporaryDirectory});
  @override
  ConsumerState<CaptureRecordsPage> createState() => _CaptureRecordsPageState();
}

class _CaptureRecordsPageState extends ConsumerState<CaptureRecordsPage> {
  late final QiniuController _qiniu;
  List<CaptureRecord> _records = [];
  final _selected = <String>{};
  bool _loading = true;
  String _error = '';
  String? _link;

  @override
  void initState() {
    super.initState();
    _qiniu = ref.read(qiniuControllerProvider);
    unawaited(Future.microtask(_load));
  }

  @override
  void dispose() {
    _qiniu.cancel();
    super.dispose();
  }

  Future<void> _load(
      {bool selectLatest = true, bool preserveSelection = false}) async {
    try {
      await _qiniu.ensureLoaded();
      final files = await widget.store.listRecordings();
      final records = <CaptureRecord>[];
      for (final f in files) {
        records.add(await CaptureRecord.load(f));
      }
      records.sort((a, b) =>
          (b.startedAt ?? DateTime(0)).compareTo(a.startedAt ?? DateTime(0)));
      if (!mounted) return;
      setState(() {
        final previous = _selected.toSet();
        _records = records;
        _selected.clear();
        if (preserveSelection) {
          _selected.addAll(records
              .where((r) => previous.contains(r.raw.path))
              .map((r) => r.raw.path));
        } else if (selectLatest) {
          _selected.addAll(latestCaptureBatch(records).map((r) => r.raw.path));
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '读取采集记录失败：$e';
          _loading = false;
        });
      }
    }
  }

  void _say(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  String? _configError() {
    final config = _qiniu.config;
    if (config == null) return '请先在首页菜单「七牛云配置」中填写七牛账号';
    return config.validationError(forDownload: true);
  }

  Future<void> _copy(Uri link) async {
    await _copyLinks([link]);
  }

  Future<void> _copyLinks(Iterable<Uri> links) async {
    final unique = links.map((link) => link.toString()).toSet();
    try {
      final text = unique.join('\n');
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) setState(() => _link = text);
      _say(
          '${unique.length == 1 ? '链接已复制' : '已复制 ${unique.length} 个链接'}，7 天内有效');
    } catch (_) {
      _say('复制链接失败，请重试');
    }
  }

  Future<void> _copyKeys(Iterable<String> keys) {
    final now = DateTime.now();
    return _copyLinks(keys
        .toSet()
        .map((key) => captureShareLink(_qiniu.config!, key, now: now)));
  }

  List<CaptureRecord> get _selectedRecords =>
      _records.where((r) => _selected.contains(r.raw.path)).toList();

  String? _bucketError(Iterable<CaptureRecord> records) {
    for (final record in records) {
      if (record.upload?['bucket'] != _qiniu.config!.bucket) {
        return '该记录上传到空间 ${record.upload?['bucket']}，与当前配置不同';
      }
    }
    return null;
  }

  Future<void> _copySelected() async {
    if (_qiniu.busy) return;
    final error = _configError();
    if (error != null) return _say(error);
    final records = _selectedRecords;
    if (records.isEmpty) return _say('请先勾选要复制链接的记录');
    if (records.any((r) => r.uploadedKey == null)) {
      return _say('选中记录中有尚未上传的文件，请先上传或取消勾选');
    }
    final bucketError = _bucketError(records);
    if (bucketError != null) return _say(bucketError);
    await _copyKeys(records.map((r) => r.uploadedKey!));
  }

  Future<void> _upload({bool force = false}) async {
    final error = _configError();
    if (error != null) return _say(error);
    final records = _selectedRecords;
    if (records.isEmpty) return _say('请先勾选要上传的记录');
    final config = _qiniu.config!;
    final reused = force
        ? <CaptureRecord>[]
        : records.where((r) => r.uploadedKey != null).toList();
    final pending =
        force ? records : records.where((r) => r.uploadedKey == null).toList();
    final bucketError = _bucketError(reused);
    if (bucketError != null) return _say(bucketError);
    if (pending.isEmpty) return _copySelected();
    try {
      final key = await _qiniu.run('上传采集记录', (task) async {
        final temp = await widget.tempDirectory();
        return uploadCaptureBatch(_qiniu.service, config, pending, task, temp,
            live: {
              for (final r in pending)
                if (_live(r)) r.raw.path
            });
      });
      await _copyKeys([
        for (final record in reused) record.uploadedKey!,
        key,
      ]);
      await _load(preserveSelection: true);
    } catch (_) {
      _say(_qiniu.error.isEmpty ? '上传失败' : _qiniu.error);
    }
  }

  Future<void> _delete() async {
    final records = _records
        .where((r) => _selected.contains(r.raw.path) && !_live(r))
        .toList();
    if (records.isEmpty) return _say('采集中的记录不能删除，请先停止');
    final skipped = _selected.length - records.length;
    final pending = records.where((r) => r.uploadedKey == null).length;
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('删除 ${records.length} 条采集记录？'),
              content: Text([
                if (pending > 0) '其中 $pending 条尚未上传，删除后无法找回。',
                if (skipped > 0) '另有 $skipped 条正在采集，不会删除。',
                '只删除本机文件，七牛上已上传的文件不受影响。',
              ].join('\n')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                FilledButton(
                    key: const Key('capture-delete-confirm'),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除')),
              ],
            ));
    if (ok != true) return;
    var failed = 0;
    for (final r in records) {
      try {
        await widget.store.deleteRecording(r.raw);
      } catch (_) {
        failed++;
      }
    }
    _say(failed == 0
        ? '已删除 ${records.length} 条记录'
        : '有 $failed 条删除失败，请确认未被其他程序占用');
    await _load(selectLatest: false);
  }

  Future<void> _relink(CaptureRecord record) async {
    final error = _configError();
    if (error != null) return _say(error);
    final config = _qiniu.config!;
    if (record.upload?['bucket'] != config.bucket) {
      return _say('该记录上传到空间 ${record.upload?['bucket']}，与当前配置不同');
    }
    await _copy(captureShareLink(config, record.uploadedKey!));
  }

  // Directory.list() joins with '\\' on Windows while sessions use '/'.
  static String _norm(String path) => path.replaceAll('\\', '/');

  bool _live(CaptureRecord r) =>
      widget.activePaths.map(_norm).contains(_norm(r.raw.path));

  String _uploadNote(CaptureRecord r) {
    if (r.uploadedKey == null) return '';
    return r.upload?['live'] == true ? ' · 已上传快照' : ' · 已上传';
  }

  String _time(DateTime? t) {
    if (t == null) return '时间未知';
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.month}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  String _size(File f) {
    final n = f.existsSync() ? f.lengthSync() : 0;
    if (n >= 1 << 20) return '${(n / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(n / 1024).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
        listenable: _qiniu,
        builder: (context, _) {
          final busy = _qiniu.busy;
          final selected = _selectedRecords;
          final allUploaded = selected.isNotEmpty &&
              selected.every((r) => r.uploadedKey != null);
          return Scaffold(
            appBar: AppBar(title: const Text('采集记录'), actions: [
              if (_records.isNotEmpty)
                IconButton(
                    key: const Key('capture-select-all'),
                    tooltip: _selected.length == _records.length ? '全不选' : '全选',
                    onPressed: busy
                        ? null
                        : () => setState(() {
                              if (_selected.length == _records.length) {
                                _selected.clear();
                              } else {
                                _selected
                                    .addAll(_records.map((r) => r.raw.path));
                              }
                            }),
                    icon: Icon(_selected.length == _records.length
                        ? Icons.deselect
                        : Icons.select_all)),
            ]),
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error.isNotEmpty
                    ? Center(child: Text(_error))
                    : _records.isEmpty
                        ? const Center(child: Text('暂无采集记录。'))
                        : ListView(children: [
                            for (final r in _records)
                              CheckboxListTile(
                                key: ValueKey(r.raw.path),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                contentPadding:
                                    const EdgeInsets.only(left: 8, right: 4),
                                value: _selected.contains(r.raw.path),
                                onChanged: busy
                                    ? null
                                    : (v) => setState(() => v == true
                                        ? _selected.add(r.raw.path)
                                        : _selected.remove(r.raw.path)),
                                title: Text(r.label),
                                subtitle: Text('${_live(r) ? '采集中 · ' : ''}'
                                    '${_time(r.startedAt)} · ${_size(r.raw)}'
                                    '${_uploadNote(r)}'),
                                secondary: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (r.uploadedKey != null)
                                        TextButton.icon(
                                            style: TextButton.styleFrom(
                                                visualDensity:
                                                    VisualDensity.compact),
                                            label: const Text('复制链接'),
                                            onPressed:
                                                busy ? null : () => _relink(r),
                                            icon: const Icon(Icons.link)),
                                      IconButton(
                                          visualDensity: VisualDensity.compact,
                                          tooltip: '导出到本机',
                                          onPressed: busy || _live(r)
                                              ? null
                                              : () => widget.onExport(r.raw),
                                          icon: const Icon(
                                              Icons.file_download_outlined)),
                                    ]),
                              )
                          ]),
            bottomNavigationBar: SafeArea(
                child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (busy) ...[
                  LinearProgressIndicator(
                      value:
                          _qiniu.total > 0 ? _qiniu.done / _qiniu.total : null),
                  const SizedBox(height: 4),
                  Text(_qiniu.total > 0
                      ? '${_qiniu.status} ${(_qiniu.done * 100 / _qiniu.total).toStringAsFixed(0)}%'
                      : '正在打包…'),
                ],
                if (_link != null && !busy)
                  SelectableText(_link.toString(),
                      maxLines: 3,
                      style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: FilledButton.icon(
                          key: Key(allUploaded
                              ? 'capture-copy-links'
                              : 'capture-upload'),
                          onPressed: busy || _selected.isEmpty
                              ? null
                              : allUploaded
                                  ? _copySelected
                                  : () => _upload(),
                          icon: Icon(allUploaded
                              ? Icons.copy
                              : Icons.cloud_upload_outlined),
                          label: Text(allUploaded
                              ? '复制选中链接（${_selected.length}）'
                              : '上传（${_selected.length}）并复制链接'))),
                  const SizedBox(width: 8),
                  if (busy)
                    OutlinedButton(
                        onPressed: _qiniu.cancel, child: const Text('取消'))
                  else
                    IconButton.outlined(
                        key: const Key('capture-delete'),
                        tooltip: '删除选中',
                        onPressed: _selected.isEmpty ? null : _delete,
                        icon: const Icon(Icons.delete_outline)),
                ]),
                if (!busy && allUploaded)
                  TextButton(
                      key: const Key('capture-reupload'),
                      onPressed: () => _upload(force: true),
                      child: const Text('重新上传选中记录（更新快照）')),
                if (!busy &&
                    !allUploaded &&
                    selected.any((r) => r.uploadedKey != null))
                  TextButton.icon(
                      key: const Key('capture-copy-links'),
                      onPressed: _copySelected,
                      icon: const Icon(Icons.copy),
                      label: const Text('仅复制链接')),
              ]),
            )),
          );
        });
  }
}
