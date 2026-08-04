import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/stream/stream_page.dart';
import 'package:honeybox/providers/remote_control_provider.dart';
import 'package:honeybox/services/ble_cmd_registry.dart';
import 'package:honeybox/services/encoder.dart';
import 'package:honeybox/services/remote_control_session.dart';
import 'package:honeybox/services/stream_protocol.dart';
import 'package:honeybox/services/stream_transport.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeEncoder encoder;
  late RemoteControlSession remote;
  final transports = <_FakeStreamTransport>[];

  setUp(() {
    encoder = _FakeEncoder();
    remote = RemoteControlSession(
      commandAvailable: () => false,
      sendCommand: (_) => null,
      notifications: const Stream<Uint8List>.empty(),
    );
  });

  tearDown(() async {
    await remote.dispose();
    for (final transport in transports) {
      await transport.dispose();
    }
    transports.clear();
  });

  Future<void> mountReadyPage(
    WidgetTester tester, {
    required List<_FakeStreamTransport> withTransports,
    Duration stopTimeout = const Duration(seconds: 5),
  }) async {
    transports.addAll(withTransports);
    final queue = Queue<_FakeStreamTransport>.of(withTransports);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [remoteControlSessionProvider.overrideWithValue(remote)],
        child: MaterialApp(
          home: StreamPage(
            deviceName: 'test',
            deviceId: 'test',
            encoder: encoder,
            transportFactory: (_) => queue.removeFirst(),
            encoderStopTimeout: stopTimeout,
            requestCameraPermission: () async => PermissionStatus.granted,
            loadEncoderConfig: () async => const EncoderConfig(),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(find.byKey(const Key('stream-shutter')), findsOneWidget);
  }

  Future<void> tapShutter(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('stream-shutter')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  testWidgets('KS_OPEN handshake completes before native encoding starts',
      (tester) async {
    final order = <String>[];
    final transport = _FakeStreamTransport(order: order);
    encoder.order = order;
    await mountReadyPage(tester, withTransports: [transport]);

    await tapShutter(tester);

    expect(order, containsAllInOrder(['KS_OPEN', 'encoder-start']));
    expect(transport.keys.first, BleCmdStreamKey.open);
    expect(encoder.startCalls, hasLength(1));
    expect(find.text('投屏中'), findsOneWidget);
  });

  testWidgets('disconnect while opening never starts native encoding',
      (tester) async {
    final transport = _FakeStreamTransport(autoAckResult: null);
    await mountReadyPage(tester, withTransports: [transport]);

    await tester.tap(find.byKey(const Key('stream-shutter')));
    await tester.pump();
    transport.emitAvailability(false);
    await tester.pump();
    await tester.pump();

    expect(encoder.startCalls, isEmpty);
    expect(encoder.stopCount, 0);
    expect(find.textContaining('连接已断开'), findsOneWidget);
    expect(transport.availabilityCancels, 1);

    transport.ackOpen();
    await tester.pump();
    expect(encoder.startCalls, isEmpty);
  });

  testWidgets('disconnect while streaming stops once without KS_CLOSE',
      (tester) async {
    final transport = _FakeStreamTransport();
    await mountReadyPage(tester, withTransports: [transport]);
    await tapShutter(tester);

    transport.emitAvailability(false);
    await tester.pump();
    await tester.pump();
    transport.emitAvailability(false);
    await tester.pump();

    expect(encoder.stopCount, 1);
    expect(
        transport.keys.where((key) => key == BleCmdStreamKey.close), isEmpty);
    expect(transport.availabilityCancels, 1);
    expect(find.textContaining('连接已断开'), findsOneWidget);
    expect(find.text('投屏中'), findsNothing);
  });

  testWidgets('user stop sends one CLOSE and cancels availability',
      (tester) async {
    final transport = _FakeStreamTransport();
    await mountReadyPage(tester, withTransports: [transport]);
    await tapShutter(tester);

    await tapShutter(tester);

    expect(encoder.stopCount, 1);
    expect(
      transport.keys.where((key) => key == BleCmdStreamKey.close),
      hasLength(1),
    );
    expect(transport.availabilityCancels, 1);
  });

  testWidgets('rapid restart waits for terminal stopped with mutable callbacks',
      (tester) async {
    final first = _FakeStreamTransport();
    final second = _FakeStreamTransport();
    encoder.autoStopEvent = false;
    await mountReadyPage(tester, withTransports: [first, second]);
    await tapShutter(tester);
    final startedCallback = encoder.onStarted;
    final stoppedCallback = encoder.onStopped;
    final frameCallback = encoder.onFrame;
    final errorCallback = encoder.onError;
    final statsCallback = encoder.onStats;

    await tapShutter(tester);
    await tester.tap(find.byKey(const Key('stream-shutter')));
    await tester.pump();
    await tester.pump();

    expect(encoder.stopCount, 1);
    expect(encoder.startCalls, hasLength(1));
    expect(second.messages, isEmpty);
    expect(identical(encoder.onStarted, startedCallback), isTrue);
    expect(identical(encoder.onStopped, stoppedCallback), isTrue);
    expect(identical(encoder.onFrame, frameCallback), isTrue);
    expect(identical(encoder.onError, errorCallback), isTrue);
    expect(identical(encoder.onStats, statsCallback), isTrue);

    encoder.emitFrame(Uint8List.fromList([9]), true);
    encoder.emitError('旧编码错误');
    encoder.emitStats(const EncoderStats(fps: 99, frames: 99));
    encoder.emitInfo('旧编码信息');
    encoder.emitPreview(true, 99, 1, 1);
    await tester.pump();

    first.emitAvailability(false);
    expect(first.frameSendCount, 0);
    expect(find.textContaining('旧编码错误'), findsNothing);
    expect(find.textContaining('99.0 fps'), findsNothing);

    encoder.emitStopped();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(encoder.stopCount, 1);
    expect(encoder.startCalls, hasLength(2));
    expect(second.keys.first, BleCmdStreamKey.open);
    expect(find.text('投屏中'), findsOneWidget);

    encoder.emitFrame(Uint8List.fromList([1, 2, 3]), true);
    await tester.pump();
    await tester.pump();
    expect(second.frameSendCount, 1);
  });

  testWidgets(
      'stopping run error cannot be rerouted into replacement camera attempt',
      (tester) async {
    final transport = _FakeStreamTransport();
    encoder.autoStopEvent = false;
    await mountReadyPage(tester, withTransports: [transport]);
    await tapShutter(tester);
    final permanentErrorDispatcher = encoder.onError;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(encoder.stopCount, 1);
    expect(identical(encoder.onError, permanentErrorDispatcher), isTrue);

    encoder.emitError('旧编码错误误投摄像头');
    await tester.pump();

    expect(find.textContaining('旧编码错误误投摄像头'), findsNothing);

    encoder.emitStopped();
    await tester.pump();
    encoder.emitError('当前摄像头错误');
    await tester.pump();

    expect(find.textContaining('当前摄像头错误'), findsWidgets);
  });

  testWidgets('stop timeout rejects restart without retiring the old run',
      (tester) async {
    final first = _FakeStreamTransport();
    final second = _FakeStreamTransport();
    encoder.autoStopEvent = false;
    await mountReadyPage(
      tester,
      withTransports: [first, second],
      stopTimeout: const Duration(milliseconds: 10),
    );
    await tapShutter(tester);

    await tapShutter(tester);
    await tester.tap(find.byKey(const Key('stream-shutter')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();

    expect(encoder.startCalls, hasLength(1));
    expect(second.messages, isEmpty);
    expect(find.text('编码器尚未停止，无法重新投屏'), findsOneWidget);
  });

  testWidgets(
      'stop method failure keeps restart blocked until terminal stopped',
      (tester) async {
    final first = _FakeStreamTransport();
    final second = _FakeStreamTransport();
    encoder
      ..autoStopEvent = false
      ..stopError = StateError('stop method failed');
    await mountReadyPage(tester, withTransports: [first, second]);
    await tapShutter(tester);

    await tapShutter(tester);
    await tester.tap(find.byKey(const Key('stream-shutter')));
    await tester.pump();
    await tester.pump();

    expect(encoder.startCalls, hasLength(1));
    expect(second.messages, isEmpty);
    expect(find.text('编码器尚未停止，无法重新投屏'), findsOneWidget);

    encoder.emitStopped();
    await tester.pump();
    await tapShutter(tester);

    expect(encoder.startCalls, hasLength(2));
    expect(second.keys.first, BleCmdStreamKey.open);
  });

  testWidgets('rejected ACK includes the raw result', (tester) async {
    final transport = _FakeStreamTransport(autoAckResult: 0x2A);
    await mountReadyPage(tester, withTransports: [transport]);

    await tapShutter(tester);

    expect(find.text('投屏握手被拒绝（result=0x2A）'), findsOneWidget);
    expect(encoder.startCalls, isEmpty);
  });

  testWidgets('open timeout has a distinct message', (tester) async {
    final transport = _FakeStreamTransport(autoAckResult: null);
    await mountReadyPage(tester, withTransports: [transport]);

    await tester.tap(find.byKey(const Key('stream-shutter')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(find.text('投屏握手超时'), findsOneWidget);
    expect(encoder.startCalls, isEmpty);
  });

  testWidgets('open transport failure has a distinct message', (tester) async {
    final transport = _FakeStreamTransport(failOpen: true);
    await mountReadyPage(tester, withTransports: [transport]);

    await tapShutter(tester);

    expect(find.text('投屏握手发送失败'), findsOneWidget);
    expect(encoder.startCalls, isEmpty);
  });

  testWidgets('H264 permit replenishes after success and failure serially',
      (tester) async {
    final transport = _FakeStreamTransport();
    await mountReadyPage(tester, withTransports: [transport]);
    await tapShutter(tester);

    transport.failNextFrame = true;
    encoder.emitFrame(Uint8List.fromList([1]), true);
    await tester.pump();
    await tester.pump();
    expect(encoder.permitCount, 1);

    final blocker = Completer<void>();
    transport.blockNextFrame = blocker;
    encoder.emitFrame(Uint8List.fromList([2]), false);
    encoder.emitFrame(Uint8List.fromList([3]), false);
    await tester.pump();
    expect(transport.frameSendCount, 2);
    blocker.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(transport.frameSendCount, 3);
    expect(transport.maxConcurrentFrameSends, 1);
    expect(encoder.permitCount, 3);
  });

  testWidgets('late transport events after dispose are ignored',
      (tester) async {
    final transport = _FakeStreamTransport(autoAckResult: null);
    await mountReadyPage(tester, withTransports: [transport]);
    await tester.tap(find.byKey(const Key('stream-shutter')));
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    transport.emitAvailability(false);
    transport.ackOpen();
    await tester.pump();

    expect(transport.availabilityCancels, 1);
    expect(tester.takeException(), isNull);
  });
}

class _FakeStreamTransport implements StreamTransport {
  _FakeStreamTransport({
    this.autoAckResult = 0,
    this.failOpen = false,
    this.order,
  }) {
    _availability = StreamController<bool>.broadcast(
      onListen: () => availabilityListens++,
      onCancel: () => availabilityCancels++,
    );
  }

  bool available = true;
  final int? autoAckResult;
  final bool failOpen;
  final List<String>? order;
  late final StreamController<bool> _availability;
  final _notifications = StreamController<Uint8List>.broadcast(sync: true);
  final List<Uint8List> messages = [];
  int availabilityListens = 0;
  int availabilityCancels = 0;
  int frameSendCount = 0;
  int _activeFrameSends = 0;
  int maxConcurrentFrameSends = 0;
  bool failNextFrame = false;
  Completer<void>? blockNextFrame;

  List<int> get keys => messages.map((message) => message[2]).toList();

  @override
  StreamTransportKind get kind => StreamTransportKind.ble;

  @override
  bool get isAvailable => available;

  @override
  Stream<bool> get availabilityChanges => _availability.stream;

  @override
  int get chunkSize => 64;

  @override
  Stream<Uint8List> get notifications => _notifications.stream;

  @override
  Future<void> send(Uint8List l2) async {
    messages.add(Uint8List.fromList(l2));
    final key = l2[2];
    if (key == BleCmdStreamKey.open) {
      order?.add('KS_OPEN');
      if (failOpen) throw StateError('open write failed');
      if (autoAckResult != null) ackOpen(result: autoAckResult!);
      return;
    }
    if (key != BleCmdStreamKey.frame) return;

    frameSendCount++;
    _activeFrameSends++;
    if (_activeFrameSends > maxConcurrentFrameSends) {
      maxConcurrentFrameSends = _activeFrameSends;
    }
    final blocker = blockNextFrame;
    blockNextFrame = null;
    final fail = failNextFrame;
    failNextFrame = false;
    try {
      await blocker?.future;
      if (fail) throw StateError('frame write failed');
    } finally {
      _activeFrameSends--;
    }
  }

  void ackOpen({int result = 0}) {
    final open = messages.lastWhere(
      (message) => message[2] == BleCmdStreamKey.open,
    );
    final sid = open[5];
    _notifications.add(buildL2Cmd(
      BleCmd.stream,
      BleCmdStreamKey.ack,
      [sid, result, 0xFF, 0xFF],
    ));
  }

  void emitAvailability(bool next) {
    available = next;
    _availability.add(next);
  }

  Future<void> dispose() async {
    await _availability.close();
    await _notifications.close();
  }
}

class _FakeEncoder extends EncoderService {
  List<String>? order;
  final List<EncoderConfig> startCalls = [];
  bool autoStopEvent = true;
  Object? stopError;
  int stopCount = 0;
  int permitCount = 0;

  @override
  void listen() {}

  @override
  Future<void> openCamera(
    EncoderConfig config, {
    bool facingFront = false,
  }) async {
    onCamera?.call(const CameraInfo(
      textureId: 41,
      previewWidth: 368,
      previewHeight: 368,
      sensorOrientation: 0,
      facingFront: false,
    ));
  }

  @override
  Future<void> restartCameraSession() async {}

  @override
  Future<void> startEncoding(
    EncoderConfig config, {
    bool stream = false,
  }) async {
    order?.add('encoder-start');
    startCalls.add(config);
    onStarted?.call('', config.width, config.height);
  }

  @override
  Future<void> stopEncoding() async {
    stopCount++;
    if (stopError != null) throw stopError!;
    if (autoStopEvent) emitStopped();
  }

  void emitStopped() => onStopped?.call(const EncoderResult());

  void emitFrame(Uint8List data, bool key) => onFrame?.call(data, key);

  void emitError(String message) => onError?.call(message);

  void emitStats(EncoderStats stats) => onStats?.call(stats);

  void emitInfo(String message) => onInfo?.call(message);

  void emitPreview(bool encoded, int textureId, int width, int height) =>
      onPreview?.call(encoded, textureId, width, height);

  @override
  Future<void> requestEncoderFrame() async {
    permitCount++;
  }

  @override
  Future<void> closeCamera() async {}

  @override
  Future<void> dispose() async {}
}
