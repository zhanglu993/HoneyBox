import 'dart:async';

typedef BleWriteOperation = Future<void> Function();

class _BleWriteEntry {
  _BleWriteEntry(this.generation, this.operation);

  final int generation;
  final BleWriteOperation operation;
  final Completer<void> done = Completer<void>();
}

/// Serializes GATT writes and invalidates outstanding work after a disconnect.
class BleWriteQueue {
  BleWriteQueue({required this.onFatalError});

  final void Function(Object, StackTrace) onFatalError;
  final List<_BleWriteEntry> _pending = [];
  _BleWriteEntry? _active;
  int _generation = 0;
  bool _running = false;
  bool _disposed = false;

  Future<void> enqueue(BleWriteOperation operation) {
    if (_disposed) {
      return Future<void>.error(StateError('queue disposed'));
    }

    final entry = _BleWriteEntry(_generation, operation);
    _pending.add(entry);
    _flush();
    return entry.done.future;
  }

  void abort(Object error, [StackTrace? stackTrace]) {
    final failed = <_BleWriteEntry>[
      if (_active case final active?) active,
      ..._pending,
    ];
    _generation++;
    _active = null;
    _pending.clear();
    for (final entry in failed) {
      if (!entry.done.isCompleted) {
        entry.done.completeError(error, stackTrace);
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    abort(StateError('queue disposed'));
    _disposed = true;
  }

  void _flush() {
    if (_running || _disposed || _pending.isEmpty) return;

    final entry = _pending.removeAt(0);
    _active = entry;
    _running = true;
    unawaited(_run(entry));
  }

  Future<void> _run(_BleWriteEntry entry) async {
    try {
      await entry.operation();
    } catch (error, stackTrace) {
      if (entry.generation != _generation) {
        _releasePhysicalGate();
        return;
      }
      _fail(entry, error, stackTrace);
      return;
    }

    if (entry.generation != _generation) {
      _releasePhysicalGate();
      return;
    }
    if (!entry.done.isCompleted) entry.done.complete();
    _active = null;
    _running = false;
    _flush();
  }

  void _releasePhysicalGate() {
    _running = false;
    _flush();
  }

  void _fail(_BleWriteEntry entry, Object error, StackTrace stackTrace) {
    final failed = <_BleWriteEntry>[entry, ..._pending];
    _generation++;
    _active = null;
    _pending.clear();
    _running = false;
    for (final failedEntry in failed) {
      if (!failedEntry.done.isCompleted) {
        failedEntry.done.completeError(error, stackTrace);
      }
    }
    onFatalError(error, stackTrace);
  }
}
