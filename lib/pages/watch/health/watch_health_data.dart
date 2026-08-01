enum WatchHealthPeriod { day, week, month }

class WatchSportRecord {
  const WatchSportRecord({
    required this.date,
    required this.offset,
    required this.mode,
    required this.steps,
    required this.activeMinutes,
    required this.caloriesMilliKcal,
    required this.distanceMeters,
  });

  final DateTime date;
  final int offset;
  final int mode;
  final int steps;
  final int activeMinutes;
  final int caloriesMilliKcal;
  final int distanceMeters;

  DateTime get timestamp => date.add(Duration(minutes: offset * 15));
}

class WatchSleepRecord {
  const WatchSleepRecord({
    required this.date,
    required this.minutes,
    required this.mode,
  });

  final DateTime date;
  final int minutes;
  final int mode;

  DateTime get timestamp => date.add(Duration(minutes: minutes));
}

class WatchHeartRateRecord {
  const WatchHeartRateRecord({
    required this.date,
    required this.seconds,
    required this.bpm,
  });

  final DateTime date;
  final int seconds;
  final int bpm;

  DateTime get timestamp => date.add(Duration(seconds: seconds));
}

class WatchSleepStage {
  const WatchSleepStage({
    required this.mode,
    required this.name,
    required this.minutes,
  });

  final int mode;
  final String name;
  final int minutes;
}

class WatchHealthTrendPoint {
  const WatchHealthTrendPoint({
    required this.label,
    required this.steps,
    required this.heartRate,
  });

  final String label;
  final int steps;
  final int? heartRate;
}

class WatchHealthTrend {
  const WatchHealthTrend({
    required this.label,
    required this.summary,
    required this.points,
  });

  final String label;
  final String summary;
  final List<WatchHealthTrendPoint> points;
}

class WatchHealthSnapshot {
  WatchHealthSnapshot.fromRecords({
    required this.syncedAt,
    required List<WatchSportRecord> sportRecords,
    required List<WatchSleepRecord> sleepRecords,
    required List<WatchHeartRateRecord> heartRateRecords,
  })  : sportRecords = List.unmodifiable(sportRecords),
        sleepRecords = List.unmodifiable(sleepRecords),
        heartRateRecords = List.unmodifiable(heartRateRecords);

  final DateTime syncedAt;
  final List<WatchSportRecord> sportRecords;
  final List<WatchSleepRecord> sleepRecords;
  final List<WatchHeartRateRecord> heartRateRecords;

  DateTime get _today => DateTime(syncedAt.year, syncedAt.month, syncedAt.day);

  Iterable<WatchSportRecord> get _todaySport =>
      sportRecords.where((record) => _sameDate(record.date, _today));

  List<WatchHeartRateRecord> get _todayHeartRates => heartRateRecords
      .where((record) => _sameDate(record.date, _today) && record.bpm > 0)
      .toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  int get steps => _todaySport.fold(0, (sum, record) => sum + record.steps);

  int get distanceMeters =>
      _todaySport.fold(0, (sum, record) => sum + record.distanceMeters);

  double get caloriesKcal => _todaySport.fold(
        0,
        (sum, record) => sum + record.caloriesMilliKcal / 1000,
      );

  int get activeMinutes =>
      _todaySport.fold(0, (sum, record) => sum + record.activeMinutes);

  int? get latestHeartRate =>
      _todayHeartRates.isEmpty ? null : _todayHeartRates.last.bpm;

  int? get minimumHeartRate => _todayHeartRates.isEmpty
      ? null
      : _todayHeartRates.map((record) => record.bpm).reduce(_min);

  int? get maximumHeartRate => _todayHeartRates.isEmpty
      ? null
      : _todayHeartRates.map((record) => record.bpm).reduce(_max);

  List<WatchSleepStage> get sleepStages {
    final records = _sortedSleepRecords();
    final totals = <int, int>{};
    for (var i = 0; i + 1 < records.length; i++) {
      final current = records[i];
      final duration = records[i + 1].timestamp.difference(current.timestamp);
      if ((current.mode == 1 || current.mode == 2) && duration.inMinutes > 0) {
        totals.update(
          current.mode,
          (value) => value + duration.inMinutes,
          ifAbsent: () => duration.inMinutes,
        );
      }
    }
    return [
      if ((totals[1] ?? 0) > 0)
        WatchSleepStage(mode: 1, name: '深睡', minutes: totals[1]!),
      if ((totals[2] ?? 0) > 0)
        WatchSleepStage(mode: 2, name: '浅睡', minutes: totals[2]!),
    ];
  }

  int get sleepMinutes =>
      sleepStages.fold(0, (sum, stage) => sum + stage.minutes);

  String? get sleepRange {
    final records = _sortedSleepRecords();
    final startIndex =
        records.indexWhere((record) => record.mode == 1 || record.mode == 2);
    if (startIndex < 0) return null;
    final endIndex = records.indexWhere(
      (record) => record.mode == 3,
      startIndex + 1,
    );
    if (endIndex < 0) return null;
    return '${_time(records[startIndex].timestamp)} - ${_time(records[endIndex].timestamp)}';
  }

  WatchHealthTrend trend(WatchHealthPeriod period) {
    return switch (period) {
      WatchHealthPeriod.day => _dayTrend(),
      WatchHealthPeriod.week => _dailyTrend(7, '近 7 天'),
      WatchHealthPeriod.month => _dailyTrend(30, '近 30 天'),
    };
  }

  WatchHealthTrend _dayTrend() {
    final points = <WatchHealthTrendPoint>[];
    for (var slot = 0; slot < 6; slot++) {
      final startHour = slot * 4;
      final endHour = startHour + 4;
      final steps = _todaySport
          .where((record) =>
              record.offset >= startHour * 4 && record.offset < endHour * 4)
          .fold(0, (sum, record) => sum + record.steps);
      final heartRates = _todayHeartRates
          .where((record) =>
              record.timestamp.hour >= startHour &&
              record.timestamp.hour < endHour)
          .map((record) => record.bpm)
          .toList();
      points.add(WatchHealthTrendPoint(
        label: '$startHour时',
        steps: steps,
        heartRate: _average(heartRates),
      ));
    }
    return WatchHealthTrend(
      label: '今天 · 分时趋势',
      summary: '今日累计 ${_number(steps)} 步',
      points: List.unmodifiable(points),
    );
  }

  WatchHealthTrend _dailyTrend(int days, String label) {
    final firstDay = _today.subtract(Duration(days: days - 1));
    final points = <WatchHealthTrendPoint>[];
    for (var i = 0; i < days; i++) {
      final date = firstDay.add(Duration(days: i));
      final daySteps = sportRecords
          .where((record) => _sameDate(record.date, date))
          .fold(0, (sum, record) => sum + record.steps);
      final heartRates = heartRateRecords
          .where((record) => _sameDate(record.date, date) && record.bpm > 0)
          .map((record) => record.bpm)
          .toList();
      points.add(WatchHealthTrendPoint(
        label: '${date.month}/${date.day}',
        steps: daySteps,
        heartRate: _average(heartRates),
      ));
    }
    final totalSteps = points.fold(0, (sum, point) => sum + point.steps);
    return WatchHealthTrend(
      label: label,
      summary: '日均 ${_number((totalSteps / days).round())} 步',
      points: List.unmodifiable(points),
    );
  }

  List<WatchSleepRecord> _sortedSleepRecords() =>
      [...sleepRecords]..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static int _min(int a, int b) => a < b ? a : b;
  static int _max(int a, int b) => a > b ? a : b;

  static int? _average(List<int> values) => values.isEmpty
      ? null
      : (values.reduce((a, b) => a + b) / values.length).round();

  static String _time(DateTime date) =>
      '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

  static String _number(int value) {
    final text = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
      buffer.write(text[i]);
    }
    return buffer.toString();
  }
}

abstract interface class WatchHealthRepository {
  Future<WatchHealthSnapshot> sync(String deviceId);
}
