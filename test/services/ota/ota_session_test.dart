import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/ota_session.dart';

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
}
