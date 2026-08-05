import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_chunk_calibrator.dart';

void main() {
  test('starts at the optimistic size while unconfirmed', () {
    final calibrator = BleChunkCalibrator(initial: 231);

    expect(calibrator.chunkSize, 231);
    expect(calibrator.isConfirmed, isFalse);
  });

  test('halves the chunk on each rejection until a write is accepted', () {
    final calibrator = BleChunkCalibrator(initial: 231);

    expect(calibrator.recordRejection(), isTrue);
    expect(calibrator.chunkSize, 115);
    expect(calibrator.recordRejection(), isTrue);
    expect(calibrator.chunkSize, 57);

    calibrator.recordSuccess(57);
    expect(calibrator.isConfirmed, isTrue);
    expect(calibrator.chunkSize, 57);
  });

  test('a confirmed size never shrinks again', () {
    // Once the link has accepted a size, later write failures are link
    // problems (disconnect, congestion) and must not degrade the chunking.
    final calibrator = BleChunkCalibrator(initial: 231);
    calibrator.recordSuccess(231);

    expect(calibrator.recordRejection(), isFalse);
    expect(calibrator.chunkSize, 231);
  });

  test('a small accepted write proves nothing about the probed size', () {
    // KS_OPEN and KS_CLOSE are a dozen bytes and always succeed. Treating them
    // as confirmation would lock in an untested chunk and disable backoff.
    final calibrator = BleChunkCalibrator(initial: 231);

    calibrator.recordSuccess(12);

    expect(calibrator.isConfirmed, isFalse);
    expect(calibrator.recordRejection(), isTrue);
    expect(calibrator.chunkSize, 115);
  });

  test('only a write that fills the probed size confirms it', () {
    final calibrator = BleChunkCalibrator(initial: 231);

    calibrator.recordSuccess(230);
    expect(calibrator.isConfirmed, isFalse);

    calibrator.recordSuccess(231);
    expect(calibrator.isConfirmed, isTrue);
  });

  test('stops at the floor implied by the 23-byte ATT MTU', () {
    final calibrator = BleChunkCalibrator(initial: 231);

    while (calibrator.recordRejection()) {
      expect(calibrator.chunkSize, greaterThanOrEqualTo(kMinStreamChunk));
    }

    expect(calibrator.chunkSize, kMinStreamChunk);
    expect(calibrator.recordRejection(), isFalse);
  });

  test('an initial at or below the floor cannot shrink', () {
    final calibrator = BleChunkCalibrator(initial: kMinStreamChunk);

    expect(calibrator.chunkSize, kMinStreamChunk);
    expect(calibrator.recordRejection(), isFalse);
  });

  test('an initial below the floor is raised to it', () {
    final calibrator = BleChunkCalibrator(initial: 1);

    expect(calibrator.chunkSize, kMinStreamChunk);
  });

  test('reset restarts probing for a new connection', () {
    final calibrator = BleChunkCalibrator(initial: 231);
    calibrator.recordRejection();
    calibrator.recordSuccess(115);

    calibrator.reset(initial: 501);

    expect(calibrator.chunkSize, 501);
    expect(calibrator.isConfirmed, isFalse);
    expect(calibrator.recordRejection(), isTrue);
    expect(calibrator.chunkSize, 250);
  });

  test('reset without an initial reuses the previous optimistic size', () {
    final calibrator = BleChunkCalibrator(initial: 231);
    calibrator.recordRejection();

    calibrator.reset();

    expect(calibrator.chunkSize, 231);
    expect(calibrator.isConfirmed, isFalse);
  });
}
