import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ble_cmd_registry.dart';
import '../services/ble_manager.dart' as ble;
import '../services/hotspot.dart';
import '../services/wifi_provisioning.dart';
import '../services/wifi_transport.dart';
import 'ble_provider.dart';

/// High-level WiFi provisioning + connection phase.
enum WifiPhase {
  idle,
  hotspotStarting, // opening the local-only hotspot
  provisioning, // CONFIG_SET sent, waiting for CONFIG_ACK
  deviceConnecting, // ACK accepted, waiting for the device to join + report IP
  tcpConnecting, // opening the TCP video socket
  connected, // TCP video link up — ready to stream
  failed, // gave up; [WifiManager.message] explains why
}

/// Owns the whole WiFi lifecycle: local-only hotspot, BLE provisioning
/// (CMD 0x0D over the command channel), and the TCP video client. A single
/// app-scoped instance so the connection survives navigating between the WiFi
/// setup page and the stream page.
class WifiManager extends ChangeNotifier {
  WifiManager(this._ble) {
    // BLE is the control channel for provisioning; if it drops, the WiFi link
    // can no longer be managed — tear the hotspot / TCP down and reset.
    _bleStateSub = _ble.onStateChanged.listen(_onBleState);
  }

  final ble.BleManager _ble;
  final HotspotService _hotspot = HotspotService();
  final TcpVideoClient client = TcpVideoClient();

  StreamSubscription<Uint8List>? _cmdSub;
  StreamSubscription<ble.BleState>? _bleStateSub;

  WifiPhase _phase = WifiPhase.idle;
  String? _message;
  HotspotInfo? _hotspotInfo;
  String? _deviceIp;
  int _devicePort = WifiProv.defaultPort;

  int _reqId = 0;
  Completer<WifiConfigAck>? _ackCompleter;
  Completer<WifiStatus>? _statusCompleter;
  Timer? _statusFirstTimer; // one-shot delay before the first STATUS query
  Timer? _statusPollTimer; // periodic queries thereafter

  /// STATUS polling cadence while waiting for the device to join the hotspot and
  /// report its IP. The first query is deferred by [_kStatusFirstDelay] (the
  /// device needs time to associate and obtain DHCP); subsequent queries repeat
  /// every [_kStatusInterval].
  static const Duration _kStatusFirstDelay = Duration(seconds: 15);
  static const Duration _kStatusInterval = Duration(seconds: 3);

  // Public state -------------------------------------------------------------
  WifiPhase get phase => _phase;
  String? get message => _message;
  HotspotInfo? get hotspotInfo => _hotspotInfo;
  String? get deviceIp => _deviceIp;
  int get devicePort => _devicePort;

  bool get isConnected => _phase == WifiPhase.connected && client.isConnected;

  /// True once the device has reported an IP — a TCP-only reconnect is possible.
  bool get canReconnect => _deviceIp != null && _deviceIp!.isNotEmpty;

  bool get _busy =>
      _phase == WifiPhase.hotspotStarting ||
      _phase == WifiPhase.provisioning ||
      _phase == WifiPhase.deviceConnecting ||
      _phase == WifiPhase.tcpConnecting;

  bool get busy => _busy;

  void _setPhase(WifiPhase p, [String? msg]) {
    _phase = p;
    _message = msg;
    notifyListeners();
  }

  /// Re-evaluate the live WiFi / TCP state on page entry so the UI reflects
  /// reality rather than a phase left over from a previous session. Checks the
  /// TCP socket and the hotspot; the device IP is preserved so a TCP-only
  /// reconnect is still offered. An in-flight flow is left untouched.
  Future<void> refreshState() async {
    if (_busy) return;

    // 1) TCP truth — the socket may have connected or dropped while we were
    //    away. It is the definitive signal for the "connected" state.
    if (client.isConnected) {
      if (_phase != WifiPhase.connected) {
        _setPhase(WifiPhase.connected, '已连接 $_deviceIp:$_devicePort');
      }
      return;
    }

    // 2) TCP is down. Verify the hotspot is still up; if not, the credentials
    //    on screen are stale, so drop them.
    var hotspotUp = false;
    try {
      hotspotUp = await _hotspot.isActive();
    } catch (_) {}
    if (!hotspotUp) _hotspotInfo = null;

    // 3) Correct any stale terminal / connected phase to idle (keeping the
    //    device IP so the reconnect shortcut remains available).
    if (_phase == WifiPhase.connected || _phase == WifiPhase.failed) {
      _setPhase(WifiPhase.idle);
    } else {
      notifyListeners(); // hotspotInfo may have changed
    }
  }

  // ── Command-channel plumbing ────────────────────────────────────────────

  void _ensureListening() {
    _cmdSub ??= _ble.commandNotifications.listen(_onCommand);
    client.onDisconnected = _onTcpDropped;
  }

  void _onCommand(Uint8List payload) {
    final frame = WifiProv.parse(payload);
    if (frame == null) return;
    switch (frame.key) {
      case BleCmdWifiProvKey.configAck:
        final ack = WifiProv.parseConfigAck(frame.value);
        if (ack != null && !(_ackCompleter?.isCompleted ?? true)) {
          _ackCompleter!.complete(ack);
        }
        break;
      case BleCmdWifiProvKey.status:
        final st = WifiProv.parseStatus(frame.value);
        if (st == null) return;
        debugPrint('WiFi/配网 STATUS state=${WifiProv.stateText(st.state)} '
            'ip=${st.ip}:${st.port} err=${st.error}');
        if (st.connected &&
            st.ip.isNotEmpty &&
            !(_statusCompleter?.isCompleted ?? true)) {
          _statusCompleter!.complete(st);
        } else if (st.failed && !(_statusCompleter?.isCompleted ?? true)) {
          _statusCompleter!.completeError(
              StateError('设备配网失败：${WifiProv.statusErrorText(st.error)}'));
        }
        break;
    }
  }

  void _onTcpDropped() {
    _stopStatusPolling();
    if (_phase == WifiPhase.connected) {
      _setPhase(WifiPhase.failed, 'WiFi 视频连接已断开');
    }
  }

  /// React to BLE connection changes. When the device disconnects, the WiFi
  /// link is no longer manageable, so stop the hotspot, drop the TCP socket and
  /// reset to idle.
  void _onBleState(ble.BleState state) {
    if (state == ble.BleState.disconnected) _resetOnBleLoss();
  }

  Future<void> _resetOnBleLoss() async {
    // Nothing to undo if we're already idle with no hotspot / link.
    if (_phase == WifiPhase.idle &&
        _hotspotInfo == null &&
        _deviceIp == null &&
        !client.isConnected) {
      return;
    }
    _stopStatusPolling();
    await client.close();
    try {
      await _hotspot.stop();
    } catch (_) {}
    _hotspotInfo = null;
    _deviceIp = null;
    _setPhase(WifiPhase.idle, '蓝牙已断开，WiFi 连接已重置');
  }

  // ── Full provisioning flow ────────────────────────────────────────────────

  /// Run the complete flow: start hotspot → push credentials over BLE → wait
  /// for the device to join and report its IP → open the TCP video link.
  Future<void> provisionAndConnect() async {
    if (_busy) return;
    if (!_ble.commandAvailable) {
      _setPhase(WifiPhase.failed, '蓝牙命令通道未就绪，请重新连接设备');
      return;
    }
    _ensureListening();

    // 1) Local-only hotspot.
    _setPhase(WifiPhase.hotspotStarting, '正在开启本地热点…');
    HotspotInfo info;
    try {
      info = await _hotspot.start();
    } catch (e) {
      _setPhase(WifiPhase.failed, '开启热点失败：$e');
      return;
    }
    if (info.ssid.isEmpty) {
      _setPhase(WifiPhase.failed, '热点凭据无效（SSID 为空）');
      return;
    }
    _hotspotInfo = info;

    // 2) Push SSID/password to the device and await its acceptance.
    _setPhase(WifiPhase.provisioning, '正在下发 WiFi 配置…');
    final reqId = (_reqId = (_reqId + 1) & 0xFFFF);
    _ackCompleter = Completer<WifiConfigAck>();
    _statusCompleter = Completer<WifiStatus>();
    try {
      _ble.sendCommand(WifiProv.buildConfigSet(
        info.ssid,
        info.password,
        requestId: reqId,
        flags: WifiProv.flagSaveCredentials,
      ));
    } catch (e) {
      _setPhase(WifiPhase.failed, '配置下发失败：$e');
      return;
    }

    try {
      final ack =
          await _ackCompleter!.future.timeout(const Duration(seconds: 8));
      if (!ack.accepted) {
        _setPhase(
            WifiPhase.failed, '设备拒绝配网：${WifiProv.ackErrorText(ack.error)}');
        return;
      }
    } on TimeoutException {
      _setPhase(WifiPhase.failed, '设备无响应（未回 CONFIG_ACK）');
      return;
    }

    // 3) Wait for the device to join the hotspot and report its IP. Poll
    //    STATUS periodically in case the device only answers on request.
    _setPhase(WifiPhase.deviceConnecting, '等待设备接入热点并获取 IP…');
    _startStatusPolling();
    WifiStatus status;
    try {
      status =
          await _statusCompleter!.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _stopStatusPolling();
      _setPhase(WifiPhase.failed, '等待设备连接超时（30s）');
      return;
    } catch (e) {
      _stopStatusPolling();
      _setPhase(WifiPhase.failed, e is StateError ? e.message : '$e');
      return;
    }
    _stopStatusPolling();
    _deviceIp = status.ip;
    _devicePort = status.port > 0 ? status.port : WifiProv.defaultPort;

    // 4) Open the TCP video link.
    await _openTcp();
  }

  void _startStatusPolling() {
    _stopStatusPolling();
    void query() {
      if (_statusCompleter?.isCompleted ?? true) return;
      _ble.sendCommand(WifiProv.buildStatusReq(requestId: _reqId));
    }

    // First query after the longer initial delay, then poll on the interval.
    _statusFirstTimer = Timer(_kStatusFirstDelay, () {
      query();
      _statusPollTimer = Timer.periodic(_kStatusInterval, (_) => query());
    });
  }

  void _stopStatusPolling() {
    _statusFirstTimer?.cancel();
    _statusFirstTimer = null;
    _statusPollTimer?.cancel();
    _statusPollTimer = null;
  }

  /// Open (or reopen) just the TCP video socket to the last reported device IP.
  /// Use this to retry after a TCP failure without re-running provisioning.
  Future<bool> connectTcp() async {
    if (_busy) return false;
    if (!canReconnect) {
      _setPhase(WifiPhase.failed, '尚无设备 IP，请先完成配网');
      return false;
    }
    _ensureListening();
    return _openTcp();
  }

  Future<bool> _openTcp() async {
    _setPhase(WifiPhase.tcpConnecting, '正在连接 $_deviceIp:$_devicePort…');
    final ok = await client.connect(_deviceIp!, _devicePort);
    if (ok) {
      _setPhase(WifiPhase.connected, '已连接 $_deviceIp:$_devicePort');
    } else {
      _setPhase(WifiPhase.failed, '连接 $_deviceIp:$_devicePort 失败');
    }
    return ok;
  }

  // ── Teardown ──────────────────────────────────────────────────────────────

  /// Drop the TCP link and stop the hotspot, returning to idle.
  Future<void> disconnect() async {
    _stopStatusPolling();
    await client.close();
    try {
      await _hotspot.stop();
    } catch (_) {}
    _hotspotInfo = null;
    _deviceIp = null;
    _setPhase(WifiPhase.idle);
  }

  @override
  void dispose() {
    _stopStatusPolling();
    _cmdSub?.cancel();
    _bleStateSub?.cancel();
    client.close();
    _hotspot.stop();
    super.dispose();
  }
}

/// App-scoped singleton so the WiFi link persists across pages.
final wifiManagerProvider = Provider<WifiManager>((ref) {
  final manager = WifiManager(ref.read(bleManagerProvider));
  ref.onDispose(manager.dispose);
  return manager;
});
