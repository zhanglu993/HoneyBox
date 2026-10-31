import 'dart:async';

import 'android_realtek_firmware_parser.dart' show formatOtaVersion;
import 'device_probe.dart';
import 'ota_device_profile.dart';

enum PostcheckStatus { verified, mismatch, unavailable }

class OtaExpectedIdentity {
  final String deviceId;
  final int? icType;
  const OtaExpectedIdentity({required this.deviceId, this.icType});
}

class PostcheckResult {
  final PostcheckStatus status;
  final int? observedVersion, observedIcType;
  final String reason, guidance;
  const PostcheckResult(
      {required this.status,
      this.observedVersion,
      this.observedIcType,
      required this.reason,
      required this.guidance});
}

class OtaPostchecker {
  OtaPostchecker(this.probe,
      {this.attempts = 3,
      this.interval = const Duration(seconds: 5),
      Future<void> Function(Duration)? delay})
      : assert(attempts > 0),
        delay = delay ?? Future<void>.delayed;
  final DeviceProbe probe;
  final int attempts;
  final Duration interval;
  final Future<void> Function(Duration) delay;

  Future<PostcheckResult> verifyTarget(
      {required OtaExpectedIdentity expectedIdentity,
      required int expectedVersion,
      OtaDeviceProfile? profile}) async {
    final target = formatOtaVersion(expectedVersion);
    final guidance = '请重新连接设备，在设备信息中确认版本为 $target，并确认设备身份。';
    // The existing probe may send a battery request for a null/BWPS profile.
    // Postcheck is read-only, so explicitly disable battery probing.
    final readOnlyProfile = OtaDeviceProfile(
        id: profile?.id ?? 'postcheck',
        displayName: profile?.displayName ?? 'postcheck',
        icType: expectedIdentity.icType ?? 0,
        evidence: '',
        batterySource: BatterySource.none);
    for (var i = 0; i < attempts; i++) {
      DeviceProbeResult? result;
      try {
        result = await probe.probe(expectedIdentity.deviceId,
            profile: readOnlyProfile);
      } catch (_) {}
      final version = result?.currentVersion;
      if (version != null) {
        final chip = result?.otaDeviceInfo?.icType;
        if (chip != null &&
            expectedIdentity.icType != null &&
            chip != expectedIdentity.icType) {
          return PostcheckResult(
              status: PostcheckStatus.mismatch,
              observedVersion: version,
              observedIcType: chip,
              reason:
                  '设备芯片类型不一致，可能连接了不同设备或硬件；读到版本 ${formatOtaVersion(version)}。',
              guidance: guidance);
        }
        if (version != expectedVersion) {
          return PostcheckResult(
              status: PostcheckStatus.mismatch,
              observedVersion: version,
              observedIcType: chip,
              reason: '读到版本 ${formatOtaVersion(version)}，与目标版本 $target 不一致。',
              guidance: guidance);
        }
        if (chip == null || expectedIdentity.icType == null) {
          return PostcheckResult(
              status: PostcheckStatus.unavailable,
              observedVersion: version,
              observedIcType: chip,
              reason: '设备身份无法证实。',
              guidance: guidance);
        }
        return PostcheckResult(
            status: PostcheckStatus.verified,
            observedVersion: version,
            observedIcType: chip,
            reason: '设备身份与版本 $target 一致。',
            guidance: '');
      }
      if (i + 1 < attempts) await delay(interval);
    }
    return PostcheckResult(
        status: PostcheckStatus.unavailable,
        reason: '无法读取设备版本。',
        guidance: guidance);
  }
}
