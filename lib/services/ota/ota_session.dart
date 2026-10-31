import 'dart:async';

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
  OtaSession(this.id, {DateTime Function()? now,
      Map<OtaPhase, Duration>? phaseTimeouts, this.onTimeout,
      Timer Function(Duration, void Function())? timerFactory})
      : _now = now ?? DateTime.now,
        _timeouts = {...defaultPhaseTimeouts, ...?phaseTimeouts},
        _timerFactory = timerFactory ?? Timer.new {
    lastActivity = _now();
  }
  static const defaultPhaseTimeouts = <OtaPhase, Duration>{
    OtaPhase.preparing: Duration(seconds: 60),
    OtaPhase.connecting: Duration(seconds: 60),
    OtaPhase.transferring: Duration(minutes: 5),
    OtaPhase.validating: Duration(minutes: 2),
    OtaPhase.activating: Duration(minutes: 2),
    OtaPhase.rebooting: Duration(minutes: 2),
    OtaPhase.reconnecting: Duration(minutes: 2),
    OtaPhase.verifying: Duration(minutes: 2),
  };
  final DateTime Function() _now;
  final Map<OtaPhase, Duration> _timeouts;
  final void Function(OtaSession)? onTimeout;
  final Timer Function(Duration, void Function()) _timerFactory;
  Timer? _timer;
  String? failureDescription;
  OtaPhase? timedOutPhase;

  void dispose() { _timer?.cancel(); _timer = null; }

  bool checkTimeout() {
    final limit = _timeouts[phase];
    if (limit == null || !hasTimedOut(limit)) return false;
    timedOutPhase = phase;
    phase = OtaPhase.finished;
    outcome = OtaOutcome.failed;
    rawType = null;
    rawCode = null;
    failureDescription = '阶段超时';
    dispose();
    onTimeout?.call(this);
    return true;
  }

  void _scheduleTimeout() {
    dispose();
    final limit = _timeouts[phase];
    if (limit == null || onTimeout == null || outcome != null) return;
    _timer = _timerFactory(limit, () {
      if (!checkTimeout() && outcome == null) _scheduleTimeout();
    });
  }

  /// A reboot disconnect is expected; elsewhere it is a failure.
  bool disconnect(String sessionId) {
    if (sessionId != id) return false;
    if (phase == OtaPhase.reconnecting && outcome == null) return true;
    if (outcome != null) return outcome == OtaOutcome.failed;
    if (phase == OtaPhase.activating || phase == OtaPhase.rebooting) {
      phase = OtaPhase.reconnecting;
      lastActivity = _now();
      _scheduleTimeout();
      return true;
    }
    failureDescription = '设备已断开';
    return apply(OtaEvent(sessionId: id, phase: OtaPhase.finished,
        outcome: OtaOutcome.failed));
  }
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
    _scheduleTimeout();
    return true;
  }
}
