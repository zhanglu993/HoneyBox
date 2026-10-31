import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ota/ota_progress.dart';

void main() {
  test('multi-image progress is clamped and never decreases', () {
    final tracker = OtaProgressTracker();
    expect(
        tracker.update(imageIndex: 0, imageCount: 2, currentPercent: 50), .25);
    expect(
        tracker.update(imageIndex: 1, imageCount: 2, currentPercent: 20), .6);
    expect(
        tracker.update(imageIndex: 0, imageCount: 2, currentPercent: 100), .6);
    expect(tracker.update(overallProgress: 20), .6);
    expect(tracker.update(overallProgress: 120), 1);
    expect(tracker.update(currentPercent: -10, imageCount: 0), 1);
  });
}
