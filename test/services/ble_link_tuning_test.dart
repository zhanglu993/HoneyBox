import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_link_tuning.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/ble_link');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<MethodCall> installHandler({Object? Function(MethodCall)? reply}) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply?.call(call);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    return calls;
  }

  test('requests and releases the faster interval for one device', () async {
    final calls = installHandler();
    final tuning = BleLinkTuning(channel: channel, supported: true);

    expect(await tuning.requestThroughput('03:22:33:77:33:13'), isTrue);
    await tuning.release('03:22:33:77:33:13');

    expect(calls.map((call) => call.method).toList(),
        ['requestThroughput', 'releaseThroughput']);
    expect(calls.first.arguments,
        containsPair('remoteId', '03:22:33:77:33:13'));
  });

  test('does nothing on a platform without a tuner', () async {
    final calls = installHandler();
    final tuning = BleLinkTuning(channel: channel, supported: false);

    expect(await tuning.requestThroughput('03:22:33:77:33:13'), isFalse);
    await tuning.release('03:22:33:77:33:13');

    expect(calls, isEmpty);
  });

  test('ignores an empty device id', () async {
    final calls = installHandler();
    final tuning = BleLinkTuning(channel: channel, supported: true);

    expect(await tuning.requestThroughput(''), isFalse);

    expect(calls, isEmpty);
  });

  test('a refused request is reported without throwing', () async {
    installHandler(
      reply: (_) => throw PlatformException(code: 'invalid_argument'),
    );
    final tuning = BleLinkTuning(channel: channel, supported: true);

    expect(await tuning.requestThroughput('03:22:33:77:33:13'), isFalse);
  });

  test('a host without the plugin is not an error', () async {
    final tuning = BleLinkTuning(
      channel: const MethodChannel('test/ble_link-missing'),
      supported: true,
    );

    expect(await tuning.requestThroughput('03:22:33:77:33:13'), isFalse);
    await tuning.release('03:22:33:77:33:13');
  });
}
