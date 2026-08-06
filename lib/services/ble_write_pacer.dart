/// Header bytes each KS_FRAME chunk carries on air beyond its payload:
/// 3 bytes of ATT plus the 13-byte L2 + KS header.
const int kStreamWriteOverhead = 16;

/// Rate the stream is paced to where the platform provides no write
/// backpressure.
///
/// The link measures a ~60 ms connection interval, and BLE carries several
/// packets per event, so roughly 160 kbps is what the radio sustains. That
/// also clears the 150 kbps the encoder is configured for, leaving the device's
/// credit window as the real limiter rather than the controller's buffer.
const int kStreamPacingBitrate = 160000;

/// Spacing that lets [chunkBytes] of payload flow at [bitsPerSecond].
///
/// Returns [Duration.zero] for inputs that cannot describe a rate, which
/// disables pacing rather than stalling the stream.
Duration spacingForBitrate({
  required int chunkBytes,
  required int bitsPerSecond,
}) {
  if (chunkBytes <= 0 || bitsPerSecond <= 0) return Duration.zero;
  final onAirBits = (chunkBytes + kStreamWriteOverhead) * 8;
  return Duration(
    microseconds: (onAirBits * 1000000 / bitsPerSecond).round(),
  );
}

/// Keeps a minimum spacing between stream writes.
///
/// Android's BLE stack paces unacknowledged writes for the caller: its write
/// callback only returns once the controller has room. Windows accepts them
/// into a buffer in about 1.5 ms regardless, so a whole 57-chunk key frame is
/// handed to the controller in under 100 ms — far more than a 60 ms connection
/// event can carry. The excess is dropped without an error and the device never
/// assembles the frame. Spacing the writes ourselves restores the backpressure
/// the platform does not provide.
///
/// Timestamps come from a monotonic clock the caller owns, so this stays pure
/// and testable.
class BleWritePacer {
  BleWritePacer({required this.minSpacing});

  /// Minimum gap between two consecutive writes. Zero disables pacing.
  final Duration minSpacing;

  Duration? _lastWrite;

  /// How long to wait before starting a write at [now].
  Duration delayBefore(Duration now) {
    final last = _lastWrite;
    if (minSpacing <= Duration.zero || last == null) return Duration.zero;
    final waited = now - last;
    // A clock that went backwards carries no usable information; never turn
    // that into a longer stall.
    if (waited.isNegative || waited >= minSpacing) return Duration.zero;
    return minSpacing - waited;
  }

  /// Record that a write started at [now].
  void recordWrite(Duration now) => _lastWrite = now;

  /// Forget the previous link's timing.
  void reset() => _lastWrite = null;
}
