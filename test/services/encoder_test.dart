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

  test('dispose during restart cancellation cannot revive event listening',
      () async {
    const method = MethodChannel('test/restart-dispose-cancel');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final cancelGate = Completer<void>();
    final streams = _EventStreamHarness(onCancel: (_) => cancelGate.future);
    var closes = 0;
    messenger.setMockMethodCallHandler(method, (call) async {
      if (call.method == 'closeCamera') closes++;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(method, null);
      await streams.close();
    });
    final service = EncoderService(
      method: method,
      eventStreamFactory: streams.create,
      eventCancellationTimeout: const Duration(minutes: 1),
    );

    service.listen();
    final restart = service.restartCameraSession();
    await Future<void>.delayed(Duration.zero);
    final dispose = service.dispose();
    cancelGate.complete();
    await Future.wait([restart, dispose]);

    service.listen();
    expect(closes, 1);
    expect(streams.listenCount, 1);
  });

  test('dispose during restart close cannot revive event listening', () async {
    const method = MethodChannel('test/restart-dispose-close');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final closeGate = Completer<void>();
    final streams = _EventStreamHarness();
    var closes = 0;
    messenger.setMockMethodCallHandler(method, (call) {
      if (call.method != 'closeCamera') return Future<void>.value();
      closes++;
      return closes == 1 ? closeGate.future : Future<void>.value();
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(method, null);
      await streams.close();
    });
    final service = EncoderService(
      method: method,
      eventStreamFactory: streams.create,
    );

    service.listen();
    final restart = service.restartCameraSession();
    await Future<void>.delayed(Duration.zero);
    final dispose = service.dispose();
    await Future<void>.delayed(Duration.zero);
    closeGate.complete();
    await Future.wait([restart, dispose]);

    service.listen();
    expect(closes, 2);
    expect(streams.listenCount, 1);
  });

  test('cancel timeout still closes the old session and relistens', () async {
    const method = MethodChannel('test/restart-cancel-timeout');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final neverCancelled = Completer<void>();
    final streams = _EventStreamHarness(onCancel: (_) => neverCancelled.future);
    var closes = 0;
    messenger.setMockMethodCallHandler(method, (call) async {
      if (call.method == 'closeCamera') closes++;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(method, null);
      await streams.close();
    });
    final service = EncoderService(
      method: method,
      eventStreamFactory: streams.create,
      eventCancellationTimeout: Duration.zero,
    );
    addTearDown(service.dispose);

    service.listen();
    await service.restartCameraSession();

    expect(closes, 1);
    expect(streams.listenCount, 2);
    neverCancelled.complete();
  });

  test('cancel error still closes the old session and relistens', () async {
    const method = MethodChannel('test/restart-cancel-error');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final streams = _EventStreamHarness(
      onCancel: (_) => Future<void>.error(StateError('cancel failed')),
    );
    var closes = 0;
    messenger.setMockMethodCallHandler(method, (call) async {
      if (call.method == 'closeCamera') closes++;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(method, null);
      await streams.close();
    });
    final service = EncoderService(
      method: method,
      eventStreamFactory: streams.create,
    );
    addTearDown(service.dispose);

    service.listen();
    await service.restartCameraSession();

    expect(closes, 1);
    expect(streams.listenCount, 2);
  });

  test('close failure leaves restart in a consistent listening state',
      () async {
    const method = MethodChannel('test/restart-close-error');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final streams = _EventStreamHarness();
    var closes = 0;
    messenger.setMockMethodCallHandler(method, (call) async {
      if (call.method == 'closeCamera') {
        closes++;
        throw PlatformException(code: 'close_failed');
      }
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(method, null);
      await streams.close();
    });
    final service = EncoderService(
      method: method,
      eventStreamFactory: streams.create,
    );
    addTearDown(service.dispose);

    service.listen();
    await service.restartCameraSession();

    expect(closes, 1);
    expect(streams.listenCount, 2);
  });
}

class _EventStreamHarness {
  _EventStreamHarness({this.onCancel});

  final Future<void> Function(int index)? onCancel;
  final List<StreamController<dynamic>> _controllers = [];

  int get listenCount => _controllers.length;

  Stream<dynamic> create() {
    final index = _controllers.length;
    final controller = StreamController<dynamic>(
      onCancel: () => onCancel?.call(index),
    );
    _controllers.add(controller);
    return controller.stream;
  }

  Future<void> close() async {
    for (final controller in _controllers) {
      if (!controller.isClosed) await controller.close();
    }
  }
}
