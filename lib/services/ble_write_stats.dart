/// Rolling latency and throughput accounting for one characteristic's writes.
///
/// The write queue is strictly serial, so each write's wall time is the link's
/// per-packet cost. Sampling it says directly how many packets the controller
/// pushes per connection event, which is what decides whether the projection
/// stream can keep up.
class BleWriteStats {
  BleWriteStats({this.reportEvery = 50})
      : assert(reportEvery > 0, 'a window needs at least one write');

  /// Writes per reporting window.
  final int reportEvery;

  int _writes = 0;
  int _bytes = 0;
  int _elapsedMicroseconds = 0;
  int _maxMicroseconds = 0;

  /// Record one completed write. Returns a one-line report when the window
  /// closes, otherwise null.
  String? record({required int bytes, required Duration elapsed}) {
    _writes++;
    _bytes += bytes;
    _elapsedMicroseconds += elapsed.inMicroseconds;
    if (elapsed.inMicroseconds > _maxMicroseconds) {
      _maxMicroseconds = elapsed.inMicroseconds;
    }
    if (_writes < reportEvery) return null;

    final meanMs = _elapsedMicroseconds / _writes / 1000.0;
    final maxMs = _maxMicroseconds / 1000.0;
    final seconds = _elapsedMicroseconds / 1000000.0;
    final throughput = seconds > 0
        ? '${(_bytes * 8 / seconds / 1000).round()} kbps'
        : 'n/a';
    final report = 'writes=$_writes bytes=$_bytes '
        'mean=${meanMs.toStringAsFixed(1)}ms '
        'max=${maxMs.toStringAsFixed(1)}ms → $throughput';
    reset();
    return report;
  }

  /// Drop the current partial window.
  void reset() {
    _writes = 0;
    _bytes = 0;
    _elapsedMicroseconds = 0;
    _maxMicroseconds = 0;
  }
}
