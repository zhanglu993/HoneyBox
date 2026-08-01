import 'package:honeybox/pages/watch/health/watch_health_data.dart';

WatchHealthSnapshot watchHealthFixture() => WatchHealthSnapshot.fromRecords(
      syncedAt: DateTime(2026, 7, 30, 12),
      sportRecords: [
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
        WatchSleepRecord(
          date: DateTime(2026, 7, 29),
          minutes: 1380,
          mode: 1,
        ),
        WatchSleepRecord(
          date: DateTime(2026, 7, 30),
          minutes: 60,
          mode: 2,
        ),
        WatchSleepRecord(
          date: DateTime(2026, 7, 30),
          minutes: 180,
          mode: 3,
        ),
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
