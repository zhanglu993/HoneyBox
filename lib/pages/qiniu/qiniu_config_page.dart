import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/qiniu/qiniu_config.dart';
import '../../services/qiniu/qiniu_controller.dart';
import '../../services/qiniu/qiniu_config_transfer.dart';

class QiniuConfigPage extends ConsumerStatefulWidget {
  const QiniuConfigPage({super.key});
  @override
  ConsumerState<QiniuConfigPage> createState() => _QiniuConfigPageState();
}

class _QiniuConfigPageState extends ConsumerState<QiniuConfigPage> {
  final _form = GlobalKey<FormState>();
  final _ak = TextEditingController(),
      _sk = TextEditingController(),
      _bucket = TextEditingController(),
      _domain = TextEditingController(),
      _prefix = TextEditingController();
  String _region = '', _notice = '';
  bool _private = true, _hidden = true, _loaded = false;
  bool _testing = false, _noticeError = false;
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final controller = ref.read(qiniuControllerProvider);
      await controller.ensureLoaded();
      if (!mounted) return;
      _fill(controller.config);
      setState(() => _loaded = true);
    });
  }

  void _fill(QiniuConfig? config) {
    _ak.text = config?.accessKey ?? '';
    _sk.text = config?.secretKey ?? '';
    _bucket.text = config?.bucket ?? '';
    _domain.text = config?.downloadDomain ?? '';
    _prefix.text = config?.prefix ?? '';
    _region = config?.region ?? '';
    _private = config?.privateBucket ?? true;
  }

  QiniuConfig _config() => QiniuConfig(
      accessKey: _ak.text.trim(),
      secretKey: _sk.text.trim(),
      bucket: _bucket.text.trim(),
      region: _region,
      downloadDomain: _domain.text.trim(),
      prefix: _prefix.text,
      privateBucket: _private);
  @override
  void dispose() {
    for (final field in [_ak, _sk, _bucket, _domain, _prefix]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _perform(bool test) async {
    if (!_form.currentState!.validate()) return;
    final config = _config(), controller = ref.read(qiniuControllerProvider);
    final validation = config.validationError();
    if (validation != null) {
      _feedback(validation, failure: true);
      return;
    }
    setState(() {
      _testing = test;
      _noticeError = false;
      _notice = test ? '正在测试连接，最多等待 20 秒…' : '正在保存配置…';
    });
    try {
      if (test) {
        await controller.testConnection(config);
      } else {
        await controller.save(config);
      }
      if (mounted) {
        _feedback(test
            ? config.downloadDomain.isEmpty
                ? '连接成功，空间可列举；未填写下载域名，无法生成分享链接。'
                : '连接成功，空间可列举，下载域名可访问；上传权限尚未验证。'
            : '配置已安全保存到本机。');
      }
    } catch (_) {
      if (mounted) {
        _feedback('${test ? '测试失败：' : ''}${controller.error}', failure: true);
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _importConfig() async {
    try {
      final result = await FilePicker.platform.pickFiles(withData: true);
      if (result == null || !mounted) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) throw const FormatException();
      final config = QiniuConfigTransfer.decode(bytes);
      await ref.read(qiniuControllerProvider).save(config);
      if (!mounted) return;
      setState(() => _fill(config));
      _feedback('配置已导入并安全保存到本机。');
    } catch (_) {
      if (mounted) _feedback('导入失败：请选择有效的七牛云配置文件。', failure: true);
    }
  }

  Future<void> _exportConfig({required bool share}) async {
    final config = _config();
    final error = config.validationError();
    if (error != null) {
      _feedback(error, failure: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(share ? '分享七牛云配置' : '保存七牛云配置'),
        content:
            const Text('导出的文件包含 AccessKey 和 SecretKey，未加密。请妥善保管，只分享给信任的人。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(share ? '继续分享' : '继续保存')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final bytes = QiniuConfigTransfer.encode(config);
      if (share) {
        await SharePlus.instance.share(ShareParams(
          files: [XFile.fromData(bytes, mimeType: 'application/json')],
          fileNameOverrides: ['honeybox-qiniu-config.json'],
        ));
        return;
      }
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出七牛云配置',
        fileName: 'honeybox-qiniu-config.json',
        bytes: bytes,
      );
      if (path == null) return;
      if (!Platform.isAndroid && !Platform.isIOS) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
      if (mounted) _feedback('配置已导出，请妥善保管文件。');
    } catch (_) {
      if (mounted) {
        _feedback(share ? '无法打开分享面板，请重试。' : '保存失败，请检查文件权限后重试。', failure: true);
      }
    }
  }

  void _feedback(String message, {bool failure = false}) {
    setState(() {
      _notice = message;
      _noticeError = failure;
    });
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: failure
            ? Theme.of(context).colorScheme.error
            : Colors.green.shade800,
        duration: const Duration(seconds: 6)));
  }

  Future<void> _clear() async {
    final controller = ref.read(qiniuControllerProvider);
    try {
      await controller.clear();
      if (mounted) {
        setState(() {
          _fill(null);
          _notice = '本机七牛配置已清除。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _notice = controller.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(qiniuControllerProvider);
    final disabled = !_loaded || controller.busy;
    return Scaffold(
        appBar: AppBar(title: const Text('七牛云配置')),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: Form(
                        key: _form,
                        child: ListView(
                            padding: const EdgeInsets.all(20),
                            children: [
                              const Text('使用自己的七牛云账号',
                                  style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              const Text(
                                  '配置仅保存在当前设备，不会同步给其他人。Key 使用本机安全存储；请使用具有目标空间权限的密钥。'),
                              const SizedBox(height: 16),
                              Wrap(spacing: 12, runSpacing: 8, children: [
                                OutlinedButton.icon(
                                  onPressed: disabled ? null : _importConfig,
                                  icon: const Icon(Icons.file_open_outlined),
                                  label: const Text('导入配置'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: disabled
                                      ? null
                                      : () => _exportConfig(share: true),
                                  icon: const Icon(Icons.share_outlined),
                                  label: const Text('分享配置'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: disabled
                                      ? null
                                      : () => _exportConfig(share: false),
                                  icon: const Icon(Icons.save_alt),
                                  label: const Text('保存配置文件'),
                                ),
                              ]),
                              const SizedBox(height: 20),
                              _field(_ak, 'AccessKey', disabled,
                                  required: true),
                              TextFormField(
                                  key: const Key('qiniu-secret'),
                                  controller: _sk,
                                  enabled: !disabled,
                                  obscureText: _hidden,
                                  enableSuggestions: false,
                                  autocorrect: false,
                                  decoration: InputDecoration(
                                      labelText: 'SecretKey',
                                      border: const OutlineInputBorder(),
                                      suffixIcon: IconButton(
                                          tooltip: _hidden
                                              ? '显示 SecretKey'
                                              : '隐藏 SecretKey',
                                          onPressed: disabled
                                              ? null
                                              : () => setState(
                                                  () => _hidden = !_hidden),
                                          icon: Icon(_hidden
                                              ? Icons.visibility_outlined
                                              : Icons
                                                  .visibility_off_outlined))),
                                  validator: (v) =>
                                      v == null || v.trim().isEmpty
                                          ? '请填写 SecretKey'
                                          : null),
                              const SizedBox(height: 16),
                              _field(_bucket, 'Bucket', disabled,
                                  required: true),
                              DropdownButtonFormField<String>(
                                  initialValue: _region,
                                  key: ValueKey(_region),
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                      labelText: '存储区域',
                                      border: OutlineInputBorder()),
                                  items: QiniuConfig.regions.entries
                                      .map((e) => DropdownMenuItem(
                                          value: e.key, child: Text(e.value)))
                                      .toList(),
                                  onChanged: disabled
                                      ? null
                                      : (v) => setState(() => _region = v!)),
                              const SizedBox(height: 16),
                              _field(_domain, '下载域名（HTTPS，下载前必填）', disabled,
                                  hint: 'https://files.example.com'),
                              SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('私有空间'),
                                  subtitle:
                                      const Text('下载时自动生成临时签名链接；公开空间请关闭。'),
                                  value: _private,
                                  onChanged: disabled
                                      ? null
                                      : (v) => setState(() => _private = v)),
                              const SizedBox(height: 8),
                              _field(_prefix, '默认路径前缀（可选）', disabled,
                                  hint: 'captures/'),
                              if (controller.busy)
                                const LinearProgressIndicator(),
                              if (_notice.isNotEmpty ||
                                  controller.error.isNotEmpty)
                                Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    child: Semantics(
                                        liveRegion: true,
                                        child: Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                                color: _noticeError
                                                    ? Theme.of(context)
                                                        .colorScheme
                                                        .errorContainer
                                                    : Colors.green.shade50,
                                                borderRadius:
                                                    BorderRadius.circular(8)),
                                            child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Icon(
                                                      _noticeError
                                                          ? Icons.error_outline
                                                          : controller.busy
                                                              ? Icons
                                                                  .hourglass_top
                                                              : Icons
                                                                  .check_circle_outline,
                                                      color: _noticeError
                                                          ? Theme.of(context)
                                                              .colorScheme
                                                              .error
                                                          : Colors
                                                              .green.shade800),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                      child: Text(_notice
                                                              .isNotEmpty
                                                          ? _notice
                                                          : controller.error)),
                                                ])))),
                              Wrap(spacing: 12, runSpacing: 12, children: [
                                OutlinedButton.icon(
                                    onPressed:
                                        disabled ? null : () => _perform(true),
                                    icon: _testing && controller.busy
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2))
                                        : const Icon(Icons.network_check),
                                    label: Text(_testing && controller.busy
                                        ? '测试中…'
                                        : '测试连接')),
                                if (_testing && controller.busy)
                                  TextButton(
                                      onPressed: controller.cancel,
                                      child: const Text('取消测试')),
                                FilledButton.icon(
                                    onPressed:
                                        disabled ? null : () => _perform(false),
                                    icon: const Icon(Icons.save_outlined),
                                    label: const Text('保存配置')),
                                TextButton(
                                    onPressed: disabled ? null : _clear,
                                    child: const Text('清除本机配置')),
                              ]),
                              const SizedBox(height: 16),
                              const Text(
                                  '测试连接仅执行只读查询，不会上传文件。路径前缀用于分类，不限制密钥本身的权限。'),
                            ])))));
  }

  Widget _field(TextEditingController input, String label, bool disabled,
          {bool required = false, String? hint}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextFormField(
              controller: input,
              enabled: !disabled,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                  labelText: label,
                  hintText: hint,
                  border: const OutlineInputBorder()),
              validator: (value) =>
                  required && (value == null || value.trim().isEmpty)
                      ? '请填写 $label'
                      : null));
}
