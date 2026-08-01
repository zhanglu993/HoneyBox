import 'dart:convert';
import 'dart:typed_data';

import 'ble_cmd_registry.dart';

/// L2 WiFi provisioning protocol (CMD 0x0D) — ported from desk-mate's
/// `protocols/l2_wifi_provisioning.py`.
///
/// Rides the BLE L1 command channel (FFC1 write / FFC2 notify). The app pushes
/// its (local-only-hotspot) SSID/password to the device; the device joins the
/// hotspot, starts a TCP video server, and reports its IP/port back so the app
/// can open the WiFi streaming transport.
///
/// L2 frame format: `[cmd(1), 0x00, key(1), vlen_hi(1), vlen_lo(1)] + value`.
///
/// CMD / key 值集中在 `ble_cmd_registry.dart`:CMD 字节走 [BleCmd.wifiProv],
/// 子命令 key 走顶层类 [BleCmdWifiProvKey](能用于 switch case 的 const 表达式);
/// 本文件保留载荷语义常量(result/error/state/flag)。
class WifiProv {
  WifiProv._();

  // CONFIG_ACK result codes
  static const int resultAccepted = 0x00;
  static const int resultRejected = 0x01;

  // CONFIG_ACK error codes
  static const int errNone = 0x00;
  static const int errMalformed = 0x01;
  static const int errUnsupportedMode = 0x02;
  static const int errInvalidSsid = 0x03;
  static const int errInvalidPassword = 0x04;
  static const int errBusy = 0x05;

  // STATUS state codes
  static const int stateIdle = 0x00;
  static const int stateConnecting = 0x01;
  static const int stateConnected = 0x02;
  static const int stateFailed = 0x03;

  // STATUS error codes
  static const int statusErrNone = 0x00;
  static const int statusErrAuthFailed = 0x01;
  static const int statusErrNoApFound = 0x02;
  static const int statusErrDhcpFailed = 0x03;
  static const int statusErrTimeout = 0x04;
  static const int statusErrTcpServerFailed = 0x05;
  static const int statusErrUnknown = 0x06;

  // Flag bits for CONFIG_SET.flags
  static const int flagSaveCredentials = 0x01;

  static const int defaultPort = 8783;

  static String ackErrorText(int error) => switch (error) {
        errNone => '无错误',
        errMalformed => 'Payload 格式错误',
        errUnsupportedMode => '不支持的配网模式',
        errInvalidSsid => '无效的 SSID',
        errInvalidPassword => '无效的密码',
        errBusy => '设备繁忙',
        _ => '未知错误(0x${error.toRadixString(16)})',
      };

  static String statusErrorText(int error) => switch (error) {
        statusErrNone => '无错误',
        statusErrAuthFailed => 'WiFi 认证失败',
        statusErrNoApFound => '未找到该 WiFi',
        statusErrDhcpFailed => 'DHCP 失败',
        statusErrTimeout => '连接超时',
        statusErrTcpServerFailed => 'TCP 服务启动失败',
        statusErrUnknown => '未知错误',
        _ => '未知错误(0x${error.toRadixString(16)})',
      };

  static String stateText(int state) => switch (state) {
        stateIdle => '空闲',
        stateConnecting => '连接中',
        stateConnected => '已连接',
        stateFailed => '失败',
        _ => '未知(0x${state.toRadixString(16)})',
      };

  // ── Frame builder ──────────────────────────────────────────────────────────

  /// Build a CMD_WIFI_PROVISIONING L2 frame with the given [key] and [value].
  static Uint8List buildFrame(int key, Uint8List value) {
    final frame = Uint8List(5 + value.length);
    frame[0] = BleCmd.wifiProv;
    frame[1] = 0x00;
    frame[2] = key;
    frame[3] = (value.length >> 8) & 0xFF;
    frame[4] = value.length & 0xFF;
    frame.setRange(5, 5 + value.length, value);
    return frame;
  }

  // ── CONFIG_SET ───────────────────────────────────────────────────────────

  /// Build a WIFI_CONFIG_SET frame.
  ///
  /// Value: `request_id u16BE, flags u8, ssid_len u8, ssid, pwd_len u8, pwd`.
  /// Throws [ArgumentError] if SSID/password lengths violate the constraints.
  static Uint8List buildConfigSet(
    String ssid,
    String password, {
    int requestId = 0,
    int flags = 0,
  }) {
    final ssidBytes = Uint8List.fromList(utf8.encode(ssid));
    final pwdBytes = Uint8List.fromList(utf8.encode(password));
    if (ssidBytes.isEmpty || ssidBytes.length > 32) {
      throw ArgumentError('SSID 编码后长度 ${ssidBytes.length} 超出范围 [1, 32]');
    }
    if (pwdBytes.length > 64) {
      throw ArgumentError('密码编码后长度 ${pwdBytes.length} 超出范围 [0, 64]');
    }
    final value = Uint8List(2 + 1 + 1 + ssidBytes.length + 1 + pwdBytes.length);
    var o = 0;
    value[o++] = (requestId >> 8) & 0xFF;
    value[o++] = requestId & 0xFF;
    value[o++] = flags & 0xFF;
    value[o++] = ssidBytes.length & 0xFF;
    value.setRange(o, o + ssidBytes.length, ssidBytes);
    o += ssidBytes.length;
    value[o++] = pwdBytes.length & 0xFF;
    value.setRange(o, o + pwdBytes.length, pwdBytes);
    return buildFrame(BleCmdWifiProvKey.configSet, value);
  }

  // ── STATUS_REQ ───────────────────────────────────────────────────────────

  static Uint8List buildStatusReq({int requestId = 0}) {
    final value = Uint8List(2);
    value[0] = (requestId >> 8) & 0xFF;
    value[1] = requestId & 0xFF;
    return buildFrame(BleCmdWifiProvKey.statusReq, value);
  }

  // ── Parsers (device → app) ─────────────────────────────────────────────────

  /// Parse a raw command-channel L2 payload as a provisioning frame, or null if
  /// it isn't one (wrong cmd / malformed).
  static WifiProvFrame? parse(Uint8List data) {
    if (data.length < 5) return null;
    if (data[0] != BleCmd.wifiProv) return null;
    final key = data[2];
    final vlen = (data[3] << 8) | data[4];
    if (data.length < 5 + vlen) return null;
    return WifiProvFrame(key: key, value: data.sublist(5, 5 + vlen));
  }

  /// Parse a CONFIG_ACK value → (requestId, result, error), or null.
  static WifiConfigAck? parseConfigAck(Uint8List v) {
    if (v.length < 4) return null;
    return WifiConfigAck(
      requestId: (v[0] << 8) | v[1],
      result: v[2],
      error: v[3],
    );
  }

  /// Parse a WIFI_STATUS value → (requestId, state, error, ip, port), or null.
  static WifiStatus? parseStatus(Uint8List v) {
    if (v.length < 6) return null;
    final requestId = (v[0] << 8) | v[1];
    final state = v[2];
    final error = v[3];
    final ipLen = v[4];
    var o = 5;
    if (o + ipLen + 2 > v.length) return null;
    final ip = ascii.decode(v.sublist(o, o + ipLen), allowInvalid: true);
    o += ipLen;
    final port = (v[o] << 8) | v[o + 1];
    return WifiStatus(
      requestId: requestId,
      state: state,
      error: error,
      ip: ip,
      port: port,
    );
  }
}

/// A parsed provisioning L2 frame (key + value).
class WifiProvFrame {
  final int key;
  final Uint8List value;
  const WifiProvFrame({required this.key, required this.value});
}

class WifiConfigAck {
  final int requestId;
  final int result;
  final int error;
  const WifiConfigAck({
    required this.requestId,
    required this.result,
    required this.error,
  });
  bool get accepted => result == WifiProv.resultAccepted;
}

class WifiStatus {
  final int requestId;
  final int state;
  final int error;
  final String ip;
  final int port;
  const WifiStatus({
    required this.requestId,
    required this.state,
    required this.error,
    required this.ip,
    required this.port,
  });
  bool get connected => state == WifiProv.stateConnected;
  bool get failed => state == WifiProv.stateFailed;
}
