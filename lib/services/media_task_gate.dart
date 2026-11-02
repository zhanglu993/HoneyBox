import 'dart:async';
import 'dart:collection';

enum MediaTaskPriority { interactive, background }

class MediaTaskGate {
  final Queue<_QueuedMediaTask> _interactive = Queue<_QueuedMediaTask>();
  final Queue<_QueuedMediaTask> _background = Queue<_QueuedMediaTask>();
  bool _active = false;
  bool _disposed = false;

  Future<T> run<T>(
    Future<T> Function() task, {
    MediaTaskPriority priority = MediaTaskPriority.interactive,
    bool Function()? shouldStart,
  }) {
    if (_disposed) {
      return Future<T>.error(StateError('MediaTaskGate has been disposed'));
    }

    final completer = Completer<T>();
    final queued = _QueuedMediaTask(
      run: () async {
        try {
          if (shouldStart != null && !shouldStart()) {
            throw const MediaTaskCancelled();
          }
          final result = await task();
          if (!completer.isCompleted) completer.complete(result);
        } catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
      reject: (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    switch (priority) {
      case MediaTaskPriority.interactive:
        _interactive.addLast(queued);
      case MediaTaskPriority.background:
        _background.addLast(queued);
    }
    _pump();
    return completer.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final error = StateError('MediaTaskGate has been disposed');
    final stackTrace = StackTrace.current;
    while (_interactive.isNotEmpty) {
      _interactive.removeFirst().reject(error, stackTrace);
    }
    while (_background.isNotEmpty) {
      _background.removeFirst().reject(error, stackTrace);
    }
  }

  void _pump() {
    if (_disposed || _active) return;

    final _QueuedMediaTask? next;
    if (_interactive.isNotEmpty) {
      next = _interactive.removeFirst();
    } else if (_background.isNotEmpty) {
      next = _background.removeFirst();
    } else {
      next = null;
    }
    if (next == null) return;

    _active = true;
    unawaited(_execute(next));
  }

  Future<void> _execute(_QueuedMediaTask task) async {
    try {
      await task.run();
    } finally {
      _active = false;
      _pump();
    }
  }
}

class _QueuedMediaTask {
  const _QueuedMediaTask({required this.run, required this.reject});

  final Future<void> Function() run;
  final void Function(Object error, StackTrace stackTrace) reject;
}

class MediaTaskCancelled implements Exception {
  const MediaTaskCancelled();

  @override
  String toString() => 'Media task cancelled before start';
}
