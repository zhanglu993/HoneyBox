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

## FIX_REQUIRED 二次跟进：持久化清理租约与显式 teardown

### 严格 RED

- controller 析构后，dispatcher 已接受但随后丢弃 cleanup callback：原实现只由 queued task 持有清理状态，task 被丢弃后没有可重试所有者；RED 先以缺少 `CameraTextureCleanupCoordinator` API 的 `C3083/C2039` 稳定失败。
- controller 析构后 cleanup 执行但首次 `UnregisterTexture=false`：RED 要求 registry provider 继续持有 coordinator，后续显式 `RetryPending()` 成功且底层只解绑一次。
- 同步 `Post`/`UnregisterTexture` 栈内重入 `Shutdown()`：严格 RED 先因 `void Shutdown()` 无法转换为 `Outcome` 的 `C2440` 失败，防止用阻塞等待掩盖同线程自等待。

### 所有权与生命周期

- 引用关系为 `controller -> coordinator`、`registry provider -> coordinator`、`queued DispatchAttempt -> coordinator`；coordinator 仅以受 shutdown 门禁保护的非 owning 指针访问 registry/dispatcher，不反向强持有 registry，因此无强引用环。
- dispatcher 丢弃 callback 时，`DispatchAttempt` 析构只把该 ID 的 `queued` 复位；pending ID 与重试所有权仍由 registry provider 持有的 coordinator 保存。首次 `UnregisterTexture=false` 同样保留 pending，后续显式 `RetryPending()` 才开启下一轮。
- 每个 `RetryPending()` 固定 pending snapshot，同一 ID 每个显式 trigger 最多投递一次；callback 不自重排，registry 长期返回 false 时不会自旋。
- `Shutdown()` 返回 `Outcome` 明确区分 stopped 与 quiesced：重入调用先停止新操作，但返回 `invalid_state`，不允许调用方据此销毁依赖；待外层操作退出后再次调用并返回成功，才表示 in-flight operation 为零且已脱离 registry/dispatcher。
- teardown 顺序为：销毁 controller，等待/取消已接收任务，调用 `Shutdown()` 直至成功，再销毁 dispatcher 与 registry。shutdown 后晚到 callback 只观察 inactive 状态，不再解引用依赖。
- stale registration、首次 mark 失败回滚、generation 门禁、平台线程调用约束与 Android 兼容 payload 均保持不变；未实现 Task 5。

### GREEN 与最终回归

- 首个 GREEN 编译仅暴露 `/WX` 下 `C4458`（局部变量遮蔽状态成员），改名后 `camera_texture_` Debug 1/1 通过；重入 shutdown 用例无阻塞。
- Camera + channel：`camera_|encoder_channel_` Debug 8/8、Release 8/8。
- Media adapter：非并行完整构建后，Debug 32/32、Release 32/32。

### 二次跟进提交

- 本提交：`fix: 持久化摄像头纹理清理所有权`。