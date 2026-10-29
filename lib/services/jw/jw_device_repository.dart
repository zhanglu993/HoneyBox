import 'history/jw_history_coordinator.dart';
import 'history/jw_history_models.dart';
import 'history/jw_history_store.dart';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'jw_codec.dart';
import 'jw_configuration.dart';
import 'jw_identity_store.dart';
import 'jw_models.dart';
import 'jw_protocol.dart';
import 'jw_session.dart';
import 'jw_transport.dart';
import 'jw_remaining_models.dart';

class JwLoginException implements Exception {
  final String message;
  const JwLoginException(this.message);
  @override
  String toString() => message;
}

class JwDeviceRepository {
  final JwSession session;
  final JwIdentityStore identityStore;
  final JwTransport transport;
  final Future<JwHistoryStore> Function()? historyStoreFactory;
  final bool ownsHistoryStore;
  final String? platformDeviceKey;
  JwHistoryStore? _historyStore;
  Future<JwHistoryStore>? _historyOpening;
  JwHistoryCoordinator? _history;
  Completer<JwHistoryResult>? _historySetupCancellation;
  StreamSubscription<JwHistoryProgress>? _historyProgress;
  final _changes = StreamController<JwDeviceState>.broadcast(sync: true);
  JwDeviceState _state = const JwDeviceState();
  StreamSubscription<JwMessage>? _events;
  StreamSubscription<void>? _down;
  StreamSubscription<JwLinkException>? _sessionFailures;
  Future<void>? _initializing;
  Future<void>? _disposing;
  List<int>? _supportedUkSportTypes;
  bool _ownedCamera = false;
  bool _ownedAlert = false;
  int? _ownedSportType;
  final _ownedMeasurements = <String>{};
  bool _disposed = false;
  bool _lost = false;
  bool _busy = false;
  bool _startingHeart = false;
  JwHeartRateSample? _earlyHeart;
  JwDeviceRepository(
      {required this.session,
      required this.identityStore,
      required this.transport,
      this.historyStoreFactory,
      this.ownsHistoryStore = true,
      this.platformDeviceKey});
  JwDeviceState get state => _state;
  Stream<JwDeviceState> get changes => _changes.stream;

  /// Activity ownership belongs to the connection, including uncertain live
  /// submissions. Route disposal never transfers or clears this ownership.
  Set<String> get ownedActivities {
    if (_disposed ||
        _lost ||
        !session.isOpen ||
        state.phase == JwDevicePhase.failed ||
        state.phase == JwDevicePhase.disconnected) {
      return const {};
    }
    return Set.unmodifiable({
      if (_ownedCamera) 'photo',
      if (_ownedAlert) 'find',
      if (_ownedSportType != null) 'sport',
      for (final name in _ownedMeasurements) 'manual-$name',
    });
  }

  void _publish(JwDeviceState next) {
    if (_disposed) return;
    if (_lost ||
        next.phase == JwDevicePhase.failed ||
        next.phase == JwDevicePhase.disconnected) {
      _supportedUkSportTypes = null;
      next = next.copyWith(configuration: const {});
    }
    _state = _lost
        ? next.copyWith(
            phase: JwDevicePhase.disconnected,
            heartRateStreaming: false,
            lastHeartRate: null,
            operationInProgress: false)
        : next;
    _changes.add(_state);
  }

  Future<void> initialize({String? expectedExistingIdentitySha256}) =>
      _initializing ??= _initialize(
          expectedExistingIdentitySha256: expectedExistingIdentitySha256);
  Future<void> _initialize({String? expectedExistingIdentitySha256}) async {
    _busy = true;
    _publish(state.copyWith(operationInProgress: true));
    _down = transport.disconnected.listen((_) {
      _lost = true;
      _earlyHeart = null;
      _publish(state.copyWith(
          phase: JwDevicePhase.disconnected,
          heartRateStreaming: false,
          lastHeartRate: null,
          operationInProgress: false));
    });
    _sessionFailures = session.failures.listen((error) {
      _earlyHeart = null;
      _startingHeart = false;
      _error(error);
    });
    _events = session.events.listen(_onMessage);
    try {
      await session.open();
      final name = await _text('2a00');
      final serial = await _text('2a25');
      final firmware = await _text('2a26');
      final hardware = await _text('2a27');
      final batteryBytes = await transport.read('2a19');
      final battery = batteryBytes?.length == 1 && batteryBytes!.single <= 100
          ? batteryBytes.single
          : null;
      _publish(state.copyWith(
          info: JwDeviceInfo(
              deviceKey: serial ?? '',
              name: name,
              firmware: firmware,
              hardware: hardware,
              battery: battery)));
      final functions = await session.request(JwCommands.functionList());
      final factory = await session.request(JwCommands.factorySwitch());
      final capabilities = JwCapabilities.fromWire(
          functions.fields.single.value, factory.fields.single.value);
      _publish(state.copyWith(
          capabilities: capabilities, phase: JwDevicePhase.readOnly));
      if (capabilities.languages) await _readLanguage();
      await _login(
          expectedExistingIdentitySha256: expectedExistingIdentitySha256);
    } catch (e) {
      _error(e, initializing: true);
    } finally {
      _busy = false;
      _publish(state.copyWith(operationInProgress: false));
    }
  }

  Future<String?> _text(String uuid) async {
    final bytes = await transport.read(uuid);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final value = utf8.decode(bytes).replaceAll('\u0000', '').trim();
      return value.isEmpty ? null : value;
    } on FormatException {
      return null;
    }
  }

  void _error(Object e, {bool initializing = false}) {
    final phase = e is JwIdentityException
        ? JwDevicePhase.identityUnavailable
        : e is JwLoginException
            ? JwDevicePhase.loginRejected
            : e is JwLinkException || initializing
                ? JwDevicePhase.failed
                : state.phase;
    _publish(state.copyWith(
        phase: phase,
        operationError: e.toString(),
        operationInProgress: e is JwLinkException ? false : null,
        heartRateStreaming: e is JwLinkException ? false : null,
        lastHeartRate: e is JwLinkException ? null : state.lastHeartRate));
  }

  Future<void> _operate(Future<void> Function() action,
      {bool write = false}) async {
    if (_disposed || _lost || !session.isOpen) {
      throw StateError('JW session unavailable; reconnect');
    }
    if (_busy) throw StateError('JW operation already in progress');
    if (write && state.phase != JwDevicePhase.loggedIn) {
      throw StateError('JW login required');
    }
    _busy = true;
    _publish(state.copyWith(operationInProgress: true, operationError: null));
    try {
      await action();
    } catch (e) {
      _error(e);
      rethrow;
    } finally {
      _busy = false;
      _publish(state.copyWith(operationInProgress: false));
    }
  }

  Future<void> _login({String? expectedExistingIdentitySha256}) async {
    final identity = expectedExistingIdentitySha256 == null
        ? await identityStore.loadOrCreate()
        : await identityStore.loadExisting();
    if (expectedExistingIdentitySha256 != null &&
        sha256.convert(identity.wireUserId).toString() !=
            expectedExistingIdentitySha256) {
      throw const JwIdentityException('Existing identifier digest mismatch');
    }
    _publish(state.copyWith(phase: JwDevicePhase.loggingIn));
    final reply = await session.request(JwCommands.login(identity.wireUserId));
    _requireSuccess(reply, 'Device refused login');
    _publish(
        state.copyWith(phase: JwDevicePhase.loggedIn, operationError: null));
  }

  Future<void> login() => _operate(_login);
  Future<void> bindFirstTime({required bool confirmedFirstBind}) =>
      _operate(() async {
        if (!confirmedFirstBind) {
          throw StateError('First bind requires explicit confirmation');
        }
        if (state.phase == JwDevicePhase.loggedIn) {
          throw StateError('Already logged in; binding is unnecessary');
        }
        final identity = await identityStore.loadOrCreate();
        final reply =
            await session.request(JwCommands.bind(identity.wireUserId));
        _requireSuccess(reply, 'Device refused first bind');
        _publish(state.copyWith(
            phase: JwDevicePhase.loggedIn, operationError: null));
      });
  void _requireSuccess(JwMessage reply, String error) {
    final value = reply.fields.single.value;
    if (value.length != 1 || value.single != 0) throw JwLoginException(error);
  }

  Future<void> syncTime(DateTime time) => _operate(() async {
        await session.send(JwCommands.time(time));
        _publish(state.copyWith(timeSubmitted: true));
      }, write: true);
  Future<int> _readLanguage({bool strict = false}) async {
    final reply =
        await session.request(JwCommands.language(singleFieldReply: strict));
    final int language;
    if (strict) {
      language = JwProtocol.language(reply);
    } else {
      final value = reply.fields.single.value;
      if (value.length != 1) throw const FormatException('JW language length');
      language = value.single;
    }
    if (strict) _requireLiveRead();
    _publish(state.copyWith(language: language));
    return language;
  }

  void _requireLiveRead() {
    if (_disposed || _lost || !session.isOpen) {
      throw StateError('JW session unavailable; reconnect');
    }
  }

  Future<T> _readOnlyOperation<T>(Future<T> Function() action) async {
    late T value;
    await _operate(() async {
      value = await action();
      _requireLiveRead();
    });
    return value;
  }

  void _requireReadCapability(bool available, String name) {
    if (!available) {
      throw JwConfigurationException(
          stage: 'unsupported', cause: '$name capability unavailable');
    }
  }

  void _requireReadContract(JwConfigurationContract contract,
      {bool allowT100 = false}) {
    if (contract != JwConfigurationContract.v101S200 ||
        (state.info?.firmware != 'T005' &&
            !(allowT100 && state.info?.firmware == 'T100')) ||
        state.info?.hardware != 'H001' ||
        state.capabilities == null) {
      throw JwConfigurationException(
          stage: 'unsupported',
          cause: 'requires explicit V101 S200 T005/H001 contract');
    }
  }

  JwRequest _remainingRequest(int command, int key,
          {List<int> value = const [],
          int? responseKey,
          int? responseCommand,
          bool mutation = false}) =>
      JwRequest(
          command: command,
          key: key,
          value: Uint8List.fromList(value),
          responseKey: responseKey,
          responseCommand: responseCommand,
          readOnly: !mutation,
          singleFieldReply: true,
          ackRetryLimit: mutation ? 0 : null);
  Uint8List _remainingReply(JwMessage message, int command, int key,
      {int? size}) {
    final raw =
        message.fields.isEmpty ? Uint8List(0) : message.fields.first.value;
    if (message.command != command ||
        message.fields.length != 1 ||
        message.fields.single.key != key ||
        (size != null && raw.length != size)) {
      throw JwConfigurationException(
          stage: 'invalid', raw: raw, cause: 'remaining command/key/length');
    }
    return raw;
  }

  Future<JwAlarmTable> _readAlarm() async => JwAlarmTable(_remainingReply(
      await session.request(_remainingRequest(2, 3, responseKey: 4)), 2, 4));
  Future<JwAlarmTable> readAlarm({required JwConfigurationContract contract}) =>
      _readOnlyOperation(() async {
        _requireReadContract(contract, allowT100: true);
        _requireReadCapability(state.capabilities!.legacyAlarm, 'alarm');
        return _readAlarm();
      });
  Future<JwSpO2PermissionReport> checkSpO2MeasureEnable(
          {required JwConfigurationContract contract}) =>
      _readOnlyOperation(() async {
        _requireReadContract(contract, allowT100: true);
        _requireReadCapability(state.capabilities!.bloodOxygen, 'SpO2');
        return JwSpO2PermissionReport(_remainingReply(
            await session.request(
                _remainingRequest(5, 0x2d, value: [2], responseKey: 0x2e)),
            5,
            0x2e,
            size: 1));
      });
  Future<JwSupportedSportTypes> readSupportDeviceSport(
          {required JwConfigurationContract contract}) =>
      _readOnlyOperation(() async {
        _requireReadContract(contract, allowT100: true);
        _requireReadCapability(state.capabilities!.exercise, 'sport support');
        _supportedUkSportTypes = null;
        final value = JwSupportedSportTypes(_remainingReply(
            await session.request(_remainingRequest(2, 0x3b,
                responseCommand: 5, responseKey: 0x17)),
            5,
            0x17,
            size: 4));
        _requireLiveRead();
        _supportedUkSportTypes = value.ukTypes;
        return value;
      });
  List<int>? getCachedSupportedUkSportTypes() =>
      _disposed || _lost || !session.isOpen || _supportedUkSportTypes == null
          ? null
          : List.unmodifiable(_supportedUkSportTypes!);
  Future<JwSportStatus> _sportRequest(int action, [int type = 255]) async =>
      JwSportStatus(_remainingReply(
          await session.request(_remainingRequest(5, 0x5c,
              value: [action, type], responseKey: 0x5d, mutation: action != 0)),
          5,
          0x5d,
          size: 3));
  void _requireSport(JwConfigurationContract contract,
      {bool allowT100 = false}) {
    _requireReadContract(contract, allowT100: allowT100);
    _requireReadCapability(
        state.capabilities!.exercise && state.capabilities!.sportControl,
        'sport control');
    if (state.phase != JwDevicePhase.loggedIn) {
      throw StateError('JW login required for sport');
    }
  }

  Future<JwSportStatus> queryDeviceSportStatus(
          {required JwConfigurationContract contract}) =>
      _readOnlyOperation(() async {
        _requireSport(contract, allowT100: true);
        return _sportRequest(0);
      });

  Future<T> _remainingOperation<T>(Future<T> Function() action) async {
    late T result;
    await _operate(() async {
      result = await action();
      _requireLiveRead();
    }, write: true);
    return result;
  }

  void _sameRaw(List<int> actual, List<int> expected, String stage) {
    if (actual.length != expected.length ||
        [for (var i = 0; i < actual.length; i++) actual[i] != expected[i]]
            .any((x) => x)) {
      throw JwConfigurationException(
          stage: stage,
          raw: Uint8List.fromList(actual),
          cause: 'expected current/readback differs');
    }
  }

  Future<JwSubmission> _submitRemaining(int command, int key, List<int> bytes,
      {int? responseKey}) async {
    final request = _remainingRequest(command, key,
        value: bytes, responseKey: responseKey, mutation: true);
    Uint8List? response;
    if (responseKey == null) {
      await session.send(request);
    } else {
      response = _remainingReply(
          await session.request(request), command, responseKey,
          size: 1);
      _sameRaw(response, bytes, 'readbackMismatch');
    }
    return JwSubmission(command, key, bytes, response: response);
  }

  Future<JwVerifiedChange<JwTurnOverWristStatus>> setTurnOverWrist(bool enabled,
          {required JwTurnOverWristStatus expectedCurrent,
          required JwConfigurationContract contract}) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        _requireReadCapability(state.capabilities!.turnOverWrist, 'wrist');
        final before = JwProtocol.turnOverWrist(
            await session.request(JwCommands.turnOverWrist()));
        _sameRaw(before.raw, expectedCurrent.raw, 'conflict');
        final requested =
            JwTurnOverWristStatus(Uint8List.fromList([enabled ? 1 : 0]));
        final submission = await _submitRemaining(2, 0x2a, requested.raw);
        final observed = JwProtocol.turnOverWrist(
            await session.request(JwCommands.turnOverWrist()));
        _sameRaw(observed.raw, requested.raw, 'readbackMismatch');
        return JwVerifiedChange(
            before: before,
            requested: requested,
            observed: observed,
            submission: submission);
      });
  Future<JwVerifiedChange<JwHeatStressReminderStatus>> setHeatStressReminder(
          JwHeatStressReminderStatus requested,
          {required JwHeatStressReminderStatus expectedCurrent,
          required JwConfigurationContract contract}) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        _requireReadCapability(
            state.capabilities!.heatStressReminder, 'heat window');
        final before = JwProtocol.heatStressReminder(
            await session.request(JwCommands.heatStressReminder()));
        _sameRaw(before.raw, expectedCurrent.raw, 'conflict');
        final submission = await _submitRemaining(2, 0x86, requested.raw);
        final observed = JwProtocol.heatStressReminder(
            await session.request(JwCommands.heatStressReminder()));
        _sameRaw(observed.raw, requested.raw, 'readbackMismatch');
        return JwVerifiedChange(
            before: before,
            requested: requested,
            observed: observed,
            submission: submission);
      });
  Future<JwSubmission> setTakePhotoControl(bool enabled,
          {required JwConfigurationContract contract}) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        _requireReadCapability(state.capabilities!.camera, 'camera');
        if (enabled && _ownedCamera) throw StateError('Camera already owned');
        if (!enabled && !_ownedCamera) {
          throw StateError('No owned camera mode to stop');
        }
        // No mode query exists: caller must ensure the device is available for this mode.
        if (enabled) _ownedCamera = true;
        final result = await _submitRemaining(7, 0x11, [enabled ? 0 : 1]);
        if (!enabled) _ownedCamera = false;
        return result;
      });
  Future<JwSubmission> findDevice(bool enabled,
          {required JwConfigurationContract contract}) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        _requireReadCapability(state.capabilities!.findDevice, 'find device');
        final alert = transport;
        if (alert is! JwImmediateAlertTransport ||
            !(alert as JwImmediateAlertTransport).immediateAlertAvailable) {
          throw JwConfigurationException(
              stage: 'unsupported',
              cause: 'IAS1802/2A06 writable endpoint unavailable');
        }
        if (!enabled && !_ownedAlert) {
          throw StateError('No owned alert to stop');
        }
        if (enabled && _ownedAlert) throw StateError('Alert already owned');
        if (enabled) _ownedAlert = true;
        await (alert as JwImmediateAlertTransport).writeImmediateAlert(enabled);
        if (!enabled) _ownedAlert = false;
        return JwSubmission(0x1802, 0x2a06, [enabled ? 2 : 0],
            acknowledged: false);
      });
  Future<JwLongSitSettings> _readLongSit() async =>
      JwLongSitSettings(_remainingReply(
          await session.request(_remainingRequest(2, 0x26, responseKey: 0x27)),
          2,
          0x27,
          size: 8));
  Future<JwLongSitSettings> readLongSit(
          {required JwConfigurationContract contract}) =>
      _readOnlyOperation(() async {
        _requireReadContract(contract);
        _requireReadCapability(state.capabilities!.longSit, 'long-sit');
        return _readLongSit();
      });
  Future<JwVerifiedChange<JwLongSitSettings>> setLongSit(
          JwLongSitSettings requested,
          {required JwLongSitSettings expectedCurrent,
          required JwConfigurationContract contract}) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        _requireReadCapability(state.capabilities!.longSit, 'long-sit');
        _requireReadCapability(
            state.capabilities!.disturb, 'long-sit DND preflight');
        if (JwProtocol.disturb(await session.request(JwCommands.disturb()))
            .active) {
          throw StateError('Active DND prevents reliable long-sit write');
        }
        final before = await _readLongSit();
        _sameRaw(before.raw, expectedCurrent.raw, 'conflict');
        final submission = await _submitRemaining(2, 0x21, requested.raw);
        final observed = await _readLongSit();
        _sameRaw(observed.raw, requested.raw, 'readbackMismatch');
        return JwVerifiedChange(
            before: before,
            requested: requested,
            observed: observed,
            submission: submission);
      });
  Future<JwVerifiedChange<JwAlarmTable>> _changeAlarm(
          JwAlarmTable expectedCurrent,
          JwConfigurationContract contract,
          JwAlarmTable Function(JwAlarmTable) update) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        _requireReadCapability(state.capabilities!.legacyAlarm, 'alarm');
        final before = await _readAlarm();
        _sameRaw(before.raw, expectedCurrent.raw, 'conflict');
        if (!before.roundTrippable) {
          throw JwConfigurationException(
              stage: 'unsupported',
              raw: before.raw,
              cause:
                  'Retained one-shot alarm reserved fields cannot round-trip through this firmware setter');
        }
        final requested = update(before);
        final normalized = requested.normalizedRaw;
        final submission = await _submitRemaining(2, 2, requested.raw);
        final observed = await _readAlarm();
        _sameRaw(observed.raw, normalized, 'readbackMismatch');
        return JwVerifiedChange(
            before: before,
            requested: requested,
            observed: observed,
            submission: submission);
      });
  Future<JwVerifiedChange<JwAlarmTable>> addAlarm(JwAlarmRecord entry,
          {required JwAlarmTable expectedCurrent,
          required JwConfigurationContract contract}) =>
      _changeAlarm(expectedCurrent, contract,
          (before) => JwAlarmTable([...before.raw, ...entry.raw]));
  Future<JwVerifiedChange<JwAlarmTable>> deleteAlarm(int index,
          {required JwAlarmTable expectedCurrent,
          required JwConfigurationContract contract}) =>
      _changeAlarm(expectedCurrent, contract, (before) {
        RangeError.checkValidIndex(index, before.records);
        return JwAlarmTable([
          ...before.raw.take(index * 5),
          ...before.raw.skip((index + 1) * 5)
        ]);
      });
  Future<JwVerifiedChange<JwAlarmTable>> modifyAlarm(
          int index, JwAlarmRecord entry,
          {required JwAlarmTable expectedCurrent,
          required JwConfigurationContract contract}) =>
      _changeAlarm(expectedCurrent, contract, (before) {
        RangeError.checkValidIndex(index, before.records);
        return JwAlarmTable([
          ...before.raw.take(index * 5),
          ...entry.raw,
          ...before.raw.skip((index + 1) * 5)
        ]);
      });
  Future<JwUserInfoSubmission> syncUserInfo(
          {required int gender,
          required int age,
          required double heightCm,
          required double weightKg,
          int? targetSteps,
          int? targetSleepMinutes,
          required JwConfigurationContract contract}) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        RangeError.checkValueInInterval(gender, 0, 1);
        RangeError.checkValueInInterval(age, 0, 127);
        if (!heightCm.isFinite ||
            !weightKg.isFinite ||
            heightCm <= 0 ||
            heightCm >= 256 ||
            weightKg <= 0 ||
            weightKg >= 512 ||
            heightCm * 2 != (heightCm * 2).round() ||
            weightKg * 2 != (weightKg * 2).round()) {
          throw ArgumentError('Profile range/half-unit precision');
        }
        if (targetSteps != null) {
          RangeError.checkValueInInterval(targetSteps, 1, 0xffffffff);
        }
        if (targetSleepMinutes != null) {
          RangeError.checkValueInInterval(targetSleepMinutes, 1, 65535);
        }
        final h = (heightCm * 2).toInt(), w = (weightKg * 2).toInt();
        final commands = <(int, List<int>)>[
          (
            0x10,
            [
              (gender << 7) | age,
              h >> 1,
              ((h << 7) | (w >> 3)) & 255,
              (w << 5) & 255
            ]
          )
        ];
        if (targetSteps != null) {
          final data = ByteData(4)..setUint32(0, targetSteps);
          commands.add((5, data.buffer.asUint8List()));
        }
        if (targetSleepMinutes != null) {
          final data = ByteData(2)..setUint16(0, targetSleepMinutes);
          commands.add((6, data.buffer.asUint8List()));
        }
        final sent = <JwSubmission>[];
        try {
          for (final command in commands) {
            sent.add(await _submitRemaining(2, command.$1, command.$2));
          }
        } catch (e) {
          throw JwCompoundSubmissionException(sent, e);
        }
        return JwUserInfoSubmission(sent);
      });
  Future<JwSubmission> _measurement(
          String name, bool enabled, JwConfigurationContract contract) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        final c = state.capabilities!;
        _requireReadCapability(
            switch (name) {
              'hr' => c.heartRate,
              'spo2' => c.bloodOxygen,
              'temperature' => c.temperature && c.factoryTemperature,
              'bp' => c.bloodPressure && c.factoryBloodPressure,
              _ => false
            },
            'manual $name');
        if (!enabled && !_ownedMeasurements.contains(name)) {
          throw StateError('No owned $name measurement');
        }
        if (enabled && _ownedMeasurements.isNotEmpty) {
          throw StateError('An owned measurement is already active');
        }
        if (enabled) {
          _requireReadCapability(
              c.healthStatus, 'manual measurement status preflight');
          final status = await _readHealthStatus();
          if (status.hrManualReported ||
              status.bpManualReported ||
              status.spo2ManualReported ||
              status.exerciseReported) {
            throw StateError('Foreign measurement/exercise reported active');
          }
          _ownedMeasurements.add(name);
        }
        final key = switch (name) {
          'hr' => 0x0d,
          'spo2' => 0x2d,
          'temperature' => 0x20,
          _ => 0x14
        };
        final result = await _submitRemaining(5, key, [enabled ? 1 : 0],
            responseKey: name == 'temperature' ? 0x21 : null);
        if (!enabled) _ownedMeasurements.remove(name);
        return result;
      });
  Future<JwSubmission> controlHeartRateMeasurement(bool enabled,
          {required JwConfigurationContract contract}) =>
      _measurement('hr', enabled, contract);
  Future<JwSubmission> controlSpO2Measurement(bool enabled,
          {required JwConfigurationContract contract}) =>
      _measurement('spo2', enabled, contract);
  Future<JwSubmission> controlTemperatureMeasurement(bool enabled,
          {required JwConfigurationContract contract}) =>
      _measurement('temperature', enabled, contract);
  Future<JwSubmission> controlBloodPressureMeasurement(bool enabled,
          {required JwConfigurationContract contract}) =>
      _measurement('bp', enabled, contract);
  Future<JwSportStatus> _controlSport(
          int action, JwConfigurationContract contract,
          {int type = 255}) =>
      _remainingOperation(() async {
        _requireSport(contract);
        if (action == 1) {
          if (_ownedSportType != null || _ownedMeasurements.isNotEmpty) {
            throw StateError('Owned activity already active');
          }
          if (_supportedUkSportTypes == null ||
              !_supportedUkSportTypes!.contains(type)) {
            throw JwConfigurationException(
                stage: 'unsupported',
                cause: 'Read actual supported sport types before start');
          }
        } else if (_ownedSportType == null) {
          throw StateError('No owned sport session');
        }
        final before = await _sportRequest(0);
        if (!before.operationAccepted) {
          throw StateError('Sport query rejected ${before.result}');
        }
        if (action == 1
            ? before.state != 0
            : before.state == 0 || before.sportType != _ownedSportType) {
          throw StateError('Sport state changed or foreign session');
        }
        final result = await _sportRequest(action, type);
        if (result.operationAccepted) {
          if (action == 1 &&
              result.result == 0 &&
              result.state == 1 &&
              result.sportType == type) {
            _ownedSportType = type;
          } else if (action == 4 && result.state == 0) {
            _ownedSportType = null;
          }
        }
        return result;
      });
  Future<JwSportStatus> startDeviceSport(int ukType,
          {required JwConfigurationContract contract}) =>
      _controlSport(1, contract, type: ukType);
  Future<JwSportStatus> pauseDeviceSport(
          {required JwConfigurationContract contract}) =>
      _controlSport(2, contract);
  Future<JwSportStatus> resumeDeviceSport(
          {required JwConfigurationContract contract}) =>
      _controlSport(3, contract);
  Future<JwSportStatus> stopDeviceSport(
          {required JwConfigurationContract contract}) =>
      _controlSport(4, contract);
  Future<JwSubmission> setSocialReminder(int mask,
          {required JwConfigurationContract contract,
          bool acknowledgedPairingRisk = false}) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        _requireReadCapability(
            state.capabilities!.socialReminder, 'social reminders');
        RangeError.checkValueInInterval(mask, 0, 0xffffffff);
        if ((mask & 0x7fc00000) != 0) {
          throw ArgumentError('Unknown social mask bits');
        }
        if (!acknowledgedPairingRisk) {
          throw JwConfigurationException(
              stage: 'unsupported',
              cause:
                  'Notification setter may pair using stored phoneOS; explicit risk acknowledgement required');
        }
        return _submitRemaining(
            2, 0x2d, (ByteData(4)..setUint32(0, mask)).buffer.asUint8List());
      });
  Future<JwSubmission> setDisturb(JwDisturbStatus requested,
          {required JwConfigurationContract contract,
          bool acknowledgedPairingRisk = false}) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        _requireReadCapability(state.capabilities!.disturb, 'DND');
        if (!acknowledgedPairingRisk) {
          throw JwConfigurationException(
              stage: 'unsupported',
              cause:
                  'DND setter may pair through notification restore; explicit risk acknowledgement required');
        }
        if (requested.active) {
          throw ArgumentError('DND active is runtime readonly');
        }
        return _submitRemaining(2, 0x47, requested.raw);
      });
  Future<JwSubmission> setHeartRateReminder(
          {required bool enabled,
          required int threshold,
          required JwConfigurationContract contract}) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        RangeError.checkValueInInterval(threshold, 0, 255);
        throw JwConfigurationException(
            stage: 'unsupported',
            cause:
                'Current firmware high-HR setter overwrites shared SpO2/temperature FTL; no safe contract');
      });

  Future<int> queryLanguage() => _readOnlyOperation(() async {
        _requireReadCapability(
            state.capabilities?.languages == true, 'language');
        return _readLanguage(strict: true);
      });
  Future<int> _readBatteryLevel() async {
    final raw = await transport.read('2a19');
    _requireLiveRead();
    return JwProtocol.battery(raw);
  }

  Future<int> readBatteryLevel() => _readOnlyOperation(() async {
        final battery = await _readBatteryLevel();
        final info = state.info;
        if (info != null) {
          _publish(state.copyWith(
              info: JwDeviceInfo(
                  deviceKey: info.deviceKey,
                  name: info.name,
                  firmware: info.firmware,
                  hardware: info.hardware,
                  battery: battery)));
        }
        return battery;
      });
  Future<JwHealthStatus> _readHealthStatus() async =>
      JwProtocol.healthStatus(await session.request(JwCommands.healthStatus()));
  Future<JwHealthStatus> readHealthStatus(
          {required JwConfigurationContract contract}) =>
      _readOnlyOperation(() async {
        _requireReadContract(contract, allowT100: true);
        _requireReadCapability(
            state.capabilities?.healthStatus == true, 'health status');
        return _readHealthStatus();
      });
  Future<JwTurnOverWristStatus> readTurnOverWrist(
          {required JwConfigurationContract contract}) =>
      _readOnlyOperation(() async {
        _requireReadContract(contract, allowT100: true);
        _requireReadCapability(
            state.capabilities?.turnOverWrist == true, 'wrist');
        return JwProtocol.turnOverWrist(
            await session.request(JwCommands.turnOverWrist()));
      });
  Future<JwDisturbStatus> readDisturb(
          {required JwConfigurationContract contract}) =>
      _readOnlyOperation(() async {
        _requireReadContract(contract, allowT100: true);
        _requireReadCapability(state.capabilities?.disturb == true, 'DND');
        return JwProtocol.disturb(await session.request(JwCommands.disturb()));
      });
  Future<JwHeatStressReminderStatus> queryHeatStressReminder(
          {required JwConfigurationContract contract}) =>
      _readOnlyOperation(() async {
        _requireReadContract(contract, allowT100: true);
        _requireReadCapability(
            state.capabilities?.heatStressReminder == true, 'heat window');
        return JwProtocol.heatStressReminder(
            await session.request(JwCommands.heatStressReminder()));
      });
  Future<JwHeartRateReminderDiagnostic> readHeartRateReminderDiagnostic(
          {required JwConfigurationContract contract}) =>
      _readOnlyOperation(() async {
        _requireReadContract(contract, allowT100: true);
        _requireReadCapability(
            state.capabilities?.highHeartRateReminder == true,
            'high HR diagnostic');
        return JwProtocol.heartRateReminderDiagnostic(
            await session.request(JwCommands.heartRateReminderDiagnostic()));
      });

  Future<void> setLanguageVerified(int language) => _operate(() async {
        if (state.capabilities?.languages != true ||
            state.language == null ||
            state.language! < 0 ||
            state.language! > 2) {
          throw StateError('Language unsupported');
        }
        await session.send(JwCommands.setLanguage(language));
        await _readLanguage();
        if (state.language != language) {
          throw StateError('Language readback mismatch');
        }
      }, write: true);

  void _requireConfiguration(
      JwConfigurationContract contract, JwConfigurationDomain? domain,
      {bool allowT100 = false}) {
    final info = state.info, c = state.capabilities;
    if (contract != JwConfigurationContract.v101S200 ||
        (info?.firmware != 'T005' &&
            !(allowT100 && info?.firmware == 'T100')) ||
        info?.hardware != 'H001' ||
        c == null) {
      throw JwConfigurationException(
          domain: domain,
          stage: 'unsupported',
          cause: 'requires explicit V101 S200 T005/H001 contract');
    }
    final supported = domain == null
        ? c.healthStatus
        : switch (domain) {
            JwConfigurationDomain.hourSystem => c.hourSystem,
            JwConfigurationDomain.distanceUnit => c.distanceUnit,
            JwConfigurationDomain.screenLightTime => c.displayTime,
            JwConfigurationDomain.screenBrightness => c.screenBrightness,
            JwConfigurationDomain.heartRateAuto => c.autoHeartRate,
            JwConfigurationDomain.bloodOxygenAuto => c.autoBloodOxygen,
            JwConfigurationDomain.bloodPressureAuto =>
              c.autoBloodPressure && c.factoryBloodPressure,
            JwConfigurationDomain.temperatureConfig =>
              c.temperature && c.factoryTemperature,
          };
    if (!supported) {
      throw JwConfigurationException(
          domain: domain,
          stage: 'unsupported',
          cause: 'operation capability unavailable');
    }
  }

  void _configurationObserved(JwConfigurationValue value) => _publish(state
      .copyWith(configuration: {...state.configuration, value.domain: value}));
  void _configurationInvalidated(JwConfigurationDomain? domain) {
    if (domain == null) {
      _publish(state.copyWith(configuration: const {}));
    } else {
      final values = Map<JwConfigurationDomain, JwConfigurationValue>.of(
          state.configuration)
        ..remove(domain);
      _publish(state.copyWith(configuration: values));
    }
  }

  Future<T> _configurationOperation<T>(
      JwConfigurationDomain? domain, Future<T> Function() action,
      {bool write = false, bool Function()? deliveryStarted}) async {
    late T result;
    try {
      await _operate(() async {
        try {
          result = await action();
        } catch (e) {
          final error = e is JwConfigurationException
              ? e
              : JwConfigurationException(
                  domain: domain,
                  stage: deliveryStarted?.call() == true
                      ? 'deliveryUnknown'
                      : 'invalid',
                  cause: e);
          if (error.stage == 'invalid' ||
              error.stage == 'deliveryUnknown' ||
              (deliveryStarted?.call() == true &&
                  error.stage != 'verificationFailed')) {
            _configurationInvalidated(domain ?? error.domain);
          }
          throw error;
        }
      }, write: write);
    } catch (e) {
      if (!write) rethrow;
      // Includes guards rejected by _operate before action is entered.
      // Submission is conservative: true as soon as send/request is invoked.
      final error = e is JwConfigurationException ? e : null;
      throw JwConfigurationException(
          domain: error?.domain ?? domain,
          stage: error?.stage ?? 'invalid',
          raw: error?.raw,
          cause: error?.cause ?? e,
          writeSubmitted: deliveryStarted?.call() == true);
    }
    return result;
  }

  Future<JwConfigurationValue> _readConfiguration(
      JwConfigurationDomain domain) async {
    final main =
        await session.request(JwConfigurationCodec.readRequest(domain));
    final companionRequest = JwConfigurationCodec.companionReadRequest(domain);
    final companion = companionRequest == null
        ? null
        : await session.request(companionRequest);
    final value =
        JwConfigurationCodec.parse(domain, main, companion: companion);
    _configurationObserved(value);
    return value;
  }

  Future<JwConfigurationValue> readConfiguration(JwConfigurationDomain domain,
          {required JwConfigurationContract contract}) =>
      _configurationOperation(domain, () async {
        _requireConfiguration(contract, domain, allowT100: true);
        return _readConfiguration(domain);
      });
  Future<JwConfigurationSnapshot> readConfigurationSnapshot(
          {required JwConfigurationContract contract}) =>
      _configurationOperation(null, () async {
        for (final d in JwConfigurationDomain.values) {
          _requireConfiguration(contract, d);
        }
        final values = <JwConfigurationDomain, JwConfigurationValue>{};
        for (final d in JwConfigurationDomain.values) {
          values[d] = await _readConfiguration(d);
        }
        return JwConfigurationSnapshot(values);
      });
  Uint8List _configurationResponse(JwMessage message, int key, int size) {
    if (message.command != 5 ||
        message.fields.length != 1 ||
        message.fields.single.key != key ||
        message.fields.single.value.length != size) {
      throw JwConfigurationException(
          stage: 'invalid', cause: 'preflight/companion command key or length');
    }
    return message.fields.single.value;
  }

  Future<JwConfigurationPreflight> _configurationPreflight() async {
    final power = await session.request(
        JwRequest(command: 5, key: 0x2a, responseKey: 0x2b, readOnly: true));
    final health = await _readHealthStatus();
    final battery = await _readBatteryLevel();
    return JwConfigurationPreflight(
        powerSaveRaw: _configurationResponse(power, 0x2b, 4),
        healthStatusRaw: health.raw,
        battery: battery);
  }

  Future<JwConfigurationPreflight> readConfigurationPreflight(
          {required JwConfigurationContract contract}) =>
      _configurationOperation(null, () async {
        _requireConfiguration(contract, null);
        return _configurationPreflight();
      });
  Future<JwConfigurationWriteResult> setConfigurationVerified(
      JwConfigurationChange change,
      {required JwConfigurationContract contract,
      required JwConfigurationValue expectedCurrent}) {
    var submitted = false;
    return _configurationOperation(change.domain, () async {
      _requireConfiguration(contract, change.domain);
      _requireConfiguration(contract, null);
      if (state.heartRateStreaming) {
        throw JwConfigurationException(
            domain: change.domain,
            stage: 'conflict',
            cause: 'heart-rate streaming active');
      }
      final before = await _readConfiguration(change.domain);
      if (!before.sameValue(expectedCurrent)) {
        throw JwConfigurationException(
            domain: change.domain,
            stage: 'conflict',
            raw: before.raw,
            cause: 'fresh configuration differs from expected');
      }
      final requested = JwConfigurationCodec.target(before, change);
      final preflight = await _configurationPreflight();
      if (!preflight.eligible) {
        throw JwConfigurationException(
            domain: change.domain,
            stage: 'conflict',
            cause: 'power save or manual measurement/exercise active');
      }
      if (!jwConfigurationBytesEqual(before.raw, requested.raw)) {
        final set = JwConfigurationCodec.writeRequest(requested);
        submitted = true;
        if (set.responseKey == null) {
          await session.send(set);
        } else {
          await session.request(set);
        }
      }
      if (change.domain == JwConfigurationDomain.bloodPressureAuto &&
          !before.sameValue(requested)) {
        final read = await session
            .request(JwConfigurationCodec.companionReadRequest(change.domain)!);
        final raw = _configurationResponse(read, 0x27, 4);
        final actual = JwConfigurationValue(change.domain, requested.raw,
            companionRaw: raw);
        if (!actual.writable) {
          throw JwConfigurationException(
              domain: change.domain,
              stage: 'conflict',
              raw: raw,
              cause: 'BP companion has unknown bits');
        }
        if (!jwConfigurationBytesEqual(raw, requested.companionRaw)) {
          submitted = true;
          await session
              .send(JwConfigurationCodec.companionWriteRequest(requested)!);
        }
      }
      final observed = await _readConfiguration(change.domain);
      if (!observed.sameValue(requested)) {
        throw JwConfigurationException(
            domain: change.domain,
            stage: 'verificationFailed',
            raw: observed.raw,
            cause: 'independent read differs from requested');
      }
      return JwConfigurationWriteResult(
          before: before, requested: requested, observed: observed);
    }, write: true, deliveryStarted: () => submitted);
  }

  Future<JwConfigurationWriteResult> setTemperatureUnitVerified(bool celsius,
          {required JwConfigurationContract contract,
          required JwConfigurationValue expectedCurrent}) =>
      setConfigurationVerified(
          JwConfigurationChange.temperature(celsius: celsius),
          contract: contract,
          expectedCurrent: expectedCurrent);

  String get historyDeviceKey {
    final serial = state.info?.deviceKey.trim();
    final value =
        serial?.isNotEmpty == true ? serial! : platformDeviceKey?.trim();
    if (value == null || value.isEmpty) {
      throw StateError(
          'Stable JW serial/MAC unavailable for history attribution');
    }
    return 'jw:$value';
  }

  Future<JwHistoryStore> _getHistoryStore() async {
    if (_disposed) {
      throw StateError('JW repository disposed');
    }
    if (_historyStore != null) {
      return _historyStore!;
    }
    try {
      final opened = await (_historyOpening ??=
          (historyStoreFactory ?? openJwHistoryStore)());
      if (_disposed) {
        if (ownsHistoryStore) {
          await opened.close();
        }
        throw StateError(
            'JW repository disposed during history initialization');
      }
      _historyStore = opened;
      return opened;
    } catch (_) {
      _historyOpening = null;
      rethrow;
    }
  }

  Future<JwHistoryInventory> historyInventory() async =>
      (await _getHistoryStore()).inventory(historyDeviceKey);
  Future<JwHistoryPage> historyPage(JwHistoryType type,
          {required String day, int offset = 0, int limit = 100}) async =>
      (await _getHistoryStore()).query(historyDeviceKey, type,
          day: day, offset: offset, limit: limit);
  JwHistoryResult _historySetupResult(JwHistoryPhase phase) => JwHistoryResult(
      batchId: '',
      phase: phase,
      counts: {},
      expectedMarkers: [],
      observedMarkers: [],
      startReceived: false,
      traditionalEndReceived: false,
      failureStage: phase == JwHistoryPhase.cancelled ? 'cancelled' : null,
      error: phase == JwHistoryPhase.cancelled
          ? 'History cancelled during initialization'
          : null,
      wireRoundComplete: false,
      localCommitComplete: false,
      applicationAckTransportDelivered: false,
      countValidation: 'notStarted');

  /// Rewinds retained device history cursors together. Transport ACK does not
  /// prove firmware application; synchronize again to observe replay. Local
  /// history journals remain intact and continue deduplicating record IDs.
  Future<JwSubmission> resetHistoryCursor(
          {required JwConfigurationContract contract}) =>
      _remainingOperation(() async {
        _requireReadContract(contract);
        final c = state.capabilities!;
        _requireReadCapability(
            c.steps ||
                c.sleep ||
                c.heartRate ||
                c.temperature ||
                c.bloodPressure ||
                c.bloodOxygen ||
                c.exercise ||
                c.hrv ||
                c.pressureMonitor ||
                c.metabDaily ||
                c.readiness,
            'history');
        return _submitRemaining(5, 0xfa, const []);
      });

  Future<JwHistoryResult> syncHistory(
      {JwHistoryOptions options = const JwHistoryOptions()}) async {
    late JwHistoryResult result;
    await _operate(() async {
      options.validate();
      final key = historyDeviceKey;
      final capabilities = state.capabilities;
      if (capabilities == null) {
        throw StateError('JW history capabilities unavailable');
      }
      final cancellation = Completer<JwHistoryResult>();
      _historySetupCancellation = cancellation;
      Future<T> setup<T>(Future<T> operation) => Future.any([
            operation,
            cancellation.future.then<T>(
                (result) => throw JwHistoryException('cancelled', result))
          ]);
      _publish(state.copyWith(
          historyProgress: _historySetupResult(JwHistoryPhase.starting),
          lastHistoryResult: null));
      try {
        if (state.heartRateStreaming) {
          await setup(_setHeartRateStreaming(false));
        }
        final store = await setup(_getHistoryStore());
        if (cancellation.isCompleted) {
          throw JwHistoryException('cancelled', await cancellation.future);
        }
        if (_disposed || _lost || !session.isOpen) {
          throw StateError('JW session lost during history initialization');
        }
        if (_history == null) {
          _history = JwHistoryCoordinator(
              session: session,
              store: store,
              deviceKey: key,
              capabilities: capabilities);
          _historyProgress = _history!.progress.listen(
              (next) => _publish(state.copyWith(historyProgress: next)));
        }
        _historySetupCancellation = null;
        result = await _history!.synchronize(options: options);
        _publish(state.copyWith(lastHistoryResult: result));
      } on JwHistoryException catch (e) {
        _publish(state.copyWith(
            historyProgress: e.result, lastHistoryResult: e.result));
        rethrow;
      } finally {
        if (identical(_historySetupCancellation, cancellation)) {
          _historySetupCancellation = null;
        }
      }
    }, write: true);
    return result;
  }

  Future<void> cancelHistory() async {
    final setup = _historySetupCancellation;
    if (setup != null && !setup.isCompleted) {
      setup.complete(_historySetupResult(JwHistoryPhase.cancelled));
      await session.close();
      return;
    }
    await _history?.cancel();
  }

  Future<void> setHeartRateStreaming(bool enabled) =>
      _operate(() => _setHeartRateStreaming(enabled), write: true);
  Future<void> _setHeartRateStreaming(bool enabled) async {
    if (state.capabilities?.heartRate != true) {
      throw StateError('Heart rate unsupported');
    }
    _startingHeart = enabled;
    _earlyHeart = null;
    try {
      final reply =
          await session.request(JwCommands.heartRateStreaming(enabled));
      final value = reply.fields.single.value;
      if (value.length != 1 || value.single != (enabled ? 1 : 0)) {
        throw StateError('Heart rate state did not match request');
      }
      _publish(state.copyWith(
          heartRateStreaming: enabled,
          lastHeartRate: enabled ? _earlyHeart : null));
    } finally {
      _startingHeart = false;
      _earlyHeart = null;
    }
  }

  void _onMessage(JwMessage message) {
    if (_disposed || _lost || (!_startingHeart && !state.heartRateStreaming)) {
      return;
    }
    try {
      final samples = JwProtocol.heartRates(message);
      if (samples.isEmpty) return;
      if (_startingHeart) {
        _earlyHeart = samples.last;
      } else {
        _publish(state.copyWith(lastHeartRate: samples.last));
      }
    } on FormatException {
      /* Invalid sensor data cannot become a health value. */
    }
  }

  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    await _events?.cancel();
    await _down?.cancel();
    await _sessionFailures?.cancel();
    try {
      await _history?.dispose();
      await _historyProgress?.cancel();
      // _getHistoryStore closes an owned store if its factory resolves after
      // disposal. Do not delay link cleanup on an unfinished directory scan.
      if (ownsHistoryStore) {
        await _historyStore?.close();
      }
    } finally {
      try {
        await session.close();
      } finally {
        await _changes.close();
      }
    }
  }
}
