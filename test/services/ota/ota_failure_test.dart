import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/device_probe.dart';
import 'package:honeybox/services/ota/ota_failure.dart';

void main() {
  test('unknown codes remain visible and do not invent a cause', () {
    final f = OtaFailure.classify(rawType: 7, rawCode: 999, message: 'error');
    expect(f.category, OtaFailureCategory.unknown);
    expect(f.rawCode, 999);
    expect(f.guidance, contains('错误码 7/999'));
    expect(f.guidance, contains('原因未确认'));
  });
  test('confirmed SDK categories remain distinct', () {
    for (final category in [
      OtaFailureCategory.crc,
      OtaFailureCategory.flash,
      OtaFailureCategory.connection
    ]) {
      expect(
          OtaFailure.classify(confirmedCategory: category).category, category);
    }
  });
  test('battery advice requires low measured battery and not charging', () {
    final low = OtaFailure.classify(
        probe: const DeviceProbeResult(batteryPercent: 20, charging: false),
        batteryMinPercent: 30);
    final unknown = OtaFailure.classify(
        probe: const DeviceProbeResult(charging: false), batteryMinPercent: 30);
    expect(low.category, OtaFailureCategory.battery);
    expect(unknown.category, OtaFailureCategory.unknown);
  });
  test('specific failure replaces generic but not conversely', () {
    final generic = OtaFailure.classify(message: 'error');
    final specific = OtaFailure.classify(
        probe: const DeviceProbeResult(batteryPercent: 10, charging: false),
        batteryMinPercent: 30);
    expect(generic.merge(specific).category, OtaFailureCategory.battery);
    expect(specific.merge(generic).category, OtaFailureCategory.battery);
  });
  test('message is bounded and blank gets a placeholder', () {
    expect(OtaFailure.classify(message: ' ').rawMessage, '无详细信息');
    expect(
        OtaFailure.classify(message: List.filled(501, 'a').join())
            .rawMessage!
            .length,
        501);
  });
}
