import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/ble_provider.dart';
import '../../../services/watch_health_repository.dart';
import 'watch_health_data.dart';

enum WatchHealthSyncPhase { idle, syncing, success, failure }

class WatchHealthState {
  final WatchHealthSyncPhase phase;
  final WatchHealthPeriod period;
  final WatchHealthSnapshot? snapshot;
  final String? errorMessage;

  const WatchHealthState({
    this.phase = WatchHealthSyncPhase.idle,
    this.period = WatchHealthPeriod.day,
    this.snapshot,
    this.errorMessage,
  });

  WatchHealthTrend? get trend => snapshot?.trend(period);

  WatchHealthState copyWith({
    WatchHealthSyncPhase? phase,
    WatchHealthPeriod? period,
    WatchHealthSnapshot? snapshot,
    String? errorMessage,
    bool clearError = false,
  }) {
    return WatchHealthState(
      phase: phase ?? this.phase,
      period: period ?? this.period,
      snapshot: snapshot ?? this.snapshot,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class WatchHealthNotifier extends StateNotifier<WatchHealthState> {
  WatchHealthNotifier({
    required WatchHealthRepository repository,
    required String deviceId,
  })  : _repository = repository,
        _deviceId = deviceId,
        super(const WatchHealthState());

  final WatchHealthRepository _repository;
  final String _deviceId;

  Future<void> sync() async {
    if (state.phase == WatchHealthSyncPhase.syncing) return;
    state = state.copyWith(
      phase: WatchHealthSyncPhase.syncing,
      clearError: true,
    );
    try {
      final snapshot = await _repository.sync(_deviceId);
      state = state.copyWith(
        phase: WatchHealthSyncPhase.success,
        snapshot: snapshot,
        clearError: true,
      );
    } catch (_) {
      state = state.copyWith(
        phase: WatchHealthSyncPhase.failure,
        errorMessage: '健康数据同步失败，请重试',
      );
    }
  }

  void selectPeriod(WatchHealthPeriod period) {
    if (state.period == period) return;
    state = state.copyWith(period: period);
  }
}

final watchHealthRepositoryProvider = Provider<WatchHealthRepository>((ref) {
  final bleManager = ref.read(bleManagerProvider);
  return WatchHealthBleRepository(
    commandAvailable: () => bleManager.commandAvailable,
    sendCommand: bleManager.sendCommand,
    notifications: bleManager.commandNotifications,
  );
});

final watchHealthProvider = StateNotifierProvider.autoDispose
    .family<WatchHealthNotifier, WatchHealthState, String>((ref, deviceId) {
  return WatchHealthNotifier(
    repository: ref.watch(watchHealthRepositoryProvider),
    deviceId: deviceId,
  );
});
