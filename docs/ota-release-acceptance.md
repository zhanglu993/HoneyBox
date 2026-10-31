# OTA 发布验收记录（2026-10-31，分支 codex/android-unified）

> 范围：Realtek OTA（S200 等数据驱动配置）。固件仓库相关事实均为“固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核”。
> 本记录区分三类证据：**fake/单元测试**、**BLE 模拟器（Linux）**、**真实设备**。模拟成功、编译成功与真机升级成功分别报告，互不替代。

## 1. 平台能力表

图例：✅ 已实现且有对应证据；🟡 已实现但仅有 fake/模拟器证据；⛔ 当前平台不支持（界面明确提示）；❓ 待验证。

| 能力 | Android | Windows | iOS/macOS/Linux |
|---|---|---|---|
| 目标工程是否存在 | ✅ `android/` | 目录存在，OTA 走 `UnsupportedOtaPlatform` | 仓库中无对应工程，未配置 |
| 扫描 | 🟡 既有功能；本批未改 | ❓ | 无 |
| 设备身份 | 🟡 deviceId（平台无关字符串）+ icType；无受信稳定身份映射 | ⛔ | 无 |
| 文件访问 | 🟡 file_picker，测试用临时文件 | ⛔ | 无 |
| 固件解析/预检 | 🟡 SDK 预解析（Android 桥）+ 数据驱动配置；版本/电量仅警告，格式/芯片/兼容/容量未知即阻断 | ⛔ | 无 |
| 传输 | 🟡 Realtek SDK；模拟器上走通完整流程（案例 A）；真机真实固件**未**刷写 | ⛔ | 无 |
| 后台运行 | ❓ 页面切后台不打断会话（widget 测试）；connectedDevice 前台服务/通知**未实现** | ⛔ | 无 |
| 升级后核验 | 🟡 只读核验 OtaPostchecker（icType + 目标版本）；无证实则“待核验”；真机读回未验证 | ⛔ | 无 |
| 诊断 | ✅ 失败分类（保留原始码）、历史记录、用户主动复制的脱敏日志（单元/widget 测试） | ⛔ | 无 |
| 续传 / DFU / 回滚 / 完整重刷恢复 | ❓ 全部“未知”，只给恢复说明，不开放按钮 | ⛔ | 无 |

后续平台（iOS、macOS、Windows、Linux）需按各自 SDK、系统权限和真实设备能力分别排期，本批不宣称支持。

## 2. 本批自动化验证（Mac）

- `flutter analyze --no-pub`：0 error、0 warning、32 info（均为风格类提示；提交 51786a3 之后修复了两个测试里的 unused_import）。
- 完整 `flutter test --no-pub`：1226 通过、2 跳过（提交 51786a3 时）。
- 稳定命令：`flutter test --no-pub test/services/ota test/pages/ota --reporter json`。
- Android arm64 Release **测试包**（`ORG_GRADLE_PROJECT_realtekSdkTestBuild=true`，调试证书，包名隔离）：
  - 构建命令：`flutter build apk --release --target-platform android-arm64 --no-pub`
  - 产物：`output/ota-release-20261031/HoneyBox-ota-test-release-arm64.apk`（git 忽略，不入库）
  - 包名 `com.honeygui.honeybox.realtektest`，versionName 0.8.23，versionCode 17，native-code 仅 arm64-v8a
  - 证书：`CN=Android Debug`，SHA-256 `afadc5693fd38591517a50ac974a0fb8d4386b1fc32dba6cd33a553e4e822f00`（**测试签名，不可作为正式发布**）
  - APK SHA-256：`45bd1a9782eafd4cd3d06062d9a6418019917cfedd78280f9fdab5d15e672be3`
  - 构建源码提交：`51786a343e014f645edd9e2304ab907b59039820`（APK 内未嵌入提交号，此处为外部记录）
  - 未做正式签名的 Release 包（需 `RELEASE_*` 与高德 Key，未配置）。

## 3. 模拟器验证（Linux BLE 模拟器，非真实硬件）

- 案例 A（正常升级）、B（低电量、未充电：警告 + 设备侧拒绝提示）已验证（调试包 69105f6）。
- 案例 C（低电量但充电中：检测到充电、升级完成并读回）**未能验证**：18:30 PDT 后 Linux 蓝牙适配器卡死（错误 133、无扫描结果），需要用户重新插拔/重置适配器；SDK 错误 2070 未诊断。

## 4. 未通过/未验证的发布门槛（逐项）

| 门槛 | 状态 |
|---|---|
| 真机合法包升级并读回身份与版本 | 未验证（无明确授权的目标设备与匹配的低版本固件） |
| 错包 / 损坏 / 低电 / 断连 / 后台 / 重启 / 旧版本 / DFU 残留 真机验证 | 仅 fake/模拟器覆盖其中部分；真机未验证 |
| Kotlin 桥：结构化阶段事件、多镜像进度、镜像编号 | 未实现（需 Gradle 构建与真机） |
| Android connectedDevice 前台服务与通知、协调器脱离 UI | 未实现 |
| FFF1 设备信息特征在真机上的读取 | 未验证 |
| 续传偏移 / DFU / 回滚能力 | 未知（无 SDK 文档或真机证据） |
| 稳定设备身份（受信映射） | 无；目前仅 icType，核验在缺证据时只能“待核验” |
| 非 Android 平台 | 仅有 Windows 目录与 unsupported 适配器；macOS 上无法构建 Windows；iOS/macOS/Linux 工程不存在 |
| 正式签名 Release 包 / 飞书交付 | 未做 |
| OPPO 设备扫描、固件选择、七牛云/采集冒烟 | 本批未执行（专用调试机由另一进程占用，且不触碰无线电） |
