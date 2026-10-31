/// Platform-neutral OTA lifecycle. SDK callbacks are inputs, not proof of success.
enum OtaPhase {
  idle,
  preparing,
  checking,
  awaitingConfirmation,
  connecting,
  transferring,
  validating,
  activating,
  rebooting,
  reconnecting,
  verifying,
  finished
}

enum OtaOutcome {
  verified,
  failed,
  cancelled,
  pendingVerification,
  recoveryRequired
}

class OtaEvent {
  const OtaEvent(
      {required this.sessionId,
      required this.phase,
      this.outcome,
      this.rawType,
      this.rawCode,
      this.progress});
  final String sessionId;
  final OtaPhase phase;
  final OtaOutcome? outcome;
  final int? rawType, rawCode;
  final double? progress;
}

class OtaSession {
  OtaSession(this.id, {DateTime Function()? now}) : _now = now ?? DateTime.now {
    lastActivity = _now();
  }
  final DateTime Function() _now;
  late DateTime lastActivity;
  bool hasTimedOut(Duration limit) =>
      outcome == null && _now().difference(lastActivity) >= limit;
  final String id;
  OtaPhase phase = OtaPhase.idle;
  OtaOutcome? outcome;
  int? rawType, rawCode;
  double? progress;

  /// Returns false for stale or invalid events. A failure may receive later details.
  bool apply(OtaEvent event) {
    if (event.sessionId != id) return false;
    final p = event.progress;
    if (p != null && (!p.isFinite || p < 0 || p > 1)) return false;
    if ((event.phase == OtaPhase.finished) != (event.outcome != null)) {
      return false;
    }
    if (outcome != null) {
      if (outcome == OtaOutcome.failed && event.outcome == OtaOutcome.failed) {
        rawType ??= event.rawType;
        rawCode ??= event.rawCode;
        return true;
      }
      return false;
    }
    if (event.phase != phase &&
        event.phase != OtaPhase.finished &&
        event.phase.index != phase.index + 1) {
      return false;
    }
    if (event.outcome == OtaOutcome.verified && phase != OtaPhase.verifying) {
      return false;
    }
    if (event.phase == OtaPhase.finished && event.outcome == null) return false;
    lastActivity = _now();
    phase = event.phase;
    outcome = event.outcome;
    rawType = event.rawType ?? rawType;
    rawCode = event.rawCode ?? rawCode;
    if (event.progress != null) {
      final next = event.progress!.clamp(0.0, 1.0);
      if (progress == null || next > progress!) progress = next;
    }
    return true;
  }
}
