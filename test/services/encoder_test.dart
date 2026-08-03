import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/encoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('openCamera uses the encoder wire contract and forwards camera events',
      () async {
    const method = MethodChannel('test/encoder');
    const events = EventChannel('test/encoder/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final cameraEvents = StreamController<dynamic>.broadcast();
    final calls = <MethodCall>[];
    StreamSubscription<dynamic>? eventSubscription;

    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          eventSubscription = cameraEvents.stream.listen(sink.success);
        },
        onCancel: (arguments) async {
          await eventSubscription?.cancel();
          eventSubscription = null;
        },
      ),
    );
    addTearDown(() async {
      await cameraEvents.close();
      messenger.setMockMethodCallHandler(method, null);
      messenger.setMockStreamHandler(events, null);
    });

    final service = EncoderService(method: method, events: events);
    addTearDown(service.dispose);
    final camera = Completer<CameraInfo>();
    service.onCamera = camera.complete;

    service.listen();
    await service.openCamera(const EncoderConfig());
    cameraEvents.add(<String, dynamic>{
      'event': 'camera',
      'textureId': 41,
      'previewWidth': 368,
      'previewHeight': 368,
      'sensorOrientation': 0,
      'facingFront': false,
    });

    final info = await camera.future;
    expect(calls, hasLength(1));
    expect(calls.single.method, 'openCamera');
    expect(calls.single.arguments, containsPair('width', 368));
    expect(calls.single.arguments, containsPair('height', 368));
    expect(calls.single.arguments, containsPair('fps', 15));
    expect(info.textureId, 41);
    expect(info.previewWidth, 368);
    expect(info.previewHeight, 368);
  });
}
