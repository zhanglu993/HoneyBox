import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../services/qiniu/qiniu_config.dart';
import '../../services/qiniu/qiniu_controller.dart';
import '../../services/qiniu/qiniu_storage_service.dart';
import '../../services/qiniu/qiniu_signer.dart';
import '../../services/qiniu/qiniu_transfer.dart';
import 'qiniu_config_page.dart';

class QiniuFilesPage extends ConsumerStatefulWidget {
  const QiniuFilesPage({super.key});
  @override
  ConsumerState<QiniuFilesPage> createState() => _QiniuFilesPageState();
}

class _QiniuFilesPageState extends ConsumerState<QiniuFilesPage> {
  final _prefix = TextEditingController();
  final _items = <QiniuObject>[];
  final _selected = <String>{};
  String _marker = '', _activePrefix = '', _message = '';
  bool _loaded = false, _picking = false;
  Future<void> Function()? _retry;
  late final QiniuController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(qiniuControllerProvider);
    Future.microtask(() async {
      await _controller.ensureLoaded();
      if (!mounted) return;
      _prefix.text = _controller.config?.prefix ?? '';
      setState(() => _loaded = true);
      if (_controller.config != null) await _list();
    });
  }

  @override
  void dispose() {
    _controller.cancel();
    _prefix.dispose();
    super.dispose();
  }

  void _say(String message) {
    if (mounted) setState(() => _message = message);
  }

  Future<void> _configure() async {
    if (_controller.busy) return;
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const QiniuConfigPage()));
    if (!mounted) return;
    _retry = null;
    _prefix.text = _controller.config?.prefix ?? '';
    setState(() {
      _items.clear();
      _selected.clear();
      _marker = '';
      _message = '';
    });
    if (_controller.config != null) await _list();
  }

  Future<void> _list({bool more = false}) async {
    final config = _controller.config;
    if (config == null || _controller.busy) return;
    final prefix = more ? _activePrefix : _prefix.text;
    final marker = more ? _marker : '';
    _say('');
    try {
      final page = await _controller.run(
          '读取文件列表',
          (task) => _controller.service
              .list(config, prefix: prefix, marker: marker, transfer: task));
      if (!mounted) return;
      setState(() {
        if (!more) {
          _items.clear();
          _selected.clear();
        }
        final existing = _items.map((e) => e.key).toSet();
        _items.addAll(page.items.where((e) => existing.add(e.key)));
        _marker = page.marker == marker ? '' : page.marker;
        _activePrefix = prefix;
      });
    } catch (_) {
      _say(_controller.error);
    }
  }

  Future<void> _chooseUpload() async {
    if (_picking || _controller.busy) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(withData: false);
      if (!mounted || result == null) return;
      final path = result.files.single.path;
      if (path == null) {
        _say('文件不可直接读取，请选择本地文件后重试');
        return;
      }
      final config = _controller.config;
      if (config == null) return;
      final file = File(path);
      final random = List.generate(6, (_) => Random.secure().nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final prefix = _prefix.text;
      final defaultKey =
          '${prefix.isEmpty ? '' : prefix.endsWith('/') ? prefix : '$prefix/'}${DateTime.now().toUtc().millisecondsSinceEpoch}_${random}_${QiniuStorageService.safeFilename(result.files.single.name)}';
      final keyInput = TextEditingController(text: defaultKey);
      String? key;
      try {
        key = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: const Text('上传文件'),
                    content: SizedBox(
                        width: 540,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(
                              '空间：${config.bucket}\n文件：${result.files.single.name}'),
                          const SizedBox(height: 16),
                          TextField(
                              controller: keyInput,
                              decoration: const InputDecoration(
                                  labelText: '云端文件路径（Key）',
                                  border: OutlineInputBorder())),
                          const SizedBox(height: 8),
                          const Text('使用新路径保存，不覆盖同名文件。'),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, keyInput.text),
                          child: const Text('上传'))
                    ]));
      } finally {
        // Dispose after the dialog route has completed its closing animation.
        Future<void>.delayed(
            const Duration(milliseconds: 400), keyInput.dispose);
      }
      if (!mounted || key == null) return;
      if (key.isEmpty ||
          key.contains('\r') ||
          key.contains('\n') ||
          key.contains('\u0000') ||
          utf8Length('${config.bucket}:$key') > 750) {
        _say('文件路径不能为空、含控制字符或超过 750 字节');
        return;
      }
      _retry = () => _upload(config, file, key!);
      await _upload(config, file, key);
    } catch (_) {
      _say('无法选择本地文件，请检查文件权限后重试');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _upload(QiniuConfig config, File file, String key) async {
    _say('');
    try {
      await _controller.run('上传文件',
          (task) => _controller.service.upload(config, file, key, task));
      _retry = null;
      if (!mounted) return;
      await _list();
      _say('上传完成：$key');
    } catch (_) {
      _say(_controller.error);
    }
  }

  Future<void> _download(QiniuObject object) async {
    final config = _controller.config;
    if (config == null || _controller.busy) return;
    final error = config.validationError(forDownload: true);
    if (error != null) {
      _say(error);
      return;
    }
    _retry = () => _download(object);
    _say('');
    File? file;
    try {
      await _controller.run('下载文件', (task) async {
        final temp = await getTemporaryDirectory();
        file = await _controller.service.download(config, object, temp, task);
        task.check();
        if (!mounted) return;
        final saved = await _export(file!);
        _say(saved == null ? '文件已下载校验，已取消保存。' : '已保存：$saved');
      });
      _retry = null;
    } catch (_) {
      _say(_controller.error);
    } finally {
      if (file != null) {
        try {
          await file!.parent.delete(recursive: true);
        } catch (_) {/* Temp cleanup can be retried by the OS. */}
      }
    }
  }

  Future<String?> _export(File file) async {
    if (Platform.isAndroid) {
      return const MethodChannel('honeybox/capture-export')
          .invokeMethod<String>('export',
              {'path': file.path, 'fileName': file.uri.pathSegments.last});
    }
    if (Platform.isWindows) {
      final path = await FilePicker.platform.saveFile(
          dialogTitle: '保存七牛云文件', fileName: file.uri.pathSegments.last);
      if (path == null) return null;
      await file.copy(path);
      return path;
    }
    throw const QiniuException('当前版本仅提供 Android 和 Windows 文件导出');
  }

  Future<void> _copyAddress(QiniuObject object) async {
    final config = _controller.config;
    if (config == null) return;
    final error = config.validationError(forDownload: true);
    if (error != null) {
      _say(error);
      return;
    }
    try {
      final uri = QiniuSigner(config).downloadUri(object.key);
      await Clipboard.setData(ClipboardData(text: uri.toString()));
      _say(config.privateBucket ? '已复制私有空间临时链接，有效期 1 小时。' : '已复制远端地址。');
    } catch (_) {
      _say('复制失败，请检查下载域名和配置。');
    }
  }

  Future<void> _deleteSelected() async {
    final config = _controller.config;
    if (config == null || _controller.busy || _selected.isEmpty) return;
    final keys = _selected.toList();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('删除 ${keys.length} 个远端文件？'),
              content: SizedBox(
                  width: 500,
                  child: SingleChildScrollView(
                      child:
                          Text('文件将从七牛云空间删除，无法在此恢复：\n\n${keys.join('\n')}'))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                FilledButton(
                    key: const Key('qiniu-delete-confirm'),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('确认删除')),
              ],
            ));
    if (confirmed != true || !mounted) return;
    final removed = <String>[];
    final failed = <String>[];
    try {
      await _controller.run('删除文件', (transfer) async {
        for (final key in keys) {
          if (transfer.cancelled) {
            failed.add(key);
            continue;
          }
          try {
            await _controller.service.delete(config, key, transfer);
            removed.add(key);
          } catch (_) {
            failed.add(key);
          }
        }
      });
    } catch (_) {
      for (final key in keys) {
        if (!removed.contains(key) && !failed.contains(key)) failed.add(key);
      }
    }
    if (!mounted) return;
    setState(() {
      _items.removeWhere((item) => removed.contains(item.key));
      _selected.removeAll(removed);
      _message = failed.isEmpty
          ? '已删除 ${removed.length} 个文件。'
          : '已删除 ${removed.length} 个，${failed.length} 个未确认删除；请刷新列表后重试。';
    });
  }

  void _details(QiniuObject object) {
    showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('文件信息'),
                content: SizedBox(
                    width: 540,
                    child: SingleChildScrollView(
                        child: SelectableText(
                            'Key：${object.key}\n大小：${object.size} 字节\n类型：${object.mimeType.isEmpty ? '未知' : object.mimeType}\n上传时间：${object.uploadedAt?.toLocal() ?? '未知'}\nHash：${object.hash.isEmpty ? '未提供' : object.hash}'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭')),
                  FilledButton(
                      onPressed: _controller.busy
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              _download(object);
                            },
                      child: const Text('下载'))
                ]));
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(qiniuControllerProvider),
        config = controller.config;
    final busy = controller.busy || _picking;
    return Scaffold(
        appBar: AppBar(title: const Text('七牛云文件'), actions: [
          IconButton(
              tooltip: '刷新文件列表',
              onPressed: busy || config == null ? null : () => _list(),
              icon: const Icon(Icons.refresh)),
          IconButton(
              tooltip: '七牛云配置',
              onPressed: busy ? null : _configure,
              icon: const Icon(Icons.settings_outlined)),
        ]),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : Column(children: [
                if (config == null)
                  Expanded(
                      child: Center(
                          child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.cloud_outlined, size: 56),
                                    const SizedBox(height: 16),
                                    const Text('先配置自己的七牛云空间'),
                                    const SizedBox(height: 12),
                                    if (controller.error.isNotEmpty)
                                      Text(controller.error),
                                    FilledButton(
                                        onPressed: busy ? null : _configure,
                                        child: const Text('前往配置'))
                                  ]))))
                else ...[
                  Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '空间：${config.bucket} · ${config.privateBucket ? '私有' : '公开'}',
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 12),
                            Row(children: [
                              Expanded(
                                  child: TextField(
                                      controller: _prefix,
                                      enabled: !busy,
                                      onSubmitted: busy ? null : (_) => _list(),
                                      decoration: const InputDecoration(
                                          labelText: '路径前缀',
                                          hintText: '例如 captures/',
                                          border: OutlineInputBorder(),
                                          isDense: true))),
                              const SizedBox(width: 8),
                              FilledButton(
                                  style: FilledButton.styleFrom(
                                      minimumSize: const Size(0, 48)),
                                  onPressed: busy ? null : () => _list(),
                                  child: const Text('查询')),
                            ]),
                            const SizedBox(height: 8),
                            Wrap(
                                spacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                          minimumSize: const Size(0, 48)),
                                      onPressed: busy ? null : _chooseUpload,
                                      icon: const Icon(Icons.upload_file),
                                      label: const Text('上传文件')),
                                  Text('已加载 ${_items.length} 个文件'),
                                  if (_items.isNotEmpty)
                                    TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => setState(() {
                                                if (_selected.length ==
                                                    _items.length) {
                                                  _selected.clear();
                                                } else {
                                                  _selected.addAll(_items
                                                      .map((item) => item.key));
                                                }
                                              }),
                                      child: Text(
                                          _selected.length == _items.length
                                              ? '取消全选'
                                              : '全选已加载'),
                                    ),
                                  if (_selected.isNotEmpty)
                                    TextButton.icon(
                                      key: const Key('qiniu-delete-selected'),
                                      onPressed: busy ? null : _deleteSelected,
                                      icon: const Icon(Icons.delete_outline),
                                      label: Text('删除选中（${_selected.length}）'),
                                    ),
                                  if (_retry != null && !busy)
                                    TextButton.icon(
                                        onPressed: _retry,
                                        icon: const Icon(Icons.replay),
                                        label: const Text('重试上次传输')),
                                ]),
                          ])),
                  if (controller.busy)
                    Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(children: [
                          LinearProgressIndicator(
                              value: controller.total > 0
                                  ? controller.done / controller.total
                                  : null),
                          Row(children: [
                            Expanded(
                                child: Text(
                                    '${controller.status}${controller.total > 0 ? ' · ${_size(controller.done)} / ${_size(controller.total)}' : ''}')),
                            TextButton(
                                onPressed: controller.cancel,
                                child: const Text('取消'))
                          ]),
                        ])),
                  if (_message.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(_message)),
                  const Divider(height: 1),
                  Expanded(
                      child: _items.isEmpty
                          ? Center(
                              child:
                                  Text(controller.busy ? '正在读取…' : '当前前缀下暂无文件'))
                          : ListView.builder(
                              itemCount:
                                  _items.length + (_marker.isNotEmpty ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index == _items.length) {
                                  return Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: OutlinedButton(
                                          onPressed: busy
                                              ? null
                                              : () => _list(more: true),
                                          child: const Text('加载更多')));
                                }
                                final object = _items[index];
                                return ListTile(
                                    leading: Checkbox(
                                      key: ValueKey(
                                          'qiniu-select-${object.key}'),
                                      value: _selected.contains(object.key),
                                      onChanged: busy
                                          ? null
                                          : (value) => setState(() {
                                                if (value == true) {
                                                  _selected.add(object.key);
                                                } else {
                                                  _selected.remove(object.key);
                                                }
                                              }),
                                    ),
                                    title: Text(object.key),
                                    subtitle: Text(
                                        '${_size(object.size)}${object.uploadedAt == null ? '' : ' · ${object.uploadedAt!.toLocal().toString().split('.').first}'}'),
                                    onTap: busy ? null : () => _details(object),
                                    trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                              key: ValueKey(
                                                  'qiniu-copy-${object.key}'),
                                              tooltip: '复制远端地址',
                                              onPressed: busy
                                                  ? null
                                                  : () => _copyAddress(object),
                                              icon: const Icon(Icons.link)),
                                          IconButton(
                                              tooltip: '下载文件',
                                              onPressed: busy
                                                  ? null
                                                  : () => _download(object),
                                              icon: const Icon(
                                                  Icons.download_outlined)),
                                        ]));
                              })),
                ],
              ]));
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
}
