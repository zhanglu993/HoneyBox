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
