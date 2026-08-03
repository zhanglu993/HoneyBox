import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/stream/stream_page.dart';
import 'package:honeybox/providers/remote_control_provider.dart';
import 'package:honeybox/services/encoder.dart';
import 'package:honeybox/services/remote_control_session.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;
  late StreamController<dynamic> events;
  StreamSubscription<dynamic>? eventSubscription;
  late EncoderService encoder;
  late RemoteControlSession remote;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    events = StreamController<dynamic>.broadcast();
    encoder = EncoderService(
      method: const MethodChannel('test/stream/encoder'),
      events: const EventChannel('test/stream/encoder/events'),
    );
    remote = RemoteControlSession(
      commandAvailable: () => false,
      sendCommand: (_) => null,
      notifications: const Stream<Uint8List>.empty(),
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(
        const MethodChannel('test/stream/encoder'), null);
    messenger.setMockMessageHandler('test/stream/encoder', null);
    messenger.setMockStreamHandler(
        const EventChannel('test/stream/encoder/events'), null);
    await eventSubscription?.cancel();
    await encoder.dispose();
    await events.close();
    await remote.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [remoteControlSessionProvider.overrideWithValue(remote)],
        child: MaterialApp(
          home: StreamPage(
            deviceName: 'test',
            deviceId: 'test',
            encoder: encoder,
            requestCameraPermission: () async => PermissionStatus.granted,
            loadEncoderConfig: () async => const EncoderConfig(),
            cameraReadyTimeout: timeout,
          ),
        ),
      ),
    );
  }

  Future<void> pumpStartup(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  void wireEvents() {
    messenger.setMockStreamHandler(
      const EventChannel('test/stream/encoder/events'),
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          eventSubscription = events.stream.listen(sink.success);
        },
        onCancel: (arguments) => Future<void>.value(),
      ),
    );
  }

  testWidgets(
      'PlatformException exits loading and retry opens the camera again',
      (tester) async {
    wireEvents();
    var opens = 0;
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/stream/encoder'),
      (call) async {
        if (call.method != 'openCamera') return;
        opens++;
        if (opens == 1) {
          throw PlatformException(
            code: 'device_unavailable',
            message: '摄像头被占用',
          );
        }
      },
    );

    await mount(tester);
    await pumpStartup(tester);

    expect(find.text('摄像头启动失败：摄像头被占用'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('正在启动摄像头…'), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pump(const Duration(milliseconds: 300));
    await pumpStartup(tester);
    events.add(<String, dynamic>{
      'event': 'camera',
      'textureId': 41,
      'previewWidth': 368,
      'previewHeight': 368,
      'sensorOrientation': 0,
      'facingFront': false,
    });
    await tester.pump();

    expect(opens, 2);
    expect(find.byType(Texture), findsOneWidget);
  });

  testWidgets('MissingPluginException has a stable Chinese retry message',
      (tester) async {
    wireEvents();
    messenger.setMockMessageHandler(
      'test/stream/encoder',
      (message) async => null,
    );

    await mount(tester);
    await pumpStartup(tester);

    expect(find.text('摄像头启动失败：当前平台未提供摄像头功能，请确认应用已正确安装。'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('native ready error exits loading with bounded message',
      (tester) async {
    wireEvents();
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/stream/encoder'),
      (call) async {},
    );

    await mount(tester);
    await pumpStartup(tester);
    events.add(<String, dynamic>{'event': 'error', 'message': '初始化失败'});
    await tester.pump();

    expect(find.text('摄像头启动失败：初始化失败'), findsWidgets);
    expect(find.text('正在启动摄像头…'), findsNothing);
  });

  testWidgets('camera ready timeout exits loading with retry', (tester) async {
    wireEvents();
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/stream/encoder'),
      (call) async {},
    );

    await mount(tester, timeout: const Duration(milliseconds: 10));
    await pumpStartup(tester);
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('摄像头启动超时，请检查设备后重试。'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('stale open failure cannot overwrite a successful retry',
      (tester) async {
    wireEvents();
    final firstOpen = Completer<void>();
    var opens = 0;
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/stream/encoder'),
      (call) {
        if (call.method != 'openCamera') return Future<void>.value();
        opens++;
        return opens == 1 ? firstOpen.future : Future<void>.value();
      },
    );

    await mount(tester, timeout: const Duration(milliseconds: 10));
    await pumpStartup(tester);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.text('重试'));
    await pumpStartup(tester);
    events.add(<String, dynamic>{
      'event': 'camera',
      'textureId': 41,
      'previewWidth': 368,
      'previewHeight': 368,
      'sensorOrientation': 0,
      'facingFront': false,
    });
    await tester.pump();

    firstOpen.completeError(PlatformException(code: 'old', message: '旧错误'));
    await tester.pump();

    expect(opens, 2);
    expect(find.byType(Texture), findsOneWidget);
    expect(find.textContaining('旧错误'), findsNothing);
  });

  testWidgets('dispose suppresses delayed startup failure', (tester) async {
    wireEvents();
    final open = Completer<void>();
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/stream/encoder'),
      (call) =>
          call.method == 'openCamera' ? open.future : Future<void>.value(),
    );

    await mount(tester);
    await pumpStartup(tester);
    await tester.pumpWidget(const SizedBox());
    open.completeError(PlatformException(code: 'lost', message: '已经离开页面'));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('error seals its attempt against a late ready event',
      (tester) async {
    final fake = _AttemptEncoderService();
    encoder = fake;

    await mount(tester);
    await pumpStartup(tester);
    fake.errorCallbacks.single?.call('初始化失败');
    await tester.pump();
    fake.cameraCallbacks.single?.call(_cameraInfo(41));
    await tester.pump();

    expect(find.text('摄像头启动失败：初始化失败'), findsWidgets);
    expect(find.byType(Texture), findsNothing);
  });

  testWidgets('timeout seals its attempt against a late ready event',
      (tester) async {
    final fake = _AttemptEncoderService();
    encoder = fake;

    await mount(tester, timeout: const Duration(milliseconds: 10));
    await pumpStartup(tester);
    await tester.pump(const Duration(milliseconds: 20));
    fake.cameraCallbacks.single?.call(_cameraInfo(41));
    await tester.pump();

    expect(find.text('摄像头启动超时，请检查设备后重试。'), findsWidgets);
    expect(find.byType(Texture), findsNothing);
  });

  testWidgets('retry rejects ready and error callbacks from the old attempt',
      (tester) async {
    final fake = _AttemptEncoderService();
    encoder = fake;

    await mount(tester);
    await pumpStartup(tester);
    fake.errorCallbacks.first?.call('第一次失败');
    await tester.pump();
    await tester.tap(find.text('重试'));
    await pumpStartup(tester);
    expect(fake.openCount, 2);

    fake.cameraCallbacks[1]?.call(_cameraInfo(42));
    await tester.pump();
    fake.cameraCallbacks.first?.call(_cameraInfo(41));
    fake.errorCallbacks.first?.call('旧错误');
    await tester.pump();

    final texture = tester.widget<Texture>(find.byType(Texture));
    expect(texture.textureId, 42);
    expect(find.textContaining('旧错误'), findsNothing);
  });
}

CameraInfo _cameraInfo(int textureId) => CameraInfo(
      textureId: textureId,
      previewWidth: 368,
      previewHeight: 368,
      sensorOrientation: 0,
      facingFront: false,
    );

class _AttemptEncoderService extends EncoderService {
  int openCount = 0;
  final List<void Function(CameraInfo info)?> cameraCallbacks = [];
  final List<void Function(String message)?> errorCallbacks = [];

  @override
  void listen() {}

  @override
  Future<void> restartCameraSession() async {}

  @override
  Future<void> openCamera(
    EncoderConfig config, {
    bool facingFront = false,
  }) async {
    openCount++;
    cameraCallbacks.add(onCamera);
    errorCallbacks.add(onError);
  }

  @override
  Future<void> closeCamera() async {}

  @override
  Future<void> dispose() async {}
}
