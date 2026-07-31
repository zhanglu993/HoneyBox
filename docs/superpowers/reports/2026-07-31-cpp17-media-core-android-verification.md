# C++17 媒体核心第一版验收报告

日期：2026-07-31

分支：`codex/cpp17-media-core-android`

代码验收提交：`c54e027560783180aca6c1813ee9f3cb17fa32cf`

## 结论

第一版迁移达到既定的代码和构建目标：

- 建立独立于 Flutter、Kotlin 和操作系统 UI 的 C++17 `honey_media_core`；
- 公开边界统一为 C99 头文件及 `hmc_` 前缀 ABI；
- Cinepak、MSV1 和 AVI 核心生产路径已迁移到 C++；
- Android 通过 JNI 使用核心，并能生成包含三种 ABI 原生库的 Debug/Release APK；
- Windows 使用 MSVC 对同一原生核心执行 Debug/Release 一致性验收。

Windows 验收只覆盖独立媒体核心，不表示 Flutter Windows runner 已增加视频转换 UI、
源视频解码、摄像头或设备传输功能。

## Windows 原生核心

命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media-core-windows.ps1
```

环境与结果：

- Visual Studio 2022 x64，Windows SDK 10.0.26100.0；
- Debug：`honey_media_core`、C99 consumer、测试程序编译成功，CTest 1/1 通过；
- Release：`honey_media_core`、C99 consumer、测试程序编译成功，CTest 1/1 通过；
- 覆盖 ABI、Cinepak、MSV1、AVI、畸形输入语料和失败原子性。

## Android

工具链：

- Temurin JDK 17.0.19；
- Flutter 3.44.4 / Dart 3.12.2；
- 本地 Android SDK 和 PUB_CACHE。

### Gradle 与单元测试

```powershell
.\scripts\run-android-gradle.ps1 :app:testDebugUnitTest `
  :app:assembleDebugAndroidTest `
  -Ptarget-platform=android-arm --offline --no-daemon --console=plain
```

结果：退出码 0，`BUILD SUCCESSFUL`，4 个 suite、18 项测试全部通过：

- `CameraMsv1State`：4；
- `CameraSoftwareConfigPolicy`：4；
- `CameraSoftwareSessionGate`：6；
- `MediaReferenceFixtures`：4。

`assembleDebugAndroidTest` 编译成功。测试覆盖关键帧请求、软件编码会话隔离、
停止/重启边界、收尾阶段配置策略，以及旧 Kotlin 固定样本与 C++ 输出的一致性。

### Flutter

```powershell
flutter test --no-pub
```

结果：67 项全部通过。

### APK

```powershell
flutter build apk --debug --no-pub
flutter build apk --release --no-pub
```

结果：

| 构建 | 大小 | SHA-256 |
| --- | ---: | --- |
| `app-debug.apk` | 185,471,379 bytes | `E91C76F2D6C630DDFDF4037BEE67313CF980049620DA30B2AF588EDAD573F8DC` |
| `app-release.apk` | 64,576,152 bytes | `C7C16C24665AF0670C522E5170F57353380046DD8437774FA9E5E1CB505D6E45` |

两份 APK 均包含：

- `arm64-v8a/libhoney_media_jni.so`；
- `armeabi-v7a/libhoney_media_jni.so`；
- `x86_64/libhoney_media_jni.so`。

DEX 检查结果：

- Debug：10 个 DEX；
- Release：1 个 DEX；
- 旧生产 Kotlin Cinepak/MSV1/AVI codec descriptor：0；
- test-only legacy reference descriptor：0。

这说明测试参考实现没有进入 APK，生产软件编解码路径不再携带旧 Kotlin codec 类。

## 尚未完成的运行时验收

`adb devices -l` 没有发现 Android 设备或模拟器，因此本轮没有执行 instrumentation
和真实相机运行时测试。下列项目必须在后续硬件验收中单独确认：

- 相机 MSV1 录制、编码预览、停止后立即重启；
- Cinepak/MSV1 文件在真实 eBadge 上的播放；
- 丢包后的关键帧重同步；
- 长时间录制、取消、内存和温度表现；
- Android 源视频解码到 C++ 编码的端到端视觉一致性。

构建中的 Gradle、AGP 和 Kotlin 后续版本支持提示为非阻断警告，不影响本次结果，
但应在未来工具链升级任务中处理。
