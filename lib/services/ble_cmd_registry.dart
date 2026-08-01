/// BLE L2 命令中心表 —— 全局唯一命名空间。
///
/// 每个 CMD 值在整个协议里全局唯一(即使物理上跑在不同 GATT 特征上,
/// 也不复用)。子命令 key 只在其 CMD 内部唯一。
///
/// 通道映射:
/// - command:  FFC1/FFC2(带 L1 封装,CRC + ACK + seq)
/// - stream:   FFC4/FFC5(裸 L2,BLE LL ARQ 兜底)
///
/// 本表仅涵盖 CMD 字节及其子命令 key。载荷语义(结果码、错误码、状态码、
/// flag 位、编码 ID、L1 控制位等)仍保留在各 protocol 文件里。
///
/// 使用方式:
/// ```dart
/// frame[0] = BleCmd.wifiProv;
/// frame[2] = BleCmdWifiProvKey.configSet;
/// switch (key) {
///   case BleCmdWifiProvKey.configAck: ...  // OK — static const
/// }
/// ```
library;

/// GATT 特征通道——每个 CMD 走的物理路径。
enum BleCmdChannel { command, stream }

/// 顶层 CMD 字节表。
///
/// key 表用独立的 `BleCmdXxxKey` 类承载(见文件下方),而非嵌套在 `BleCmd`
/// 里 —— 这样 `case BleCmdXxxKey.foo:` 是合法的 const 表达式,能直接用于
/// switch 分支;若做成 `BleCmd.xxxKey.foo`(实例字段/类型别名转发),Dart
/// 的 const 分析器不认这条访问链。
class BleCmd {
  BleCmd._();

  // ── CMD 字节 ────────────────────────────────────────────────────────
  static const int watchTime = 0x02; // command
  static const int watchBind = 0x03; // command
  static const int watchNotification = 0x04; // command
  static const int watchHealth = 0x05; // command
  static const int wifiProv = 0x0D; // command
  static const int stream = 0x0E; // stream (!!)
  static const int remoteControl = 0x0F; // command
  static const int fileTransfer = 0x10; // command

  /// 该 CMD 跑在哪条 GATT 特征上。除 [stream] 外全部走命令通道。
  static BleCmdChannel channelOf(int cmd) => switch (cmd) {
        stream => BleCmdChannel.stream,
        _ => BleCmdChannel.command,
      };
}

/// Watch time sync (CMD 0x02) sub-command keys.
abstract class BleCmdWatchTimeKey {
  static const int setTime = 0x01; // App → Dev
}

/// Watch bind (CMD 0x03) sub-command keys.
abstract class BleCmdWatchBindKey {
  static const int bindRequest = 0x01; // App → Dev
  static const int bindResponse = 0x02; // Dev → App
}

/// Watch notification (CMD 0x05) sub-command keys.
abstract class BleCmdWatchNotificationKey {
  static const int pushNotification = 0x01; // App → Dev
  // 0x02 (app filter list) / 0x03 (master enable) 已在协议 spec 保留但未实现 —
  // 尚无 builder,故本表也不列。
}

/// Watch sport / health data (CMD 0x05) sub-command keys.
abstract class BleCmdWatchHealthKey {
  static const int requestData = 0x01; // App -> Dev
  static const int sportData = 0x02; // Dev -> App
  static const int sleepData = 0x03; // Dev -> App
  static const int more = 0x04; // Dev -> App
  static const int sleepSettings = 0x05; // Dev -> App
  static const int realtime = 0x06; // App -> Dev
  static const int syncStart = 0x07; // Dev -> App
  static const int syncEnd = 0x08; // Dev -> App
  static const int todaySport = 0x09;
  static const int latestSport = 0x0A;
  static const int calibrate = 0x0B;
  static const int calibrateResponse = 0x0C;
  static const int heartRateData = 0x0D; // Dev -> App
}

/// WiFi provisioning (CMD 0x0D) sub-command keys.
abstract class BleCmdWifiProvKey {
  static const int configSet = 0x01; // App → Dev
  static const int configAck = 0x02; // Dev → App
  static const int statusReq = 0x03; // App → Dev
  static const int status = 0x04; // Dev → App
}

/// Video streaming (CMD 0x0E) sub-command keys — runs on FFC4/FFC5 stream service.
abstract class BleCmdStreamKey {
  static const int open = 0x01; // App → Dev
  static const int ack = 0x02; // Dev → App
  static const int frame = 0x03; // App → Dev (consumes 1 credit)
  static const int close = 0x04; // App → Dev
  static const int credit = 0x05; // Dev → App
  static const int report = 0x06; // Dev → App
}

/// File transfer (CMD 0x10) sub-command keys.
abstract class BleCmdFileTransferKey {
  static const int beginReq = 0x01; // App → Dev
  static const int beginRsp = 0x02; // Dev → App
  static const int data = 0x03; // App → Dev
  static const int endReq = 0x05; // App → Dev
  static const int endRsp = 0x06; // Dev → App
  static const int abort = 0x07; // 双向
}

/// Remote control (CMD 0x0F) sub-command keys.
///
/// 见 `docs/superpowers/specs/2026-07-30-remote-control-protocol-design.md`。
/// 全部 key 一次冻结,即使 P0 只实现 capture / setZoom / stateReport / ctrlResult /
/// lastShotReady 五个 —— 冻结的目的是让协议字节层稳定,后续加实现不用改中心表。
abstract class BleCmdRemoteControlKey {
  // Control 请求(0x01–0x0F,两端都能发,但 app 本地变化不发这些)
  static const int capture = 0x01;
  static const int recordStart = 0x02;
  static const int recordStop = 0x03;
  static const int setZoom = 0x04;
  static const int focusPoint = 0x05;
  static const int setEv = 0x06;
  static const int setFlash = 0x07;
  static const int setTimer = 0x08;
  static const int setMode = 0x09;
  static const int flipCamera = 0x0A;

  // State 通知(0x10–0x1F,只由 app 发)
  static const int stateReport = 0x10;
  static const int ctrlResult = 0x11;
  static const int lastShotReady = 0x12;

  // Preview 拉取(0x20–0x2F,P0 一律 UNSUPPORTED)
  static const int previewReq = 0x20;
  static const int previewAck = 0x21;
}
