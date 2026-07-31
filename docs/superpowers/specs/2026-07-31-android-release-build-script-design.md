# Android Release 编译脚本设计

## 目标

在 `tool/build-android-release.ps1` 提供一个可直接执行的 PowerShell 脚本，用当前仓库旁已安装的 Flutter、JDK 17 和 Android SDK 构建 HoneyBox Release APK。脚本必须适配当前 Windows 未开启开发者模式、用户目录包含中文字符的环境，并且不修改任何受 Git 跟踪的项目文件。

## 调用方式

从仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\build-android-release.ps1
```

脚本不接收参数，避免同一仓库出现多套未经验证的构建组合。

## 环境配置

脚本根据自身位置确定仓库根目录，并使用仓库同级目录 `F:\sourcecode\8773EWE\.codex-build-tools` 中的工具链。执行前验证以下文件或目录存在：

- Flutter：`.codex-build-tools/flutter/bin/flutter.bat`
- JDK：`.codex-build-tools/jdk17`
- Android SDK：`.codex-build-tools/android-sdk`

脚本为当前进程设置 `JAVA_HOME`、`ANDROID_HOME`、`ANDROID_SDK_ROOT`、`FLUTTER_ROOT` 和 `PATH`。`PUB_CACHE` 固定为 `.codex-build-tools/pub-cache` 的纯英文路径，避免 `jni` 的 CMake/Ninja 任务在中文用户名路径下发生编码错误。依赖和 Flutter 资源使用项目当前采用的国内镜像。

## 构建流程

1. 验证脚本正在 Flutter 仓库根目录中运行，并检查工具链完整性。
2. 执行 `flutter pub get --enforce-lockfile`，确保严格使用仓库提交的 `pubspec.lock`。
3. 若 `pub get` 成功，继续构建；若它在输出 `Got dependencies!` 后仅因 Windows symlink 支持返回非零，则视为依赖准备完成并进入兼容路径；其他错误立即终止。
4. 如果存在被 Git 忽略的旧 `GeneratedPluginRegistrant.java`，删除该可再生文件，避免旧插件包名进入 Java 编译。若该文件被 Git 跟踪，则脚本拒绝删除并终止。
5. 执行 `flutter build apk --release --no-pub`。依赖已在前一步准备完成，`--no-pub` 可避免再次触发 Windows 桌面插件 symlink 检查。
6. 验证 `build/app/outputs/apk/release/HoneyBox-release.apk` 存在且大小大于零。
7. 输出 APK 的绝对路径、字节数、修改时间和 SHA-256。

## 错误处理

脚本对缺失工具链、依赖下载失败、锁文件不满足、非 symlink 类型的 `pub get` 错误、受跟踪的旧注册文件、Flutter 构建失败和 APK 缺失分别返回非零退出码。错误信息使用中文，并包含用户下一步可处理的具体路径或命令。

脚本只接受同时包含 `Got dependencies!` 和 `Building with plugins requires symlink support` 的已知兼容场景，不会把网络错误或依赖解析错误误判为成功。

## 验证

实现后执行以下验证：

1. 使用 PowerShell Parser 检查脚本语法。
2. 在当前工作区实际运行脚本，确认退出码为 0。
3. 检查 APK 包名为 `com.honeygui.honeybox`、版本为当前 `pubspec.yaml` 中的版本，并通过 APK v2 签名验证。
4. 检查 `git status --short`，确认除新增脚本和设计相关文件外没有意外的受跟踪改动。

验证只证明本机 Release APK 成功生成和签名结构有效，不代表已在 Android 真机上安装或完成功能回归。
