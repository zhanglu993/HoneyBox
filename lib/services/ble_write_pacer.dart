/// Header bytes each KS_FRAME chunk carries on air beyond its payload:
/// 3 bytes of ATT plus the 13-byte L2 + KS header.
const int kStreamWriteOverhead = 16;

/// Default rate the stream is paced to where the platform provides no write
/// backpressure.
///
/// Measured against this link: an acknowledged write round trip takes ~62 ms,
/// so the connection interval is ~60 ms. Pacing at 160 kbps put five packets
/// into each event and the device only credited a quarter to a half of them,
/// meaning the rest never made it on air. This default sits near the rate the
/// device was observed to actually credit; [resolveStreamPacingBitrate] allows
/// overriding it while the right value is being measured.
const int kStreamPacingBitrate = 60000;

/// Environment variable that overrides [kStreamPacingBitrate] at runtime, so a
/// value can be measured on real hardware without a rebuild.
const String kStreamPacingEnvironmentKey = 'HONEYBOX_STREAM_PACING_BPS';

/// Reads the pacing rate from [environment], falling back to the default.
///
/// A value of `0` disables pacing entirely, which is how the unpaced behaviour
/// can be compared against a paced one on the same build.
int resolveStreamPacingBitrate(Map<String, String> environment) {
  final raw = environment[kStreamPacingEnvironmentKey];
  if (raw == null) return kStreamPacingBitrate;
  final parsed = int.tryParse(raw.trim());
  if (parsed == null || parsed < 0) return kStreamPacingBitrate;
  return parsed;
}

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
