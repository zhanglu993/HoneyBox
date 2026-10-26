import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../android_ble_permissions.dart';
import 'capture_models.dart';
import 'capture_session.dart';

Future<void> ensureCapturePermissions() async {
  if (Platform.isAndroid && !await requestAndroidBlePermissions()) {
    throw StateError('请授予蓝牙及定位权限后重试');
  }
}

CaptureChannel captureChannelFor(BluetoothCharacteristic c) => CaptureChannel(
      service: normalizeCaptureUuid(c.serviceUuid.str),
      characteristic: normalizeCaptureUuid(c.characteristicUuid.str),
      primaryService: c.primaryServiceUuid == null
          ? null
          : normalizeCaptureUuid(c.primaryServiceUuid!.str),
      instance: c.instanceId,
    );

class CaptureBleConnection implements CaptureConnection {
  final BluetoothDevice device;
  final List<StreamSubscription<List<int>>> _subscriptions = [];
  final List<BluetoothCharacteristic> _enabled = [];
  final _events = StreamController<void>.broadcast();
  StreamSubscription<BluetoothConnectionState>? _state;
  bool _wasConnected = false;
  List<BluetoothService> services = [];
  bool _owned = false;
  CaptureBleConnection(String id) : device = BluetoothDevice.fromId(id);
  @override
  Stream<void> get disconnected => _events.stream;
  @override
  Future<void> connect() async {
    await ensureCapturePermissions();
    // Do not take over a connection held by Watch/eBadge or another module.
    if (device.isConnected) throw StateError('设备已被其他功能连接，请先断开后再采集');
    _owned = true;
    _state = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.connected) _wasConnected = true;
      if (_owned &&
          _wasConnected &&
          s == BluetoothConnectionState.disconnected) {
        _events.add(null);
      }
    }, onError: (Object e) {
      if (!_events.isClosed) _events.addError(e);
    });
    await device.connect(
        license: License.nonprofit, timeout: const Duration(seconds: 20));
    if (Platform.isAndroid) {
      try {
        await device.requestMtu(247);
      } catch (_) {/* Retain negotiated MTU. */}
    }
    final primary = await device.discoverServices();
    final visited = <BluetoothService>{};
    services = [];
    void addService(BluetoothService service) {
      // Service equality includes characteristic instance IDs, unlike UUID alone.
      if (!visited.add(service)) return;
      services.add(service);
      for (final child in service.includedServices) {
        addService(child);
      }
    }

    for (final service in primary) {
      addService(service);
    }
  }

  List<BluetoothCharacteristic> get characteristics => [
        for (final service in services) ...service.characteristics,
      ];
  @override
  Future<void> subscribe(
      CaptureChannel channel, void Function(List<int>) receive) async {
    final matches =
        characteristics.where((c) => captureChannelFor(c) == channel).toList();
    if (matches.length != 1) throw StateError('找不到唯一特征 ${channel.key}，请重新配置');
    final c = matches.single;
    if (!c.properties.notify && !c.properties.indicate) {
      throw StateError('特征不支持 Notify/Indicate：${channel.key}');
    }
    _subscriptions.add(c.onValueReceived.listen(receive, onError: (Object e) {
      if (!_events.isClosed) _events.addError(e);
    }));
    // Track before enabling so partial failures still get cleaned up.
    _enabled.add(c);
    await c.setNotifyValue(true);
  }

  @override
  Future<void> close() async {
    await _state?.cancel();
    _state = null;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    try {
      if (_owned && device.isConnected) {
        for (final c in _enabled) {
          try {
            await c.setNotifyValue(false);
          } catch (_) {/* Disconnect clears CCCD. */}
        }
      }
    } finally {
      _enabled.clear();
      if (_owned) {
        _owned = false;
        await device.disconnect();
      }
      if (!_events.isClosed) await _events.close();
    }
  }
}
