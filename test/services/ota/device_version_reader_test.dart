import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/android_realtek_ota_platform.dart';
import 'package:honeybox/services/ota/device_version_reader.dart';

class FakeVersionReader implements DeviceVersionReader {
  final result = Completer<int?>();
  @override
  Future<int?> readVersion(String deviceId) => result.future;
}

void main() {
  test('version read completes before SDK prepare can begin', () async {
    final reader = FakeVersionReader();
    final platform = AndroidRealtekOtaPlatform(versionReader: reader);
    final pending = platform.deviceCapabilities('device');
    await expectLater(
        platform.prepare('device', sessionId: '1'), throwsStateError);
    reader.result.complete(0x3000000f);
    final caps = await pending;
    expect(caps.currentVersion, 0x3000000f);
    expect(caps.confirmed, isTrue);
  });
  test('missing version is unconfirmed', () async {
    final reader = FakeVersionReader()..result.complete(null);
    final caps = await AndroidRealtekOtaPlatform(versionReader: reader)
        .deviceCapabilities('device');
    expect(caps.confirmed, isFalse);
    expect(caps.currentVersion, isNull);
  });
}
