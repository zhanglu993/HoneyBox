import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'ble_cmd_registry.dart';

/// L2 real-time video-stream protocol (CMD_STREAM = 0x0E).
///
/// Ported from the w04_web_app reference implementation. Runs over a separate
/// GATT Stream Service (write FFC4 / notify FFC5) carrying **raw L2 messages
/// with no L1 wrapper**. Reliability comes from BLE LL ARQ + credit flow
/// control + per-frame gap retransmission (see the design spec).
///
/// This layer is transport-agnostic: it sends via a [SendL2] callback and is
/// fed inbound notifications through [onNotify], so it works over BLE today and
/// any future transport (e.g. WiFi) unchanged.
///
/// CMD / key 值集中定义在 `ble_cmd_registry.dart`:CMD 字节走 [BleCmd.stream],
/// 子命令 key 走 [BleCmdStreamKey](顶层类,能用于 switch case 的 const 表达式)。
/// 本文件只保留编码语义常量([StreamCodec])。

/// Stream codec identifiers (negotiated in KS_OPEN).
class StreamCodec {
  StreamCodec._();
  static const int msv1 = 0x00; // RGB555 16bpp (Microsoft Video 1 family)
  static const int jpeg = 0x01;
  static const int h264 = 0x02; // baselined H.264 Annex-B byte stream
}

// ── Byte helpers ─────────────────────────────────────────────────────────
int _u16be(int a, int b) => (a << 8) | b;
int _u24be(int a, int b, int c) => (a << 16) | (b << 8) | c;

/// Build a generic L2 message: `[cmd, 0x00, key, vlen_hi, vlen_lo, ...value]`.
Uint8List buildL2Cmd(int cmd, int key, List<int> value) {
  final out = Uint8List(5 + value.length);
  out[0] = cmd;
  out[1] = 0x00;
  out[2] = key;
  out[3] = (value.length >> 8) & 0xFF;
  out[4] = value.length & 0xFF;
  out.setRange(5, 5 + value.length, value);
  return out;
}

/// KS_OPEN value: `sid u8, codec u8, width u16LE, height u16LE, fps u8`.
Uint8List buildStreamOpen(int sid, int codec, int w, int h, int fps) {
  return buildL2Cmd(BleCmd.stream, BleCmdStreamKey.open, [
    sid & 0xFF,
    codec & 0xFF,
    w & 0xFF,
    (w >> 8) & 0xFF,
    h & 0xFF,
    (h >> 8) & 0xFF,
    fps & 0xFF,
  ]);
}

Uint8List buildStreamClose(int sid) =>
    buildL2Cmd(BleCmd.stream, BleCmdStreamKey.close, [sid & 0xFF]);

/// KS_FRAME value: `frame_seq u16BE, byte_offset u24BE, total_len u24BE, data`.
Uint8List buildStreamChunk(int seq, int off, int total, Uint8List data) {
  final out = Uint8List(8 + data.length);
  out[0] = (seq >> 8) & 0xFF;
  out[1] = seq & 0xFF;
  out[2] = (off >> 16) & 0xFF;
  out[3] = (off >> 8) & 0xFF;
  out[4] = off & 0xFF;
  out[5] = (total >> 16) & 0xFF;
  out[6] = (total >> 8) & 0xFF;
  out[7] = total & 0xFF;
  out.setRange(8, 8 + data.length, data);
  return buildL2Cmd(BleCmd.stream, BleCmdStreamKey.frame, out);
}

/// Sends a complete raw L2 message over the active transport.
typedef SendL2 = Future<void> Function(Uint8List l2);

class _RetxEntry {
  final Uint8List chunk;
  final int totalLen;
  const _RetxEntry(this.chunk, this.totalLen);
}

enum StreamState { idle, opening, open }

/// Client-side state machine for the L2 video-stream protocol with credit flow
/// control and gap retransmission.
class StreamSession {
  /// Sends one raw L2 message (a single BLE write — never fragmented here).
  final SendL2 send;

  /// Bytes of frame data carried per KS_FRAME = `fragSize - 13` (no L1).
  final int Function() chunkSize;

  StreamSession({required this.send, required this.chunkSize});

  static const Duration _openTimeout = Duration(seconds: 5);
  static const Duration _creditTimeout = Duration(seconds: 5);
  static const int _retxKeep = 3;

  StreamState _state = StreamState.idle;
  int _sessionId = 0;
  int _frameSeq = 0;

  // Credit flow control. _flowOn=false means the device disabled flow control
  // (init_credits=0xFFFF) → fire-and-forget.
  bool _flowOn = false;
  int _credits = 0;
  Completer<bool>? _creditWake;
  Timer? _creditTimer;

  Completer<bool>? _openCompleter;
  Timer? _openTimer;

  /// Retransmit buffers: frame_seq → (byte_offset → chunk). Keeps the last
  /// [_retxKeep] frames so a device gap report that arrives after we've moved
  /// on to the next frame can still be served.
  final Map<int, Map<int, _RetxEntry>> _retxFrames = {};

  StreamState get state => _state;
  bool get isOpen => _state == StreamState.open;
  bool get flowOn => _flowOn;
  int get credits => _credits;

  // ──────────────────────────────────────────────────────────────────────
  // Session lifecycle
  // ──────────────────────────────────────────────────────────────────────

  /// Open a stream session and await the device KS_ACK. Returns false on
  /// timeout / rejection.
  Future<bool> open(int codec, int w, int h, int fps) async {
    _sessionId = (_sessionId + 1) & 0xFF;
    _frameSeq = 0;
    _state = StreamState.opening;
    _credits = 0;
    _flowOn = false;
    _wakeCredit(false);
    _retxFrames.clear();

    final completer = Completer<bool>();
    _openCompleter = completer;
    _openTimer?.cancel();
    _openTimer = Timer(_openTimeout, () {
      if (_state == StreamState.opening) {
        _state = StreamState.idle;
        _openCompleter = null;
        if (!completer.isCompleted) completer.complete(false);
      }
    });

    try {
      await send(buildStreamOpen(_sessionId, codec, w, h, fps));
    } catch (_) {
      _openTimer?.cancel();
      _state = StreamState.idle;
      _openCompleter = null;
      if (!completer.isCompleted) completer.complete(false);
    }
    return completer.future;
  }

  /// Split one frame into KS_FRAME chunks and send them, honouring credit flow
  /// control (sliding window). Returns false if the frame was dropped (credit
  /// timeout / session closed / write error).
  Future<bool> sendFrame(Uint8List frameBytes) async {
    if (_state != StreamState.open) return false;
    final cs = chunkSize();
    final seq = _frameSeq;
    final total = frameBytes.length;
    _frameSeq = (_frameSeq + 1) & 0xFFFF;

    // Register a per-frame retransmit buffer; evict the oldest beyond the keep.
    final retxBuf = <int, _RetxEntry>{};
    _retxFrames[seq] = retxBuf;
    while (_retxFrames.length > _retxKeep) {
      _retxFrames.remove(_retxFrames.keys.first);
    }

    bool failed = false;
    Future<void>? last;
    for (int off = 0; off < total; off += cs) {
      if (_flowOn) {
        while (_credits <= 0) {
          debugPrint('流/信用耗尽 seq=$seq off=$off/$total 等待补充...');
          final got = await _waitCredit();
          if (!got) {
            debugPrint('流/信用超时(5s未补) 丢帧 seq=$seq @off=$off/$total');
            return false;
          }
          if (_state != StreamState.open) return false;
        }
        if (_state != StreamState.open) return false;
        _credits--;
      }
      final end = (off + cs < total) ? off + cs : total;
      final chunk = Uint8List.sublistView(frameBytes, off, end);
      retxBuf[off] = _RetxEntry(chunk, total);
      final p = send(buildStreamChunk(seq, off, total, chunk));
      p.catchError((_) {
        failed = true;
      });
      last = p;
    }
    if (last != null) {
      try {
        await last;
      } catch (_) {}
    }
    return !failed && _state == StreamState.open;
  }

  /// Close the session (sends KS_CLOSE).
  void close() {
    if (_state == StreamState.idle) return;
    _openTimer?.cancel();
    final prev = _state;
    _state = StreamState.idle;
    _openCompleter = null;
    _credits = 0;
    _wakeCredit(false);
    _retxFrames.clear();
    if (prev != StreamState.idle) {
      send(buildStreamClose(_sessionId)).catchError((_) {});
    }
  }

  /// Reset on transport disconnect (no KS_CLOSE — peer is gone).
  void onDisconnect() {
    _openTimer?.cancel();
    _state = StreamState.idle;
    _credits = 0;
    _wakeCredit(false);
    _retxFrames.clear();
    final c = _openCompleter;
    _openCompleter = null;
    if (c != null && !c.isCompleted) c.complete(false);
  }

  // ──────────────────────────────────────────────────────────────────────
  // Inbound (KS_ACK / KS_CREDIT / KS_REPORT)
  // ──────────────────────────────────────────────────────────────────────

  /// Feed a raw inbound L2 notification (from FFC5).
  void onNotify(Uint8List l2) {
    if (l2.length < 5 || l2[0] != BleCmd.stream) return;
    final key = l2[2];
    final vlen = _u16be(l2[3], l2[4]);
    final v = Uint8List.sublistView(l2, 5, (5 + vlen).clamp(5, l2.length));

    if (key == BleCmdStreamKey.ack && _state == StreamState.opening) {
      _onAck(v, vlen);
    } else if (key == BleCmdStreamKey.credit) {
      _onCredit(v);
    } else if (key == BleCmdStreamKey.report) {
      _onReport(v);
    } else {
      debugPrint('流/收到未知下行 key=0x${key.toRadixString(16)} vlen=$vlen');
    }
  }

  void _onAck(Uint8List v, int vlen) {
    _openTimer?.cancel();
    final ackSid = v.isNotEmpty ? v[0] : -1;
    if (ackSid != _sessionId) {
      debugPrint('流/ACK sid 差异! 设备回 sid=$ackSid 我们发 sid=$_sessionId '
          '(后续 CREDIT 若用设备 sid 将被丢弃)');
    }
    final ok = v.length >= 2 && v[1] == 0x00;
    // KS_ACK may carry init_credits(u16be) after result. 0xFFFF or missing =
    // unlimited (no flow control).
    final ic = (vlen >= 4) ? _u16be(v[2], v[3]) : 0xFFFF;
    _state = ok ? StreamState.open : StreamState.idle;
    if (ok) {
      if (ic == 0xFFFF) {
        _flowOn = false;
        _credits = 0;
      } else {
        _flowOn = true;
        _credits = ic;
      }
    }
    final c = _openCompleter;
    _openCompleter = null;
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  void _onCredit(Uint8List v) {
    if (v.length < 3) return;
    final sid = v[0];
    final n = _u16be(v[1], v[2]);
    if (!_flowOn) {
      debugPrint('流/CREDIT 被忽略(无限信用模式) sid=$sid +$n');
      return;
    }
    if (sid != _sessionId) {
      debugPrint('流/CREDIT sid 不匹配! 收到 sid=$sid 期望=$_sessionId +$n '
          '(信用不会补充 → 会卡住)');
      return;
    }
    _grantCredits(n);
    debugPrint('流/CREDIT +$n → 剩余=$_credits');
  }

  Future<void> _onReport(Uint8List v) async {
    // session_id(u8) frame_seq(u16be) gap_count(u8) [gap_start(u24be) gap_end(u24be)]*
    if (v.length < 4 || v[0] != _sessionId) return;
    final repSeq = _u16be(v[1], v[2]);
    final gc = v[3];
    if (gc == 0) {
      _retxFrames.remove(repSeq); // frame complete → drop its retx buffer
      return;
    }
    debugPrint('流/REPORT seq=$repSeq 缺口×$gc → 重传');
    final buf = _retxFrames[repSeq];
    if (buf == null) return;
    const baseLen = 4, gapBytes = 6;
    if (v.length < baseLen + gc * gapBytes) return;

    // Match each gap [gs,ge) against buffered chunk ranges [boff, boff+len).
    final retxOffs = <int>{};
    for (int i = 0; i < gc; i++) {
      final base = baseLen + i * gapBytes;
      final gs = _u24be(v[base], v[base + 1], v[base + 2]);
      final ge = _u24be(v[base + 3], v[base + 4], v[base + 5]);
      buf.forEach((boff, entry) {
        if (boff < ge && boff + entry.chunk.length > gs) retxOffs.add(boff);
      });
    }
    final sorted = retxOffs.toList()..sort();
    for (final boff in sorted) {
      if (_state != StreamState.open) break;
      final entry = buf[boff];
      if (entry == null) continue;
      // Retransmits don't consume credit and are sent one at a time (no burst).
      try {
        await send(buildStreamChunk(repSeq, boff, entry.totalLen, entry.chunk));
      } catch (_) {}
    }
  }

  // ── Credit helpers ──
  void _grantCredits(int n) {
    if (!_flowOn) return;
    _credits += n;
    _wakeCredit(true);
  }

  Future<bool> _waitCredit() {
    if (_credits > 0) return Future.value(true);
    final c = Completer<bool>();
    _creditWake = c;
    _creditTimer?.cancel();
    _creditTimer = Timer(_creditTimeout, () {
      if (_creditWake == c) _creditWake = null;
      if (!c.isCompleted) c.complete(false);
    });
    return c.future;
  }

  void _wakeCredit(bool ok) {
    _creditTimer?.cancel();
    final w = _creditWake;
    _creditWake = null;
    if (w != null && !w.isCompleted) w.complete(ok);
  }
}
