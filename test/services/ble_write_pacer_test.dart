import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_write_pacer.dart';

void main() {
  test('the first write is never delayed', () {
    final pacer = BleWritePacer(minSpacing: const Duration(milliseconds: 12));

    expect(pacer.delayBefore(const Duration(microseconds: 1000)), Duration.zero);
  });

  test('a write that arrived too soon waits out the remaining spacing', () {
    final pacer = BleWritePacer(minSpacing: const Duration(milliseconds: 12));
    pacer.recordWrite(Duration.zero);

    expect(pacer.delayBefore(const Duration(milliseconds: 2)),
        const Duration(milliseconds: 10));
  });

  test('a write that already waited long enough is not delayed', () {
    final pacer = BleWritePacer(minSpacing: const Duration(milliseconds: 12));
    pacer.recordWrite(Duration.zero);

    expect(pacer.delayBefore(const Duration(milliseconds: 12)), Duration.zero);
    expect(pacer.delayBefore(const Duration(milliseconds: 40)), Duration.zero);
  });

  test('spacing is measured from the previous write, not from the first', () {
    final pacer = BleWritePacer(minSpacing: const Duration(milliseconds: 12));
    pacer.recordWrite(Duration.zero);
    pacer.recordWrite(const Duration(milliseconds: 12));

    expect(pacer.delayBefore(const Duration(milliseconds: 14)),
        const Duration(milliseconds: 10));
  });

  test('zero spacing disables pacing entirely', () {
    final pacer = BleWritePacer(minSpacing: Duration.zero);
    pacer.recordWrite(Duration.zero);

    expect(pacer.delayBefore(Duration.zero), Duration.zero);
  });

  test('reset forgets the previous link', () {
    final pacer = BleWritePacer(minSpacing: const Duration(milliseconds: 12));
    pacer.recordWrite(const Duration(milliseconds: 500));

    pacer.reset();

    // A fresh connection starts its own clock instead of inheriting a stale
    // timestamp that would either stall or skip the first spacing.
    expect(pacer.delayBefore(Duration.zero), Duration.zero);
  });

  test('a clock that moved backwards does not produce a negative delay', () {
    final pacer = BleWritePacer(minSpacing: const Duration(milliseconds: 12));
    pacer.recordWrite(const Duration(milliseconds: 100));

    expect(pacer.delayBefore(const Duration(milliseconds: 90)), Duration.zero);
  });

  group('spacingForBitrate', () {
    test('derives spacing from the payload size and target bitrate', () {
      // 231 payload + 16 header = 247 bytes on air; at 160 kbps that is one
      // packet every 12.35 ms.
      expect(spacingForBitrate(chunkBytes: 231, bitsPerSecond: 160000),
          const Duration(microseconds: 12350));
    });

    test('a faster target packs writes closer together', () {
      final fast = spacingForBitrate(chunkBytes: 231, bitsPerSecond: 320000);
      final slow = spacingForBitrate(chunkBytes: 231, bitsPerSecond: 160000);

      expect(fast, lessThan(slow));
    });

    test('nonsense inputs disable pacing instead of stalling the stream', () {
      expect(spacingForBitrate(chunkBytes: 0, bitsPerSecond: 160000),
          Duration.zero);
      expect(spacingForBitrate(chunkBytes: 231, bitsPerSecond: 0),
          Duration.zero);
      expect(spacingForBitrate(chunkBytes: -1, bitsPerSecond: -1),
          Duration.zero);
    });
  });
}
