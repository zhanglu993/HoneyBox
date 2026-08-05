/// Frame payload per KS_FRAME write implied by the 23-byte ATT MTU floor.
/// Every BLE link supports at least this much, so probing never goes below it.
const int kMinStreamChunk = 7;

/// Starting chunk used when the platform reports no MTU: `(247 - 3) - 13`.
///
/// 247 is the ATT MTU virtually every BLE 4.2+ peripheral negotiates, and this
/// value is measured to work against the eBadge on Windows. It is deliberately
/// not raised to the 517-byte spec maximum: an oversized KS_FRAME write is not
/// rejected cleanly by the WinRT stack, it drops the connection, so every
/// over-guess costs a reconnect. Probing therefore only ever backs off.
const int kProbeStreamChunk = 231;

/// Discovers the largest KS_FRAME chunk the link actually accepts.
///
/// Android learns the usable size from the negotiated ATT MTU. Windows cannot:
/// the flutter_blue_plus WinRT plugin never populates the GATT session map its
/// `requestMtu` handler looks in, and never subscribes to `MaxPduSizeChanged`,
/// so no MTU is ever reported and the link would be pinned to a 7-byte chunk.
///
/// So the size is discovered instead of asked for: start optimistic, halve on
/// each rejected write, and stop probing once a write is accepted. After that
/// the size is confirmed — later failures are link problems (disconnect,
/// congestion), not size problems, and must not degrade chunking.
class BleChunkCalibrator {
  BleChunkCalibrator({required int initial, this.minimum = kMinStreamChunk})
      : _initial = initial < minimum ? minimum : initial,
        _chunkSize = initial < minimum ? minimum : initial;

  /// Never probe below this size.
  final int minimum;

  int _initial;
  int _chunkSize;
  bool _confirmed = false;

  /// The chunk size to use for the next write.
  int get chunkSize => _chunkSize;

  /// Whether a write at the current size has been accepted by the link.
  bool get isConfirmed => _confirmed;

  /// Record that a write of [acceptedBytes] was accepted.
  ///
  /// Only a write that actually filled the current chunk confirms it. Control
  /// messages such as KS_OPEN are a dozen bytes and succeed on any link, so
  /// treating them as confirmation would lock in an untested size and silently
  /// disable backoff.
  void recordSuccess(int acceptedBytes) {
    if (acceptedBytes >= _chunkSize) _confirmed = true;
  }

  /// Record that a write was rejected.
  ///
  /// Returns true when the chunk was reduced, meaning the same payload is worth
  /// re-sending in smaller slices. Returns false when the size is already
  /// confirmed or already at [minimum], leaving the failure to the caller.
  bool recordRejection() {
    if (_confirmed || _chunkSize <= minimum) return false;
    final halved = _chunkSize ~/ 2;
    _chunkSize = halved < minimum ? minimum : halved;
    return true;
  }

  /// Start probing again, for a new connection.
  void reset({int? initial}) {
    if (initial != null) {
      _initial = initial < minimum ? minimum : initial;
    }
    _chunkSize = _initial;
    _confirmed = false;
  }
}
