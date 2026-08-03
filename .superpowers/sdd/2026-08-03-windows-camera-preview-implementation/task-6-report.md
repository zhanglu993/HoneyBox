# Task 6 Report: Dart 摄像头启动失败终态与重试

## 初始实现

- `EncoderService` 保持 `ebadge/encoder` 与 `ebadge/encoder/events` 默认 wire，支持测试注入，并在重试前取消旧订阅、关闭旧 session、以 listener generation 丢弃旧回调。
- `StreamPage` 对 MissingPlugin、PlatformException、native ready error 和 ready 超时提供有界中文错误与“重试”。
- 初始实现提交：`9392474 fix: 修复Windows摄像头启动卡死`。

## Review RED

- `test/services/encoder_test.dart` 新增 dispose/restart 并发、cancel timeout/error、close failure 用例后，首次编译因 `EncoderService` 尚无 `eventStreamFactory` / `eventCancellationTimeout` 注入点而失败。
- `test/pages/stream/stream_page_camera_test.dart` 新增 3 个 attempt 终止语义用例；首次运行 3/3 失败：错误后 late ready 清除了错误、超时后 late ready 清除了超时、旧 attempt ready 把新 texture 42 覆盖成 41。
- Android 真实回调源码契约首次运行 1/1 失败，首个断言为 `CameraEncoder.kt` 的 `openCamera must begin a new camera generation`。
- Android generation gate 单测首次编译失败：`CameraSessionGenerationTest.kt:11:26 Unresolved reference 'CameraSessionGeneration'`。

## Review GREEN

- `EncoderService` 增加 disposed/operation generation；每个异步边界后重新检查，dispose 期间的 restart 不再复活事件订阅；cancel timeout/error 与 close failure 均保持关闭和监听状态一致。
- `StreamPage` 为每次启动/重试绑定独立 attempt 回调；error/timeout 会把 attempt 标为终态，旧 attempt 的 ready/error 不再影响新 UI。
- 原 `stale open failure` 用例在 10 ms timeout 下重试后先推进 300 ms，过去实际上依赖“超时后 late ready 复活”的漏洞；现已让重试 ready 在 10 ms 终止超时前到达，未放松生产终态语义。
- Android 新增内部 `CameraSessionGeneration`，`closeCamera` 首先失效 token；GL、CameraDevice、CameraCaptureSession、camera ready/error/info 在写全局状态或投递事件前校验 token。Method/Event channel 名称和 camera/parameters/ready/error map 均未改变。
- Dart focused：`flutter_tools.snapshot test --no-pub test/services/encoder_test.dart test/pages/stream/stream_page_camera_test.dart`，15 passed。
- Flutter full：`flutter_tools.snapshot test --no-pub`，147 passed。
- Android focused：离线 Gradle `:app:testDebugUnitTest --tests 'com.honeygui.honeybox.CameraSessionGeneration*' -x :app:compileFlutterBuildDebug`，4 passed（gate 3、真实回调源码契约 1），failures/errors=0，`BUILD SUCCESSFUL`。
- 第一次不跳过 Flutter 前置任务的 Android 命令在 123 秒工具超时，只输出既有版本弃用警告且未进入测试结果；随后仅跳过已独立验证的 `compileFlutterBuildDebug`，Android Kotlin 编译与聚焦单测成功。
- Windows Debug：`flutter_tools.snapshot build windows --debug --no-pub`，成功生成 `build\windows\x64\runner\Debug\HoneyBox.exe`；未修改 Windows 原生/Task 5 文件。
- `git diff --check` 与 staged diff check 均通过。

## 独立终审修复

### RED

- Dart 新增“dispose 的事件订阅 cancel 永不完成”与“cancel 超时后 native close 抛异常”两个确定性用例；修复前两项都在 100 ms 外层保护处失败：`TimeoutException: Future not completed`，证明 `dispose()` 永远到不了 `closeCamera()`。
- Android 新增可在本地 JVM 运行的 `CameraSessionCallbackGateTest`；修复前 `:app:compileDebugUnitTestKotlin` 失败：`CameraSessionCallbackGateTest.kt:10:29 Unresolved reference 'CameraSessionCallbackGate'`。
- 原 `CameraSessionGenerationContractTest` 的宽泛全文件 `contains` / DOTALL 检查被替换；新契约按 `openCamera`、GL lambda、CameraDevice callbacks、CaptureSession callback、ready/error emitter 的具体函数块和副作用顺序检查。

### GREEN

- `EncoderService.dispose()` 对 subscription cancel 复用 `_eventCancellationTimeout`；cancel 永挂或报错后仍继续 native close，native close 报错也被吸收，Dart focused 8/8 passed。
- Android 新增纯 Kotlin `CameraSessionCallbackGate`，`CameraEncoder` 在 GL surface、CameraDevice opened、CaptureSession configured、ready/error 主线程投递的真实副作用位置调用它；stale device/session 分别执行 close，不写全局状态或发事件。
- Android focused：`CameraSessionCallbackGateTest` 5、精确集成契约 2、generation gate 3，共 10/10 passed，failures/errors=0，`BUILD SUCCESSFUL`。
- 精确契约内置 14 个负向 mutation：删除 7 个具体 gate，以及把对应 surface/global write/emit 移到 gate 前 7 个；14 个 mutation 均被契约拒绝，不能再由文件其它位置的无关 gate 蒙混通过。
- Flutter full：149/149 passed。
- Windows Debug：成功生成 `build\windows\x64\runner\Debug\HoneyBox.exe`。
- 最终 `git diff --check` 与 staged diff check 均通过；未修改 wire、Windows 原生/Task 5 文件。

## Commits

- 初始实现：`9392474 fix: 修复Windows摄像头启动卡死`
- Review 修复：`ef00845 fix: 修复摄像头重试旧回调竞争`
- 独立终审修复：`cd1fb97 fix: 完善摄像头会话终审保护`

## 边界

- 本任务未执行 Task 7 真机验证；Android 真机摄像头切换/后台恢复仍需后续设备回归。
