import 'package:flutter/services.dart';
import 'ota_platform.dart';

/// Android bridge; selected by composition root, never by shared OTA logic.
class AndroidRealtekOtaPlatform implements OtaPlatform {
  const AndroidRealtekOtaPlatform();
  static const _commands = MethodChannel('honeybox/realtek-ota');
  static const _events = EventChannel('honeybox/realtek-ota/events');
  @override
  bool get supported => true;
  @override
  Stream<Map<String, Object?>> get events => _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => Map<String, Object?>.from(e as Map));
  @override
  Future<void> prepare(String deviceId) =>
      _commands.invokeMethod<void>('prepare', {'address': deviceId});
  @override
  Future<void> start(String filePath) =>
      _commands.invokeMethod<void>('start', {'path': filePath});
  @override
  Future<void> close() => _commands.invokeMethod<void>('close');
}
