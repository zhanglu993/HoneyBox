# HoneyBox

HoneyBox 是一款基于 Flutter 开发的内部设备调试工具，面向电子胸牌等硬件的连接、内容制作、文件传输和功能验证。项目目前支持 Android 与 Windows，主要通过 BLE 与设备通信；Android 还提供本地热点配网和 WiFi 视频通道。

> 本项目仅用于研发和调试，不作为商业产品发布。

## 仓库说明

- **GitHub（开发仓库）**：[realmcu/HoneyBox](https://github.com/realmcu/HoneyBox)。项目的代码开发、Issue、Pull Request 和版本发布均以 GitHub 为准。
- **Gitee（镜像仓库）**：[realmcu/HoneyBox](https://gitee.com/realmcu/HoneyBox)。Gitee 仅作为镜像仓库，主要用于方便国内用户下载 APK，不作为项目开发和代码贡献入口。

## 主要功能

### 设备连接

- 扫描附近的 BLE 设备，并按设备名称过滤
- 显示设备名称、地址、信号强度和可连接状态
- 建立连接、发现服务并维护连接状态
- 在设备断开时自动返回扫描页面并清理传输状态

### 内容制作与传输

- **图片**：选择图片、裁剪取景、调整尺寸/背景/质量并发送到设备
- **弹幕**：编辑文字、字体、字号、颜色和滚动模式并生成内容
- **视频 / GIF**：转换媒体文件并通过设备协议传输
- **多图轮播**：组合多张图片，配置画面质量、停留时长并生成轮播内容
- **拍照投屏**：采集相机画面，经编码后通过 BLE 或 WiFi 视频通道发送
- **本地缓存**：保存转换后的内容，支持查看、筛选、复用和清理

### 设备与应用管理

- Android 本地热点配网与 WiFi/TCP 视频连接
- 应用内版本检查与 APK 更新流程
- 缓存容量设置和缓存管理
- OTA 页面引导用户使用 Realtek OTA App 完成固件升级

## 当前完成度

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| eBadge | 可用 | BLE 扫描、连接、内容制作与传输已实现 |
| Watch / JW | 已接入 | 设备与健康 UI、历史同步/离线记录、配置及协议控制台；以设备能力为准 |
| 仪表盘 | 预览 | 已保留应用入口，业务功能尚未实现 |
| 芯片配置 | 预留 | 当前为占位页面 |
| OTA 升级 | 外部工具 | 由 Realtek OTA App 执行 |

## 平台支持

| 能力 | Android | Windows |
| --- | :---: | :---: |
| BLE 扫描与连接 | ✓ | ✓ |
| 图片、弹幕、视频和轮播传输 | ✓ | ✓ |
| BLE 拍照投屏 | ✓ | 取决于相机和插件支持 |
| 本地热点配网 | ✓ | — |
| WiFi/TCP 视频通道 | ✓ | — |
| 应用内 APK 更新 | ✓ | — |

Android application ID 和 namespace 均为 `com.honeygui.honeybox`，Dart package 名称为 `honeybox`。由于不再沿用旧应用标识，Android 会将 HoneyBox 识别为一个新的独立应用，不能覆盖安装旧版 eBadge。

## 技术栈

- Flutter / Dart
- Material Design
- Riverpod 状态管理
- `flutter_blue_plus` BLE 通信
- 自定义 L1/L2 文件传输协议
- 图片、视频和流媒体转换处理
- Android 本地热点与 WiFi/TCP 通道
- Windows C++ Runner 与 WinRT BLE 插件

## 项目结构

```text
lib/
├── pages/          页面与业务入口
├── providers/      Riverpod 状态管理
├── services/       BLE、传输协议、媒体转换、缓存和 WiFi 服务
└── theme/          应用主题
test/               Flutter 单元测试和组件测试
tool/               构建辅助脚本
windows/            Windows Runner 与 CMake 配置
android/            Android 平台配置
assets/             图片及示例媒体资源
```

## 开发环境

建议使用项目 `.metadata` 对应的 Flutter stable 版本。开始前先确认环境：

```powershell
flutter doctor -v
flutter pub get
```

### Android 环境

- Flutter SDK
- Android SDK 与 Android Studio
- 已启用开发者选项和 USB 调试的 Android 设备
- 支持 BLE 的真机；部分功能还需要相机和 WiFi

### Windows 环境

- Windows 10 或 Windows 11
- Visual Studio，安装“使用 C++ 的桌面开发”工作负载
- Windows SDK、CMake 和 NuGet
- 支持 BLE 的 Windows 设备

Flutter Windows 插件通常通过 symlink 接入项目。Windows 创建 symlink 需要管理员权限或开发者模式；如果开发环境两者都不可用，可在 `windows/flutter/ephemeral/.plugin_symlinks` 下使用目录 junction 指向 Pub Cache 中的插件目录。junction 只属于本机构建产物，不应提交到 Git。

## 运行项目

查看可用设备：

```powershell
flutter devices
```

运行 Android：

```powershell
flutter run -d <android-device-id>
```

运行 Windows：

```powershell
flutter run -d windows
```

## 构建发布包

### Android APK

```powershell
flutter build apk --release
```

主要产物：

```text
build/app/outputs/apk/release/HoneyBox-release.apk
```

Release 必须使用正式签名，不会回退到 debug 签名。Android 的本机密钥与签名配置写入已忽略的 `android/local.properties`：

```properties
AMAP_DEBUG_KEY=高德控制台中为Debug签名申请的Key
AMAP_RELEASE_KEY=高德控制台中为Release签名申请的Key
RELEASE_STORE_FILE=D:/secure/path/honeybox-release.jks
RELEASE_STORE_PASSWORD=本机真实密码
RELEASE_KEY_ALIAS=honeybox
RELEASE_KEY_PASSWORD=本机真实密码
```

不要把真实 Key、密码或 keystore 提交到 Git；`*.keystore` 和 `*.jks` 已被忽略。高德 Android Key 按 **Key + 最终包名 + 实际签名 SHA1** 校验：

1. 在[高德开放平台控制台](https://console.amap.com/)分别创建/配置 Debug 与 Release 的 Android Key，包名均填写 `com.honeygui.honeybox`。
2. Debug Key 绑定本机 debug 证书 SHA1；本机已知值为 `88:77:8B:76:1C:6E:AE:5A:20:E8:EC:B2:10:63:8A:A6:73:87:28:F4`。Release Key 绑定团队正式 keystore 的实际 SHA1，不能填写 Debug SHA1。
3. 查看各变体签名信息：`cd android; .\gradlew.bat signingReport`。也可运行 `& "$env:JAVA_HOME\bin\keytool.exe" -list -v -keystore D:\secure\honeybox-release.jks -alias honeybox` 获取 Release SHA1。
4. 构建 Debug：`flutter build apk --debug`；构建 Release：`flutter build apk --release`。缺少对应 AMap Key，或 Release 缺少任一签名项时，构建会明确失败。
5. 验证产物签名：`$bt = Get-ChildItem "$env:LOCALAPPDATA\Android\Sdk\build-tools" -Directory | Sort-Object Name -Descending | Select-Object -First 1; & "$($bt.FullName)\apksigner.bat" verify --print-certs build\app\outputs\apk\release\HoneyBox-release.apk`。输出的 SHA-1 必须与高德控制台 Release Key 绑定值一致。

### Windows EXE

普通环境可直接构建：

```powershell
flutter build windows --release
```

在当前无管理员权限、使用 junction 的构建环境中，可避免重新执行 `pub get`：

```powershell
$env:TrackFileAccess = 'false'
$env:_CL_ = '/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS'
$env:PATH = "$env:LOCALAPPDATA\NuGet\CommandLine;$env:PATH"
flutter build windows --release --no-pub
```

主要产物：

```text
build/windows/x64/runner/Release/HoneyBox.exe
```

运行 Windows 程序时，应保留 Release 目录中的 DLL、`data` 等配套文件，不能只复制 EXE。

## GitHub CI

GitHub Actions 工作流位于 `.github/workflows/flutter-ci.yml`，自动执行代码检查、测试、构建和发布：

1. **Pull Request 检查**：向 `master` 或 `main` 提交 Pull Request 时，运行 Dart 格式检查、CI 规则检查、`flutter analyze` 和 `flutter test`。
2. **分支构建**：向 `master`、`main` 或 `develop` 推送非文档、非资源文件改动时，在检查通过后构建 Android Debug APK 和 Windows x64 Release，并将产物保留 7 天。
3. **手动构建**：可在 GitHub Actions 页面手动触发相同的检查及 Android、Windows 构建流程。
4. **版本发布**：推送 `v*` 格式的标签（例如 `v1.2.0`）后，CI 构建 Android Release APK 和 Windows x64 Release，创建 GitHub Release 并上传构建产物。
5. **同步国内镜像**：版本发布成功后，CI 将代码与标签同步到 Gitee。Gitee Release 的 APK **不由 CI 上传**，需在发布后手动上传，步骤见 [docs/release-guide.md](docs/release-guide.md)。Gitee 在此流程中仅承担镜像和国内下载用途。

开发与发布流程以 GitHub CI 的执行结果为准；Gitee 镜像的代码与标签由发布流程自动更新，不接受直接开发提交。

CI 构建 Android 包需要高德 Key 与 release 签名凭据，这些内容不入库，由 GitHub Secrets 在构建前注入。所需 Secret 清单与配置步骤见 [docs/ci_release_signing.md](docs/ci_release_signing.md)。未配置时打标签会导致 release 构建失败。

## Windows BLE 稳定性补丁

`flutter_blue_plus_winrt 0.0.20` 在启动或停止扫描时，可能让同步 WinRT 异常越过 Flutter 原生回调并终止进程。项目通过以下文件在 CMake 构建阶段生成补丁源码，不直接修改 Pub Cache：

- `tool/patch_flutter_blue_plus_winrt.ps1`
- `test/windows/flutter_blue_plus_winrt_patch_test.ps1`
- `windows/CMakeLists.txt`

当插件源码结构变化导致补丁无法安全应用时，CMake 会主动终止构建，而不是静默生成未经保护的程序。

## 测试

运行 Flutter 测试：

```powershell
flutter test
```

运行 Windows 插件补丁回归测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\windows\flutter_blue_plus_winrt_patch_test.ps1
```

提交前建议同时检查 diff 格式：

```powershell
git diff --check
```

## 使用注意事项

- Android BLE 扫描需要蓝牙权限；部分 Android 版本还要求定位服务处于开启状态。
- Windows 不使用 Android 的运行时蓝牙与定位权限流程。
- 首次连接、扫描或开启热点时，请按系统提示授予所需权限。
- BLE 和 WiFi 功能依赖目标设备固件及对应服务正常工作。
- Watch 功能由实际设备协议与能力决定；仪表盘和芯片配置仍为预留入口。
- 请勿提交 `build/`、`windows/flutter/ephemeral/` 或本机插件 junction。

## 许可证与用途

HoneyBox 是内部研发调试工具。项目连接 `flutter_blue_plus` 时声明 `License.nonprofit`，其使用方式以非商业调试场景为前提。如未来用途发生变化，应重新评估第三方依赖许可、Android 签名和发布配置。

## Watch / JW（Realtek 方案）

从 Watch 扫描列表选择设备，完整匹配 JW GATT 服务和特征后进入专用页面；原有 eBadge 与旧 Watch 协议入口保留。提供设备及能力查询、持久身份登录、配置读回、实时心率、历史同步与离线健康数据、运动记录，以及按能力和固件契约开放的协议控制台。

详细使用方法、SDK 接口分层、能力限制及命令行验证方式见 [JW SDK 使用指南](docs/jw-sdk-guide.md)。Android 与 Windows 共用 Dart SDK 和 Flutter 界面；Android 真机 BLE 验收需单独完成，不能用 Windows 模拟界面或 APK 构建替代。

开发入口为 `lib/main.dart`。本地检查使用 `flutter test`、`flutter analyze` 和 `dart format --output=none --set-exit-if-changed lib/ test/`；项目 CI 固定的 Flutter 版本见 `.github/workflows/flutter-ci.yml`。

Windows 命令行工具 `tool/jw_sdk_acceptance.ps1` 直接复用生产扫描、provider、GATT 及 JW SDK。需 PowerShell 7、可用 Flutter Windows 构建环境和实际 BLE 设备。扫描可配置窗口、重试和取消；具体模式及参数见使用指南。新报告写入已忽略的 `output/`，过程记录不随源码发布。
