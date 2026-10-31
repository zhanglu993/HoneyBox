import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/ota_device_profile.dart';

void main() {
  test('stable default lookup and missing id', () {
    expect(OtaProfileRegistry.defaultProfileById('s200').batterySource, BatterySource.basAndBwps);
    expect(() => OtaProfileRegistry.defaultProfileById('missing'), throwsStateError);
  });
  test('battery source JSON accepts known values and rejects unknown', () {
    Map<String, Object> profile(String source) => {'id':'x','displayName':'X','icType':9,'imageId':1,'evidence':'test','batterySource':source};
    for (final source in BatterySource.values) {
      expect(OtaProfileRegistry.fromJson(jsonEncode([profile(source.name)])).profiles.single.batterySource, source);
    }
    expect(() => OtaProfileRegistry.fromJson(jsonEncode([profile('invalid')])), throwsFormatException);
  });
}
