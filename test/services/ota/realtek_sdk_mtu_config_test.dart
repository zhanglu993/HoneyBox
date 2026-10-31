import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native SDK buffer check uses the 256-byte ATT MTU budget', () {
    final bridge = File(
      'android/app/src/main/kotlin/com/honeygui/honeybox/RealtekOtaBridge.kt',
    ).readAsStringSync();
    expect(bridge, contains('BUFFER_CHECK_MTU_UPDATE_MECHANISM_CUSTOMIZED'));
    final match = RegExp(
      r'\.preferredMtuSize\(\((\d+) - (\d+)\) / (\d+) \* (\d+)\)',
    ).firstMatch(bridge);
    expect(match, isNotNull);
    final values = List.generate(4, (i) => int.parse(match!.group(i + 1)!));
    final packet = (values[0] - values[1]) ~/ values[2] * values[3];
    expect(values, [256, 3, 16, 16]);
    expect(packet, 240);
    expect(packet, lessThanOrEqualTo(256 - 3));
    // CUSTOMIZED uses this packet size even when the 0x09 reply says 517.
    expect(packet, lessThan(517 - 3));
  });
}
