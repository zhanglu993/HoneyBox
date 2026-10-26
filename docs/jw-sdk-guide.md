# JW SDK 使用指南

HoneyBox 的 Watch 模块接入 JW 协议设备，提供设备信息、登录与绑定、配置读取与校验写入、实时心率、历史同步、离线健康数据和协议控制台。Realtek 是芯片方案，JW 是这里适配的用户协议；其他 Realtek 设备是否兼容需核对 GATT 和协议。

## 连接与界面

从 Watch 扫描列表选择实际发现的设备。广播信息只用于发现候选设备，连接后根据完整 GATT 服务选择协议。JW 服务为 `000001ff-3c17-d293-8e48-14fe2e4da212`，FF02 用于带响应的写入，FF03 用于通知，传输按协商后的 ATT 容量分片。原有 eBadge 和旧 Watch 协议路由保留。

设备页显示连接、身份和能力状态，健康页展示日/周数据与原始记录，历史页支持同步和离线查看，控制台按设备能力和固件契约开放命令。运动目标由应用本地保存。数据缺失与有效的零值分别处理；不支持的指标和命令会显示不可用状态。

普通查询、配置和历史同步按已连接的 JW 协议、功能位、工厂开关及响应校验开放，不将测试设备的 `T005/H001` 版本作为通用白名单；例如 `T009/H001` 不会仅因版本不同被禁用。配置写入仍需登录、读取原值并校验读回。全设备历史游标重置是独立操作，目前仍限已验证的 `T005/H001` 目标；不兼容时只禁用重置，正常同步和离线查看仍可使用。协议能力允许执行不代表该型号已完成实机验收。

Android 和 Windows 共用 Dart SDK 与 Flutter 界面。真机 BLE 验收需分别在目标平台完成；Windows 模拟测试或 Android APK 构建不能替代 Android 真机通信验证。固件升级和表盘传输不属于本 JW 接入已完成的闭环。

## SDK 分层与接口

- [传输与协议](../lib/services/jw/)负责帧编码、分片、通知重组、请求调度、重试与应答。
- [JwDeviceRepository](../lib/services/jw/jw_device_repository.dart)提供 `state`、`changes`、`initialize`、`login`、`bindFirstTime`、`syncTime`、`queryLanguage`、`setLanguageVerified`、`setHeartRateStreaming` 等设备接口。
- 配置接口 `readConfigurationSnapshot`、`readConfigurationPreflight`、`setConfigurationVerified` 提供读取、能力检查与读回校验。
- 历史接口 `syncHistory`、`cancelHistory`、`historyInventory`、`historyPage`、`resetHistoryCursor` 提供同步控制、持久化查询与游标管理。
- [验证入口](../lib/validation/jw_sdk_acceptance_main.dart)和 [PowerShell 工具](../tool/jw_sdk_acceptance.ps1)用于直接验证 SDK 和真实 BLE 链路。

身份是持久化的 32 字节 ASCII 协议值，其 SHA-256 摘要用于检查本次使用的既有身份，不代表密码学强认证。首次绑定必须显式确认；登录失败或身份存储异常不会自动创建新身份覆盖原绑定。

命令 ACK 表示设备接受了协议请求，不保证物理动作或设置已经生效。提供读回验证的接口会进一步比较结果；读回失败或状态不确定时，应保留该状态供调用方处理。

历史记录先写入本地日志再确认，重传与游标回退通过去重保留已有记录。超时、断连或取消可能留下部分数据，应查看同步结果，不能据此认定同步完成。重置历史游标使后续同步重新读取设备仍保留的历史记录，不会清除设备或本地健康数据，操作需要显式确认。

## 本地检查

在配置好的 Flutter 环境中运行：

```powershell
flutter test
flutter analyze
dart format --output=none --set-exit-if-changed lib/ test/
```

CI 的固定 Flutter 版本见 [.github/workflows/flutter-ci.yml](../.github/workflows/flutter-ci.yml)。协议测试数据保存在 [test/fixtures](../test/fixtures/)，包括 configuration、history、readonly 和 observation 四组输入；历史向量的来源与时间基准见 [向量说明](../test/fixtures/jw_history_vectors_v1.README.md)。

## Windows 真机验证工具

需要 PowerShell 7、可构建 Windows 应用的 Flutter 环境和 BLE 适配器。地址或名称必须来自实际扫描。使用已有本地验收结果中的 `identitySha256`，或对应用支持目录 `jw_identity_v1.json` 中的 `userId` 按 UTF-8 计算 SHA-256；MAC 地址和设备序列号不能替代本机协议身份摘要。每次使用新的输出目录，已有结果不会被覆盖。

```powershell
pwsh -NoProfile -File tool/jw_sdk_acceptance.ps1 `
  -Address '<实际扫描到的地址>' -Mode ReadOnly `
  -ExpectedIdentitySha256 '<已有身份的 SHA-256>' `
  -ScanSeconds 120 -ScanAttempts 3 `
  -OutputDirectory '<新的本地输出目录>'
```

| 模式 | 用途与边界 |
| --- | --- |
| `Phase1` | 基础连接、登录与功能验证，包含时间同步等写操作 |
| `History` | 历史同步、持久化与重启检查，包含协议应答和游标推进 |
| `HistoryReplay` | 显式游标回退与重放检查，要求地址、既有身份摘要和 `-ReferenceCapabilities` |
| `ConfigurationRead` | 配置快照读取 |
| `Configuration` | 配置修改、读回、恢复与重启验证 |
| `ReadOnly` | 既有身份下的只读查询，要求身份摘要，不自动首次绑定 |
| `RemainingObserve` | 能力允许的观察接口验证，要求身份摘要 |
| `RemainingRoutine` | 常规设备命令验证，可能产生设备动作，要求身份摘要 |
| `RemainingLab` | 专用测试设备的实验命令验证，还需显式 `-LabAuthorized` |

扫描默认 120 秒、最多三轮，可通过 `-ScanSeconds`（1–3600）和 `-ScanAttempts`（1–10）调整。`-Flutter` 指定 Flutter 命令路径，`-SkipBuild` 复用已有独立验证程序。历史模式还支持 `-HistoryRounds`、`-HistoryIdleSeconds`、`-HistoryTotalSeconds` 和 `-HistoryMaxQueueMb`。

工具持续报告进度，在本次输出目录创建名为 `cancel` 的文件可请求取消。退出码为 0（通过）、1（失败）、2（取消）；详细结果在该目录的 `results.json` 和分模式记录中。默认输出位于被 Git 忽略的 `output/`，不要将真机日志、构建文件或过程记录加入发布提交。
