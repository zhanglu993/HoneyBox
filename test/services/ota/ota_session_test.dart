import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/ota_session.dart';

class _Timer implements Timer {
  _Timer(this.callback);
  final void Function() callback;
  bool active = true;
  @override
  bool get isActive => active;
  @override
  int get tick => active ? 0 : 1;
  @override
  void cancel() => active = false;
  void fire() { if (active) { active = false; callback(); } }
}

void main() {
  test('旧会话与传输完成不会确认升级成功', () {
    final session = OtaSession('a');
    expect(
        session.apply(
            const OtaEvent(sessionId: 'b', phase: OtaPhase.transferring)),
        false);
    for (final phase in [
      OtaPhase.preparing,
      OtaPhase.checking,
      OtaPhase.awaitingConfirmation,
      OtaPhase.connecting
    ]) {
      expect(session.apply(OtaEvent(sessionId: 'a', phase: phase)), true);
    }
    expect(
        session.apply(const OtaEvent(
            sessionId: 'a', phase: OtaPhase.transferring, progress: 1)),
        true);
    expect(session.outcome, isNull);
    expect(
        session.apply(const OtaEvent(
            sessionId: 'a',
            phase: OtaPhase.finished,
            outcome: OtaOutcome.verified)),
        false);
  });
  test('泛化错误后的详细错误被保留且成功不能覆盖失败', () {
    final session = OtaSession('a');
    session.apply(const OtaEvent(
        sessionId: 'a', phase: OtaPhase.finished, outcome: OtaOutcome.failed));
    session.apply(const OtaEvent(
        sessionId: 'a',
        phase: OtaPhase.finished,
        outcome: OtaOutcome.failed,
        rawType: 3,
        rawCode: 42));
    expect(session.rawCode, 42);
    expect(session.rawType, 3);
    expect(
        session.apply(const OtaEvent(
            sessionId: 'a',
            phase: OtaPhase.finished,
            outcome: OtaOutcome.verified)),
        false);
  });
  test('拒绝跳阶段、非法终态与无效进度', () {
    final session = OtaSession('a');
    expect(
        session.apply(
            const OtaEvent(sessionId: 'a', phase: OtaPhase.transferring)),
        false);
    expect(
        session.apply(const OtaEvent(
            sessionId: 'a',
            phase: OtaPhase.preparing,
            outcome: OtaOutcome.failed)),
        false);
    expect(
        session.apply(const OtaEvent(
            sessionId: 'a', phase: OtaPhase.preparing, progress: double.nan)),
        false);
    expect(
        session.apply(const OtaEvent(
            sessionId: 'a', phase: OtaPhase.preparing, progress: 1.1)),
        false);
    expect(session.phase, OtaPhase.idle);
  });
  test('超时使用注入时钟且只检查当前阶段', () {
    var now = DateTime.utc(2026);
    final session = OtaSession('a', now: () => now);
    session.apply(const OtaEvent(sessionId: 'a', phase: OtaPhase.preparing));
    now = now.add(const Duration(seconds: 5));
    expect(session.hasTimedOut(const Duration(seconds: 6)), false);
    now = now.add(const Duration(seconds: 1));
    expect(session.hasTimedOut(const Duration(seconds: 6)), true);
  });
  test('阶段超时失败并接受晚到详细码', () {
    var now = DateTime.utc(2026);
    final session = OtaSession('timeout', now: () => now,
        phaseTimeouts: {OtaPhase.connecting: const Duration(seconds: 2)});
    for (final phase in [OtaPhase.preparing, OtaPhase.checking,
      OtaPhase.awaitingConfirmation, OtaPhase.connecting]) {
      session.apply(OtaEvent(sessionId: 'timeout', phase: phase));
    }
    now = now.add(const Duration(seconds: 2));
    expect(session.checkTimeout(), isTrue);
    expect(session.outcome, OtaOutcome.failed);
    expect(session.failureDescription, '阶段超时');
    expect(session.rawCode, isNull);
    expect(session.apply(const OtaEvent(sessionId: 'timeout', phase: OtaPhase.finished,
        outcome: OtaOutcome.failed, rawCode: 42)), isTrue);
    expect(session.rawCode, 42);
    session.dispose();
  });
  test('激活或重启断连进入重连，其他阶段断连失败', () {
    for (final target in [OtaPhase.activating, OtaPhase.rebooting, OtaPhase.transferring]) {
      final session = OtaSession('disconnect');
      for (final phase in OtaPhase.values.skip(1)) {
        session.apply(OtaEvent(sessionId: session.id, phase: phase));
        if (phase == target) break;
      }
      expect(session.disconnect('disconnect'), isTrue);
      if (target == OtaPhase.transferring) {
        expect(session.outcome, OtaOutcome.failed);
      } else {
        expect(session.phase, OtaPhase.reconnecting);
        expect(session.disconnect('disconnect'), isTrue);
        expect(session.outcome, isNull);
      }
      session.dispose();
    }
  });

  test('注入定时器自动触发超时，旧定时器被取消', () {
    var now = DateTime.utc(2026);
    final timers = <_Timer>[];
    var notifications = 0;
    final session = OtaSession('timer', now: () => now,
        phaseTimeouts: {OtaPhase.connecting: const Duration(seconds: 2)},
        timerFactory: (duration, callback) {
          final timer = _Timer(callback);
          timers.add(timer);
          return timer;
        }, onTimeout: (_) => notifications++);
    for (final phase in [OtaPhase.preparing, OtaPhase.checking,
      OtaPhase.awaitingConfirmation, OtaPhase.connecting]) {
      session.apply(OtaEvent(sessionId: session.id, phase: phase));
    }
    session.apply(OtaEvent(sessionId: session.id, phase: OtaPhase.connecting));
    expect(timers.first.isActive, isFalse);
    now = now.add(const Duration(seconds: 2));
    timers.last.fire();
    expect(session.outcome, OtaOutcome.failed);
    expect(notifications, 1);
    session.dispose();
  });

}
