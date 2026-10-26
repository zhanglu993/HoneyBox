import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/capture/capture_models.dart';
import 'package:honeybox/services/capture/capture_polar.dart';

void main() {
  test('Polar selects discovered identities and persists ordered commands', () {
    const hr =
        CaptureChannel(service: '180d', characteristic: '2a37', instance: 3);
    const cp = CaptureChannel(
        service: polarService, characteristic: polarControl, instance: 2);
    const data =
        CaptureChannel(service: polarService, characteristic: polarData);
    final profile = polarCaptureProfile(
        id: 'H10', name: 'Polar', available: [hr, cp, data]);
    final restored = CaptureProfile.fromJson(profile.toJson());
    expect(restored.channels, [hr, cp, data]);
    expect(restored.minimumMtu, 232);
    expect(
        restored.startCommands.where((c) => c.hex != null).map((c) => c.hex), [
      '0300',
      '0302',
      '02000001820001010e00',
      '0202000119000101100002010800'
    ]);
    expect(restored.startCommands[3].waitChannel, data);
    expect(restored.startCommands[3].timeoutSeconds, 60);
    expect(restored.stopCommands.length, 2);
    expect(
        CaptureProfile.fromJson({
          'id': 'v1',
          'name': 'Old',
          'channels': [hr.toJson()]
        }).startCommands,
        isEmpty);
  });
  test('Polar requires all discovered channels and supports HR only', () {
    const hr = CaptureChannel(service: '180d', characteristic: '2a37');
    expect(() => polarCaptureProfile(id: 'a', name: 'a', available: [hr]),
        throwsStateError);
    final p = polarCaptureProfile(
        id: 'a',
        name: 'a',
        available: [hr],
        options: const PolarCaptureOptions(ecg: false, acc: false));
    expect(p.channels, [hr]);
    expect(p.minimumMtu, 0);
    expect(p.startCommands, isEmpty);
  });
}
