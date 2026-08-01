import 'dart:typed_data';

import 'ble_cmd_registry.dart';

/// L2 remote-control protocol (CMD 0x0F) —— 双向控制,app 权威。
///
/// 见 `docs/superpowers/specs/2026-07-30-remote-control-protocol-design.md`。
///
/// L2 帧格式: `[cmd(1), 0x00, key(1), vlen_hi(1), vlen_lo(1)] + value`
///
/// CMD / key 值集中在 `ble_cmd_registry.dart`:CMD 字节走 [BleCmd.remoteControl],
/// 子命令 key 走 [BleCmdRemoteControlKey]。本文件保留载荷语义常量与 TLV 编解码。
class RemoteControlProtocol {
  RemoteControlProtocol._();

  // ── CTRL_RESULT status codes ────────────────────────────────────────────
  // 对齐 spec §七 错误码表。0x00 保留(spec §5.2:成功不发 CTRL_RESULT,
  // 成功语义靠 STATE_REPORT 隐含表达)。
  static const int resultUnsupported = 0x01;
  static const int resultBusy = 0x02;
  static const int resultOutOfRange = 0x03;
  static const int resultNotReady = 0x04;
  static const int resultUnknown = 0xFF;

  static String resultText(int code) => switch (code) {
        resultUnsupported => 'UNSUPPORTED',
        resultBusy => 'BUSY',
        resultOutOfRange => 'OUT_OF_RANGE',
        resultNotReady => 'NOT_READY',
        resultUnknown => 'UNKNOWN',
        _ => 'UNKNOWN(0x${code.toRadixString(16)})',
      };

  // ── STATE_REPORT TLV tags (P0 subset) ───────────────────────────────────
  // 对齐 spec §5.2 tag 表:recording=0x01, mode=0x02, facing=0x03,
  // zoom_x100=0x04, …, has_last_shot=0x0F, last_shot_id=0x10。
  static const int tagRecording = 0x01; // u8 bool
  static const int tagFacing = 0x03; // u8: 0=back, 1=front
  static const int tagZoom = 0x04; // u16BE fixed-point ×100 (1.00 → 100)
  static const int tagHasLastShot = 0x0F; // u8 bool
  static const int tagLastShotId =
      0x10; // u16BE (与 spec §5.2.4 LAST_SHOT_READY 同源)

  // ── Frame builder ───────────────────────────────────────────────────────
  static Uint8List buildFrame(int key, Uint8List value) {
    final frame = Uint8List(5 + value.length);
    frame[0] = BleCmd.remoteControl;
    frame[1] = 0x00;
    frame[2] = key;
    frame[3] = (value.length >> 8) & 0xFF;
    frame[4] = value.length & 0xFF;
    frame.setRange(5, 5 + value.length, value);
    return frame;
  }

  // ── Top-level parse ─────────────────────────────────────────────────────
  static RemoteControlFrame? parse(Uint8List data) {
    if (data.length < 5) return null;
    if (data[0] != BleCmd.remoteControl) return null;
    final key = data[2];
    final vlen = (data[3] << 8) | data[4];
    if (data.length < 5 + vlen) return null;
    return RemoteControlFrame(key: key, value: data.sublist(5, 5 + vlen));
  }

  // ── CAPTURE (0x01) ──────────────────────────────────────────────────────

  /// Build an empty-payload CAPTURE request frame (device → app in P0).
  static Uint8List buildCapture() =>
      buildFrame(BleCmdRemoteControlKey.capture, Uint8List(0));

  // ── SET_ZOOM (0x04) ─────────────────────────────────────────────────────

  /// Build a SET_ZOOM request frame. [zoom] is the linear crop-zoom factor
  /// (1.0 = full field of view). Encoded as u16BE fixed-point × 100, so the
  /// on-wire range is 0.00 … 655.35 (the range app-side clamps enforce is much
  /// tighter — see `stream_page.dart` `_kMin/MaxZoom`).
  static Uint8List buildSetZoom(double zoom) {
    if (zoom.isNaN || zoom < 0 || zoom > 655.35) {
      throw ArgumentError.value(zoom, 'zoom', 'must be in [0, 655.35]');
    }
    final scaled = (zoom * 100).round() & 0xFFFF;
    final value = Uint8List(2);
    value[0] = (scaled >> 8) & 0xFF;
    value[1] = scaled & 0xFF;
    return buildFrame(BleCmdRemoteControlKey.setZoom, value);
  }

  /// Parse a SET_ZOOM payload → double, or null if malformed.
  static double? parseSetZoom(Uint8List v) {
    if (v.length < 2) return null;
    final scaled = (v[0] << 8) | v[1];
    return scaled / 100.0;
  }

  // ── CTRL_RESULT (0x11) ──────────────────────────────────────────────────

  /// Build a CTRL_RESULT frame. [echoedKey] is the sub-command being answered
  /// (e.g. 0x04 for a SET_ZOOM that was rejected). [status] is one of
  /// [resultUnsupported] / [resultBusy] / [resultOutOfRange] / [resultNotReady]
  /// / [resultUnknown]. The third byte (`detail`) is reserved (0) per spec §5.2.
  ///
  /// spec §5.2:CTRL_RESULT 仅在**执行失败**时发送;成功语义由随后的
  /// STATE_REPORT 隐含表达。session 层照此约束调用(见 [RemoteControlSession])。
  static Uint8List buildCtrlResult(int echoedKey, int status) {
    final value = Uint8List(3);
    value[0] = echoedKey & 0xFF;
    value[1] = status & 0xFF;
    value[2] = 0; // reserved (detail)
    return buildFrame(BleCmdRemoteControlKey.ctrlResult, value);
  }

  /// Parse a CTRL_RESULT payload → (echoedKey, status), or null if the payload
  /// is shorter than the 3-byte spec (detail byte is currently ignored).
  static CtrlResult? parseCtrlResult(Uint8List v) {
    if (v.length < 3) return null;
    return CtrlResult(echoedKey: v[0], status: v[1]);
  }

  // ── LAST_SHOT_READY (0x12) ──────────────────────────────────────────────

  /// Build a LAST_SHOT_READY push. [shotId] is a monotonically increasing u16
  /// (starts at 0 on session boot); matches `tagLastShotId` inside STATE_REPORT.
  /// Third byte is reserved (0) per spec §5.2.4.
  static Uint8List buildLastShotReady(int shotId) {
    if (shotId < 0 || shotId > 0xFFFF) {
      throw ArgumentError.value(shotId, 'shotId', 'must fit in u16');
    }
    final value = Uint8List(3);
    value[0] = (shotId >> 8) & 0xFF;
    value[1] = shotId & 0xFF;
    value[2] = 0; // reserved
    return buildFrame(BleCmdRemoteControlKey.lastShotReady, value);
  }

  /// Parse a LAST_SHOT_READY payload → shot_id (u16be), or null if malformed.
  /// The reserved third byte is currently ignored.
  static int? parseLastShotReady(Uint8List v) {
    if (v.length < 3) return null;
    return (v[0] << 8) | v[1];
  }

  // ── STATE_REPORT (0x10) ─────────────────────────────────────────────────

  /// Build a STATE_REPORT push. Only the non-null fields of [report] are
  /// serialized — this is a partial-update TLV, absent tags mean "unchanged".
  static Uint8List buildStateReport(StateReport report) {
    final b = BytesBuilder(copy: false);
    void appendTag(int tag, List<int> value) {
      b.addByte(tag);
      b.addByte(value.length & 0xFF);
      b.add(value);
    }

    if (report.recording != null) {
      appendTag(tagRecording, [report.recording! ? 1 : 0]);
    }
    if (report.facing != null) {
      appendTag(tagFacing, [report.facing! & 0xFF]);
    }
    if (report.zoom != null) {
      final scaled = (report.zoom! * 100).round() & 0xFFFF;
      appendTag(tagZoom, [(scaled >> 8) & 0xFF, scaled & 0xFF]);
    }
    if (report.hasLastShot != null) {
      appendTag(tagHasLastShot, [report.hasLastShot! ? 1 : 0]);
    }
    if (report.lastShotId != null) {
      final id = report.lastShotId! & 0xFFFF;
      appendTag(tagLastShotId, [
        (id >> 8) & 0xFF,
        id & 0xFF,
      ]);
    }

    return buildFrame(BleCmdRemoteControlKey.stateReport, b.toBytes());
  }

  /// Parse a STATE_REPORT payload → [StateReport] with only present tags set.
  /// Returns null if TLV framing is malformed (declared length overshoots).
  static StateReport? parseStateReport(Uint8List v) {
    bool? recording;
    int? facing;
    double? zoom;
    bool? hasLastShot;
    int? lastShotId;
    var o = 0;
    while (o < v.length) {
      if (o + 2 > v.length) return null;
      final tag = v[o];
      final len = v[o + 1];
      final end = o + 2 + len;
      if (end > v.length) return null;
      switch (tag) {
        case tagRecording:
          if (len >= 1) recording = v[o + 2] != 0;
          break;
        case tagFacing:
          if (len >= 1) facing = v[o + 2];
          break;
        case tagZoom:
          if (len >= 2) {
            final scaled = (v[o + 2] << 8) | v[o + 3];
            zoom = scaled / 100.0;
          }
          break;
        case tagHasLastShot:
          if (len >= 1) hasLastShot = v[o + 2] != 0;
          break;
        case tagLastShotId:
          if (len >= 2) {
            lastShotId = (v[o + 2] << 8) | v[o + 3];
          }
          break;
        default:
          // 未知 tag —— 静默跳过,forward compatibility
          break;
      }
      o = end;
    }
    return StateReport(
      recording: recording,
      facing: facing,
      zoom: zoom,
      hasLastShot: hasLastShot,
      lastShotId: lastShotId,
    );
  }
}

/// A parsed CMD 0x0F frame (key + value).
class RemoteControlFrame {
  final int key;
  final Uint8List value;
  const RemoteControlFrame({required this.key, required this.value});
}

/// Parsed CTRL_RESULT payload. Spec §5.2 guarantees this is only sent on
/// failure — receiving one means the corresponding sub-command was rejected.
class CtrlResult {
  final int echoedKey;
  final int status;
  const CtrlResult({required this.echoedKey, required this.status});
}

/// STATE_REPORT payload (partial-update TLV; nulls mean "unchanged").
class StateReport {
  final bool? recording;
  final int? facing; // 0 = back, 1 = front
  final double? zoom;
  final bool? hasLastShot;
  final int? lastShotId;

  const StateReport({
    this.recording,
    this.facing,
    this.zoom,
    this.hasLastShot,
    this.lastShotId,
  });

  bool get isEmpty =>
      recording == null &&
      facing == null &&
      zoom == null &&
      hasLastShot == null &&
      lastShotId == null;
}
