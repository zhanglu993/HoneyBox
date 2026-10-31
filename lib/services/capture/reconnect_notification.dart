import 'capture_session.dart';

/// Reports only transitions into reconnecting, not every retry or UI refresh.
class ReconnectNotificationTracker {
  final _phases = <String, CapturePhase>{};

  bool shouldNotify(String id, CapturePhase phase, {required bool enabled}) {
    final previous = _phases[id];
    _phases[id] = phase;
    return enabled &&
        phase == CapturePhase.reconnecting &&
        previous == CapturePhase.recording;
  }

  void remove(String id) => _phases.remove(id);
}
