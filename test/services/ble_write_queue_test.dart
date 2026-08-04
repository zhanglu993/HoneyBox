import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_write_queue.dart';

void main() {
  test('writes run in FIFO order with no overlap', () async {
    final firstRelease = Completer<void>();
    final order = <int>[];
    var active = 0;
    var maxActive = 0;
    final queue = BleWriteQueue(onFatalError: (_, __) {});
    addTearDown(queue.dispose);

    Future<void> write(int value, [Future<void>? wait]) async {
      order.add(value);
      active++;
      maxActive = maxActive < active ? active : maxActive;
      if (wait != null) await wait;
      active--;
    }

    final first = queue.enqueue(() => write(1, firstRelease.future));
    final second = queue.enqueue(() => write(2));
    final third = queue.enqueue(() => write(3));

    expect(order, [1]);
    firstRelease.complete();
    await Future.wait([first, second, third]);

    expect(order, [1, 2, 3]);
    expect(maxActive, 1);
  });

  test('abort rejects active and pending writes then permits reuse', () async {
    final firstRelease = Completer<void>();
    final order = <int>[];
    final queue = BleWriteQueue(onFatalError: (_, __) {});
    addTearDown(queue.dispose);

    final active = queue.enqueue(() async {
      order.add(1);
      await firstRelease.future;
    });
    final pending = queue.enqueue(() async => order.add(2));
    expect(order, [1]);

    queue.abort(StateError('disconnect'));
    await expectLater(active, throwsStateError);
    await expectLater(pending, throwsStateError);

    firstRelease.complete();
    await queue.enqueue(() async => order.add(3));
    expect(order, [1, 3]);
  });

  test('active failure rejects all queued writes and reports one fatal error',
      () async {
    final fatal = <Object>[];
    final queue = BleWriteQueue(onFatalError: (error, _) => fatal.add(error));
    addTearDown(queue.dispose);

    final active = queue.enqueue(() async => throw StateError('write failed'));
    final pending = queue.enqueue(() async {});

    await expectLater(active, throwsStateError);
    await expectLater(pending, throwsStateError);
    expect(fatal, hasLength(1));
    expect(fatal.single, isA<StateError>());
  });

  test('late success after abort cannot start stale pending work', () async {
    final release = Completer<void>();
    final order = <int>[];
    final queue = BleWriteQueue(onFatalError: (_, __) {});
    addTearDown(queue.dispose);

    final active = queue.enqueue(() async {
      order.add(1);
      await release.future;
    });
    final pending = queue.enqueue(() async => order.add(2));
    queue.abort(StateError('disconnect'));
    await expectLater(active, throwsStateError);
    await expectLater(pending, throwsStateError);
    final current = queue.enqueue(() async => order.add(3));
    expect(order, [1]);

    release.complete();
    await current;
    expect(order, [1, 3]);
  });

  test('late error after abort is ignored and does not report a fatal error',
      () async {
    final release = Completer<void>();
    final fatal = <Object>[];
    final order = <int>[];
    final queue = BleWriteQueue(onFatalError: (error, _) => fatal.add(error));
    addTearDown(queue.dispose);

    final active = queue.enqueue(() async {
      await release.future;
      throw StateError('late failure');
    });
    final pending = queue.enqueue(() async {});
    queue.abort(StateError('disconnect'));
    await expectLater(active, throwsStateError);
    await expectLater(pending, throwsStateError);
    final current = queue.enqueue(() async {
      order.add(1);
    });
    expect(order, isEmpty);

    release.complete();
    await current;
    expect(fatal, isEmpty);
    expect(order, [1]);
  });

  test('dispose completes outstanding writes and rejects new writes', () async {
    final release = Completer<void>();
    final queue = BleWriteQueue(onFatalError: (_, __) {});

    final active = queue.enqueue(() => release.future);
    final pending = queue.enqueue(() async {});
    queue.dispose();

    await expectLater(active, throwsStateError);
    await expectLater(pending, throwsStateError);
    await expectLater(queue.enqueue(() async {}), throwsStateError);
    release.complete();
  });
}
