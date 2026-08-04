# Task 7 Windows 预览颜色修复报告

## 问题与根因

Flutter Windows PixelBufferTexture 按 RGBA 解释字节。原实现却把：

- Media Foundation 的 BGRA 解码成 RGBA、完成变换后，又转回 BGRA；
- 视频源已经提供的 RgbaFrame 再转成 BGRA；
- 公共 PixelBufferView、相机帧和稳定缓冲仍命名为 BGRA。

因此红、蓝通道在最终纹理中被交换；相机 BGRA 转换还把 alpha 强制写成 255。

## TDD 证据

RED：

- Debug 测试目标成功编译。
- 命令：ctest --test-dir build/media-windows-adapter-msvc-x64 -C Debug --output-on-failure --no-tests=error -R video_player_state
- 结果：exit 8。
- 失败断言：video_player_state_test.cpp:353 期望最终 PixelBuffer 为 RGBA {10,20,30,255,40,50,60,255}，旧实现仍发布 BGRA。

GREEN：

- 视频 RgbaFrame 只校验并复制，按 RGBA 原样发布。
- MF 输入只做一次 BGRA 到 RGBA，再执行 TransformRgba 并直接发布。
- BgraToRgba 保留源 alpha；删除 RgbaToBgra。
- PixelBufferView::rgba、stable_rgba、CameraFrame::rgba、latest_rgba、allocate_rgba 和 FrameState::rgba 统一表达同一字节契约。
- 新增纯红/纯蓝 MF 输入、视频 RGBA 原样、Camera PixelBuffer 红蓝通道及 Texture registry 稳定/并发快照测试。

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
| Windows Release build | PASS，生成 build/windows/x64/runner/Release/HoneyBox.exe |
| git diff --check | PASS |
| 旧 BGRA 发布字段/转换检索 | 0 处 |

原生命令在只保留一个去重 Path、CMAKE_BUILD_PARALLEL_LEVEL=1 的子进程中执行，以规避宿主同时注入 PATH/Path 导致的 MSBuild MSB6001。Flutter 使用 SDK 的 dart.exe + flutter_tools.snapshot 等价入口并设置 FLUTTER_ALREADY_LOCKED=true。

## 范围边界

- 未修改 Dart、Android、Method/Event channel wire、生命周期或生成文件。
- 构建前确认没有运行中的 HoneyBox.exe；未终止用户进程。
- 未启动 GUI，也未声称完成真实摄像头设备颜色回归。
