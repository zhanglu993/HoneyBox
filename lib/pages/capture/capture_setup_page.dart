import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../services/capture/capture_ble_transport.dart';
import '../../services/capture/capture_models.dart';
import '../../services/capture/capture_polar.dart';
import '../../services/capture/capture_scan_filter.dart';
import '../../services/capture/capture_scan_settings.dart';
import '../../services/capture/capture_store.dart';

class CaptureSetupPage extends StatefulWidget {
  final CaptureProfile? profile;
  final Set<String> existingIds;
  final CaptureStore? store;
  const CaptureSetupPage(
      {super.key, this.profile, required this.existingIds, this.store});
  @override
  State<CaptureSetupPage> createState() => _CaptureSetupPageState();
}

class _CaptureSetupPageState extends State<CaptureSetupPage> {
  final _name = TextEditingController();
  final _filter = TextEditingController();
  final _selected = <CaptureChannel>{};
  bool _polar = false;
  PolarCaptureOptions _polarOptions = const PolarCaptureOptions();
  List<CaptureCommand> _startCommands = [], _stopCommands = [];
  int _minimumMtu = 0;
  List<ScanResult> _results = [];
  List<BluetoothService> _services = [];
  StreamSubscription<List<ScanResult>>? _scan;
  StreamSubscription<BluetoothConnectionState>? _state;
  CaptureBleConnection? _connection;
  String? _id;
  String? _error;
  bool _busy = false, _scanning = false, _leaving = false;
  bool _canPop = false;
  int _minimumRssi = -127;
  bool _strongestFirst = true;
  bool _hideUnnamed = false;
  bool _showResults = true;
  StreamSubscription<bool>? _scanState;
  CaptureStore? _settingsStore;
  bool _settingsLoading = true;
  String? _settingsError;
  Future<void> _settingsSave = Future.value();
  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
    _scanState = FlutterBluePlus.isScanning.listen((scanning) {
      if (mounted && !_leaving) setState(() => _scanning = scanning);
    });
    _filter.addListener(() {
      if (mounted) setState(() {});
    });
    final profile = widget.profile;
    if (profile != null) {
      _name.text = profile.name;
      _selected.addAll(profile.channels);
      _startCommands = profile.startCommands;
      _stopCommands = profile.stopCommands;
      _minimumMtu = profile.minimumMtu;
      _polar = profile.polarOptions != null;
      if (_polar) {
        _polarOptions = PolarCaptureOptions.fromJson(profile.polarOptions!);
      }
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _connect(profile.id, profile.name));
    }
  }

  Future<void> _loadSettings() async {
    try {
      _settingsStore = widget.store ?? await CaptureStore.create();
      final saved = await _settingsStore!.loadScanSettings();
      if (!mounted) return;
      _minimumRssi = saved.minimumRssi;
      _strongestFirst = saved.strongestFirst;
      _hideUnnamed = saved.hideUnnamed;
    } catch (e) {
      _settingsError = '筛选条件读取失败，暂用默认值：$e';
    } finally {
      if (mounted) setState(() => _settingsLoading = false);
    }
  }

  void _saveSettings() {
    final store = _settingsStore;
    if (store == null) {
      setState(() => _settingsError = '筛选条件无法保存，请重新打开页面重试');
      return;
    }
    _settingsSave = store
        .saveScanSettings(CaptureScanSettings(
      strongestFirst: _strongestFirst,
      minimumRssi: _minimumRssi,
      hideUnnamed: _hideUnnamed,
    ))
        .then((_) {
      if (mounted) setState(() => _settingsError = null);
    }).catchError((Object e) {
      if (mounted) setState(() => _settingsError = '筛选条件保存失败：$e');
    });
  }

  void _setError(Object e) {
    if (mounted) setState(() => _error = '$e');
  }

  Future<void> _stopScan() async {
    await _scan?.cancel();
    _scan = null;
    if (_scanning) {
      _scanning = false;
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _busy = true;
      _error = null;
      _showResults = true;
    });
    try {
      await ensureCapturePermissions();
      await _stopScan();
      _scan = FlutterBluePlus.onScanResults.listen((results) {
        if (mounted && !_leaving) setState(() => _results = results);
      }, onError: _setError);
      _scanning = true;
      await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 12), androidUsesFineLocation: true);
    } catch (e) {
      _setError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect(String id, String name) async {
    if (_busy || _leaving) return;
    if (widget.existingIds.contains(id) && id != widget.profile?.id) {
      _setError('该设备已有配置，请编辑已有设备');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _services = [];
    });
    try {
      await _stopScan();
      await _state?.cancel();
      _state = null;
      await _connection?.close();
      final connection = CaptureBleConnection(id);
      _connection = connection;
      await connection.connect();
      if (_leaving || !mounted) {
        await connection.close();
        return;
      }
      if (_id != id && widget.profile?.id != id) {
        _selected.clear();
        _polar = false;
        _startCommands = [];
        _stopCommands = [];
        _minimumMtu = 0;
      }
      _id = id;
      _name.text = widget.profile?.id == id
          ? widget.profile!.name
          : (name.isEmpty ? id : name);
      _services = connection.services;
      _showResults = false;
      final available = connection.characteristics
          .where((c) => c.properties.notify || c.properties.indicate)
          .map(captureChannelFor)
          .toSet();
      _selected.removeWhere((c) => !available.contains(c));
      _state = connection.device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected &&
            mounted &&
            !_leaving) {
          setState(() {
            _services = [];
            _error = '设备已断开，请重新发现服务';
          });
        }
      });
    } catch (e) {
      _setError(e);
      try {
        await _connection?.close();
      } catch (closeError) {
        _setError(closeError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave([CaptureProfile? result]) async {
    if (_leaving || _busy) return;
    _leaving = true;
    setState(() => _busy = true);
    try {
      await _settingsSave;
      await _stopScan();
      await _state?.cancel();
      await _connection?.close();
      if (mounted) {
        setState(() => _canPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, result);
        });
      }
    } catch (e) {
      _setError(e);
      _leaving = false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applyPolar([PolarCaptureOptions? options]) {
    try {
      final next = options ?? _polarOptions;
      final profile = polarCaptureProfile(
          id: _id!,
          name: _name.text.trim().isEmpty ? 'Polar H10' : _name.text.trim(),
          available: _connection!.characteristics
              .where((c) => c.properties.notify || c.properties.indicate)
              .map(captureChannelFor),
          options: next);
      // CP must also support writes with response.
      if (next.ecg || next.acc) {
        final cp = _connection!.characteristics
            .singleWhere((c) => captureChannelFor(c) == profile.channels[1]);
        if (!cp.properties.write) throw StateError('Polar 控制点不支持 Write');
      }
      setState(() {
        _polar = true;
        _polarOptions = next;
        _selected
          ..clear()
          ..addAll(profile.channels);
        _startCommands = profile.startCommands;
        _stopCommands = profile.stopCommands;
        _minimumMtu = profile.minimumMtu;
        _error = null;
      });
    } catch (e) {
      _setError(e);
    }
  }

  void _save() {
    if (_name.text.trim().isEmpty || _selected.isEmpty || _id == null) {
      _setError('请填写名称并选择至少一个通知特征');
      return;
    }
    unawaited(_leave(CaptureProfile(
        id: _id!,
        name: _name.text.trim(),
        channels: _selected.toList(),
        startCommands: _startCommands,
        stopCommands: _stopCommands,
        minimumMtu: _minimumMtu,
        polarOptions: _polar ? _polarOptions.toJson() : null)));
  }

  @override
  void dispose() {
    unawaited(_stopScan());
    unawaited(_state?.cancel());
    unawaited(_scanState?.cancel());
    final connection = _connection;
    if (connection != null) {
      unawaited(connection.close().catchError((Object _) {}));
    }
    _name.dispose();
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSave = !_busy &&
        !_settingsLoading &&
        _services.isNotEmpty &&
        _selected.isNotEmpty;
    final results = filterCaptureScanResults(_results,
        query: _filter.text,
        minimumRssi: _minimumRssi == -127 ? null : _minimumRssi,
        strongestFirst: _strongestFirst,
        hideUnnamed: _hideUnnamed);
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
            title: Text(widget.profile == null ? '添加采集设备' : '编辑采集设备'),
            actions: [
              TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white54,
                  ),
                  onPressed: canSave ? _save : null,
                  child: const Text('保存配置')),
            ]),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (!canSave && !_busy)
                Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(_services.isEmpty
                        ? '连接设备后，选择要采集的通知特征'
                        : '请至少选择一个 Notify / Indicate 特征')),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('capture-save-bottom'),
                    onPressed: canSave ? _save : null,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存配置'),
                  )),
            ]),
          ),
        ),
        body: _settingsLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(16), children: [
                if (_settingsError != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(_settingsError!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                const Text('选择设备，再选择要采集的通知特征。Polar 快捷配置会发送启动和停止命令。'),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: _filter,
                          decoration:
                              const InputDecoration(labelText: '按设备名称或地址筛选'))),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 112,
                    child: FilledButton.tonal(
                        onPressed: _busy ? null : _startScan,
                        child: const Text('扫描设备')),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                      child: DropdownButtonFormField<bool>(
                    key: const Key('capture-rssi-sort'),
                    initialValue: _strongestFirst,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '信号排序'),
                    items: const [
                      DropdownMenuItem(value: true, child: Text('信号强 → 弱')),
                      DropdownMenuItem(value: false, child: Text('信号弱 → 强'))
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => _strongestFirst = v);
                        _saveSettings();
                      }
                    },
                  )),
                  const SizedBox(width: 12),
                  Expanded(
                      child: DropdownButtonFormField<int>(
                    key: const Key('capture-rssi-minimum'),
                    initialValue: _minimumRssi,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '最低信号'),
                    items: [
                      const DropdownMenuItem(value: -127, child: Text('不限')),
                      for (final value in [-90, -80, -70, -60, -50, -40])
                        DropdownMenuItem(
                            value: value, child: Text('≥ $value dBm'))
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => _minimumRssi = v);
                        _saveSettings();
                      }
                    },
                  )),
                ]),
                CheckboxListTile(
                  key: const Key('capture-hide-unnamed'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('隐藏无名设备'),
                  value: _hideUnnamed,
                  onChanged: (value) {
                    setState(() => _hideUnnamed = value ?? false);
                    _saveSettings();
                  },
                ),
                const SizedBox(height: 8),
                Text(
                    '${_scanning ? '正在扫描' : '扫描已停止'} · 显示 ${results.length} / ${_results.length} 台设备'),
                if (results.isEmpty)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(_results.isEmpty
                          ? '点击“扫描设备”查找附近的手表或传感器。'
                          : '没有符合条件的设备，请放宽信号、名称或无名设备筛选。')),
                if (_id != null && _services.isEmpty)
                  TextButton(
                      onPressed:
                          _busy ? null : () => _connect(_id!, _name.text),
                      child: const Text('重新发现服务')),
                if (_services.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('已连接：$_id · ${_services.length} 个服务',
                          style: const TextStyle(fontWeight: FontWeight.bold))),
                for (final r in _showResults ? results : <ScanResult>[])
                  ListTile(
                    title: Text(r.advertisementData.advName.isNotEmpty
                        ? r.advertisementData.advName
                        : (r.device.platformName.isEmpty
                            ? '未命名设备'
                            : r.device.platformName)),
                    subtitle: Text('${r.device.remoteId.str} · ${r.rssi} dBm'),
                    enabled: !_busy &&
                        (widget.profile == null ||
                            widget.profile!.id == r.device.remoteId.str),
                    onTap: () => _connect(
                        r.device.remoteId.str, r.advertisementData.advName),
                  ),
                if (_services.isNotEmpty)
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Divider(),
                        TextField(
                            controller: _name,
                            decoration:
                                const InputDecoration(labelText: '配置名称')),
                        const SizedBox(height: 12),
                        SelectableText('设备：$_id'),
                        Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                                onPressed: _busy
                                    ? null
                                    : () {
                                        final matches = _connection!
                                            .characteristics
                                            .where((c) =>
                                                normalizeCaptureUuid(
                                                        c.serviceUuid.str) ==
                                                    'e0ff' &&
                                                normalizeCaptureUuid(c
                                                        .characteristicUuid
                                                        .str) ==
                                                    'ffe1' &&
                                                (c.properties.notify ||
                                                    c.properties.indicate))
                                            .map(captureChannelFor)
                                            .toList();
                                        if (matches.isEmpty) {
                                          _setError(
                                              '当前设备未发现 V101 调试通知 E0FF / FFE1');
                                        } else {
                                          setState(() {
                                            _polar = false;
                                            _startCommands = [];
                                            _stopCommands = [];
                                            _minimumMtu = 0;
                                            _selected
                                              ..clear()
                                              ..addAll(matches);
                                            _error = null;
                                          });
                                        }
                                      },
                                child: const Text(
                                    '选择 V101 BLE Log（E0FF / FFE1）'))),
                        Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                                key: const Key('capture-polar-preset'),
                                onPressed: _busy ? null : () => _applyPolar(),
                                child: const Text(
                                    '选择 Polar H10（ECG / ACC / HR-RR）'))),
                        if (_polar) ...[
                          CheckboxListTile(
                              title: const Text('ECG（130 Hz）'),
                              value: _polarOptions.ecg,
                              onChanged: _busy
                                  ? null
                                  : (v) => _applyPolar(PolarCaptureOptions(
                                      ecg: v!,
                                      acc: _polarOptions.acc,
                                      rate: _polarOptions.rate,
                                      range: _polarOptions.range))),
                          CheckboxListTile(
                              title: const Text('ACC'),
                              value: _polarOptions.acc,
                              onChanged: _busy
                                  ? null
                                  : (v) => _applyPolar(PolarCaptureOptions(
                                      ecg: _polarOptions.ecg,
                                      acc: v!,
                                      rate: _polarOptions.rate,
                                      range: _polarOptions.range))),
                          DropdownButtonFormField<int>(
                              key: ValueKey('polar-rate-${_polarOptions.rate}'),
                              initialValue: _polarOptions.rate,
                              decoration:
                                  const InputDecoration(labelText: 'ACC 采样率'),
                              items: [
                                for (final n in [25, 50, 100, 200])
                                  DropdownMenuItem(
                                      value: n, child: Text('$n Hz'))
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => _applyPolar(PolarCaptureOptions(
                                      ecg: _polarOptions.ecg,
                                      acc: _polarOptions.acc,
                                      rate: v!,
                                      range: _polarOptions.range))),
                          DropdownButtonFormField<int>(
                              key: ValueKey(
                                  'polar-range-${_polarOptions.range}'),
                              initialValue: _polarOptions.range,
                              decoration:
                                  const InputDecoration(labelText: 'ACC 量程'),
                              items: [
                                for (final n in [2, 4, 8])
                                  DropdownMenuItem(
                                      value: n, child: Text('±$n g'))
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => _applyPolar(PolarCaptureOptions(
                                      ecg: _polarOptions.ecg,
                                      acc: _polarOptions.acc,
                                      rate: _polarOptions.rate,
                                      range: v!))),
                          const Text(
                              '始终采集 HR / RR；ECG / ACC 需要 MTU ≥ 232。等待首个 ECG 包最多 60 秒。'),
                        ],
                        if (_startCommands.isNotEmpty ||
                            _stopCommands.isNotEmpty)
                          Text(
                              '启动 ${_startCommands.length} 步 · 停止 ${_stopCommands.length} 步'),
                        for (final service in _services)
                          Card(
                              child: ExpansionTile(
                            initiallyExpanded: false,
                            title: Text('服务 ${service.uuid.str}'),
                            subtitle: Text(
                                '已选 ${service.characteristics.where((c) => _selected.contains(captureChannelFor(c))).length} / ${service.characteristics.length} 个特征'),
                            children: [
                              for (final c in service.characteristics)
                                CheckboxListTile(
                                  title: Text(c.uuid.str),
                                  subtitle: Text(
                                      '${c.properties.notify ? 'Notify ' : ''}${c.properties.indicate ? 'Indicate ' : ''}'
                                      '${c.properties.read ? 'Read ' : ''}${c.properties.write ? 'Write ' : ''} · 实例 ${c.instanceId}'),
                                  value:
                                      _selected.contains(captureChannelFor(c)),
                                  onChanged: _busy ||
                                          _polar ||
                                          (!c.properties.notify &&
                                              !c.properties.indicate)
                                      ? null
                                      : (checked) {
                                          setState(() {
                                            if (checked!) {
                                              _selected
                                                  .add(captureChannelFor(c));
                                            } else {
                                              _selected
                                                  .remove(captureChannelFor(c));
                                            }
                                          });
                                        },
                                )
                            ],
                          )),
                      ]),
              ]),
      ),
    );
  }
}
