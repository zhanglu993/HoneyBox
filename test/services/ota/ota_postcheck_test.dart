import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/device_probe.dart';
import 'package:honeybox/services/ota/ota_device_profile.dart';
import 'package:honeybox/services/ota/ota_postcheck.dart';

class ScriptedProbe implements DeviceProbe {
  ScriptedProbe(this.responses);
  final List<Object> responses;
  int calls = 0;
  @override
  Future<DeviceProbeResult> probe(String deviceId,
      {OtaDeviceProfile? profile}) async {
    final response = responses[calls++];
    if (response is DeviceProbeResult) return response;
    throw response;
  }
}

const info = OtaDeviceInfoRecord(
    icType: 9,
    otaVersion: 1,
    secureVersion: 0,
    modeBits: 0,
    maxBuffer: 0,
    tempBankSizeBytes: null,
    imgIndicator: 0);
const other = OtaDeviceInfoRecord(
    icType: 8,
    otaVersion: 1,
    secureVersion: 0,
    modeBits: 0,
    maxBuffer: 0,
    tempBankSizeBytes: null,
    imgIndicator: 0);
const identity = OtaExpectedIdentity(deviceId: 'device', icType: 9);

void main() {
  for (final scenario in [
    (
      const DeviceProbeResult(currentVersion: 2, otaDeviceInfo: info),
      identity,
      PostcheckStatus.verified
    ),
    (
      const DeviceProbeResult(currentVersion: 1, otaDeviceInfo: info),
      identity,
      PostcheckStatus.mismatch
    ),
    (
      const DeviceProbeResult(currentVersion: 2, otaDeviceInfo: other),
      identity,
      PostcheckStatus.mismatch
    ),
    (
      const DeviceProbeResult(currentVersion: 2),
      identity,
      PostcheckStatus.unavailable
    ),
    (
      const DeviceProbeResult(currentVersion: 2, otaDeviceInfo: info),
      const OtaExpectedIdentity(deviceId: 'device'),
      PostcheckStatus.unavailable
    ),
  ]) {
    test('checks version and identity: ${scenario.$3}', () async {
      final result = await OtaPostchecker(ScriptedProbe([scenario.$1]))
          .verifyTarget(expectedIdentity: scenario.$2, expectedVersion: 2);
      expect(result.status, scenario.$3);
    });
  }
  test('unreadable version retries without real delays', () async {
    final probe = ScriptedProbe(
        [Exception(), const DeviceProbeResult(), const DeviceProbeResult()]);
    final delays = <Duration>[];
    final result = await OtaPostchecker(probe, delay: (d) async {
      delays.add(d);
    }).verifyTarget(expectedIdentity: identity, expectedVersion: 2);
    expect(result.status, PostcheckStatus.unavailable);
    expect(result.guidance, contains('设备信息'));
    expect(probe.calls, 3);
    expect(delays, [const Duration(seconds: 5), const Duration(seconds: 5)]);
  });
  test('recovers after a probe failure', () async {
    final probe = ScriptedProbe([
      Exception(),
      const DeviceProbeResult(currentVersion: 2, otaDeviceInfo: info)
    ]);
    final result = await OtaPostchecker(probe, delay: (_) async {})
        .verifyTarget(expectedIdentity: identity, expectedVersion: 2);
    expect(result.status, PostcheckStatus.verified);
    expect(probe.calls, 2);
  });
}
