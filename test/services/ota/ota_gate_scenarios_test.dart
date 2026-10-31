import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/ota_ownership.dart';
import 'package:honeybox/services/ota/ota_preflight.dart';
import '../../helpers/ota_fake_platform.dart';

void main() {
  test('ownership is exclusive and release is owner-only and idempotent', () {
    final ownership = OtaOwnership();
    expect(ownership.acquire(OtaOwner.capture).success, isTrue);
    expect(ownership.acquire(OtaOwner.capture).success, isFalse);
    expect(ownership.acquire(OtaOwner.ota).reason, contains('采集'));
    ownership.release(OtaOwner.ota);
    expect(ownership.owner, OtaOwner.capture);
    ownership.release(OtaOwner.capture);
    ownership.release(OtaOwner.capture);
    expect(ownership.owner, isNull);
  });
  for (final conflict in ['采集正在占用蓝牙', '普通连接正在占用蓝牙']) {
    test('environment conflict blocks start: $conflict', () async {
      final platform = OtaFakePlatform();
      final report = addEnvironmentChecks(
          PreflightReport(
              [const OtaCheck('format', OtaCheckStatus.pass, '通过')]),
          EnvironmentStatus(
              blePermissionGranted: true, ownershipConflict: conflict));
      if (report.canStart) await platform.start('fake');
      expect(platform.calls, isNot(contains('start')));
      await platform.controller.close();
    });
  }
  for (final permission in [false, null]) {
    test('permission $permission blocks start', () async {
      final platform = OtaFakePlatform();
      final report = addEnvironmentChecks(
          PreflightReport(
              [const OtaCheck('format', OtaCheckStatus.pass, '通过')]),
          EnvironmentStatus(blePermissionGranted: permission));
      if (report.canStart) await platform.start('fake');
      expect(platform.calls, isNot(contains('start')));
      await platform.controller.close();
    });
  }
  for (final id in ['compatibility', 'chip', 'capacity']) {
    test('$id blocks start', () async {
      final platform = OtaFakePlatform();
      final report = addEnvironmentChecks(
          PreflightReport([OtaCheck(id, OtaCheckStatus.block, '不匹配')]),
          const EnvironmentStatus(blePermissionGranted: true));
      if (report.canStart) await platform.start('fake');
      expect(platform.calls, isNot(contains('start')));
      await platform.controller.close();
    });
  }
  test('battery warnings require confirmation but do not block', () {
    final report = addEnvironmentChecks(
        PreflightReport(
            [const OtaCheck('battery', OtaCheckStatus.warn, '无法读取电量')]),
        const EnvironmentStatus(blePermissionGranted: true));
    expect(report.canStart, isTrue);
    expect(report.checks.any((c) => c.status == OtaCheckStatus.warn), isTrue);
  });
}
