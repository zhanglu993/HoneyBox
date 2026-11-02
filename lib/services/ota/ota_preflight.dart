/// A safety check must pass explicitly; unknown never grants write access.
enum OtaCheckStatus { pass, warn, block, unknown }

class OtaCheck {
  final String id;
  final OtaCheckStatus status;
  final String explanation;
  const OtaCheck(this.id, this.status, this.explanation);
}

class PreflightReport {
  final List<OtaCheck> checks;
  PreflightReport(Iterable<OtaCheck> checks)
      : checks = List.unmodifiable(checks);
  bool get canStart =>
      checks.isNotEmpty &&
      checks.every((c) =>
          c.status == OtaCheckStatus.pass || c.status == OtaCheckStatus.warn);
}

/// Required checks are supplied by the protocol adapter, not by device name.
/// Duplicate or omitted checks fail closed.
PreflightReport evaluateOtaPreflight({
  required Set<String> requiredChecks,
  required Iterable<OtaCheck> checks,
}) {
  final results = checks.toList();
  final seen = <String>{};
  final duplicates = <String>{};
  for (final check in results) {
    if (!seen.add(check.id)) duplicates.add(check.id);
  }
  for (final id in duplicates) {
    results.add(OtaCheck(id, OtaCheckStatus.block, '检查项重复，无法确认结果'));
  }
  for (final id in requiredChecks.difference(seen)) {
    results.add(OtaCheck(id, OtaCheckStatus.unknown, '尚未获得检查结果'));
  }
  if (requiredChecks.isEmpty) {
    results.add(const OtaCheck('policy', OtaCheckStatus.unknown, '尚未配置设备检查策略'));
  }
  return PreflightReport(results);
}

class EnvironmentStatus {
  final bool? blePermissionGranted;
  final String? ownershipConflict;
  const EnvironmentStatus({this.blePermissionGranted, this.ownershipConflict});
}

PreflightReport addEnvironmentChecks(
        PreflightReport report, EnvironmentStatus environment) =>
    PreflightReport([
      ...report.checks,
      OtaCheck(
          'permission',
          environment.blePermissionGranted == true
              ? OtaCheckStatus.pass
              : environment.blePermissionGranted == false
                  ? OtaCheckStatus.block
                  : OtaCheckStatus.unknown,
          environment.blePermissionGranted == true
              ? '蓝牙权限已授予'
              : environment.blePermissionGranted == false
                  ? '蓝牙或附近设备权限未授予'
                  : '蓝牙权限状态未知，请检查系统设置'),
      OtaCheck(
          'ownership',
          environment.ownershipConflict == null
              ? OtaCheckStatus.pass
              : OtaCheckStatus.block,
          environment.ownershipConflict ?? '蓝牙未被其他任务占用'),
    ]);
