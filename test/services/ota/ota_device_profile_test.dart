import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/ota_device_profile.dart';
import 'package:honeybox/services/ota/realtek_image_header.dart';

import 'realtek_image_header_test.dart' show makeRealtekImage;

void main() {
  final header = RealtekImageHeader.parse(makeRealtekImage());
  const defaultRegistry = OtaProfileRegistry();
  final s200 = OtaProfileRegistry.defaultProfiles.single;
  test('exact, missing, ambiguous and partial matches', () {
    expect(defaultRegistry.match(header).status, OtaProfileMatchStatus.matched);
    expect(const OtaProfileRegistry([]).match(header).status,
        OtaProfileMatchStatus.none);
    expect(OtaProfileRegistry([s200, s200]).match(header).status,
        OtaProfileMatchStatus.ambiguous);
    final partial = RealtekImageHeader.parse(makeRealtekImage().sublist(0, 10));
    expect(
        defaultRegistry.match(partial).status, OtaProfileMatchStatus.ambiguous);
    const incomplete = OtaDeviceProfile(
        id: 'partial',
        displayName: 'partial',
        icType: 9,
        imageId: 0x2793,
        evidence: 'test');
    expect(const OtaProfileRegistry([incomplete]).match(header).status,
        OtaProfileMatchStatus.ambiguous);
  });
  test('JSON supports lists, ranges and optional policy fields', () {
    final registry = OtaProfileRegistry.fromJson(jsonEncode([
      {
        'id': 'test',
        'displayName': 'Test',
        'icType': 9,
        'imageIds': [0x2793, 2],
        'imageIdMin': 10,
        'imageIdMax': 12,
        'customerName': 'S200_62#',
        'appBankSize': 1048576,
        'batteryMinPercent': 55,
        'evidence': 'test'
      }
    ]));
    expect(registry.match(header).status, OtaProfileMatchStatus.matched);
    expect(registry.profiles.single.acceptsImageId(11), isTrue);
    expect(registry.profiles.single.allowedCommitIds, isNull);
  });
  test('invalid JSON and invalid profile give FormatException', () {
    for (final source in [
      '{',
      '{}',
      '[{}]',
      '[{"id": 2}]',
      '[{"id":"x","displayName":"x","icType":9,"imageIdMin":4,"imageIdMax":2,"evidence":"x"}]'
    ]) {
      expect(() => OtaProfileRegistry.fromJson(source), throwsFormatException);
    }
  });
}
