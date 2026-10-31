import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/capture/capture_store.dart';
import 'package:honeybox/services/capture/reconnect_notification.dart';
import 'package:honeybox/services/capture/capture_session.dart';

void main() {
  test('重连提醒配置按设备保存，默认关闭', () async {
    final dir = await Directory.systemTemp.createTemp('capture_notification');
    addTearDown(() => dir.delete(recursive: true));
    final store = CaptureStore(dir);
    expect(await store.loadReconnectNotifications(), isEmpty);
    await store.saveReconnectNotifications({'A'});
    expect(await CaptureStore(dir).loadReconnectNotifications(), {'A'});
    await store.saveReconnectNotifications({});
    expect(await store.loadReconnectNotifications(), isEmpty);
  });
  test('每次进入重连只提醒一次，关闭开关不会提醒', () {
    final tracker = ReconnectNotificationTracker();
    expect(
        tracker.shouldNotify('A', CapturePhase.starting, enabled: true), false);
    expect(tracker.shouldNotify('A', CapturePhase.reconnecting, enabled: true),
        false);
    expect(tracker.shouldNotify('A', CapturePhase.recording, enabled: true),
        false);
    expect(tracker.shouldNotify('A', CapturePhase.reconnecting, enabled: true),
        true);
    expect(tracker.shouldNotify('A', CapturePhase.reconnecting, enabled: true),
        false);
    expect(tracker.shouldNotify('A', CapturePhase.recording, enabled: true),
        false);
    expect(tracker.shouldNotify('A', CapturePhase.reconnecting, enabled: false),
        false);
    expect(tracker.shouldNotify('A', CapturePhase.reconnecting, enabled: true),
        false);
    expect(tracker.shouldNotify('A', CapturePhase.recording, enabled: true),
        false);
    expect(tracker.shouldNotify('A', CapturePhase.reconnecting, enabled: true),
        true);
  });
}
