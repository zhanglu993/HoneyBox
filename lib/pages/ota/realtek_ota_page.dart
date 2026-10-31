import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/ble_provider.dart';
import '../../providers/rtl8762_ota_provider.dart';
import '../../services/ota/ota_platform.dart';
import '../../services/ota/android_realtek_ota_platform.dart';

final otaPlatformProvider = Provider<OtaPlatform>((ref) =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? const AndroidRealtekOtaPlatform()
        : const UnsupportedOtaPlatform());

class RealtekOtaPage extends ConsumerStatefulWidget {
  final ScanDevice device;
  const RealtekOtaPage({super.key, required this.device});

  @override
  ConsumerState<RealtekOtaPage> createState() => _RealtekOtaPageState();
}

class _RealtekOtaPageState extends ConsumerState<RealtekOtaPage> {
  late final OtaPlatform _platform;
  StreamSubscription<dynamic>? _subscription;
  String? _path;
  String? _name;
  String _status = '请选择与设备匹配的固件';
  double? _progress;
  bool _running = false;
  bool _ready = false;
  String? _errorDetails;
  bool _pendingVerification = false;
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    _platform = ref.read(otaPlatformProvider);
    if (_platform.supported) {
      _subscription = _platform.events.listen((event) {
        if (!mounted) return;
        final message = event['message'];
        final progress = event['progress'];
        final done = event['done'] == true;
        setState(() {
          if (message is String) _status = message;
          if (progress is num) _progress = (progress / 100).clamp(0, 1);
          if (done) _running = false;
          if (event['ready'] == true) _ready = true;
          if (done) _ready = false;
          if (event['errorType'] != null || event['errorCode'] != null) {
            _errorDetails =
                'SDK 错误类型：${event['errorType'] ?? '未知'}，错误码：${event['errorCode'] ?? '未知'}';
          }
          if (done) {
            _pendingVerification = event['outcome'] == 'pendingVerification';
          }
        });
        if (done) ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
      }, onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _ready = false;
          _status = _running
              ? '升级状态通信中断，设备可能仍在写入。请勿断电，等待设备状态确认：$error'
              : '连接状态通信失败：$error';
        });
      });
      unawaited(_prepare());
    }
  }

  Future<void> _prepare() async {
    if (_preparing || _running) return;
    setState(() {
      _preparing = true;
      _ready = false;
    });
    try {
      if (mounted) setState(() => _status = '正在连接设备');
      await _platform.close();
      await _platform.prepare(widget.device.deviceId);
    } catch (error) {
      if (mounted) setState(() => _status = '连接失败：$error');
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    unawaited(_platform.close().catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _choose() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (!mounted || result == null) return;
      final file = result.files.single;
      setState(() {
        _path = file.path;
        _name = file.name;
        _status = file.path == null ? '无法读取所选文件' : '已选择固件';
        _progress = null;
      });
    } catch (error) {
      if (mounted) setState(() => _status = '选择文件失败：$error');
    }
  }

  Future<void> _start() async {
    if (_path == null || _running || _preparing || !_ready) return;
    setState(() {
      _running = true;
      _progress = null;
      _status = '正在连接设备';
    });
    ref.read(rtl8762OtaInProgressProvider.notifier).state = true;
    try {
      await _platform.start(_path!);
    } catch (error) {
      if (mounted) {
        setState(() {
          _running = false;
          _status = '启动失败：$error';
        });
      }
      ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_running,
        child: Scaffold(
          appBar: AppBar(
              title: const Text('Realtek OTA'),
              automaticallyImplyLeading: !_running),
          body: Padding(
              padding: const EdgeInsets.all(24),
              child: ListView(
                children: [
                  Text('设备：${widget.device.name}'),
                  const SizedBox(height: 12),
                  Text(_name ?? '尚未选择固件'),
                  OutlinedButton(
                      onPressed: _running ? null : _choose,
                      child: const Text('选择固件')),
                  FilledButton(
                      onPressed: !_running &&
                              !_preparing &&
                              _ready &&
                              _path != null &&
                              _platform.supported
                          ? _start
                          : null,
                      child: const Text('开始升级')),
                  const SizedBox(height: 20),
                  if (_progress != null)
                    LinearProgressIndicator(value: _progress),
                  Text(_platform.supported ? _status : '当前平台暂不支持 OTA'),
                  if (_pendingVerification)
                    const Text('结果待核验：SDK 已报告完成，尚未确认设备运行的新固件版本。'),
                  if (_errorDetails != null) SelectableText(_errorDetails!),
                  if (!_running && _platform.supported)
                    OutlinedButton(
                      onPressed: _preparing ? null : _prepare,
                      child: const Text('重新连接'),
                    ),
                ],
              )),
        ),
      );
}
