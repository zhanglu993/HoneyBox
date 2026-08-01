import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ble_cmd_registry.dart';
import 'remote_control_protocol.dart';

/// Called when the device asks the app to take a picture. Return the freshly
/// generated shot id (u16, monotonically increasing) once the capture is done,
/// or null to signal failure (session will reply CTRL_RESULT BUSY).
typedef CaptureHandler = Future<int?> Function();

/// Called when the device asks the app to change zoom. Return true if applied,
/// false if the value was rejected (out of range → session replies
/// CTRL_RESULT OUT_OF_RANGE).
typedef ZoomHandler = Future<bool> Function(double zoom);

typedef CommandAvailable = bool Function();
typedef SendCommand = int? Function(Uint8List frame);

/// L2 双向控制会话(CMD 0x0F)。
///
/// 见 `docs/superpowers/specs/2026-07-30-remote-control-protocol-design.md`。
///
/// 生命周期:BLE 连接期间存活。UI 层(相机页)通过 [registerHandlers] 挂上
/// CAPTURE / SET_ZOOM 处理器,通过 [reportCameraReady] / [reportZoom] /
/// [reportCaptureDone] 反向 push STATE_REPORT。
///
/// P0 只处理 CAPTURE (0x01) / SET_ZOOM (0x04);其它子命令一律回
/// CTRL_RESULT UNSUPPORTED。
class RemoteControlSession {
  RemoteControlSession({
    required CommandAvailable commandAvailable,
    required SendCommand sendCommand,
    required Stream<Uint8List> notifications,
  })  : _commandAvailable = commandAvailable,
        _sendCommand = sendCommand {
    _sub = notifications.listen(_onFrame);
  }

  final CommandAvailable _commandAvailable;
  final SendCommand _sendCommand;
  StreamSubscription<Uint8List>? _sub;

  CaptureHandler? _captureHandler;
  ZoomHandler? _zoomHandler;

  // ── Public API ─────────────────────────────────────────────────────────

  /// Register (or replace) the capture / zoom handlers. Passing null clears
  /// that slot. Called from `stream_page.initState` / `dispose`.
  void registerHandlers({
    CaptureHandler? capture,
    ZoomHandler? zoom,
  }) {
    _captureHandler = capture;
    _zoomHandler = zoom;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _captureHandler = null;
    _zoomHandler = null;
  }

  // ── Inbound (device → app) ─────────────────────────────────────────────

  Future<void> _onFrame(Uint8List raw) async {
    final frame = RemoteControlProtocol.parse(raw);
    if (frame == null) return;
    switch (frame.key) {
      case BleCmdRemoteControlKey.capture:
        await _handleCapture();
        break;
      case BleCmdRemoteControlKey.setZoom:
        await _handleSetZoom(frame.value);
        break;
      case BleCmdRemoteControlKey.previewReq:
      case BleCmdRemoteControlKey.recordStart:
      case BleCmdRemoteControlKey.recordStop:
      case BleCmdRemoteControlKey.focusPoint:
      case BleCmdRemoteControlKey.setEv:
      case BleCmdRemoteControlKey.setFlash:
      case BleCmdRemoteControlKey.setTimer:
      case BleCmdRemoteControlKey.setMode:
      case BleCmdRemoteControlKey.flipCamera:
        _reply(frame.key, RemoteControlProtocol.resultUnsupported);
        break;
      default:
        // stateReport / ctrlResult / lastShotReady / previewAck — 都是 app 自己
        // 发的,收到即忽略(设备不该回发)
        debugPrint(
            'RemoteControlSession: ignoring unexpected inbound key 0x${frame.key.toRadixString(16)}');
        break;
    }
  }

  Future<void> _handleCapture() async {
    final handler = _captureHandler;
    if (handler == null) {
      _reply(BleCmdRemoteControlKey.capture,
          RemoteControlProtocol.resultUnsupported);
      return;
    }
    // spec §5.2:成功不发 CTRL_RESULT,成功语义由 handler push 出去的
    // STATE_REPORT + LAST_SHOT_READY 隐含表达。失败(handler 返回 null,例如
    // 相机忙、正在录制等)才回 CTRL_RESULT BUSY,让设备侧稍后重试。
    final shotId = await handler();
    if (shotId == null) {
      _reply(BleCmdRemoteControlKey.capture, RemoteControlProtocol.resultBusy);
    }
  }

  Future<void> _handleSetZoom(Uint8List value) async {
    final zoom = RemoteControlProtocol.parseSetZoom(value);
    if (zoom == null) {
      _reply(BleCmdRemoteControlKey.setZoom,
          RemoteControlProtocol.resultOutOfRange);
      return;
    }
    final handler = _zoomHandler;
    if (handler == null) {
      _reply(BleCmdRemoteControlKey.setZoom,
          RemoteControlProtocol.resultUnsupported);
      return;
    }
    final applied = await handler(zoom);
    if (!applied) {
      // 越界 —— spec §7 code 0x03 OUT_OF_RANGE。生效则不发 CTRL_RESULT,
      // 由 handler 负责通过 reportZoom push STATE_REPORT 表达成功。
      _reply(BleCmdRemoteControlKey.setZoom,
          RemoteControlProtocol.resultOutOfRange);
    }
  }

  void _reply(int echoedKey, int status) {
    if (!_commandAvailable()) return;
    _sendCommand(RemoteControlProtocol.buildCtrlResult(echoedKey, status));
  }

  // ── Outbound (app → device) ────────────────────────────────────────────

  int _nextShotId = 0;

  /// Reserve a new shot id (monotonically increasing) —— use before actually
  /// running the native capture, so on completion the id is stable.
  int allocateShotId() => ++_nextShotId;

  /// Push a full STATE_REPORT snapshot (typically once on camera-ready).
  void reportSnapshot({
    required bool recording,
    required int facing,
    required double zoom,
    required bool hasLastShot,
    required int lastShotId,
  }) {
    if (!_commandAvailable()) return;
    _sendCommand(RemoteControlProtocol.buildStateReport(StateReport(
      recording: recording,
      facing: facing,
      zoom: zoom,
      hasLastShot: hasLastShot,
      lastShotId: lastShotId,
    )));
  }

  /// Push a STATE_REPORT increment carrying just [zoom].
  void reportZoom(double zoom) {
    if (!_commandAvailable()) return;
    _sendCommand(RemoteControlProtocol.buildStateReport(StateReport(
      zoom: zoom,
    )));
  }

  /// Push a STATE_REPORT increment carrying just [facing].
  void reportFacing(int facing) {
    if (!_commandAvailable()) return;
    _sendCommand(RemoteControlProtocol.buildStateReport(StateReport(
      facing: facing,
    )));
  }

  /// Capture just finished: push STATE_REPORT(hasLastShot=1, lastShotId) +
  /// LAST_SHOT_READY(shotId).
  void reportCaptureDone(int shotId) {
    if (!_commandAvailable()) return;
    _sendCommand(RemoteControlProtocol.buildStateReport(StateReport(
      hasLastShot: true,
      lastShotId: shotId,
    )));
    _sendCommand(RemoteControlProtocol.buildLastShotReady(shotId));
  }
}
