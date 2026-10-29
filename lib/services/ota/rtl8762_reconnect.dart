import 'dart:async';

/// Retry only transport failures; never retry incompatible device data.
Future<T> retryRtl8762Reconnect<T>(Future<T> Function() attempt,
    {Future<void> Function()? delay}) async {
  for (var i = 0; i < 3; i++) {
    try {
      return await attempt();
    } on FormatException {
      rethrow;
    } catch (_) {
      if (i == 2) rethrow;
      await (delay?.call() ?? Future<void>.delayed(const Duration(seconds: 3)));
    }
  }
  throw StateError('unreachable');
}
