import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/watch_notification_protocol.dart';

void main() {
  test('uses the notification command namespace', () {
    final frame = WatchNotificationProtocol.buildNotification(
      appName: 'WeChat',
      title: 'Alice',
      message: 'Hello',
    );

    expect(frame.first, 0x04);
  });
}
