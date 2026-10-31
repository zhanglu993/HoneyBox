import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/ota_platform.dart';

class WaitingPlatform implements OtaPlatform {
  final waiting = Completer<void>();
  @override
  bool get supported => true;
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> prepare(String deviceId) => waiting.future;
  @override
  Future<void> start(String filePath) async {}
  @override
  Future<void> close() async {}
}

void main() {
  test('unsupported platform cannot prepare or start an upgrade', () async {
    const platform = UnsupportedOtaPlatform();
    expect(platform.supported, isFalse);
    expect(platform.capabilities.transport, OtaCapabilityStatus.unsupported);
    expect(platform.capabilities.resume, OtaCapabilityStatus.unknown);
    await expectLater(platform.prepare('opaque'), throwsUnsupportedError);
    await expectLater(platform.start('/tmp/file'), throwsUnsupportedError);
    await platform.close();
  });

  test('typed events retain unknown data and exact raw error values', () {
    final source = <String, Object?>{
      'message': 'failed',
      'done': true,
      'errorType': 3,
      'errorCode': 42,
      'sessionId': 'opaque',
      'extra': 'future',
    };
    final event = OtaPlatformEvent.fromMap(source);
    source['errorCode'] = 0;
    expect(event.errorType, 3);
    expect(event.errorCode, 42);
    expect(event.sessionId, 'opaque');
    expect(event.raw['extra'], 'future');
    expect(event.done, isTrue);
  });

  test('unknown and malformed event values do not imply success', () {
    final event = OtaPlatformEvent.fromMap({'done': 'true', 'progress': '100'});
    expect(event.done, isFalse);
    expect(event.progress, isNull);
    expect(event.errorCode, isNull);
  });

  test('prepare timeout bounds the wait without claiming native cancellation',
      () async {
    final platform = WaitingPlatform();
    await expectLater(
        platform.prepareWithTimeout('device', const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()));
    expect(platform.waiting.isCompleted, isFalse);
    platform.waiting.complete();
  });
}
