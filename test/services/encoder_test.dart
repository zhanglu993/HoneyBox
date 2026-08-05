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

  test('startEncoding sends the Android-compatible H264 stream configuration',
      () async {
    const method = MethodChannel('test/encoder-start');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(method, null));

    final service = EncoderService(method: method);
    await service.startEncoding(const EncoderConfig(), stream: true);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'startEncoding');
    final arguments = calls.single.arguments as Map;
    expect(arguments, containsPair('format', 'h264'));
    expect(arguments, containsPair('width', 368));
    expect(arguments, containsPair('height', 368));
    expect(arguments, containsPair('fps', 15));
    expect(arguments, containsPair('bitrate', 150000));
    expect(arguments, containsPair('iFrameIntervalSec', 6));
    expect(arguments, containsPair('cropZoom', 1.0));
    expect(arguments, containsPair('msv1Skip', true));
    expect(arguments, containsPair('msv1SkipThr', 0));
    expect(arguments, containsPair('jpegQuality', 80));
    expect(arguments, containsPair('recordToFile', false));
    expect(arguments, containsPair('stream', true));
  });

  test('stop, keyframe, and encoder-frame requests use bare method names',
      () async {
    const method = MethodChannel('test/encoder-requests');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(method, null));

    final service = EncoderService(method: method);
    await service.stopEncoding();
    await service.requestKeyframe();
    await service.requestEncoderFrame();

    expect(calls.map((call) => call.method).toList(),
        ['stopEncoding', 'requestKeyframe', 'requestEncoderFrame']);
    expect(calls.every((call) => call.arguments == null), isTrue);
  });

  test('encoder events forward started, frame, stats, stopped, and info',
      () async {
    const method = MethodChannel('test/encoder-events');
    const events = EventChannel('test/encoder-events/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final encoderEvents = StreamController<dynamic>.broadcast();
    StreamSubscription<dynamic>? eventSubscription;

    messenger.setMockMethodCallHandler(method, (call) async {});
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          eventSubscription = encoderEvents.stream.listen(sink.success);
        },
        onCancel: (arguments) async {
          await eventSubscription?.cancel();
          eventSubscription = null;
        },
      ),
    );
    addTearDown(() async {
      await encoderEvents.close();
      messenger.setMockMethodCallHandler(method, null);
      messenger.setMockStreamHandler(events, null);
    });

    final service = EncoderService(method: method, events: events);
    addTearDown(service.dispose);

    final started = Completer<(String, int, int)>();
    final frame = Completer<(Uint8List, bool)>();
    final stats = Completer<EncoderStats>();
    final stopped = Completer<EncoderResult>();
    final info = Completer<String>();
    service.onStarted = (path, width, height) =>
        started.complete((path, width, height));
    service.onFrame = (data, key) => frame.complete((data, key));
    service.onStats = stats.complete;
    service.onStopped = stopped.complete;
    service.onInfo = info.complete;

    service.listen();
    encoderEvents.add(<String, dynamic>{
      'event': 'started',
      'path': null,
      'width': 368,
      'height': 368,
    });
    encoderEvents.add(<String, dynamic>{
      'event': 'frame',
      'data': Uint8List.fromList([0, 0, 0, 1, 0x65]),
      'key': true,
    });
    encoderEvents.add(<String, dynamic>{
      'event': 'stats',
      'frames': 12,
      'keyframes': 3,
      'bytes': 4096,
      'keyBytes': 2048,
      'fps': 14.5,
      'lastBytes': 256,
    });
    encoderEvents.add(<String, dynamic>{
      'event': 'info',
      'message': 'encoder note',
    });
    encoderEvents.add(<String, dynamic>{
      'event': 'stopped',
      'path': null,
      'frames': 12,
      'keyframes': 3,
      'bytes': 4096,
    });

    expect(await started.future, ('', 368, 368));
    final (data, key) = await frame.future;
    expect(data, [0, 0, 0, 1, 0x65]);
    expect(key, isTrue);
    final liveStats = await stats.future;
    expect(liveStats.frames, 12);
    expect(liveStats.keyframes, 3);
    expect(liveStats.bytes, 4096);
    expect(liveStats.keyBytes, 2048);
    expect(liveStats.fps, 14.5);
    expect(liveStats.lastBytes, 256);
    expect(await info.future, 'encoder note');
    final result = await stopped.future;
    expect(result.path, isNull);
    expect(result.frames, 12);
    expect(result.keyframes, 3);
    expect(result.bytes, 4096);
  });

  test('an error event carrying a Windows code still reports its message',
      () async {
    const method = MethodChannel('test/encoder-error');
    const events = EventChannel('test/encoder-error/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final encoderEvents = StreamController<dynamic>.broadcast();
    StreamSubscription<dynamic>? eventSubscription;

    messenger.setMockMethodCallHandler(method, (call) async {});
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          eventSubscription = encoderEvents.stream.listen(sink.success);
        },
        onCancel: (arguments) async {
          await eventSubscription?.cancel();
          eventSubscription = null;
        },
      ),
    );
    addTearDown(() async {
      await encoderEvents.close();
      messenger.setMockMethodCallHandler(method, null);
      messenger.setMockStreamHandler(events, null);
    });

    final service = EncoderService(method: method, events: events);
    addTearDown(service.dispose);
    final error = Completer<String>();
    service.onError = error.complete;

    service.listen();
    encoderEvents.add(<String, dynamic>{
      'event': 'error',
      'message': 'MFT rejected the input frame',
      'code': 'encode_failed',
      'details': 'encoder',
    });

    expect(await error.future, 'MFT rejected the input frame');
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

  test('dispose cancel timeout still closes the native camera', () async {
    const method = MethodChannel('test/dispose-cancel-timeout');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final cancelGate = Completer<void>();
    final streams = _EventStreamHarness(onCancel: (_) => cancelGate.future);
    var closes = 0;
    messenger.setMockMethodCallHandler(method, (call) async {
      if (call.method == 'closeCamera') closes++;
    });
    addTearDown(() async {
      if (!cancelGate.isCompleted) cancelGate.complete();
      messenger.setMockMethodCallHandler(method, null);
      await streams.close();
    });
    final service = EncoderService(
      method: method,
      eventStreamFactory: streams.create,
      eventCancellationTimeout: Duration.zero,
    );

    service.listen();
    await service.dispose().timeout(const Duration(milliseconds: 100));

    expect(closes, 1);
  });

  test('dispose cancel timeout absorbs a native close failure', () async {
    const method = MethodChannel('test/dispose-timeout-close-error');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final cancelGate = Completer<void>();
    final streams = _EventStreamHarness(onCancel: (_) => cancelGate.future);
    var closes = 0;
    messenger.setMockMethodCallHandler(method, (call) async {
      if (call.method == 'closeCamera') {
        closes++;
        throw PlatformException(code: 'close_failed');
      }
    });
    addTearDown(() async {
      if (!cancelGate.isCompleted) cancelGate.complete();
      messenger.setMockMethodCallHandler(method, null);
      await streams.close();
    });
    final service = EncoderService(
      method: method,
      eventStreamFactory: streams.create,
      eventCancellationTimeout: Duration.zero,
    );

    service.listen();
    await service.dispose().timeout(const Duration(milliseconds: 100));

    expect(closes, 1);
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
