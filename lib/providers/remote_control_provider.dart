import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/remote_control_session.dart';
import 'ble_provider.dart';

/// Session lives for the entire app run — BleManager itself handles reconnect,
/// and `commandNotifications` / `sendCommand` remain valid across reconnects
/// (they're bound to the manager, not to a specific connection). So one
/// session per app is enough; UI pages register/unregister handlers as they
/// come and go.
final remoteControlSessionProvider = Provider<RemoteControlSession>((ref) {
  final ble = ref.read(bleManagerProvider);
  final session = RemoteControlSession(
    commandAvailable: () => ble.commandAvailable,
    sendCommand: ble.sendCommand,
    notifications: ble.commandNotifications,
  );
  ref.onDispose(session.dispose);
  return session;
});
