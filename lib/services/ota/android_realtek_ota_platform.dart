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
      bool? charging,
      bool allowSameOrOlderVersion = false}) async {
    if (_reading || _preparing || _needsClose) {
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
          charging: charging,
          allowSameOrOlderVersion: allowSameOrOlderVersion);
    } finally {
      _reading = false;
    }
  }

  @override
  Future<void> prepare(String deviceId, {String? sessionId}) async {
    if (_reading || _preparing || _needsClose) throw StateError('OTA 会话尚未关闭');
    if (sessionId == null || sessionId.isEmpty) {
      throw ArgumentError('sessionId required');
    }
    _preparing = true;
    _needsClose = true;
    try {
      await _commands.invokeMethod<void>(
          'prepare', {'address': deviceId, 'sessionId': sessionId});
    } finally {
      _preparing = false;
    }
  }

  @override
  Future<void> start(String filePath) =>
      _commands.invokeMethod<void>('start', {'path': filePath});
  @override
  Future<void> close() async {
    if (!_needsClose) return;
    if (_preparing) throw StateError('OTA 正在准备');
    await _commands.invokeMethod<void>('close');
    _needsClose = false;
  }
}
