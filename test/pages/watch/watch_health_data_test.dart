import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/watch/health/watch_health_data.dart';

void main() {
  final snapshot = WatchHealthSnapshot.fromRecords(
    syncedAt: DateTime(2026, 7, 30, 12),
    sportRecords: [
      WatchSportRecord(
        date: DateTime(2026, 7, 29),
        offset: 80,
        mode: 1,
        steps: 900,
        activeMinutes: 12,
        caloriesMilliKcal: 20000,
        distanceMeters: 700,
      ),
      WatchSportRecord(
        date: DateTime(2026, 7, 30),
        offset: 32,
        mode: 1,
        steps: 600,
        activeMinutes: 10,
        caloriesMilliKcal: 12500,
        distanceMeters: 420,
      ),
      WatchSportRecord(
        date: DateTime(2026, 7, 30),
        offset: 33,
        mode: 2,
        steps: 400,
        activeMinutes: 8,
        caloriesMilliKcal: 7500,
        distanceMeters: 280,
      ),
    ],
    sleepRecords: [
      WatchSleepRecord(date: DateTime(2026, 7, 29), minutes: 1380, mode: 1),
      WatchSleepRecord(date: DateTime(2026, 7, 30), minutes: 60, mode: 2),
      WatchSleepRecord(date: DateTime(2026, 7, 30), minutes: 180, mode: 3),
    ],
    heartRateRecords: [
      WatchHeartRateRecord(
        date: DateTime(2026, 7, 30),
        seconds: 36000,
        bpm: 72,
      ),
      WatchHeartRateRecord(
        date: DateTime(2026, 7, 30),
        seconds: 36600,
        bpm: 78,
      ),
    ],
  );

  test('computes today metrics from actual records', () {
    expect(snapshot.steps, 1000);
    expect(snapshot.distanceMeters, 700);
    expect(snapshot.caloriesKcal, 20);
    expect(snapshot.activeMinutes, 18);
    expect(snapshot.latestHeartRate, 78);
    expect(snapshot.minimumHeartRate, 72);
    expect(snapshot.maximumHeartRate, 78);
  });

  test('computes sleep stages from state transitions', () {
    expect(snapshot.sleepMinutes, 240);
    expect(snapshot.sleepRange, '23:00 - 03:00');
    expect(
      snapshot.sleepStages.map((stage) => (stage.mode, stage.minutes)).toList(),
      [(1, 120), (2, 120)],
    );
  });

  test('aggregates real records for week trends', () {
    final trend = snapshot.trend(WatchHealthPeriod.week);

    expect(
        trend.points.map((point) => point.steps).reduce((a, b) => a + b), 1900);
    expect(trend.points.last.heartRate, 75);
    expect(trend.points.where((point) => point.steps > 0), hasLength(2));
  });

  test('exposes null values instead of inventing unavailable data', () {
    final empty = WatchHealthSnapshot.fromRecords(
      syncedAt: DateTime(2026, 7, 30),
      sportRecords: const [],
      sleepRecords: const [],
      heartRateRecords: const [],
    );

    expect(empty.latestHeartRate, isNull);
    expect(empty.minimumHeartRate, isNull);
    expect(empty.sleepRange, isNull);
    expect(empty.trend(WatchHealthPeriod.day).points, isNotEmpty);
  });
}
