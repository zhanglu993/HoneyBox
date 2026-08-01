import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/pages/watch/health/watch_health_data.dart';
import 'package:honeybox/pages/watch/health/watch_health_provider.dart';

import '../helpers/watch_health_fixture.dart';

class _Repository implements WatchHealthRepository {
  _Repository({required this.result, this.error});

  final WatchHealthSnapshot result;
  final Object? error;
  final List<String> requestedDeviceIds = [];

  @override
  Future<WatchHealthSnapshot> sync(String deviceId) async {
    requestedDeviceIds.add(deviceId);
    if (error != null) throw error!;
    return result;
  }
}

void main() {
  test('starts empty and stores a synchronized snapshot', () async {
    final repository = _Repository(result: watchHealthFixture());
    final notifier = WatchHealthNotifier(
      repository: repository,
      deviceId: 'watch-01',
    );

    expect(notifier.state.phase, WatchHealthSyncPhase.idle);
    expect(notifier.state.snapshot, isNull);

    final future = notifier.sync();
    expect(notifier.state.phase, WatchHealthSyncPhase.syncing);
    await future;

    expect(repository.requestedDeviceIds, ['watch-01']);
    expect(notifier.state.phase, WatchHealthSyncPhase.success);
    expect(notifier.state.snapshot?.steps, 1000);
    expect(notifier.state.errorMessage, isNull);
  });

  test('exposes a retryable failure without inventing data', () async {
    final repository = _Repository(
      result: watchHealthFixture(),
      error: StateError('transport unavailable'),
    );
    final notifier = WatchHealthNotifier(
      repository: repository,
      deviceId: 'watch-02',
    );

    await notifier.sync();

    expect(notifier.state.phase, WatchHealthSyncPhase.failure);
    expect(notifier.state.snapshot, isNull);
    expect(notifier.state.errorMessage, '健康数据同步失败，请重试');
  });

  test('changes trend period without synchronizing again', () async {
    final repository = _Repository(result: watchHealthFixture());
    final notifier = WatchHealthNotifier(
      repository: repository,
      deviceId: 'watch-03',
    );
    await notifier.sync();

    notifier.selectPeriod(WatchHealthPeriod.week);

    expect(notifier.state.period, WatchHealthPeriod.week);
    expect(notifier.state.trend?.summary, '日均 143 步');
    expect(repository.requestedDeviceIds, hasLength(1));
  });
}
