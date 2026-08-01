import 'dart:async' as async_;
import 'dart:convert';
import 'dart:typed_data';

import 'ble_cmd_registry.dart';

// ---------------------------------------------------------------------------
// CRC-32 (polynomial 0xEDB88320, reflected)
// ---------------------------------------------------------------------------

/// Precomputed CRC-32 lookup table (256 entries), built once at compile time.
final _crc32Table = List<int>.generate(256, (int i) {
  int crc = i;
  for (int j = 0; j < 8; j++) {
    if (crc & 1 != 0) {
      crc = (crc >> 1) ^ 0xEDB88320;
    } else {
      crc = crc >> 1;
    }
  }
  return crc;
});

/// Compute a table-based CRC-32 over [data] and return the unsigned 32-bit
/// value.
int crc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (int i = 0; i < data.length; i++) {
    final index = (crc ^ data[i]) & 0xFF;
    crc = (crc >> 8) ^ _crc32Table[index];
  }
  return (crc ^ 0xFFFFFFFF) >>> 0; // force unsigned 32-bit
}

// ---------------------------------------------------------------------------
// Protocol constants
// ---------------------------------------------------------------------------
//
// CMD 字节和子命令 key 集中在 `ble_cmd_registry.dart`:
//   CMD:  [BleCmd.fileTransfer]
//   key:  [BleCmdFileTransferKey] (顶层 abstract class — 能用于 switch case)
// 本文件保留载荷语义常量([TYPE] 文件类型 / [L2State] 状态机)。

/// File type identifiers.
class TYPE {
  TYPE._();
  static const int raw = 0x00;
  static const int image = 0x01;
  static const int video = 0x02;
}

/// L2 state machine states.
class L2State {
  L2State._();
  static const int idle = 0;
  static const int negotiating = 1;
  static const int transferring = 2;
  static const int verifying = 3;
}

// ---------------------------------------------------------------------------
// Byte helpers
// ---------------------------------------------------------------------------

void _writeU16(Uint8List data, int offset, int value) {
  data[offset] = (value >> 8) & 0xFF;
  data[offset + 1] = value & 0xFF;
}

void _writeU32(Uint8List data, int offset, int value) {
  data[offset] = (value >> 24) & 0xFF;
  data[offset + 1] = (value >> 16) & 0xFF;
  data[offset + 2] = (value >> 8) & 0xFF;
  data[offset + 3] = value & 0xFF;
}

int _readU16(Uint8List data, int offset) {
  return (data[offset] << 8) | data[offset + 1];
}

// ---------------------------------------------------------------------------
// Timeout constants
// ---------------------------------------------------------------------------

const int _defaultChunkSize = 2048;
// Host-waits-for-slave-reply timeouts: a slow device may erase flash before
// replying with BEGIN_RSP, or verify the CRC and commit the file before
// END_RSP, so give ample headroom before declaring the transfer failed. The
// handshake gets the most (flash erase is the slowest step).
const Duration _negotiationTimeout = Duration(seconds: 30); // BEGIN_RSP (握手)
const Duration _dataAckTimeout = Duration(seconds: 25); // DATA L1 ACK
const Duration _verifyTimeout = Duration(seconds: 25); // END_RSP

// ---------------------------------------------------------------------------
// Parsed L2 frame
// ---------------------------------------------------------------------------

/// A single parsed L2 frame.
class L2Frame {
  final int cmdId;
  final int key;
  final Uint8List value;

  const L2Frame({
    required this.cmdId,
    required this.key,
    required this.value,
  });
}

// ---------------------------------------------------------------------------
// Frame builders
// ---------------------------------------------------------------------------

/// Build a generic L2 frame: [cmd, 0x00, key, vLen_hi, vLen_lo] + value
Uint8List buildL2Frame(int key, Uint8List value) {
  final len = value.length;
  final frame = Uint8List(5 + len);
  frame[0] = BleCmd.fileTransfer;
  frame[1] = 0x00;
  frame[2] = key;
  frame[3] = (len >> 8) & 0xFF;
  frame[4] = len & 0xFF;
  if (len > 0) {
    frame.setRange(5, 5 + len, value);
  }
  return frame;
}

/// Build a BEGIN_REQ frame.
///
/// Payload layout:
///   [type(1), totalSize(4), chunkSize(2), nameLen(1), utf8Name]
Uint8List buildBeginReq(
  int fileType,
  int totalSize,
  int chunkSize,
  String filename,
) {
  final nameBytes = Uint8List.fromList(utf8.encode(filename));
  final value = Uint8List(8 + nameBytes.length);
  value[0] = fileType;
  _writeU32(value, 1, totalSize);
  _writeU16(value, 5, chunkSize);
  value[7] = nameBytes.length & 0xFF;
  value.setRange(8, 8 + nameBytes.length, nameBytes);
  return buildL2Frame(BleCmdFileTransferKey.beginReq, value);
}

/// Build a DATA frame.
///
/// Payload: [seq_hi, seq_lo] + chunk
Uint8List buildDataFrame(int seq, Uint8List chunk) {
  final value = Uint8List(2 + chunk.length);
  _writeU16(value, 0, seq);
  value.setRange(2, 2 + chunk.length, chunk);
  return buildL2Frame(BleCmdFileTransferKey.data, value);
}

/// Build an END_REQ frame.
///
/// Payload: [crc32(4)]
Uint8List buildEndReq(int crc32Val) {
  final value = Uint8List(4);
  _writeU32(value, 0, crc32Val);
  return buildL2Frame(BleCmdFileTransferKey.endReq, value);
}

/// Build an ABORT frame.
///
/// Payload: [reason]
Uint8List buildAbort(int reason) {
  final value = Uint8List(1);
  value[0] = reason & 0xFF;
  return buildL2Frame(BleCmdFileTransferKey.abort, value);
}

/// Parse a raw L2 payload (already stripped of the L1 header) into an
/// [L2Frame]. Returns `null` on malformed input.
L2Frame? parseL2Frame(Uint8List data) {
  if (data.length < 5) return null;
  if (data[0] != BleCmd.fileTransfer) return null;

  final key = data[2];
  final valLen = (data[3] << 8) | data[4];
  if (data.length < 5 + valLen) return null;

  final value = data.sublist(5, 5 + valLen);
  return L2Frame(cmdId: data[0], key: key, value: value);
}

// ---------------------------------------------------------------------------
// Timer provider abstraction
// ---------------------------------------------------------------------------

/// Typedef for a no-argument callback used by [TimerProvider].
typedef TimerCallback = void Function();

/// Minimal abstraction so [FileTransferSession] can use timers without a
/// direct `dart:async` dependency on the public API. Production code uses
/// the default dart:async-based provider. Tests can inject a fake.
abstract class TimerProvider {
  void start(Duration duration, TimerCallback callback);
  void cancel();
}

/// Default timer provider backed by `dart:async.Timer`.
class _DefaultTimerProvider implements TimerProvider {
  async_.Timer? _timer;

  @override
  void start(Duration duration, TimerCallback callback) {
    _timer = async_.Timer(duration, callback);
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

// ---------------------------------------------------------------------------
// FileTransferSession
// ---------------------------------------------------------------------------

/// Signature for sending raw L2 bytes through the L1 engine.
///
/// Returns the L1 sequence number assigned to the frame, which the session
/// uses to match ACKs.
typedef SendL2Fn = int Function(Uint8List frame);

/// Manages the L2 file-transfer state machine.
///
/// This class has **no Flutter dependency** and communicates with the L1 layer
/// through callbacks passed at construction time.
class FileTransferSession {
  // --------------------------------------------------------------------------
  // Dependencies
  // --------------------------------------------------------------------------

  /// Function to send a raw L2 frame via the L1 engine.
  final SendL2Fn sendL2;

  /// Called when the session should attach itself to the L1 engine (so
  /// [onL2Frame] calls arrive).
  final void Function(FileTransferSession session)? attachToL1;

  /// Called when the session should detach itself from the L1 engine.
  final void Function()? detachFromL1;

  // --------------------------------------------------------------------------
  // State
  // --------------------------------------------------------------------------

  int _state = L2State.idle;

  /// The complete file buffer being transferred.
  late Uint8List _buf;

  int _totalSize = 0;
  int _chunkSize = _defaultChunkSize;
  int _sentBytes = 0;
  int _dataSeq = 0;
  int _pendingL1Seq = -1;
  int _lastChunkLen = 0;
  int _crc32Val = 0;
  int _fileType = TYPE.raw;
  String _filename = '';

  /// Injected timer provider for timeouts. Falls back to a default dart:async
  /// provider when not injected.
  final TimerProvider _timerProvider;

  // --------------------------------------------------------------------------
  // Callbacks
  // --------------------------------------------------------------------------

  void Function(int sent, int total)? onProgress;
  void Function()? onComplete;
  void Function(String reason)? onError;

  /// Optional diagnostic sink for handshake / control frames (BEGIN, END,
  /// ABORT) and their L1 ACK/NAKs. DATA frames are deliberately **not** logged
  /// through this (a transfer can have thousands — they would flood the log).
  /// Kept as a callback so this class stays Flutter-free; the BLE layer routes
  /// it to `debugPrint`.
  void Function(String message)? onLog;

  // --------------------------------------------------------------------------
  // Construction
  // --------------------------------------------------------------------------

  FileTransferSession({
    required this.sendL2,
    this.attachToL1,
    this.detachFromL1,
    this.onProgress,
    this.onComplete,
    this.onError,
    this.onLog,
    TimerProvider? timerProvider,
  }) : _timerProvider = timerProvider ?? _DefaultTimerProvider();

  // --------------------------------------------------------------------------
  // Properties
  // --------------------------------------------------------------------------

  int get state => _state;
  int get sentBytes => _sentBytes;
  int get totalSize => _totalSize;
  int get chunkSize => _chunkSize;
  String get filename => _filename;
  int get fileType => _fileType;

  double get progress => _totalSize > 0 ? _sentBytes / _totalSize : 0.0;

  // --------------------------------------------------------------------------
  // Public API
  // --------------------------------------------------------------------------

  /// Start a file transfer.
  ///
  /// [fileType] is one of [TYPE.raw], [TYPE.image], or [TYPE.video].
  /// [buffer] contains the complete file bytes.
  /// [filename] is a human-readable name sent in the BEGIN_REQ.
  void send(int fileType, Uint8List buffer, String filename) {
    if (_state != L2State.idle) {
      _fail('Already in transfer');
      return;
    }

    _state = L2State.negotiating;
    _buf = buffer;
    _totalSize = buffer.length;
    _chunkSize = _defaultChunkSize;
    _fileType = fileType;
    _filename = filename;
    _sentBytes = 0;
    _dataSeq = 0;
    _pendingL1Seq = -1;
    _lastChunkLen = 0;
    _crc32Val = crc32(buffer);

    // Attach to L1 engine so onL2Frame callbacks arrive.
    attachToL1?.call(this);

    // Send BEGIN_REQ.
    final l2 = buildBeginReq(fileType, _totalSize, _chunkSize, filename);
    _pendingL1Seq = sendL2(l2);
    _log('→ BEGIN_REQ  type=$fileType size=$_totalSize chunk=$_chunkSize '
        'crc=${_hex(_crc32Val, 8)} name="$filename" (L1 seq=$_pendingL1Seq)');
    _startTimer(_negotiationTimeout, 'Wait for BEGIN_RSP timed out');
  }

  /// Abort the current transfer.
  void abort() {
    if (_state == L2State.idle) return;
    _log('→ ABORT (user requested, state=$_state)');
    sendL2(buildAbort(0x01));
    _cleanUp();
  }

  /// Called by the L1 engine when an L2 frame arrives.
  void onL2Frame(Uint8List raw) {
    final frame = parseL2Frame(raw);
    if (frame == null) {
      _log('← malformed L2 frame (${raw.length} bytes)');
      return;
    }

    switch (frame.key) {
      case BleCmdFileTransferKey.beginRsp:
        _onBeginRsp(frame.value);
        break;
      case BleCmdFileTransferKey.endRsp:
        _onEndRsp(frame.value);
        break;
      case BleCmdFileTransferKey.abort:
        _log('← ABORT (peer, reason='
            '${frame.value.isNotEmpty ? _hex(frame.value[0], 2) : "?"})');
        _fail('Peer aborted');
        break;
      default:
        _log('← unexpected L2 key=${_hex(frame.key, 2)} '
            'len=${frame.value.length}');
    }
  }

  /// Called by the L1 engine when an ACK/NAK for our sent frame arrives.
  void onL1Ack(int seq, bool ok) {
    if (seq != _pendingL1Seq) return;
    if (_state == L2State.idle) return;

    if (!ok) {
      _log('← L1 NAK  seq=$seq (state=$_state)');
      _fail('NAK for seq $seq');
      return;
    }

    if (_state == L2State.negotiating) {
      // L1-level ACK confirming BEGIN_REQ was delivered; the data phase still
      // waits on the L2 BEGIN_RSP.
      _log('← L1 ACK  BEGIN_REQ delivered (seq=$seq), awaiting BEGIN_RSP');
    } else if (_state == L2State.transferring) {
      _clearTimer();
      _sentBytes += _lastChunkLen;
      if (_sentBytes > _totalSize) _sentBytes = _totalSize;
      onProgress?.call(_sentBytes, _totalSize);
      _sendNextChunk();
    } else if (_state == L2State.verifying) {
      _log('← L1 ACK  END_REQ delivered (seq=$seq), awaiting END_RSP');
      // END_REQ was ACK'd -- wait for END_RSP.
      _startTimer(_verifyTimeout, 'Wait for END_RSP timed out');
    }
  }

  // --------------------------------------------------------------------------
  // Internal helpers
  // --------------------------------------------------------------------------

  void _log(String message) => onLog?.call(message);

  /// Fixed-width lowercase hex, e.g. `_hex(0x1a, 2)` → `0x1a` (diagnostics).
  String _hex(int value, int width) =>
      '0x${value.toRadixString(16).padLeft(width, '0')}';

  void _sendNextChunk() {
    if (_sentBytes >= _totalSize) {
      // All data sent -- send END_REQ.
      _state = L2State.verifying;
      final l2 = buildEndReq(_crc32Val);
      _pendingL1Seq = sendL2(l2);
      _log('→ END_REQ  crc=${_hex(_crc32Val, 8)} '
          '($_dataSeq data frames / $_sentBytes bytes sent) '
          '(L1 seq=$_pendingL1Seq)');
      _startTimer(_verifyTimeout, 'Wait for END_RSP timed out');
      return;
    }

    final remaining = _totalSize - _sentBytes;
    final chunkLen = remaining < _chunkSize ? remaining : _chunkSize;
    final chunk = _buf.sublist(_sentBytes, _sentBytes + chunkLen);

    final l2 = buildDataFrame(_dataSeq, chunk);
    _pendingL1Seq = sendL2(l2);
    _dataSeq++;
    _lastChunkLen = chunkLen;
    _startTimer(_dataAckTimeout, 'DATA ACK timed out');
  }

  void _onBeginRsp(Uint8List value) {
    if (_state != L2State.negotiating) {
      _log('← BEGIN_RSP ignored (unexpected in state=$_state)');
      return;
    }
    _clearTimer();

    final status = value.isNotEmpty ? value[0] : 0;
    if (status != 0) {
      const reasons = {
        0x01: '设备忙',
        0x02: '存储空间不足',
        0x03: '不支持的文件类型',
      };
      _log('← BEGIN_RSP REJECTED status=${_hex(status, 2)}');
      _fail('握手被拒绝: ${reasons[status] ?? '0x${status.toRadixString(16)}'}');
      return;
    }

    if (value.length >= 3) {
      final agreedChunkSize = _readU16(value, 1);
      if (agreedChunkSize > 0) _chunkSize = agreedChunkSize;
    }

    _log('← BEGIN_RSP ACCEPTED, agreed chunk=$_chunkSize — begin data phase');
    _state = L2State.transferring;
    _sendNextChunk();
  }

  void _onEndRsp(Uint8List value) {
    if (_state != L2State.verifying) {
      _log('← END_RSP ignored (unexpected in state=$_state)');
      return;
    }
    _clearTimer();
    _log('← END_RSP  transfer complete & verified');
    _state = L2State.idle;
    onComplete?.call();
    _cleanUp();
  }

  // --------------------------------------------------------------------------
  // Timer
  // --------------------------------------------------------------------------

  void _startTimer(Duration duration, String message) {
    _clearTimer();
    _timerProvider.start(duration, () => _fail(message));
  }

  void _clearTimer() {
    _timerProvider.cancel();
  }

  // --------------------------------------------------------------------------
  // Cleanup
  // --------------------------------------------------------------------------

  void _fail(String reason) {
    _clearTimer();
    if (_state != L2State.idle) {
      _log('✗ FAIL (state=$_state): $reason → sending ABORT');
      sendL2(buildAbort(0x01));
    } else {
      _log('✗ FAIL: $reason');
    }
    onError?.call(reason);
    _cleanUp();
  }

  void _cleanUp() {
    _clearTimer();
    detachFromL1?.call();
    _state = L2State.idle;
    _buf = Uint8List(0);
    _totalSize = 0;
    _sentBytes = 0;
    _dataSeq = 0;
    _pendingL1Seq = -1;
    _lastChunkLen = 0;
    _crc32Val = 0;
    _fileType = TYPE.raw;
    _filename = '';
  }
}
