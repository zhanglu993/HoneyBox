import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/android_realtek_ota_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('prepare sends session id and close is idempotent, retry after failure',
      () async {
    final calls = <MethodCall>[];
    var fail = true;
    const channel = MethodChannel('honeybox/realtek-ota');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'prepare' && fail) {
        fail = false;
        throw PlatformException(code: 'failed');
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final adapter = AndroidRealtekOtaPlatform();
    await expectLater(adapter.prepare('opaque', sessionId: 'one'),
        throwsA(isA<PlatformException>()));
    await adapter.close();
    await adapter.close();
    await adapter.prepare('opaque', sessionId: 'two');
    expect((calls.last.arguments as Map)['sessionId'], 'two');
    await adapter.close();
    await adapter.close();
    expect(calls.where((call) => call.method == 'close').length, 2);
  });
}
