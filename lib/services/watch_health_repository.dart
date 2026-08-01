import 'dart:async';
import 'dart:typed_data';

import '../pages/watch/health/watch_health_data.dart';
import 'watch_health_protocol.dart';

typedef WatchHealthCommandAvailable = bool Function();
typedef WatchHealthSendCommand = int? Function(Uint8List frame);
typedef WatchHealthClock = DateTime Function();

class WatchHealthSyncException implements Exception {
  const WatchHealthSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WatchHealthBleRepository implements WatchHealthRepository {
  WatchHealthBleRepository({
    required WatchHealthCommandAvailable commandAvailable,
    required WatchHealthSendCommand sendCommand,
    required Stream<Uint8List> notifications,
    this.timeout = const Duration(seconds: 8),
    WatchHealthClock clock = DateTime.now,
  })  : _commandAvailable = commandAvailable,
        _sendCommand = sendCommand,
        _notifications = notifications,
        _clock = clock;

  final WatchHealthCommandAvailable _commandAvailable;
  final WatchHealthSendCommand _sendCommand;
  final Stream<Uint8List> _notifications;
  final WatchHealthClock _clock;
  final Duration timeout;

  bool _syncing = false;

  @override
  Future<WatchHealthSnapshot> sync(String deviceId) async {
    if (_syncing) {
      throw const WatchHealthSyncException('Health synchronization is busy');
    }
    if (!_commandAvailable()) {
      throw const WatchHealthSyncException('Watch command channel unavailable');
    }

    _syncing = true;
    final completer = Completer<WatchHealthSnapshot>();
    final sports = <WatchSportRecord>[];
    final sleeps = <WatchSleepRecord>[];
    final heartRates = <WatchHeartRateRecord>[];
    StreamSubscription<Uint8List>? subscription;
    Timer? timer;
    var started = false;

    void finishError(Object error, [StackTrace? stackTrace]) {
      if (completer.isCompleted) return;
      timer?.cancel();
      if (stackTrace == null) {
        completer.completeError(error);
      } else {
        completer.completeError(error, stackTrace);
      }
    }

    void resetTimeout() {
      timer?.cancel();
      timer = Timer(timeout, () {
        finishError(TimeoutException('Watch health synchronization timed out'));
      });
    }

    bool sendRequest() {
      if (!_commandAvailable()) return false;
      try {
        return _sendCommand(WatchHealthProtocol.buildRequest()) != null;
      } catch (_) {
        return false;
      }
    }

    subscription = _notifications.listen((frame) {
      if (completer.isCompleted) return;
      try {
        final events = WatchHealthProtocol.parseFrame(frame);
        if (events.isEmpty) return;
        resetTimeout();
        for (final event in events) {
          if (event == WatchHealthMarker.syncStart) {
            started = true;
            sports.clear();
            sleeps.clear();
            heartRates.clear();
          } else if (!started) {
            continue;
          } else if (event is WatchSportData) {
            sports.addAll(event.items.map((item) => WatchSportRecord(
                  date: event.date,
                  offset: item.offset,
                  mode: item.mode,
                  steps: item.steps,
                  activeMinutes: item.activeMinutes,
                  caloriesMilliKcal: item.caloriesMilliKcal,
                  distanceMeters: item.distanceMeters,
                )));
          } else if (event is WatchSleepData) {
            sleeps.addAll(event.items.map((item) => WatchSleepRecord(
                  date: event.date,
                  minutes: item.minutes,
                  mode: item.mode,
                )));
          } else if (event is WatchHeartRateData) {
            heartRates.addAll(event.items.map((item) => WatchHeartRateRecord(
                  date: event.date,
                  seconds: item.seconds,
                  bpm: item.bpm,
                )));
          } else if (event == WatchHealthMarker.more) {
            if (!sendRequest()) {
              finishError(const WatchHealthSyncException(
                'Failed to request the next health data batch',
              ));
              return;
            }
          } else if (event == WatchHealthMarker.syncEnd) {
            timer?.cancel();
            completer.complete(WatchHealthSnapshot.fromRecords(
              syncedAt: _clock(),
              sportRecords: sports,
              sleepRecords: sleeps,
              heartRateRecords: heartRates,
            ));
            return;
          }
        }
      } catch (error, stackTrace) {
        finishError(error, stackTrace);
      }
    }, onError: finishError);

    if (!sendRequest()) {
      finishError(const WatchHealthSyncException(
        'Failed to send the health data request',
      ));
    } else {
      resetTimeout();
    }

    try {
      return await completer.future;
    } finally {
      timer?.cancel();
      await subscription.cancel();
      _syncing = false;
    }
  }
}
