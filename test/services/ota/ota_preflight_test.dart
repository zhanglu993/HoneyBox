import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/ota_preflight.dart';

void main() {
  const pass = OtaCheckStatus.pass;
  test('all required checks must explicitly pass', () {
    final report = evaluateOtaPreflight(requiredChecks: {
      'file',
      'device'
    }, checks: [
      const OtaCheck('file', pass, 'ok'),
      const OtaCheck('device', pass, 'ok'),
    ]);
    expect(report.canStart, isTrue);
  });
  test('missing or unknown device capability blocks writing', () {
    final missing = evaluateOtaPreflight(
        requiredChecks: {'file', 'device'},
        checks: [const OtaCheck('file', pass, 'ok')]);
    expect(missing.canStart, isFalse);
    expect(missing.checks.last.status, OtaCheckStatus.unknown);
    final unknown = evaluateOtaPreflight(
        requiredChecks: {'device'},
        checks: [const OtaCheck('device', OtaCheckStatus.unknown, 'unknown')]);
    expect(unknown.canStart, isFalse);
  });
  test('empty policy and conflicting duplicated checks fail closed', () {
    expect(
        evaluateOtaPreflight(requiredChecks: {}, checks: []).canStart, isFalse);
    expect(
        evaluateOtaPreflight(requiredChecks: {
          'device'
        }, checks: [
          const OtaCheck('device', pass, ''),
          const OtaCheck('device', pass, '')
        ]).canStart,
        isFalse);
  });
}
