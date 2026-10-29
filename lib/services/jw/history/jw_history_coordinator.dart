import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';
import '../jw_codec.dart';
import '../jw_protocol.dart';
import '../jw_session.dart';
import '../jw_models.dart';
import 'jw_history_decoder.dart';
import 'jw_history_models.dart';
import 'jw_history_store.dart';

const _types = <int, JwHistoryType>{
  2: JwHistoryType.steps,
  3: JwHistoryType.sleep,
  0x1b: JwHistoryType.heartTemperature,
  0x29: JwHistoryType.heartTemperature,
  0x13: JwHistoryType.bloodPressure,
  0x16: JwHistoryType.exercise,
  0x2c: JwHistoryType.bloodOxygen,
  0x3c: JwHistoryType.hrv,
  0x5b: JwHistoryType.pressure,
  0x60: JwHistoryType.metabolism,
  0x64: JwHistoryType.readiness
};

// START type IDs from firmware T_HISTORY_DATA_TYPE.
const _startTypes = <int, JwHistoryType>{
  0: JwHistoryType.steps,
  1: JwHistoryType.sleep,
  2: JwHistoryType.heartTemperature,
  3: JwHistoryType.bloodPressure,
  4: JwHistoryType.exercise,
  5: JwHistoryType.bloodOxygen,
  6: JwHistoryType.hrv,
  0x0e: JwHistoryType.pressure,
  0x0f: JwHistoryType.metabolism,
  0x10: JwHistoryType.readiness,
};

class _Counts {
  int received = 0, persisted = 0, quarantined = 0;
  int? expected;
  final ids = <String>{};
  JwHistoryTypeStats snapshot() => JwHistoryTypeStats(
      received: received,
      uniqueInBatch: ids.length,
      newlyPersisted: persisted,
      deduplicated: received - persisted,
      quarantined: quarantined,
      expectedCount: expected);
}

class _RoundFailure implements Exception {
  final String stage, message;
  _RoundFailure(this.stage, this.message);
}

/// Owns a single serialized history round over the already validated session.
/// Notification listeners only admit bounded work; file IO never runs there.
class JwHistoryCoordinator {
  final JwSession session;
  final JwHistoryStore store;
  final String deviceKey;
  final JwCapabilities capabilities;
  final _progress = StreamController<JwHistoryProgress>.broadcast(sync: true);
  final _queue = Queue<(JwFrame, JwMessage)>();
  final _seenFrames = <int, String>{};
  final _counts = <JwHistoryType, _Counts>{};
  final _markers = <int>{}, _expectedMarkers = <int>{};
  StreamSubscription<JwFrame>? _frames;
  StreamSubscription<JwLinkException>? _failures;
  Timer? _idle, _total;
  Completer<void>? _wake;
  Future<JwHistoryResult>? _running;
  Future<void>? _closingLink;
  Object? _cleanupError;
  JwFrame? _diagnostic;
  _RoundFailure? _failure;
  JwHistoryOptions _options = const JwHistoryOptions();
  JwHistoryPhase _phase = JwHistoryPhase.idle;
  String _batch = '';
  int _queuedBytes = 0, _ordinal = 0;
  int? _lastSequence;
  bool _active = false,
      _disposed = false,
      _startAdmitted = false,
      _start = false,
      _end = false;
  bool _wireComplete = false, _committed = false, _acked = false;

  JwHistoryCoordinator(
      {required this.session,
      required this.store,
      required this.deviceKey,
      required this.capabilities});
  Stream<JwHistoryProgress> get progress => _progress.stream;

  Future<JwHistoryResult> synchronize(
      {JwHistoryOptions options = const JwHistoryOptions()}) {
    if (_disposed || _active) {
      return Future.error(
          StateError('History round unavailable/already running'));
    }
    try {
      options.validate();
    } catch (e) {
      return Future.error(e);
    }
    _active = true;
    _options = options;
    _failure = null;
    _closingLink = null;
    _cleanupError = null;
    _diagnostic = null;
    _queue.clear();
    _seenFrames.clear();
    _counts.clear();
    for (final type in JwHistoryType.values) {
      _counts[type] = _Counts();
    }
    _markers.clear();
    _expectedMarkers.clear();
    if (capabilities.pressureMonitor) {
      _expectedMarkers.add(0x5b);
    }
    if (capabilities.metabDaily) {
      _expectedMarkers.add(0x60);
    }
    if (capabilities.readiness) {
      _expectedMarkers.add(0x64);
    }
    _queuedBytes = 0;
    _ordinal = 0;
    _lastSequence = null;
    _startAdmitted = false;
    _start = false;
    _end = false;
    _wireComplete = false;
    _committed = false;
    _acked = false;
    final random = Random.secure();
    _batch =
        '${DateTime.now().microsecondsSinceEpoch}_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    _phase = JwHistoryPhase.starting;
    _running = _run();
    return _running!;
  }

  void _notify() {
    if (!_progress.isClosed) {
      _progress.add(_snapshot());
    }
  }

  JwHistoryResult _snapshot() => JwHistoryResult(
      batchId: _batch,
      phase: _phase,
      counts: {for (final e in _counts.entries) e.key: e.value.snapshot()},
      expectedMarkers: _expectedMarkers,
      observedMarkers: _markers,
      startReceived: _start,
      traditionalEndReceived: _end,
      failureStage: _failure?.stage,
      error: _failure?.message,
      wireRoundComplete: _wireComplete,
      localCommitComplete: _committed,
      applicationAckTransportDelivered: _acked,
      countValidation: _counts.values.any((c) => c.expected == 65535)
          ? 'saturatedLowerBound'
          : 'announcedMinimum');
  void _signal() {
    if (_wake != null && !_wake!.isCompleted) {
      _wake!.complete();
    }
  }

  void _closeSoon() {
    _closingLink ??= Future<void>.microtask(() async {
      try {
        await session.close();
      } catch (e) {
        _cleanupError = e;
      }
    });
  }

  void _abort(String stage, String message) {
    _failure ??= _RoundFailure(stage, message);
    _closeSoon();
    _signal();
  }

  void _check() {
    if (_failure != null) {
      throw _failure!;
    }
  }

  void _touch() {
    _idle?.cancel();
    _idle = Timer(
        _options.idleTimeout,
        () => _abort(
            'idleTimeout', 'No verified history progress within idle budget'));
  }

  bool _marker(Uint8List bytes) =>
      bytes.length == 8 && String.fromCharCodes(bytes) == 'overover';
  void _admit(JwFrame frame) {
    if (!_active || _failure != null || frame.ack) {
      return;
    }
    JwMessage message;
    try {
      message = JwCodec.decodeL2(frame.payload);
    } on FormatException catch (e) {
      _diagnostic = frame;
      _abort('parse', e.toString());
      return;
    }
    if (!_startAdmitted) {
      if (message.command == 5 && message.fields.any((f) => f.key == 7)) {
        _startAdmitted = true;
      } else if (message.command == 5 &&
          message.fields.any((f) => _types.containsKey(f.key) || f.key == 8)) {
        _diagnostic = frame;
        _abort('order', 'History arrived before START');
        return;
      } else {
        return;
      }
    }
    final signature =
        frame.payload.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
    if (_seenFrames[frame.seq] == signature) {
      return;
    }
    if (_seenFrames.containsKey(frame.seq)) {
      _diagnostic = frame;
      _abort('sequenceConflict', 'Repeated sequence changed payload');
      return;
    }
    if (_lastSequence != null && frame.seq != ((_lastSequence! + 1) & 0xffff)) {
      _diagnostic = frame;
      _abort('sequenceGap',
          'Device sequence discontinuity ${_lastSequence!} -> ${frame.seq}');
      return;
    }
    _seenFrames[frame.seq] = signature;
    _lastSequence = frame.seq;
    if (_seenFrames.length > 128) {
      _seenFrames.remove(_seenFrames.keys.first);
    }
    if (_phase == JwHistoryPhase.committing ||
        _phase == JwHistoryPhase.confirming) {
      if (message.command == 5 &&
          message.fields.any((f) => ![0x0f, 0x28, 0x1a].contains(f.key))) {
        _diagnostic = frame;
        _abort('lateData', 'History arrived after stream completion');
      }
      return;
    }
    final size = 8 + frame.payload.length;
    if (_queuedBytes + size > _options.maxQueuedBytes) {
      _diagnostic = frame;
      _abort(
          'queueOverflow', 'History admission exceeded configured byte budget');
      return;
    }
    _queuedBytes += size;
    _queue.add((frame, message));
    _signal();
  }

  Future<JwHistoryResult> _run() async {
    Future<void>? startup;
    try {
      await store.beginBatch(_batch, deviceKey);
      _check();
      _frames = session.incomingFrames.listen(_admit);
      _failures = session.failures.listen((e) => _abort(
          _phase == JwHistoryPhase.confirming ? 'confirmation' : 'disconnected',
          e.toString()));
      _total = Timer(_options.totalTimeout,
          () => _abort('totalTimeout', 'History exceeded total budget'));
      _touch();
      _notify();
      startup = session
          .request(
              JwRequest(command: 5, key: 1, responseKey: 7, readOnly: false))
          .then<void>((_) {}, onError: (Object e, StackTrace st) {
        _abort('historyRequest', e.toString());
      });
      while (true) {
        _check();
        if (_queue.isNotEmpty) {
          final item = _queue.removeFirst();
          _queuedBytes -= 8 + item.$1.payload.length;
          try {
            await _process(item.$2);
          } on _RoundFailure {
            _diagnostic ??= item.$1;
            rethrow;
          }
          continue;
        }
        if (_start && _end && _markers.containsAll(_expectedMarkers)) {
          await startup;
          _check();
          if (await _finish()) {
            return _snapshot();
          }
          continue;
        }
        _wake = Completer<void>();
        if (_queue.isEmpty && _failure == null) {
          await _wake!.future;
        }
        _wake = null;
      }
    } catch (e) {
      if (e is _RoundFailure) {
        _failure ??= e;
      } else {
        _failure ??=
            _RoundFailure(_acked ? 'storageAfterAck' : 'storage', e.toString());
      }
      if ([
        'parse',
        'order',
        'lateData',
        'unexpectedStream',
        'sequenceGap',
        'sequenceConflict',
        'countMismatch'
      ].contains(_failure!.stage)) {
        _wireComplete = false;
      }
      _closeSoon();
      final diagnostic = _diagnostic;
      if (diagnostic != null) {
        try {
          await store.quarantine(_batch, -1, _hex(diagnostic.payload),
              'L1 sequence ${diagnostic.seq}: ${_failure!.stage}');
        } catch (_) {}
      }
      await _retainQueuedPartials();
      try {
        await store.noteFailure(_batch, _failure!.stage, _failure!.message);
      } catch (_) {}
      try {
        await store.flush();
      } catch (_) {}
      _phase = _failure!.stage == 'cancelled'
          ? JwHistoryPhase.cancelled
          : _failure!.stage == 'disconnected'
              ? JwHistoryPhase.disconnected
              : JwHistoryPhase.failed;
      _notify();
      // Build the error after cleanup, preserving the original failure stage.
    } finally {
      _idle?.cancel();
      _total?.cancel();
      await _frames?.cancel();
      await _failures?.cancel();
      _frames = null;
      _failures = null;
      if (_failure != null) {
        _closeSoon();
        await _closingLink;
        if (_cleanupError != null) {
          _failure = _RoundFailure(_failure!.stage,
              '${_failure!.message}; disconnect cleanup: $_cleanupError');
        }
      }
      if (startup != null) {
        await startup;
      }
      _active = false;
      _queue.clear();
      _queuedBytes = 0;
    }
    throw JwHistoryException(_failure!.stage, _snapshot());
  }

  Future<void> _process(JwMessage message) async {
    if (message.command != 5) {
      return;
    }
    for (final field in message.fields) {
      _check();
      if (field.key == 7) {
        _readStart(field.value);
        continue;
      }
      if (field.key == 8) {
        if (!_start || _end || field.value.isNotEmpty) {
          throw _RoundFailure('order', 'Invalid/duplicate END');
        }
        _end = true;
        _phase = JwHistoryPhase.receivingModern;
        _touch();
        _notify();
        continue;
      }
      if ([0x0f, 0x28, 0x1a].contains(field.key)) {
        continue;
      }
      final type = _types[field.key];
      if (type == null) {
        await store.quarantine(
            _batch, field.key, _hex(field.value), 'unknownHistoryKey');
        throw _RoundFailure('parse', 'Unknown history key ${field.key}');
      }
      final modern = [0x5b, 0x60, 0x64].contains(field.key);
      if (modern && !_expectedMarkers.contains(field.key)) {
        await store.quarantine(
            _batch, field.key, _hex(field.value), 'unexpectedStream');
        throw _RoundFailure(
            'unexpectedStream', 'Unexpected modern stream ${field.key}');
      }
      if (modern && _marker(field.value)) {
        if (!_markers.add(field.key)) {
          throw _RoundFailure('order', 'Duplicate modern marker');
        }
        _touch();
        _notify();
        continue;
      }
      if (!_start || (!modern && _end) || _markers.contains(field.key)) {
        await store.quarantine(
            _batch, field.key, _hex(field.value), 'lateData');
        throw _RoundFailure('lateData', 'Record outside its declared stream');
      }
      await _save(field);
      _notify();
    }
  }

  void _readStart(Uint8List bytes) {
    if (_start || bytes.isEmpty || bytes.length % 3 != 0) {
      throw _RoundFailure('parse', 'Invalid/duplicate START');
    }
    final types = <int>{};
    for (var i = 0; i < bytes.length; i += 3) {
      final type = bytes[i];
      final historyType = _startTypes[type];
      if (historyType == null || !types.add(type)) {
        throw _RoundFailure('parse', 'Unknown/duplicate START type');
      }
      _counts[historyType]!.expected = (bytes[i + 1] << 8) | bytes[i + 2];
    }
    final required = {0, 1, 2, 3, 4, 5, if (capabilities.hrv) 6};
    if (!types.containsAll(required)) {
      throw _RoundFailure('parse', 'Missing START types');
    }
    _start = true;
    _phase = JwHistoryPhase.receivingTraditional;
    _touch();
    _notify();
  }

  Future<void> _save(JwField field) async {
    final counts = _counts[_types[field.key]]!;
    List<JwHistoryRecord> records;
    try {
      records = decodeJwHistoryField(deviceKey, field.key, field.value,
          batchId: _batch, firstSeenOrdinal: _ordinal);
    } on FormatException catch (e) {
      counts.quarantined++;
      await store.quarantine(
          _batch, field.key, _hex(field.value), e.toString());
      throw _RoundFailure('parse', e.toString());
    }
    _ordinal += records.length;
    counts.received += records.length;
    var newInBatch = false;
    for (final row in records) {
      newInBatch = counts.ids.add(row.recordId) || newInBatch;
    }
    final saved = await store.append(_batch, records);
    counts.persisted += saved.insertedIds.length;
    if (newInBatch) {
      _touch();
    }
  }

  Future<bool> _finish() async {
    for (final c in _counts.values) {
      if (c.expected != null &&
          c.expected != 65535 &&
          c.ids.length < c.expected!) {
        throw _RoundFailure('countMismatch',
            'Unique records below announced START minimum; retries/identical records cannot prove missing entries');
      }
    }
    _wireComplete = true;
    _phase = JwHistoryPhase.committing;
    _notify();
    await store.flush();
    _check();
    if (_queue.isNotEmpty) {
      _phase = JwHistoryPhase.receivingModern;
      return false;
    }
    final ids = _counts.values.expand((c) => c.ids).toSet();
    await store.commit(JwHistoryBatchCommit(
        batchId: _batch,
        deviceKey: deviceKey,
        recordIds: ids,
        summary: {..._snapshot().toJson(), 'localCommitComplete': true}));
    _committed = true;
    _check();
    await store.noteAck(_batch, 'requested');
    _check();
    _phase = JwHistoryPhase.confirming;
    _notify();
    await session.send(JwRequest(command: 5, key: 0x1c, readOnly: false));
    _acked = true;
    _check();
    await store.noteAck(_batch, 'transportDelivered');
    _check();
    _phase = JwHistoryPhase.completed;
    _notify();
    return true;
  }

  Future<void> _retainQueuedPartials() async {
    while (_queue.isNotEmpty) {
      final message = _queue.removeFirst().$2;
      if (message.command != 5) {
        continue;
      }
      for (final field in message.fields) {
        if (!_types.containsKey(field.key) || _marker(field.value)) {
          continue;
        }
        try {
          await _save(field);
        } on _RoundFailure {
          continue;
        } catch (_) {
          return;
        }
      }
    }
  }

  String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  Future<void> cancel() async {
    if (!_active) {
      return;
    }
    _abort('cancelled', 'History cancelled');
    try {
      await _running;
    } on JwHistoryException {/* Caller receives the result. */}
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await cancel();
    await _progress.close();
  }
}
