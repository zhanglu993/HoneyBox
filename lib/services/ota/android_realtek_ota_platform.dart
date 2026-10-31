import 'package:flutter/services.dart';
import 'ota_platform.dart';
import 'firmware_inspection.dart';

/// Android channel adapter. Closing cannot cancel a native transfer.
class AndroidRealtekOtaPlatform implements OtaPlatform {
  static const _commands = MethodChannel('honeybox/realtek-ota');
  static const _events = EventChannel('honeybox/realtek-ota/events');
  bool _needsClose = false;
  bool _preparing = false;
  @override
  bool get supported => true;
  @override
  Stream<Map<String, Object?>> get events => _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => Map<String, Object?>.from(e as Map));
  Future<DeviceCapabilities> deviceCapabilities({int? expectedIcType}) async {
    final values = await _commands.invokeMapMethod<String, Object?>('deviceCapabilities');
    final ic = values?['icType'];
    final id = values?['imageId'];
    final version = values?['currentVersion'];
    final capacity = values?['capacity'];
    return DeviceCapabilities(
      confirmed: ic is int && ic > 0 && id is int && id > 0 &&
          version is int && version >= 0 && capacity is int && capacity > 0,
      expectedIcType: expectedIcType,
      icType: ic is int ? ic : null, imageId: id is int ? id : null,
      currentVersion: version is int ? version : null,
      capacity: capacity is int ? capacity : null,
    );
  }

  @override
  Future<void> prepare(String deviceId, {String? sessionId}) async {
    if (_preparing || _needsClose) throw StateError('OTA 会话尚未关闭');
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
