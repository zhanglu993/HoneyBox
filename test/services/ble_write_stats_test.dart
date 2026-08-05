import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_write_stats.dart';

void main() {
  test('stays quiet until a window closes', () {
    final stats = BleWriteStats(reportEvery: 3);

    expect(
      stats.record(bytes: 244, elapsed: const Duration(milliseconds: 30)),
      isNull,
    );
    expect(
      stats.record(bytes: 244, elapsed: const Duration(milliseconds: 30)),
      isNull,
    );
    expect(
      stats.record(bytes: 244, elapsed: const Duration(milliseconds: 30)),
      isNotNull,
    );
  });

  test('reports write count, mean and max latency, and throughput', () {
    final stats = BleWriteStats(reportEvery: 2);
    stats.record(bytes: 244, elapsed: const Duration(milliseconds: 20));

    final report =
        stats.record(bytes: 244, elapsed: const Duration(milliseconds: 40));

    // 488 bytes over 60ms = 65066 bps.
    expect(report, contains('writes=2'));
    expect(report, contains('bytes=488'));
    expect(report, contains('mean=30.0ms'));
    expect(report, contains('max=40.0ms'));
    expect(report, contains('65 kbps'));
  });

  test('each window measures only its own writes', () {
    final stats = BleWriteStats(reportEvery: 2);
    stats.record(bytes: 100, elapsed: const Duration(milliseconds: 90));
    stats.record(bytes: 100, elapsed: const Duration(milliseconds: 90));

    stats.record(bytes: 244, elapsed: const Duration(milliseconds: 10));
    final second =
        stats.record(bytes: 244, elapsed: const Duration(milliseconds: 10));

    expect(second, contains('mean=10.0ms'));
    expect(second, contains('max=10.0ms'));
  });

  test('a zero-duration window reports no throughput instead of dividing by zero',
      () {
    final stats = BleWriteStats(reportEvery: 1);

    final report = stats.record(bytes: 244, elapsed: Duration.zero);

    expect(report, contains('writes=1'));
    expect(report, isNot(contains('Infinity')));
    expect(report, isNot(contains('NaN')));
  });

  test('reset drops a partial window', () {
    final stats = BleWriteStats(reportEvery: 2);
    stats.record(bytes: 244, elapsed: const Duration(milliseconds: 10));

    stats.reset();

    expect(
      stats.record(bytes: 244, elapsed: const Duration(milliseconds: 10)),
      isNull,
    );
  });
}
