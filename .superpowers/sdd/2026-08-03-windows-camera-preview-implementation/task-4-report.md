# Task 4：Windows Texture 与 Encoder Channel 实现报告

## 范围

- 实现 `CameraTextureController`、`EncoderChannel` 与 `EncoderEventSender`。
- 保持 Android `openCamera`/`closeCamera` 的立即 method success、异步 ready/error event 语义；缺少尺寸参数时沿用 `640x480@15` 默认值，显式非正数或错误类型返回 `invalid_argument`。
- ready payload 固定包含 Android 兼容的 10 个字段；Windows 当前仅默认摄像头，故 `sensorOrientation=0`、`facingFront=false`、EV 为 0、`focusSupported=false`。
- 未实现 Task 5 插件注册、Dart UI、still image、编码、传输、控制或设备选择；未修改 generated registrant/generated CMake。

## RED

1. Texture RED：
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -Configuration Debug -TestRegex camera_texture_`
   失败为 MSVC `C1083`，缺少 `honey_camera_windows/encoder_channel.h`。
2. Channel RED：
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-camera-windows-preview.ps1 -Configuration Debug -TestRegex encoder_channel_`
   Flutter wrapper 测试 include seam 建立后，失败为 MSVC `C2039`，`hcw::EncoderChannel` 尚不存在。

## GREEN 与回归

- Focused Debug/Release：`camera_texture_controller` 与 `encoder_channel_contract` 各配置 2/2 CTest 通过。
- 完整 camera 回归：`-TestRegex "camera_|encoder_channel_"`，Debug 8/8、Release 8/8 通过。
- media adapter：在同一专用 CMake build directory 中按配置完整、非并行构建后，Debug 32/32、Release 32/32 CTest 通过。
- 无 regex 的 camera wrapper 会只构建 camera test target、却枚举 media 子目录测试；Debug 曾因旧产物存在而 40/40，Release 的 30 个 media 测试因 executable 未构建而 Not Run。该结果不计为通过，未越过 Task 4 修改 Task 1 脚本。
- media wrapper 的一次 `--parallel` 构建还触发 MSBuild `MSB6001`（环境同时含 `PATH`/`Path`）并遗留 node-reuse 进程；非并行完整构建和 CTest 给出了有效回归证据。

## 自审

- `RegisterPixelBufferTexture`、`MarkFrameAvailable`、ready/error callback、`UnregisterTexture` 均只在 `PlatformDispatcher` 回调中执行。
- 最新 BGRA 只保留一个 `shared_ptr<const vector<uint8_t>>`；provider 返回 snapshot owner，尺寸和 byte count 在发布前检查，Flutter 读取期间无悬空指针。
- controller generation 在 open/close/destructor 变化；所有 queued register/mark/ready/error 回调执行前重检，旧代回调被抑制；reopen 先排队解绑旧 texture，再注册新 texture。
- `Close` 与析构幂等；解绑失败保留 pending 记录供后续 close 重试；析构后 queued unregister 仍可完成，但其它回调受 alive/generation 门禁。
- channel generation、alive、terminal 三重门禁保证单一终态 error event；method result 每条路径只完成一次。
- `windows_media_plugin.h` 最终未修改：Task 4 的类型契约由新 header 自含，实际 MethodChannel/EventChannel 注册与 sink 安装/取消保留给 Task 5。

## 提交

- 实现提交：`2bb7c58`（`feat: 打通Windows摄像头纹理与通道`）

## FIX_REQUIRED 跟进：纹理解绑所有权

### 严格 RED

- 新增析构与回滚测试后，Debug `camera_texture_` 稳定失败：已注册纹理在 controller 析构后 `unregister_attempts=0`；ready 回调内销毁 controller 同样未解绑。
- stale registration 与首次 `MarkFrameAvailable` 失败时，第一次 `UnregisterTexture=false` 后 ID 丢失；后续 `Close()` 的 attempts 仍停在 1，期望的第 2 次重试未发生。

### 修复与有界语义

- 所有已注册但不再 active 的 texture ID 先进入去重的 pending ownership；唯一底层 `UnregisterTexture` 调用只在平台线程完成函数中执行，返回 true 后才移除 ID。
- dispatcher 接受的 cleanup task 强持有 `State`，所以 controller 析构或 ready callback 内销毁 controller 后仍能完成已排队解绑。task 不捕获 controller/raw `this`、不自我重排；`State` 也不持有 task，因此不存在永久引用环。
- `UnregisterTexture=false` 只将 pending 的 `queued` 复位。每次 `ScheduleUnregisters` 记录本轮 attempted ID，即使 dispatcher 同步执行且 registry 长期返回 false，每个 ID 每轮也仅尝试一次；后续显式 `Close()` 才触发下一轮重试。
- dispatcher 拒绝 Post 时，pending ownership 保留且 `Close()` 返回失败；controller 存活期间的下一次 `Close()` 可重试。
- 剩余 teardown 边界：若析构时 dispatcher 直接拒绝 cleanup task，或析构后唯一 cleanup task 执行但 registry 持续返回 false，则已没有 controller 可再次触发重试。本实现保持有界且不在错误线程强行解绑，也不无限自调度；最终资源回收依赖 Flutter engine/registry teardown。

### 跟进验证

- Focused：`camera_texture_` Debug 1/1、Release 1/1。
- Camera + channel：`camera_|encoder_channel_` Debug 8/8、Release 8/8。
- Media adapter：去重构建进程的 `PATH`/`Path` 后非并行构建，Debug 32/32、Release 32/32。
- 新增覆盖：已注册后析构、ready callback 内销毁、stale registration 回滚失败重试、首次 mark 失败回滚重试、dispatcher 拒绝后重试、同步 dispatcher 下长期 false 单轮不自旋。

### 跟进提交

- 评审修复：本提交（中文 commit：`fix: 保证摄像头纹理可靠解绑`）。
