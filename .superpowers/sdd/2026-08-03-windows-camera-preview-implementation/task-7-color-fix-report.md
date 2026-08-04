# Task 7 Windows 预览颜色修复报告

## 问题与根因

Flutter Windows PixelBufferTexture 按 RGBA 解释字节。原实现却把：

- Media Foundation 的 BGRA 解码成 RGBA、完成变换后，又转回 BGRA；
- 视频源已经提供的 RgbaFrame 再转成 BGRA；
- 公共 PixelBufferView、相机帧和稳定缓冲仍命名为 BGRA。

因此红、蓝通道在最终纹理中被交换。另一个独立边界是 MFVideoFormat_RGB32 实际为 X8R8G8B8：第 4 字节是未定义的 X，发布到 Flutter RGBA 前必须归一化为不透明 A=255。

## TDD 证据

RED：

- Debug 测试目标成功编译。
- 命令：ctest --test-dir build/media-windows-adapter-msvc-x64 -C Debug --output-on-failure --no-tests=error -R video_player_state
- 结果：exit 8。
- 失败断言：video_player_state_test.cpp:353 期望最终 PixelBuffer 为 RGBA {10,20,30,255,40,50,60,255}，旧实现仍发布 BGRA。

独立复审 alpha RED：

- 将 MF RGB32 的 X=0/17/23 全部期望为最终 A=255。
- camera_rgba_helpers 失败于直接 BGRA 到 RGBA 输出仍透传 X。
- camera_texture_controller 失败于最终纯红/纯蓝纹理 alpha 仍为 0/17/23。

GREEN：

- 视频 RgbaFrame 只校验并复制，按 RGBA 原样发布。
- MF 输入只做一次 BGRA 到 RGBA，再执行 TransformRgba 并直接发布。
- BgraToRgba 忽略 MF RGB32 的未定义 X 并强制 A=255；删除 RgbaToBgra。
- PixelBufferView::rgba、stable_rgba、CameraFrame::rgba、latest_rgba、allocate_rgba 和 FrameState::rgba 统一表达同一字节契约。
- 新增纯红/纯蓝 MF 输入、X=0/17/23 不透明化、视频真实 RGBA alpha 原样、Camera PixelBuffer 红蓝通道及 Texture registry 稳定/并发快照测试。

focused GREEN：

- media：video_player_state|flutter_texture_registry，2/2 PASS。
- camera：camera_(rgba|texture)，2/2 PASS。

## 全量验证

| 验证项 | 结果 |
| --- | --- |
| Windows media adapter Debug | 32/32 PASS |
| Windows media adapter Release | 32/32 PASS |
| Windows camera aggregate Debug | 42/42 PASS |
| Windows camera aggregate Release | 42/42 PASS |
| Flutter 全量测试 | 149/149 PASS |
| Windows Release build | PASS，生成 build/windows/x64/runner/Release/HoneyBox.exe，SHA-256 9E348EA0650235FB79850CFFC599E8A7B04EAF75B8F0A812D35D0EC954BEB44D |
| git diff --check | PASS |
| 旧 BGRA 发布字段/转换检索 | 0 处 |

独立复审修复后重新执行 Camera Debug/Release aggregate，各 42/42 PASS；其中包含全部 media 测试。由于 media 生产代码未再变化，额外重编并执行 video_player_state 与 flutter_texture_registry focused，2/2 PASS，未重复单独的 media aggregate。Flutter 149/149 与 Windows Release build 也均重新执行。

原生命令在只保留一个去重 Path、CMAKE_BUILD_PARALLEL_LEVEL=1 的子进程中执行，以规避宿主同时注入 PATH/Path 导致的 MSBuild MSB6001。Flutter 使用 SDK 的 dart.exe + flutter_tools.snapshot 等价入口并设置 FLUTTER_ALREADY_LOCKED=true。

## 范围边界

- 未修改 Dart、Android、Method/Event channel wire、生命周期或生成文件。
- 构建前确认没有运行中的 HoneyBox.exe；未终止用户进程。
- 未启动 GUI，也未声称完成真实摄像头设备颜色回归。
