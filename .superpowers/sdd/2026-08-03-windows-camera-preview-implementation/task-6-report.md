# Task 6 Report: Dart 摄像头启动失败终态与重试

## RED

- `test/services/encoder_test.dart` 首次运行失败：`EncoderService` 不接受注入的 `method` / `events` 参数。
- `test/pages/stream/stream_page_camera_test.dart` 首次运行失败：`StreamPage` 不接受注入的 `encoder` 参数。

## GREEN

- `EncoderService` 保持 `ebadge/encoder` 与 `ebadge/encoder/events` 默认 wire，支持测试注入，并在重试前取消旧订阅、关闭旧 session、以 listener generation 丢弃旧回调。
- `StreamPage` 对 MissingPlugin、PlatformException、native ready error 和 ready 超时提供有界中文错误与“重试”；retry 使用 camera generation 防止旧 open Future 覆盖新 ready，dispose/lifecycle 会失效 generation 并取消 timer。
- focused：`flutter_tools.snapshot test --no-pub test/services/encoder_test.dart test/pages/stream/stream_page_camera_test.dart`，7 passed。
- full：`flutter_tools.snapshot test --no-pub`，139 passed。
- Windows：`flutter_tools.snapshot build windows --debug --no-pub`，成功生成 `build\\windows\\x64\\runner\\Debug\\HoneyBox.exe`。
- 直接 `flutter.bat test` 曾在约 63 秒内无输出而超时；后续使用同一显式 SDK 的既有 `flutter_tools.snapshot` runner 完成全部验证。

## Commit

- SHA: 9392474
