import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/ble_provider.dart';
import '../../../providers/rtl8762_ota_provider.dart';
import '../../../services/ota/rtl8762_cipher.dart';
import '../../../services/ota/rtl8762_default_key.dart';
import '../../../services/ota/rtl8762_flutter_blue_adapter.dart';
import '../../../services/ota/rtl8762_upgrade.dart';
import '../../../services/ota/s200_firmware_image.dart';

class WatchOtaPage extends ConsumerStatefulWidget {
  const WatchOtaPage({super.key});
  @override
  ConsumerState<WatchOtaPage> createState() => _WatchOtaPageState();
}

class _WatchOtaPageState extends ConsumerState<WatchOtaPage> {
  Uint8List? _file;
  String? _name;
  String _status = '选择 RTL8762D S200 固件';
  bool _running = false;
  double? _progress;

  Future<void> _select() async {
    try {
      final result = await FilePicker.platform.pickFiles(
          type: FileType.custom, allowedExtensions: ['bin'], withData: true);
      if (result == null) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) throw const FormatException('无法读取固件文件');
      final image = S200FirmwareImage.parse(bytes);
      if (!mounted) return;
      setState(() {
        _file = bytes;
        _name = result.files.single.name;
        _status =
            '固件已检查，版本 0x${image.version.toRadixString(16).padLeft(8, '0')}';
        _progress = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _file = null;
        _name = null;
        _status = '固件无效：$e';
      });
    }
  }

  Future<void> _start() async {
    final selected = _file;
    final connected = ref.read(connectedDeviceProvider);
    if (selected == null ||
        connected == null ||
        connected.name.toUpperCase() != 'S200') {
      setState(() => _status = '请先连接 S200 并选择其固件');
      return;
    }
    setState(() {
      _running = true;
      _progress = 0;
    });
    ref.read(rtl8762OtaInProgressProvider.notifier).state = true;
    final cipher = Rtl8762Cipher(rtl8762DefaultKey());
    try {
      await Rtl8762Upgrade(
              Rtl8762FlutterBlueAdapter(connected.deviceId), cipher.encrypt)
          .run(selected, onProgress: (phase, done, total) {
        if (mounted) {
          setState(() {
            _status = phase;
            _progress = total == 0 ? null : done / total;
          });
        }
      });
      if (mounted) setState(() => _status = '升级成功：设备已重新连接，身份和版本验证通过');
    } catch (e) {
      if (mounted) setState(() => _status = '升级未完成：$e');
    } finally {
      ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(connectedDeviceProvider);
    return PopScope(
        canPop: !_running,
        child: Scaffold(
          appBar: AppBar(
              title: const Text('RTL8762 固件升级'),
              automaticallyImplyLeading: !_running),
          body: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('当前支持 RTL8762D S200',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 16),
                    Text('设备：${connected?.name ?? '未连接'}'),
                    const SizedBox(height: 12),
                    Text(_name ?? '尚未选择固件'),
                    const SizedBox(height: 12),
                    OutlinedButton(
                        onPressed: _running ? null : _select,
                        child: const Text('选择 BIN 固件')),
                    const SizedBox(height: 12),
                    FilledButton(
                        onPressed: _running ||
                                _file == null ||
                                connected?.name.toUpperCase() != 'S200'
                            ? null
                            : _start,
                        child: const Text('开始升级')),
                    const SizedBox(height: 24),
                    if (_progress != null)
                      LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 12),
                    Text(_status),
                  ])),
        ));
  }
}
