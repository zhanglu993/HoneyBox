# 多设备 BLE 原始数据采集

在 HoneyBox 首页选择 **数据采集**。支持 Android 和 Windows，可同时记录 V101 手环和 Polar H10。配置保存在本机，设备地址不跨系统共享。

## 配置与复用

1. 点击“添加设备”及“扫描设备”，按名称或地址过滤。未命名设备默认显示；“隐藏无名设备”可排除空白名称。信号排序支持强到弱、弱到强，最低信号支持不限或 ≥ -90 / -80 / -70 / -60 / -50 / -40 dBm。未知 RSSI 不参与门槛匹配。
2. 选择设备，等待连接和服务发现。连接后收起扫描结果；再次扫描可以重新选择。已有 Watch / eBadge 连接时先断开，采集模块不接管其他功能的连接。
3. 填写配置名称，选择 Notify / Indicate 特征，或使用快捷配置。服务默认折叠，标题显示已选数量。通道身份包含服务、主服务和特征实例，快捷配置使用实际发现的身份；缺失或不唯一会提示错误。
4. 使用底部固定的“保存配置”或右上角同名按钮。下次打开默认勾选所有已配置设备，可在顶部总览或设备卡片取消不需要的设备，点击“开始选中（N）”批量启动；“全选/全不选”方便切换，全部取消时不能批量开始。选择操作不会停止正在运行的设备，批量开始也不会重复启动已经采集中的设备；仍可使用单台“开始”。可分别停止、修改或删除设备配置。

扫描排序、最低信号、隐藏无名设备自动保存到 `capture_scan_settings.json`，无需另点保存。设备及控制步骤保存在 `capture_profiles.json`，当前版本为 **2**，仍接受版本 1；旧配置的控制步骤默认为空。损坏配置会报告错误并保留原文件。

V101 快捷选择服务 **E0FF**、通知 **FFE1**，不发送 FFE9 命令；固件应启用调试服务和数据输出。重连后重新订阅，适配 V101 ADBG 在 Notify 0→1 时重建调试会话的行为。

## Polar H10

连接广播名称为 `Polar H10 xxxxxxxx` 的胸带后，点击“选择 Polar H10（ECG / ACC / HR-RR）”。默认 ECG 开启、ACC 开启、ACC 25 Hz、±8 g；ACC 可选 25/50/100/200 Hz、±2/4/8 g，ECG/ACC 可分别关闭。参数和开关随设备配置保存。两者均关闭时仅订阅 HR/RR，不发送 PMD 命令，也不要求大 MTU。

快捷配置选择实际发现的三个通道：

- HR：服务 `180d`、通知 `2a37`。
- PMD：服务 `fb005c80-02e7-f387-1cad-8acd2d8df0c8`；控制点 `fb005c81-02e7-f387-1cad-8acd2d8df0c8`（Indicate / Write），数据 `fb005c82-02e7-f387-1cad-8acd2d8df0c8`（Notify）。

所有通道订阅成功后，依次 STOP ECG `03 00`、STOP ACC `03 02`、START ECG `02 00 00 01 82 00 01 01 0E 00`，等待本次启动后的首个 ECG 包（最多 **60 秒**），再 START ACC `02 02 00 01 RATE 00 01 01 10 00 02 01 RANGE 00`。关闭的流不发送 START；仅 ACC 时不等待 ECG。写入均要求 GATT response，并等待控制点响应 `F0 op type status more ...`，按 op/type 匹配，状态 0 和 6 接受，其余明确报错；状态 10 提示 `invalid_mtu`。停止时尽力分别发送两个 STOP，再关闭连接和文件；已经断开的链路无法确认 STOP。

ECG/ACC 要求协商 **ATT MTU ≥ 232**，不足时停止该设备并提示实际 MTU；Android 请求 247，Windows 使用系统协商值。CP 响应与普通通知一起原样记录。ECG 130 Hz / 14 bit；ACC 设置由上述选项决定。以上流程来自 2026-10-26 所提供的 Python/bleak 台架结果，本次 Flutter 实现尚未进行胸带或多设备实机验证。

## 通用控制步骤

每个设备可有可选 `startCommands` 和 `stopCommands` 列表。启动步骤在全部订阅后执行；停止步骤在关闭连接前执行。普通自选通道不自动生成命令；当前界面通过 Polar 快捷配置生成，其他厂商步骤可在停止采集后编辑本机配置 JSON。每步为一种操作：

```json
{"channel":{"service":"abcd","characteristic":"abce","primaryService":null,"instance":0},"hex":"0102","withResponse":true,"polarResponse":false,"timeoutSeconds":10}
```

```json
{"waitChannel":{"service":"abcd","characteristic":"abcf","primaryService":null,"instance":0},"prefix":"00","timeoutSeconds":60}
```

`withResponse` 控制 GATT write response；`polarResponse` 额外校验 Polar CP 响应。等待步骤要求指定通道本连接内、上一条写入开始后收到首包，可用 HEX `prefix` 筛选（空字符串接受任意包）。写入过程中提前到达的数据也会满足等待。等待在停止或掉线时取消，重连后重新计算。写入目标可以是未订阅的 Write 特征；等待通道和 Polar CP 必须已订阅。设备可指定 `minimumMtu`，缺省为 0。

## 重连与文件持久化

每台设备独立连接和排队写入。开始时创建一次记录，连接、服务发现或订阅失败，以及刚连接几秒就掉线，均以 **2、5、10、30 秒（封顶）** 退避重试，直到用户停止；每次成功连接后退避从 2 秒重新开始。已连接但 **60 秒** 没有收到任何通知（以最后一包和本次连接建立时间中较晚者计）时，视为掉线：记录 `disconnected`（原因“超过 60 秒无数据，主动重连”），断开后按同样规则重连。采集页顶部总览超过 15 秒无数据即标黄提示。重连继续使用同一个文件和递增序号，重新发现服务、订阅所有通道、执行全部启动步骤。界面显示“等待重连”、错误原因和重连次数；次数表示重试后成功建立的连接（后续订阅仍可能失败）。一台设备故障不会停止其他设备。参数/CP 状态错误、MTU 不足、磁盘失败或写队列过满会停止该设备；固件改变通道身份后应重新配置。

应用支持目录的 `captures/capture_<唯一标识>/` 包含：

- `device.json`：配置名称、设备 ID、订阅通道、启动/停止步骤、Polar 参数和开始时间。
- `raw.jsonl`：原始通知和附加事件，流式写入，不解包、不拼接。

旧通知行格式保持不变：

```json
{"time":"2026-10-26T00:00:00.000Z","sequence":1,"deviceId":"device-A","service":"e0ff","characteristic":"ffe1","primaryService":null,"instance":0,"hex":"00ff800a"}
```

新增行携带 `event`：`write`（尝试写入，含 HEX、通道和 `withResponse`）、`write_complete`（GATT 写入返回）、`write_error`（含原因）、`disconnected`（含原因和尝试序号）、`reconnected`（连接建立后、重新订阅前，含重连次数）。CP indication 没有 `event`，保持原始通知格式。离线消费者应先过滤带 `event` 的行，避免把写入 HEX 当作传感器数据。所有行共用递增 `sequence`，包数/字节数只统计通知。断连事件的通道字段沿用该配置首个通道，仅用于保留行结构，不表示特定通道断开。

`time` 是主机 UTC 接收时间；写入事件为主机操作时间，既不是设备采样时间，也不是硬件同步证据。每秒在同一写入队列中安排一次文件 flush，停止时排空队列并 flush/close。在磁盘正常、队列可及时处理的条件下，将未刷新的窗口限制在约 1–2 秒；系统掉电、存储故障或写入严重积压仍不能保证绝对丢失上限。积压达到 4096 项会停止该设备并报错。预览固定保留 30 包，界面最多展示 10 包并截断长 HEX，文件保留完整字节，内存不随整夜数据量增长。

停止后可“导出”。Android 用系统保存对话框流式导出 JSONL；Windows 选择目录复制 JSONL 和元数据。“采集记录”可导出旧记录，重启或删除配置不删除记录。Android 单独导出的 JSONL 仍含通道和启动写入信息，转换器可据此恢复 ACC 速率。

## 离线转换（Python 3 标准库）

每次输入一个设备的 `raw.jsonl`。以下命令在仓库根目录执行：

```powershell
python tools/capture/jsonl_to_adbg.py path/to/raw.jsonl path/to/adbg.txt
python tools/capture/jsonl_to_polar.py path/to/raw.jsonl path/to/polar_csv
python -m unittest discover -s tools/capture -p "test_*.py" -v
```

`jsonl_to_adbg.py` 只取 E0FF/FFE1 通知，一包一行输出 **HEXUPPER yyyy:mm:dd:HH:MM:SS.mmm**，时间转换到运行转换器机器的本地时区，供固件 `tools/trace/parse_algo_trace.py` 消费；不拼接分片。需要不同的本地时区时应先设置转换环境的时区。

`jsonl_to_polar.py` 输出：

- `rr.csv`：`host_ns,hr_bpm,contact,rr_ms`。解析 8/16 bit HR、接触状态、跳过 energy expended，并将每个 RR 的 1/1024 秒转换为毫秒。同包多个 RR 分别成行；没有 RR 时保留 HR，`rr_ms` 为空。contact 为 `unsupported` / `not_detected` / `detected`。
- `ecg.csv`：`host_ns,sensor_ns,uv`。PMD 类型 0、帧类型 0，int24 LE 有符号微伏。
- `acc.csv`：`host_ns,sensor_ns,x_mg,y_mg,z_mg`。PMD 类型 2、帧类型 1，int16 LE 有符号 mG。
- `segments.csv`：记录每个流的分段编号和首行（CSV 表头之后从 1 开始）、主机时间及该帧末样本时间。重连、启动/停止命令、传感器时间回退或不递增时开启新段；不跨段插值。

每帧头的 uint64 LE 纳秒时间属于最后一个样本。当前段有前一帧时，用 `(本帧末时间 - 前帧末时间) / 本帧样本数` 向前回填；段首 ECG 回退到 130.08 Hz，ACC 回退到配置速率。ACC 速率优先随原始 START 写入更新，初值读取同目录 `device.json`，否则用 25 Hz；也可用 `--acc-rate 50` 指定初值。若丢帧，跨帧间隔可能包含缺失样本，这种回填只是估计，不能证明连续采样。sensor_ns 保留原设备时间基准，不把断连后的新时间基准强行拼接。每个样本的 host_ns 保持该帧主机接收时间；数值以纳秒表示，精度受原始 Dart 时间戳限制。

不支持的压缩帧（帧类型含 0x80）及截断数据会明确报错，已写出的 CSV 可能是部分结果；原始 JSONL 不变。输出目录中的同名 CSV 会被覆盖。转换按行流式处理，不需要第三方依赖。

## Android 整夜采集及验证边界

采集、连接和重连等待期间通过原生 `FLAG_KEEP_SCREEN_ON` 保持当前 Activity 屏幕唤醒，最后一台停止或退出采集页时释放；不增加插件依赖或 Manifest 权限。保持应用前台、接通电源，并按需手动调低屏幕亮度。屏幕持续亮起会耗电。

这里**没有前台服务，也没有后台 CPU wakelock**。手动锁屏、切到后台、厂商省电策略、进程回收或系统强制停止时，不保证 BLE 和写入持续运行；Keep-screen-on 仅对前台可见窗口有效。Windows 也应关闭系统自动休眠；本模块不修改系统电源计划。返回上一页会先停止所有采集。暂不提供跨平台配置导入或多设备时钟同步。

测试覆盖配置版本兼容、Polar 选择和控制状态、文件连续性、重订阅及启动重放、首包等待取消、周期刷新、多设备隔离和合成包转换。Flutter 单元测试、静态检查与 Python 测试均不代替实机验收。本次不做硬件验证；Windows/Android 的 MTU、长时间并发吞吐、实际掉线恢复、屏幕保持唤醒及系统文件导出仍需在目标设备上验收。

## 上传七牛并分享链接

采集页右上「采集记录」进入记录列表。默认勾选最近一批（与最新记录开始时间相差 2 分钟内的多设备记录），可手动增减。点「上传选中并复制链接」：

- 选中记录打成一个 zip，含 `manifest.json` 和每个设备的 `<设备名>_<MAC>/raw.jsonl`、`device.json`。同一设备有多条记录时目录名再加开始时间。
- 对象路径为 `<前缀>/captures/<最早开始时间>_<设备名_MAC>+..._<随机>.zip`，超过 4 台设备只列前 4 台。
- 上传后自动复制下载链接。每条已上传记录都有明确的“复制链接”按钮，私有空间会重新生成 7 天有效的签名链接，不需要再次上传。勾选的记录全部已上传时，底部主按钮变为“复制选中链接”；同一上传包去重为一个链接，多个包的链接按行复制。混合选择已上传/未上传记录时，上传按钮只上传未上传部分，并同时复制已有链接。
- 只有需要更新采集中快照时，才点击“重新上传选中记录（更新快照）”。复制快照链接对应上次上传的内容，不会自动追加后来采集的数据。已有链接的空间必须与当前七牛配置一致。
- 上传结果写入记录目录的 `upload.json`。

需要先在「七牛云配置」中填写账号、Bucket 和下载域名。拿到链接后可用 `curl -o capture.zip "<链接>"` 下载，再用 `tools/capture/` 下的转换脚本处理。
