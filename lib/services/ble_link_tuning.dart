import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// Asks the host for a throughput-optimized BLE connection interval.
///
/// Windows defaults an LE link to its "balanced" profile (30-60 ms connection
/// interval), which measured out at roughly 30 kbps on the projection link.
/// The throughput-optimized profile asks for a fixed 15 ms interval. Android
/// needs nothing here, and flutter_blue_plus offers no cross-platform API for
/// it, so this rides HoneyBox's own Windows plugin.
class BleLinkTuning {
  BleLinkTuning({
    MethodChannel channel = const MethodChannel('ebadge/ble_link'),
    bool? supported,
  })  : _channel = channel,
        _supported = supported ?? (!kIsWebPlatform && Platform.isWindows);

  static const bool kIsWebPlatform = bool.fromEnvironment('dart.library.js_util');

  final MethodChannel _channel;
  final bool _supported;

  /// Whether this platform has a link tuner at all.
  bool get isSupported => _supported;

  /// Request the faster interval for [remoteId]. Failures are non-fatal: the
  /// link keeps working at the system default.
  Future<bool> requestThroughput(String remoteId) async {
    if (!_supported || remoteId.isEmpty) return false;
    try {
      await _channel.invokeMethod<void>(
        'requestThroughput',
        <String, dynamic>{'remoteId': remoteId},
      );
      return true;
    } on PlatformException catch (e) {
      debugPrint('BleLinkTuning: throughput request refused: ${e.code}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Return [remoteId] to the system default interval.
  Future<void> release(String remoteId) async {
    if (!_supported || remoteId.isEmpty) return;
    try {
      await _channel.invokeMethod<void>(
        'releaseThroughput',
        <String, dynamic>{'remoteId': remoteId},
      );
    } on PlatformException catch (_) {
      // Releasing is best effort; the request dies with the process anyway.
    } on MissingPluginException {
      // Host without the tuner.
    }
  }
}
