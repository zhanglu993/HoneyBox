import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/ble_provider.dart';
import '../../providers/rtl8762_ota_provider.dart';

class RealtekOtaPage extends ConsumerStatefulWidget {
  final ScanDevice device;
  const RealtekOtaPage({super.key, required this.device});

  @override
  ConsumerState<RealtekOtaPage> createState() => _RealtekOtaPageState();
}

class _RealtekOtaPageState extends ConsumerState<RealtekOtaPage> {
  static const _commands = MethodChannel('honeybox/realtek-ota');
  static const _events = EventChannel('honeybox/realtek-ota/events');
  StreamSubscription<dynamic>? _subscription;
  String? _path;
  String? _name;
  String _status = '请选择与设备匹配的固件';
  double? _progress;
  bool _running = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _subscription = _events.receiveBroadcastStream().listen((event) {
        if (!mounted || event is! Map) return;
        final message = event['message'];
        final progress = event['progress'];
        final done = event['done'] == true;
        setState(() {
          if (message is String) _status = message;
          if (progress is num) _progress = (progress / 100).clamp(0, 1);
          if (done) _running = false;
          if (event['ready'] == true) _ready = true;
          if (done) _ready = false;
        });
        if (done) ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
      }, onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _status = '升级失败：$error';
        });
        ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
      });
      unawaited(_prepare());
    }
  }

  Future<void> _prepare() async {
    try {
      if (mounted) setState(() => _status = '正在连接设备');
      await _commands
          .invokeMethod<void>('prepare', {'address': widget.device.deviceId});
    } catch (error) {
      if (mounted) setState(() => _status = '连接失败：$error');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    if (Platform.isAndroid) unawaited(_commands.invokeMethod<void>('close'));
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
    if (_path == null || _running) return;
    setState(() {
      _running = true;
      _progress = null;
      _status = '正在连接设备';
    });
    ref.read(rtl8762OtaInProgressProvider.notifier).state = true;
    try {
      await _commands.invokeMethod<void>('start', {'path': _path});
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('设备：${widget.device.name}'),
                  const SizedBox(height: 12),
                  Text(_name ?? '尚未选择固件'),
                  OutlinedButton(
                      onPressed: _running ? null : _choose,
                      child: const Text('选择固件')),
                  FilledButton(
                      onPressed: !_running &&
                              _ready &&
                              _path != null &&
                              Platform.isAndroid
                          ? _start
                          : null,
                      child: const Text('开始升级')),
                  const SizedBox(height: 20),
                  if (_progress != null)
                    LinearProgressIndicator(value: _progress),
                  Text(Platform.isAndroid ? _status : '当前仅支持 Android'),
                ],
              )),
        ),
      );
}
