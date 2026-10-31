import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/ota/ota_failure_card.dart';
import 'package:honeybox/services/ota/ota_failure.dart';
import 'package:honeybox/services/ota/ota_recovery_capability.dart';
import 'package:honeybox/services/ota/ota_session.dart';

void main() {
  test('unverified capabilities stay unknown and provide guidance', () {
    final c = OtaRecoveryCapabilities.forProfile(null);
    expect([c.restart, c.resumeOffset, c.dfuMode, c.rollback],
        everyElement(RecoveryCapabilityState.unknown));
    expect(c.guidance(OtaPhase.transferring), isNotEmpty);
  });
  testWidgets('unknown recovery capabilities expose no recovery buttons',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: OtaFailureCard(
                failure: OtaFailure.classify(phase: OtaPhase.transferring),
                retryCount: 0))));
    expect(find.textContaining('未经验证'), findsWidgets);
    for (final label in ['续传', '回滚', 'DFU']) {
      expect(find.widgetWithText(OutlinedButton, label), findsNothing);
      expect(find.widgetWithText(FilledButton, label), findsNothing);
    }
  });
}
