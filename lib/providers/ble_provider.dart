import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ble_manager.dart' as manager;
import '../services/jw/jw_scan_policy.dart';
import 'package:flutter/foundation.dart' show debugPrint;

// BLE state enum
enum BleState { disconnected, scanning, connecting, connected, disconnecting }

/// 虚拟设备 id 前缀。见 [BleNotifier.connect] / [BleNotifier.disconnect]
/// 里的旁路逻辑,以及扫描页对首行假设备的注入。
/// See docs/superpowers/specs/2026-07-29-debug-mode-fake-device-design.md
const String kDebugDeviceIdPrefix = 'DEBUG:';

// Scan device data class
class ScanDevice {
  final String deviceId;
  final String name;
  final int rssi;
  final bool connectable;
  final bool jwCandidate;
  final DateTime? firstSeen;
  final DateTime? identitySeen;

  /// 虚拟调试设备(仅供扫描页显示区分,不影响连接逻辑——连接旁路走
  /// [kDebugDeviceIdPrefix] 判定)。
  final bool debug;

  ScanDevice({
    required this.deviceId,
    required this.name,
    required this.rssi,
    this.connectable = true,
    this.debug = false,
    this.jwCandidate = false,
    this.firstSeen,
    this.identitySeen,
  });
}

// Connected device info
class ConnectedDeviceInfo {
  final String deviceId;
  final String name;
  final int mtu;
  final bool isJw;

  ConnectedDeviceInfo({
    required this.deviceId,
    required this.name,
    required this.mtu,
    this.isJw = false,
  });
}

// Singleton BleManager with auto-dispose
final bleManagerProvider = Provider<manager.BleManager>((ref) {
  final bleManager = manager.BleManager();
  ref.onDispose(bleManager.dispose);
  return bleManager;
});

// BLE notifier provider — manages scan state, device list, connection state
final bleNotifierProvider = StateNotifierProvider<BleNotifier, BleState>((ref) {
  final bleManager = ref.read(bleManagerProvider);
  return BleNotifier(bleManager, ref);
});

// Scanned devices list
final scannedDevicesProvider =
    StateNotifierProvider<ScannedDevicesNotifier, List<ScanDevice>>((ref) {
  return ScannedDevicesNotifier();
});

// Connected device info
final connectedDeviceProvider =
    StateProvider<ConnectedDeviceInfo?>((ref) => null);

class BleNotifier extends StateNotifier<BleState> {
  final manager.BleManager _bleManager;
  final Ref _ref;
  StreamSubscription<manager.BleState>? _managerStateSub;

  BleNotifier(this._bleManager, this._ref) : super(BleState.disconnected) {
    // Subscribe to manager-level disconnect events so unexpected BLE
    // disconnections are reflected in the Riverpod state.
    //
    // 但要排除两类"虚假"的 disconnected 事件:
    // (a) 假设备旁路时,connect() 内部会先 stopScan() 让 manager 从
    //     scanning 落回 disconnected —— 这不代表连接掉,只是停扫描。
    // (b) 用户点击/停止扫描时,BleManager.stopScan 里也会发一次
    //     disconnected —— 同样与"设备断开"无关。
    // 两者的共同特征:此刻 connectedDeviceProvider 要么是 null(尚未连接),
    // 要么承载一个假设备(DEBUG: 前缀,manager 从未参与)。真实的物理
    // 断开必然对应 provider 里是真实设备。据此过滤,避免误清假连接。
    _managerStateSub = _bleManager.onStateChanged.listen((next) {
      if (next != manager.BleState.disconnected) return;
      final info = _ref.read(connectedDeviceProvider);
      if (info == null) {
        // A delayed stop event may arrive after a new scan has started.
        if (state == BleState.scanning &&
            _bleManager.state == manager.BleState.disconnected) {
          state = BleState.disconnected;
        }
        return;
      }
      if (info.deviceId.startsWith(kDebugDeviceIdPrefix)) return;
      _ref.read(connectedDeviceProvider.notifier).state = null;
      if (state != BleState.disconnected) state = BleState.disconnected;
    });
  }

  @override
  void dispose() {
    _managerStateSub?.cancel();
    super.dispose();
  }

  Future<void> startScan({String? serviceUuid}) async {
    state = BleState.scanning;
    final devicesNotifier = _ref.read(scannedDevicesProvider.notifier);
    devicesNotifier.clear();

    await _bleManager.startScan((result) {
      final device = result.device;
      // Prefer the advertised name, falling back to the OS-cached platform name
      // (`localName` was removed/deprecated in newer flutter_blue_plus).
      final advName = result.advertisementData.advName.trim();
      final name = advName.isNotEmpty ? advName : device.platformName.trim();
      final displayName = name.isEmpty ? '未知设备' : name;
      devicesNotifier.addDevice(ScanDevice(
        deviceId: device.remoteId.toString(),
        name: displayName,
        rssi: result.rssi,
        connectable: result.advertisementData.connectable,
        jwCandidate: JwScanPolicy.isCandidate(
            serviceUuids: result.advertisementData.serviceUuids
                .map((u) => u.toString())
                .toSet(),
            manufacturerData: result.advertisementData.manufacturerData),
      ));
    }, serviceUuid: serviceUuid);
  }

  void stopScan() {
    _bleManager.stopScan();
    // Only fall back to disconnected if we were actually scanning. ScanPage's
    // dispose() calls this even when it's being torn down *because* a connect
    // succeeded — without this guard we'd clobber the fresh connected state.
    if (state == BleState.scanning) {
      state = BleState.disconnected;
    }
  }

  Future<bool> connect(String deviceId, String deviceName,
      {bool allowJw = false}) async {
    // 调试模式旁路:虚拟设备不发起真实 GATT 连接,直接把
    // connectedDeviceProvider 置为一个"看起来已连"的 info,让
    // EBadgeAppRoot 自动切到 DevicePage。BleManager 不参与,不占资源。
    //
    // 但仍需先停扫描——真实 connect 内部会先 stopScan(),让 BleManager
    // 从 scanning 落回 disconnected。若跳过这一步,ScanPage 卸载时的
    // stopScan 会让 manager 从 scanning → disconnected 发一次事件,
    // _managerStateSub 会把刚设好的 connectedDeviceProvider 清掉,
    // EBadgeAppRoot 立刻走"设备已断开"分支。所以此处先 stopScan(在
    // provider 置 info 之前触发 listener 时,provider 还是 null,清 null
    // → null 无影响),再切 connected 状态。
    if (deviceId.startsWith(kDebugDeviceIdPrefix)) {
      state = BleState.connecting;
      _bleManager.stopScan();
      _ref.read(connectedDeviceProvider.notifier).state = ConnectedDeviceInfo(
        deviceId: deviceId,
        name: deviceName,
        mtu: 512,
      );
      state = BleState.connected;
      return true;
    }

    state = BleState.connecting;
    final success =
        await _bleManager.connect(deviceId, deviceName, allowJw: allowJw);
    if (success) {
      _ref.read(connectedDeviceProvider.notifier).state = ConnectedDeviceInfo(
        deviceId: deviceId,
        name: deviceName,
        mtu: _bleManager.mtu,
        isJw: _bleManager.jwTransport != null,
      );
      state = BleState.connected;
    } else {
      state = BleState.disconnected;
    }
    return success;
  }

  Future<void> disconnect() async {
    // 虚拟设备无需通知 BleManager,只清 provider + 状态即可。
    final currentId = _ref.read(connectedDeviceProvider)?.deviceId;
    if (currentId != null && currentId.startsWith(kDebugDeviceIdPrefix)) {
      state = BleState.disconnecting;
      _ref.read(connectedDeviceProvider.notifier).state = null;
      state = BleState.disconnected;
      return;
    }

    state = BleState.disconnecting;
    await _bleManager.disconnect();
    _ref.read(connectedDeviceProvider.notifier).state = null;
    state = BleState.disconnected;
  }
}

class ScannedDevicesNotifier extends StateNotifier<List<ScanDevice>> {
  ScannedDevicesNotifier() : super([]);

  void addDevice(ScanDevice device) {
    final index = state.indexWhere((d) => d.deviceId == device.deviceId);
    final previous = index >= 0 ? state[index] : null;
    final named = device.name.trim().isNotEmpty && device.name != '未知设备';
    final name = named ? device.name : previous?.name ?? device.name;
    final now = DateTime.now();
    final merged = ScanDevice(
        deviceId: device.deviceId,
        name: name,
        rssi: device.rssi,
        connectable: device.connectable,
        debug: device.debug,
        jwCandidate: device.jwCandidate || (previous?.jwCandidate ?? false),
        firstSeen: previous?.firstSeen ?? device.firstSeen ?? now,
        identitySeen: previous?.identitySeen ??
            device.identitySeen ??
            (named ? now : null));
    if (previous != null &&
        previous.rssi == merged.rssi &&
        previous.name == merged.name &&
        previous.connectable == merged.connectable &&
        previous.jwCandidate == merged.jwCandidate) {
      return;
    }
    if (merged.jwCandidate &&
        (previous == null ||
            (!previous.jwCandidate) ||
            (previous.identitySeen == null && merged.identitySeen != null))) {
      debugPrint(
          'JW scan: id=${merged.deviceId} first=${merged.firstSeen?.toUtc().toIso8601String()} identity=${merged.identitySeen?.toUtc().toIso8601String()} name=${merged.name}');
    }
    if (index >= 0) {
      final updated = [...state];
      updated[index] = merged;
      state = updated;
    } else {
      state = [...state, merged];
    }
  }

  void clear() => state = [];
}
