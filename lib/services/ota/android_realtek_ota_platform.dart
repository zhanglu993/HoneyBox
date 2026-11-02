import 'package:flutter/services.dart';
import 'ota_platform.dart';
import 'firmware_inspection.dart';
import 'device_version_reader.dart';

/// Android channel adapter. Closing cannot cancel a native transfer.
class AndroidRealtekOtaPlatform implements OtaPlatform {
  static const _commands = MethodChannel('honeybox/realtek-ota');
  static const _events = EventChannel('honeybox/realtek-ota/events');
  final DeviceVersionReader versionReader;
  AndroidRealtekOtaPlatform(
      {this.versionReader = const FlutterBlueDeviceVersionReader()});
  bool _reading = false;
  bool _needsClose = false;
  bool _preparing = false;
  bool _started = false;
  bool _prepared = false;
  bool _closing = false;
  @override
  bool get supported => true;
  @override
  Stream<Map<String, Object?>> get events => _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => Map<String, Object?>.from(e as Map));
  Future<DeviceCapabilities> deviceCapabilities(String deviceId,
      {int? expectedIcType,
      int? deviceReportedCapacity,
      int? batteryPercent,
      bool? charging}) async {
    if (_reading || _preparing || _needsClose || _closing) {
      throw StateError('OTA 连接正在使用，无法读取版本');
    }
    _reading = true;
    try {
      final version = await versionReader.readVersion(deviceId);
      return DeviceCapabilities(
          confirmed: version != null,
          expectedIcType: expectedIcType,
          deviceReportedCapacity: deviceReportedCapacity,
          currentVersion: version,
          batteryPercent: batteryPercent,
          charging: charging);
    } finally {
      _reading = false;
    }
  }

  @override
  Future<void> prepare(String deviceId, {String? sessionId}) async {
    if (_reading || _preparing || _needsClose || _closing) throw StateError('OTA 会话尚未关闭');
    if (sessionId == null || sessionId.isEmpty) {
      throw ArgumentError('sessionId required');
    }
    _preparing = true;
    _needsClose = true;
    try {
      await _commands.invokeMethod<void>(
          'prepare', {'address': deviceId, 'sessionId': sessionId});
      _prepared = true;
    } finally {
      _preparing = false;
    }
  }

  @override
  Future<void> start(String filePath) async {
    if (!_prepared || _preparing || _closing || _started) {
      throw StateError('OTA 会话未准备或已启动');
    }
    _started = true;
    await _commands.invokeMethod<void>('start', {'path': filePath});
  }
  @override
  Future<void> close() async {
    if (!_needsClose) return;
    if (_preparing) throw StateError('OTA 正在准备');
    if (_closing) throw StateError('OTA 正在关闭');
    _closing = true;
    try {
      await _commands.invokeMethod<void>('close');
      _needsClose = false;
      _started = false;
      _prepared = false;
    } finally {
      _closing = false;
    }
  }
}
