import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/media_task_gate.dart';

void main() {
  test('interactive work overtakes queued background work without overlap',
      () async {
    final gate = MediaTaskGate();
    addTearDown(gate.dispose);
    final firstRelease = Completer<void>();
    final started = <String>[];
    var active = 0;
    var maxActive = 0;

    Future<void> record(String name, [Future<void>? wait]) async {
      started.add(name);
      active++;
      if (active > maxActive) maxActive = active;
      if (wait != null) await wait;
      active--;
    }

    final first = gate.run(
      () => record('background-1', firstRelease.future),
      priority: MediaTaskPriority.background,
    );
    await Future<void>.delayed(Duration.zero);
    final second = gate.run(
      () => record('background-2'),
      priority: MediaTaskPriority.background,
    );
    final interactive = gate.run(
      () => record('interactive'),
      priority: MediaTaskPriority.interactive,
    );

    expect(started, ['background-1']);
    firstRelease.complete();
    await Future.wait([first, second, interactive]);

    expect(started, ['background-1', 'interactive', 'background-2']);
    expect(maxActive, 1);
  });

  test('task failure releases the single slot for the next task', () async {
    final gate = MediaTaskGate();
    addTearDown(gate.dispose);
    final started = <String>[];

    final failed = gate.run<void>(() async {
      started.add('failed');
      throw StateError('boom');
    });
    final next = gate.run<void>(() async {
      started.add('next');
    });

    await expectLater(failed, throwsStateError);
    await next;
    expect(started, ['failed', 'next']);
  });

  test('dispose rejects queued tasks without starting them', () async {
    final gate = MediaTaskGate();
    final release = Completer<void>();
    var queuedStarted = false;

    final active = gate.run(() => release.future);
    await Future<void>.delayed(Duration.zero);
    final queued = gate.run<void>(() async {
      queuedStarted = true;
    });

    gate.dispose();
    await expectLater(queued, throwsStateError);
    expect(queuedStarted, isFalse);

    release.complete();
    await active;
    gate.dispose();
  });
  test('cancelled queued work is rejected before task starts', () async {
    final gate = MediaTaskGate();
    addTearDown(gate.dispose);
    final release = Completer<void>();
    var shouldStart = true;
    var queuedStarted = false;

    final active = gate.run(() => release.future);
    await Future<void>.delayed(Duration.zero);
    final queued = gate.run<void>(
      () async => queuedStarted = true,
      shouldStart: () => shouldStart,
    );

    shouldStart = false;
    release.complete();
    await active;

    await expectLater(queued, throwsA(isA<MediaTaskCancelled>()));
    expect(queuedStarted, isFalse);
  });
}
