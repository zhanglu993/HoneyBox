# iOS 开发

## 环境

- 使用与 CI 一致的 Flutter 3.47.0（包含 Dart 3.13.0）。
- 安装完整 Xcode，完成首次启动配置，并在 Xcode Settings 中安装 iOS 模拟器运行时。
- 安装 CocoaPods；当前 `open_filex` 尚未支持 Swift Package Manager，因此仍需 CocoaPods。其余支持的插件由 Flutter 的 Swift Package Manager 集成处理。
- 使用 `flutter doctor -v` 确认 Xcode 和 CocoaPods 检查通过。

本次在 Apple Silicon Mac、Xcode 27.1、CocoaPods 1.17.0 和 iOS 27.1 模拟器上进行基础构建验证。部署版本下限是 iOS 15.0。

## 运行

在仓库根目录执行：

```sh
flutter pub get
flutter devices
flutter run -d <ios-device-id>
```

只构建模拟器调试包：

```sh
flutter build ios --simulator --debug
```

从 Xcode 调试时打开 `ios/Runner.xcworkspace`，先执行一次 Flutter 构建以生成插件及本机配置。`Pods/`、Flutter 临时文件和开发者个人设置不提交；`Podfile.lock` 和 SwiftPM 的 `Package.resolved` 保留用于固定原生依赖。

## 真机

### 无线调试与热重载

本机 Flutter 3.47.0 已应用 `tool/flutter-3.47.0-ios-wireless.patch`。该补丁让 CoreDevice 启动发现逻辑使用指定的 VM 服务端口，避免用设备显示名称匹配 Bonjour 主机名。此次设备显示名称为中文，而 Bonjour 主机名为拉丁字母，原来的名称匹配会失败。仅授权本地网络不能解决这种匹配失败。

启动命令（先确认 `flutter` 指向项目使用的 SDK）：

```sh
sh tool/run-ios-wireless.sh -d <ios-device-id>
```

连接成功后，终端会显示 Dart VM Service 和 DevTools 地址；按 `r` 热重载，按 `R` 热重启，Dart 日志会直接输出到此终端。脚本只为当前进程清除 HTTP 代理环境变量，系统代理不变。端口 54321 只在开发调试时使用，保留 Flutter 的认证机制。

在其他 Mac 上使用同一版本 SDK 时，先应用补丁并重新生成工具缓存：

```sh
# 将 /path/to/flutter 替换成 Flutter 3.47.0 SDK 根目录。
git -C /path/to/flutter apply "$PWD/tool/flutter-3.47.0-ios-wireless.patch"
rm -f /path/to/flutter/bin/cache/flutter_tools.snapshot
flutter --version
```

撤销补丁使用 `git -C /path/to/flutter apply -R` 加同一个补丁路径，然后重新生成工具缓存。升级 Flutter 时需先检查该问题是否已修复，不能直接将此补丁应用到其他版本。

### 签名与设备授权

Bundle ID 为 `com.honeygui.honeybox`。在 Xcode 的 Runner → Signing & Capabilities 中选择自己的 Team；个人签名设置无需共享。连接 iPhone、信任此电脑并按系统提示开启开发者模式后，用 `flutter run` 运行。

`Info.plist` 包含蓝牙、相机、照片图库和本地网络的用途说明。仅在相关功能调用时由系统请求授权。蓝牙由 `flutter_blue_plus` 调用 CoreBluetooth；iOS 不使用 Android 的蓝牙/定位授权流程，设备标识通常是系统分配的 UUID，不应当作 MAC 地址。

## 本阶段范围与后续验收

当前基础工程用于验证应用构建及启动，不代表现有 Android 功能全部可用。应用图标仍为 Flutter 模板图标，正式分发前需替换。

- BLE 扫描、连接、服务发现、通知订阅、传输及断连恢复必须用真实 iPhone 和目标设备验收；模拟器不能作为 BLE 通信证据。
- 视频转换、视频播放、相机编码、热点配网、地图/导航捕获、自定义通知监听等原生通道尚未实现 iOS 对应端。相关页面仍可能提示不支持或产生插件缺失错误，需要后续逐项适配。
- iOS 的更新入口只提示通过原安装渠道更新，不进入 APK 下载/安装流程。
- 本地网络传输、相册选择、相机权限拒绝后的恢复，以及 iOS 15 设备兼容性仍需真机验证。
- 后台 BLE 尚未声明为支持能力，不启用蓝牙后台模式。

### 真机验证记录（2026-10-29）

使用 iPhone 11 Pro（iOS 27.0.1）和 V101 手表，通过广播厂商数据匹配目标，在临时 Release 验证程序中确认：BLE 扫描、连接、GATT 服务发现、读取标准电量特征、订阅 JW FF03、发送功能列表及工厂开关只读请求并收到回复。未执行首次绑定和设备设置写入。iOS 设备标识不能按 Android MAC 地址直接匹配；不同扫描应用显示的 UUID 也可能不同，测试使用了目标设备广播中的地址信息。

对 Watch 扫描页运行 30 秒 Profile 测量，1,780 帧中构建耗时均低于 16.7 ms，1 帧绘制超过 16.7 ms；本次未模拟滚动或连接操作，不能据此排除所有卡顿。Debug 对照未采集到有效帧，且另一次 Debug 诊断程序曾在 Flutter JIT 调试断点附近收到 signal 10；原因及与卡顿的关系尚待确认。

后续从真机崩溃报告确认，正常应用的 Debug 会话也发生了 `EXC_BAD_ACCESS / SIGBUS`。其 LLDB 输出与 [Flutter iOS 27 调试问题 #190307](https://github.com/flutter/flutter/issues/190307) 描述的现象高度相似；上游 [修复 #191434](https://github.com/flutter/flutter/pull/191434) 采用手动继续断点。独立 Flutter 3.47.8 SDK 对照期间，V101 的 BLE 与 JW 只读测试和两次热重启成功，未复现崩溃；这不能证明长期稳定或卡顿已解决。该独立 SDK 仅为本次测试临时修补无线发现端口，测试后已还原；仓库 CI 仍固定 3.47.0。

同机 Flutter 3.47.8 Debug 扫描加自动滚动采样 30 秒，1,140 帧中 77 帧构建耗时超过 16.7 ms，构建 P95 为 18.865 ms、最大 728.283 ms；同期绘制无帧超过 16.7 ms。Profile 对照仅采到 16 帧，样本不足，不能作为对比结论。继续排查需控制前台状态并采集滚动期间的 CPU/帧事件。

V101 宣告支持抬腕和勿扰功能，两项只读查询的回复均通过协议解析；设备宣告支持语言，读取返回原始值 `0x41`，不在当前认可的 `0..2` 枚举内。应用保持原始值并阻止不安全的语言写入，不应在没有协议证据时猜测其含义。

扫描处理改为逐条交付广播，避免每次收到设备更新时重新遍历整个累计列表。回归测试覆盖了不同设备及同一设备后续广播；改动后再次使用真实 V101 验证 HoneyBox BLE 连接、JW 通知订阅、功能列表和工厂开关只读请求，均成功。仍需在用户实际操作下继续评估 Debug 模式卡顿。

验证命令：

```sh
flutter analyze
flutter test
```
