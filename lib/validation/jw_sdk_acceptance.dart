import 'dart:convert';
import 'dart:typed_data';
import '../services/jw/jw_codec.dart';
import '../services/jw/jw_session.dart';
import 'package:crypto/crypto.dart';
import '../services/jw/jw_configuration.dart';
import '../services/jw/jw_protocol.dart';
import 'dart:async';
import '../services/jw/history/jw_history_models.dart';
import '../providers/ble_provider.dart';
import '../services/jw/jw_models.dart';
import '../services/jw/jw_device_repository.dart';
import '../services/jw/jw_transport.dart';
import 'jw_remaining_acceptance.dart';
import 'jw_history_replay_acceptance.dart';

class AcceptanceConfig {
  final String outputDirectory;
  final String? address, name, expectedIdentitySha256, expectedFunctions;
  final int? expectedFactory;
  final Duration scanWindow, heartTimeout;
  final int scanAttempts, reconnectRounds;
  final String mode;
  final String? historyBaselineFile;
  final String? configurationBaselineFile;
  final String? readOnlyBaselineFile;
  final String? remainingBaselineFile;
  final bool labAuthorized;
  final int historyRounds;
  final JwHistoryOptions historyOptions;
  AcceptanceConfig(
      {required this.outputDirectory,
      this.address,
      this.name,
      this.scanWindow = const Duration(seconds: 120),
      this.scanAttempts = 3,
      this.heartTimeout = const Duration(seconds: 60),
      this.reconnectRounds = 2,
      this.mode = 'full',
      this.historyBaselineFile,
      this.configurationBaselineFile,
      this.readOnlyBaselineFile,
      this.remainingBaselineFile,
      this.labAuthorized = false,
      this.historyRounds = 2,
      this.historyOptions = const JwHistoryOptions(),
      this.expectedIdentitySha256,
      this.expectedFunctions,
      this.expectedFactory}) {
    if (outputDirectory.isEmpty ||
        (address == null && (name?.isEmpty ?? true)) ||
        (address != null &&
            !RegExp(r'^[0-9A-F]{2}(:[0-9A-F]{2}){5}$').hasMatch(address!)) ||
        scanWindow.inSeconds < 1 ||
        scanWindow.inSeconds > 3600 ||
        scanAttempts < 1 ||
        scanAttempts > 10 ||
        reconnectRounds < 0 ||
        reconnectRounds > 10 ||
        heartTimeout.inSeconds < 1 ||
        heartTimeout.inSeconds > 300 ||
        ![
          'full',
          'restart',
          'history',
          'history-restart',
          'history-replay',
          'history-replay-restart',
          'configuration-read',
          'configuration',
          'configuration-restart',
          'read-only',
          'read-only-restart',
          'remaining-observe',
          'remaining-routine',
          'remaining-lab',
          'remaining-restart'
        ].contains(mode) ||
        (['restart', 'history-restart', 'configuration-restart']
                .contains(mode) &&
            expectedIdentitySha256 == null) ||
        ((mode.startsWith('read-only') || mode.startsWith('remaining-')) &&
            expectedIdentitySha256 == null) ||
        (mode.startsWith('history-replay') &&
            (expectedIdentitySha256 == null ||
                address == null ||
                expectedFunctions == null ||
                expectedFactory == null)) ||
        (mode == 'history-replay-restart' &&
            (historyBaselineFile?.isEmpty ?? true)) ||
        (mode == 'read-only-restart' &&
            (readOnlyBaselineFile?.isEmpty ?? true)) ||
        (mode == 'history-restart' && (historyBaselineFile?.isEmpty ?? true)) ||
        (mode == 'configuration-restart' &&
            (configurationBaselineFile?.isEmpty ?? true)) ||
        historyRounds < 1 ||
        historyRounds > 10 ||
        (expectedIdentitySha256 != null &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedIdentitySha256!)) ||
        (expectedFunctions != null &&
            !RegExp(r'^[0-9a-f]{16}$').hasMatch(expectedFunctions!)) ||
        (expectedFactory != null &&
            (expectedFactory! < 0 || expectedFactory! > 255))) {
      throw ArgumentError(
          'Invalid SDK acceptance selector, window, mode or digest');
    }
    historyOptions.validate();
  }
  factory AcceptanceConfig.parse(List<String> args) {
    const allowed = {
      '--address',
      '--name',
      '--output',
      '--scan-seconds',
      '--scan-attempts',
      '--heart-seconds',
      '--reconnect-rounds',
      '--mode',
      '--expected-id-sha256',
      '--expect-functions',
      '--expect-factory',
      '--history-rounds',
      '--history-idle-seconds',
      '--history-total-seconds',
      '--history-max-queue-mb',
      '--history-baseline',
      '--configuration-baseline',
      '--read-only-baseline',
      '--remaining-baseline',
      '--lab-authorized'
    };
    final values = <String, String>{};
    for (var i = 0; i < args.length; i += 2) {
      if (!allowed.contains(args[i]) ||
          i + 1 >= args.length ||
          values.containsKey(args[i])) {
        throw ArgumentError(
            'Unknown, duplicate or missing command-line argument');
      }
      values[args[i]] = args[i + 1];
    }
    int number(String key, int fallback) {
      final n = values[key] == null ? fallback : int.tryParse(values[key]!);
      if (n == null) throw ArgumentError('Invalid numeric argument $key');
      return n;
    }

    final factory = values['--expect-factory'];
    final factoryValue =
        factory == null ? null : int.tryParse(factory, radix: 16);
    if (factory != null && factoryValue == null) {
      throw ArgumentError('Invalid factory hex');
    }
    return AcceptanceConfig(
        outputDirectory:
            values['--output'] ?? 'output/jw-sdk-acceptance/manual',
        address: values['--address']?.toUpperCase(),
        name: values['--name']?.trim(),
        scanWindow: Duration(seconds: number('--scan-seconds', 120)),
        scanAttempts: number('--scan-attempts', 3),
        heartTimeout: Duration(seconds: number('--heart-seconds', 60)),
        reconnectRounds: number('--reconnect-rounds', 2),
        mode: values['--mode'] ?? 'full',
        historyBaselineFile: values['--history-baseline'],
        configurationBaselineFile: values['--configuration-baseline'],
        readOnlyBaselineFile: values['--read-only-baseline'],
        remainingBaselineFile: values['--remaining-baseline'],
        labAuthorized: values['--lab-authorized'] == 'true',
        historyRounds: number('--history-rounds', 2),
        historyOptions: JwHistoryOptions(
            idleTimeout:
                Duration(seconds: number('--history-idle-seconds', 30)),
            totalTimeout:
                Duration(seconds: number('--history-total-seconds', 1800)),
            maxQueuedBytes: number('--history-max-queue-mb', 32) * 1024 * 1024),
        expectedIdentitySha256: values['--expected-id-sha256'],
        expectedFunctions: values['--expect-functions']?.toLowerCase(),
        expectedFactory: factoryValue);
  }
  bool matches(ScanDevice d) =>
      !d.debug &&
      d.connectable &&
      (address == null || d.deviceId.toUpperCase() == address) &&
      (name == null || d.name == name);
}

/// Orchestration boundary only. The Windows adapter calls production providers;
/// protocol framing, requests, retries and identity persistence stay in the SDK.
abstract interface class JwAcceptancePort {
  Future<void> startScan();
  void stopScan();
  List<ScanDevice> get devices;
  Future<void> connect(ScanDevice target);
  Future<void> initialize();
  Future<void> bindFirstTime({required bool confirmedFirstBind});
  JwDeviceState get state;
  Future<String> identityDigest();
  Future<void> setLanguage(int value);
  Future<void> setHeartRateStreaming(bool enabled);
  Future<void> syncTime(DateTime value);
  Future<void> disconnect();
  Future<void> close();
}

abstract interface class JwHistoryAcceptancePort implements JwAcceptancePort {
  Future<JwHistoryResult> syncHistory(JwHistoryOptions options);
  Future<JwHistoryInventory> historyInventory();
  Future<void> cancelHistory();
}

abstract interface class JwConfigurationAcceptancePort
    implements JwAcceptancePort {
  Future<JwConfigurationValue> readConfiguration(JwConfigurationDomain domain,
      {required JwConfigurationContract contract});
  Future<JwConfigurationSnapshot> readConfigurationSnapshot(
      {required JwConfigurationContract contract});
  Future<JwConfigurationPreflight> readConfigurationPreflight(
      {required JwConfigurationContract contract});
  Future<JwConfigurationWriteResult> setConfigurationVerified(
      JwConfigurationChange change,
      {required JwConfigurationContract contract,
      required JwConfigurationValue expectedCurrent});
  Future<JwConfigurationWriteResult> setTemperatureUnitVerified(bool celsius,
      {required JwConfigurationContract contract,
      required JwConfigurationValue expectedCurrent});
}

String _configurationHex(List<int> bytes) =>
    bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
Map<String, Object?> _configurationValueJson(JwConfigurationValue value) => {
      'raw': _configurationHex(value.raw),
      if (value.companionRaw != null)
        'companionRaw': _configurationHex(value.companionRaw!),
    };

const _configurationSources = {
  'sdk': '631bb21e149ec4822516b34cacf2a78193b208f6',
  'firmware': '91dc0a6077d118969fbd25126283d06f1d6107fa',
  'honeyboxDesign': '8a784056923aba99cef54254e59faa8eb70af5fd',
};

class _ConfigurationBaseline {
  final Map<String, Object?> payload;
  final JwConfigurationSnapshot snapshot;
  final String digest;
  _ConfigurationBaseline._(this.payload, this.snapshot, this.digest);
  factory _ConfigurationBaseline.parse(Map<String, Object?> envelope) {
    if (jsonEncode(envelope).length > 1024 * 1024 ||
        envelope['schemaVersion'] != 3 ||
        envelope['baseline'] is! Map ||
        envelope['baselineSha256'] is! String) {
      throw StateError('Invalid configuration baseline envelope');
    }
    final p = (jsonDecode(jsonEncode(envelope['baseline'])) as Map)
        .cast<String, Object?>();
    final hash = sha256.convert(utf8.encode(jsonEncode(p))).toString();
    if (hash != envelope['baselineSha256']) {
      throw StateError('Configuration baseline SHA mismatch');
    }
    const keys = {
      'deviceKey',
      'identitySha256',
      'contract',
      'firmware',
      'hardware',
      'functions',
      'factory',
      'sources',
      'configuration'
    };
    if (p.keys.toSet().difference(keys).isNotEmpty ||
        p.length != keys.length ||
        p['deviceKey'] is! String ||
        !(p['deviceKey'] as String).startsWith('jw:') ||
        (p['deviceKey'] as String).length <= 3 ||
        p['identitySha256'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(p['identitySha256'] as String) ||
        p['contract'] != 'v101S200' ||
        p['firmware'] != 'T005' ||
        p['hardware'] != 'H001' ||
        p['functions'] is! String ||
        !RegExp(r'^[0-9a-f]{16}$').hasMatch(p['functions'] as String) ||
        p['factory'] is! int ||
        (p['factory'] as int) < 0 ||
        (p['factory'] as int) > 255 ||
        p['sources'] is! Map ||
        (p['sources'] as Map).length != _configurationSources.length ||
        _configurationSources.entries
            .any((e) => (p['sources'] as Map)[e.key] != e.value) ||
        p['configuration'] is! Map) {
      throw StateError('Invalid configuration baseline metadata');
    }
    final entries = p['configuration'] as Map;
    if (entries.length != 8 ||
        entries.keys
            .toSet()
            .difference(JwConfigurationDomain.values.map((d) => d.name).toSet())
            .isNotEmpty) {
      throw StateError('Configuration baseline requires exactly eight domains');
    }
    Uint8List raw(Object? s) {
      if (s is! String ||
          s.length > 8 ||
          !RegExp(r'^(?:[0-9a-f]{2})+$').hasMatch(s)) {
        throw StateError('Invalid configuration baseline raw hex');
      }
      return Uint8List.fromList([
        for (var i = 0; i < s.length; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16)
      ]);
    }

    final values = <JwConfigurationDomain, JwConfigurationValue>{};
    for (final d in JwConfigurationDomain.values) {
      final e = entries[d.name];
      if (e is! Map ||
          e.length != (d == JwConfigurationDomain.bloodPressureAuto ? 2 : 1) ||
          !e.containsKey('raw') ||
          (d == JwConfigurationDomain.bloodPressureAuto &&
              !e.containsKey('companionRaw'))) {
        throw StateError('Invalid configuration baseline value');
      }
      final value = JwConfigurationValue(d, raw(e['raw']),
          companionRaw: d == JwConfigurationDomain.bloodPressureAuto
              ? raw(e['companionRaw'])
              : null);
      if (!value.writable) {
        throw StateError('Noncanonical configuration baseline');
      }
      values[d] = value;
    }
    return _ConfigurationBaseline._(
        Map.unmodifiable(p), JwConfigurationSnapshot(values), hash);
  }
  Map<String, Object?> get envelope => {
        'schemaVersion': 3,
        'baseline': jsonDecode(jsonEncode(payload)),
        'baselineSha256': digest,
      };
}

abstract interface class JwReadOnlyAcceptancePort implements JwAcceptancePort {
  Stream<JwFrame> get outgoingFrames;
  Future<void> prepareReadOnlyIdentity(String expectedDigest);
  Future<int> queryLanguage();
  Future<int> readBatteryLevel();
  Future<JwHealthStatus> readHealthStatus(
      {required JwConfigurationContract contract});
  Future<JwTurnOverWristStatus> readTurnOverWrist(
      {required JwConfigurationContract contract});
  Future<JwDisturbStatus> readDisturb(
      {required JwConfigurationContract contract});
  Future<JwHeatStressReminderStatus> queryHeatStressReminder(
      {required JwConfigurationContract contract});
  Future<JwHeartRateReminderDiagnostic> readHeartRateReminderDiagnostic(
      {required JwConfigurationContract contract});
}

const _readOnlyNames = [
  'language',
  'battery',
  'health',
  'wrist',
  'dnd',
  'heatWindow',
  'highHrDiagnostic'
];
String _readHex(List<int> raw) =>
    raw.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
Uint8List _readBytes(String raw) {
  if (!RegExp(r'^(?:[0-9a-f]{2})+$').hasMatch(raw)) {
    throw StateError('Invalid read-only raw hex');
  }
  return Uint8List.fromList([
    for (var i = 0; i < raw.length; i += 2)
      int.parse(raw.substring(i, i + 2), radix: 16)
  ]);
}

Map<String, Object?> _readOnlyFields(String name, Uint8List raw) {
  switch (name) {
    case 'language':
      return {
        'value': JwProtocol.language(JwMessage(2, [JwField(0x50, raw)]))
      };
    case 'battery':
      return {'value': JwProtocol.battery(raw)};
    case 'health':
      final v = JwHealthStatus(raw);
      return {
        'reportedBits': v.reportedBits,
        'hrManualReported': v.hrManualReported,
        'hrContinuousReported': v.hrContinuousReported,
        'bpManualReported': v.bpManualReported,
        'bpContinuousReported': v.bpContinuousReported,
        'spo2ManualReported': v.spo2ManualReported,
        'spo2ContinuousReported': v.spo2ContinuousReported,
        'stressManualReported': v.stressManualReported,
        'stressContinuousReported': v.stressContinuousReported,
        'exerciseReported': v.exerciseReported,
        'ecgReported': v.ecgReported
      };
    case 'wrist':
      return {'savedEnabled': JwTurnOverWristStatus(raw).savedEnabled};
    case 'dnd':
      final v = JwDisturbStatus(raw);
      return {
        'enabled': v.enabled,
        'startMinutes': v.startMinutes,
        'endMinutes': v.endMinutes,
        'active': v.active
      };
    case 'heatWindow':
      final v = JwHeatStressReminderStatus(raw);
      return {
        'timeWindowEnabled': v.timeWindowEnabled,
        'startMinutes': v.startMinutes,
        'endMinutes': v.endMinutes,
        'allDayAllowedByTimeGate': v.allDayAllowedByTimeGate
      };
    case 'highHrDiagnostic':
      final v = JwHeartRateReminderDiagnostic(raw);
      return {'reportedFlag': v.reportedFlag, 'threshold': v.threshold};
    default:
      throw StateError('Unknown read-only operation');
  }
}

String _readOnlyStable(String name, String raw) => name == 'dnd'
    ? (int.parse(raw, radix: 16) & 0x7fffff).toRadixString(16).padLeft(6, '0')
    : raw;

class _ReadOnlyRun {
  final JwReadOnlyAcceptancePort port;
  final AcceptanceConfig config;
  final Map<String, Object?>? baseline;
  final List<Map<String, Object?>> results = [], wire = [];
  final observed = <String, int>{};
  final saved = <String, String>{};
  StreamSubscription<JwFrame>? subscription;
  Map<String, Object?>? device;
  String? violation;
  bool? staticRetained;
  _ReadOnlyRun(this.port, this.config, this.baseline);
  Future<void> prepare() async {
    if (config.mode == 'read-only-restart') {
      final b = baseline;
      if (b == null ||
          b['schemaVersion'] != 4 ||
          b['mode'] != 'read-only' ||
          b['status'] != 'pass' ||
          b['exitCode'] != 0 ||
          b['readOnlyWireAudit'] is! Map ||
          (b['readOnlyWireAudit'] as Map)['status'] != 'pass' ||
          b['readOnlyDevice'] is! Map ||
          b['readOnlyResults'] is! List) {
        throw StateError('Invalid read-only restart baseline');
      }
      for (final dynamic entry in b['readOnlyResults'] as List) {
        if (entry is! Map ||
            entry['status'] != 'pass' ||
            !_readOnlyNames.contains(entry['operation']) ||
            entry['raw'] is! String ||
            saved.containsKey(entry['operation'])) {
          throw StateError('Invalid read-only baseline result');
        }
        final name = entry['operation'] as String, raw = entry['raw'] as String;
        _readOnlyFields(name, _readBytes(raw));
        saved[name] = raw;
      }
      if (saved.length != 7) {
        throw StateError('Read-only baseline requires seven queries');
      }
    }
    subscription = port.outgoingFrames.listen(_observe);
    await port.prepareReadOnlyIdentity(config.expectedIdentitySha256!);
  }

  void _observe(JwFrame frame) {
    final event = <String, Object?>{
      'type': 'wireAttempt',
      'seq': frame.seq,
      'ack': frame.ack
    };
    try {
      if (frame.ack) {
        if (frame.payload.isNotEmpty || frame.error) {
          throw StateError('Invalid outbound ACK');
        }
      } else {
        final m = JwCodec.decodeL2(frame.payload);
        if (m.fields.length != 1) throw StateError('Multiple outbound fields');
        final f = m.fields.single;
        event.addAll(
            {'command': m.command, 'key': f.key, 'length': f.value.length});
        final tag = '${m.command}/${f.key}';
        final query = {
              '2/54',
              '6/61',
              '2/79',
              '5/58',
              '2/43',
              '2/72',
              '2/135',
              '2/118'
            }.contains(tag) &&
            f.value.isEmpty;
        final login = tag == '3/3' && f.value.length == 32;
        if (!query && !login) {
          throw StateError(
              'Outbound command outside read-only allowlist: $tag');
        }
        observed[tag] = (observed[tag] ?? 0) + 1;
      }
      event['allowed'] = true;
    } catch (e) {
      violation ??= e.toString();
      event['allowed'] = false;
      event['error'] = e.toString();
    }
    wire.add(event);
  }

  void checkAudit() {
    if (violation != null) throw StateError(violation!);
  }

  void checkDevice(String key, String identity) {
    final s = port.state, c = s.capabilities;
    if (s.info?.firmware != 'T005' || s.info?.hardware != 'H001' || c == null) {
      throw JwConfigurationException(
          stage: 'unsupported',
          cause: 'read-only requires V101 S200 T005/H001 contract');
    }
    device = {
      'deviceKey': key,
      'identitySha256': identity,
      'functions': c.rawHex,
      'factory': c.factorySwitchRaw,
      'firmware': s.info!.firmware,
      'hardware': s.info!.hardware
    };
    if (baseline != null) {
      final previous = baseline!['readOnlyDevice'] as Map;
      for (final entry in device!.entries) {
        if (previous[entry.key] != entry.value) {
          throw StateError(
              'Read-only device attribution changed: ${entry.key}');
        }
      }
    }
    checkAudit();
  }

  Future<void> queryAll(
      Future<Map<String, Object?>> Function(
              String, Future<Map<String, Object?>> Function())
          step) async {
    const contract = JwConfigurationContract.v101S200;
    for (final name in _readOnlyNames) {
      final entry = await step('readOnly.$name', () async {
        final Uint8List raw;
        switch (name) {
          case 'language':
            final value = await port.queryLanguage();
            if (value < 0 || value > 2) {
              throw StateError('Invalid language scalar');
            }
            raw = Uint8List.fromList([value]);
            break;
          case 'battery':
            final value = await port.readBatteryLevel();
            if (value < 0 || value > 100) {
              throw StateError('Invalid battery scalar');
            }
            raw = Uint8List.fromList([value]);
            break;
          case 'health':
            raw = (await port.readHealthStatus(contract: contract)).raw;
            break;
          case 'wrist':
            raw = (await port.readTurnOverWrist(contract: contract)).raw;
            break;
          case 'dnd':
            raw = (await port.readDisturb(contract: contract)).raw;
            break;
          case 'heatWindow':
            raw = (await port.queryHeatStressReminder(contract: contract)).raw;
            break;
          default:
            raw =
                (await port.readHeartRateReminderDiagnostic(contract: contract))
                    .raw;
        }
        checkAudit();
        final fields = _readOnlyFields(name, raw), hex = _readHex(raw);
        return {
          'operation': name,
          'status': 'pass',
          'raw': hex,
          'fields': fields
        };
      });
      results.add(entry);
    }
    if (config.mode == 'read-only-restart') {
      staticRetained = results
          .where(
              (r) => r['operation'] != 'battery' && r['operation'] != 'health')
          .every((r) =>
              _readOnlyStable(r['operation'] as String, r['raw'] as String) ==
              _readOnlyStable(
                  r['operation'] as String, saved[r['operation']]!));
      if (staticRetained != true) {
        throw StateError('Read-only static intent changed; no recovery writes');
      }
    }
  }

  Future<Map<String, Object?>> finish(
      Future<void> Function(Map<String, Object?>) record,
      {required bool success}) async {
    await subscription?.cancel();
    final required = {
      '2/54',
      '6/61',
      '2/79',
      '3/3',
      '5/58',
      '2/43',
      '2/72',
      '2/135',
      '2/118'
    };
    final witnessed = required.every((t) => (observed[t] ?? 0) > 0) &&
        (observed['2/79'] ?? 0) >= 2;
    if (success && !witnessed) {
      violation ??= 'Missing actual outbound query witnesses';
    }
    for (final event in wire) {
      await record(event);
    }
    return {
      'status': violation != null
          ? 'fail'
          : success && witnessed
              ? 'pass'
              : 'incomplete',
      'attempts': wire.length,
      'applicationAttempts': wire.where((e) => e['ack'] == false).length,
      'ackAttempts': wire.where((e) => e['ack'] == true).length,
      'observedCommandCounts': observed,
      'forbiddenAttempts': wire.where((e) => e['allowed'] == false).length,
      if (violation != null) 'error': violation
    };
  }
}

class _Cancelled implements Exception {
  @override
  String toString() => 'Acceptance cancelled';
}

class AcceptanceRunner {
  final JwAcceptancePort port;
  final AcceptanceConfig config;
  final DateTime Function() now;
  final Future<void> Function(Duration) delay;
  final bool Function() isCancelled;
  final Future<void> Function(Map<String, Object?>) record;
  final _steps = <Map<String, Object?>>[];
  String? _identity;
  String _firstBindResult = 'not_run_no_destructive_action_authorization';
  final Map<String, Object?>? historyBaseline;
  final Map<String, Object?>? configurationBaseline;
  final Map<String, Object?>? readOnlyBaseline;
  _ReadOnlyRun? _readOnly;
  Map<String, Object?>? _readOnlyAudit;
  JwHistoryReplayRun? _replay;
  bool get _isReplay => config.mode.startsWith('history-replay');
  bool get _isReadOnly => config.mode.startsWith('read-only');
  final Future<void> Function(Map<String, Object?>)? saveConfigurationBaseline;
  _ConfigurationBaseline? _configurationSaved;
  String? _configurationDeviceKey, _configurationJournalError;
  bool _restoringConfiguration = false,
      _configurationRecoveryUsed = false,
      _configurationRestorePending = false;
  bool? _configurationRestored, _configurationReadyForProbe;
  final _configurationDomains = <Map<String, Object?>>[];
  final _historyRounds = <Map<String, Object?>>[];
  Map<String, Object?>? _historyInventory;
  String? _historyFailureStage, _targetAddress, _savedHistoryDeviceKey;
  bool? _persistedBaselineRetained, _exactInventoryDigestMatch;
  bool get _isHistory => config.mode.startsWith('history');
  String get _historyDeviceKey {
    final serial = port.state.info?.deviceKey.trim();
    return 'jw:${serial != null && serial.isNotEmpty ? serial : _targetAddress}';
  }

  AcceptanceRunner(
      {required this.port,
      required this.config,
      required this.record,
      this.historyBaseline,
      this.configurationBaseline,
      this.readOnlyBaseline,
      this.saveConfigurationBaseline,
      DateTime Function()? now,
      Future<void> Function(Duration)? delay,
      bool Function()? isCancelled})
      : now = now ?? DateTime.now,
        delay = delay ?? Future<void>.delayed,
        isCancelled = isCancelled ?? (() => false);
  void _cancel() {
    if (_restoringConfiguration) return;
    if (isCancelled()) throw _Cancelled();
  }

  void _require(bool ok, String message) {
    if (!ok) throw StateError(message);
  }

  void _ready() {
    _require(
        port.state.canWrite && port.state.operationError == null,
        port.state.operationError ??
            'SDK not logged in or operation incomplete');
  }

  Future<Map<String, Object?>> _step(
      String name, Future<Map<String, Object?>> Function() action) async {
    final start = now();
    try {
      _cancel();
      final data = await action();
      _cancel();
      final result = {
        'name': name,
        'status': 'pass',
        'elapsedMs': now().difference(start).inMilliseconds,
        ...data
      };
      _steps.add(result);
      await record({'type': 'step', ...result});
      return data;
    } catch (e) {
      final result = {
        'name': name,
        'status': e is _Cancelled ? 'cancelled' : 'fail',
        'elapsedMs': now().difference(start).inMilliseconds,
        'error': e.toString(),
        if (e is JwConfigurationException) 'raw': _readHex(e.raw),
        if (e is JwConfigurationException) 'failureStage': e.stage,
        if (e is JwLinkException) 'failureStage': e.stage
      };
      _steps.add(result);
      await record({'type': 'step', ...result});
      rethrow;
    }
  }

  Future<ScanDevice> _discover(String tag) async {
    ScanDevice? selected;
    await _step('scan.$tag', () async {
      for (var attempt = 1; attempt <= config.scanAttempts; attempt++) {
        _cancel();
        final start = now();
        var progress = start;
        try {
          await port.startScan();
          await record({
            'type': 'scanStart',
            'attempt': attempt,
            'tag': tag,
            'windowSeconds': config.scanWindow.inSeconds
          });
          while (now().difference(start) < config.scanWindow) {
            _cancel();
            for (final d in port.devices) {
              if (config.matches(d)) {
                selected = d;
                break;
              }
            }
            if (selected != null) {
              return {
                'attempt': attempt,
                'discoveryMs': now().difference(start).inMilliseconds,
                'target': selected!.deviceId,
                'targetName': selected!.name,
                'candidate': selected!.jwCandidate,
                'firstSeenUtc': selected!.firstSeen?.toUtc().toIso8601String(),
                'identitySeenUtc':
                    selected!.identitySeen?.toUtc().toIso8601String()
              };
            }
            if (now().difference(progress) >= const Duration(seconds: 5)) {
              progress = now();
              await record({
                'type': 'scanProgress',
                'tag': tag,
                'attempt': attempt,
                'elapsedMs': now().difference(start).inMilliseconds,
                'devicesObserved': port.devices.length
              });
            }
            await delay(const Duration(milliseconds: 200));
          }
          await record({
            'type': 'scanWindowElapsed',
            'tag': tag,
            'attempt': attempt,
            'elapsedMs': now().difference(start).inMilliseconds,
            'devicesObserved': port.devices.length
          });
        } finally {
          port.stopScan();
        }
        if (attempt < config.scanAttempts) {
          await delay(const Duration(seconds: 1));
        }
      }
      throw StateError(
          'Target not discovered after configured scan windows; no address bypass');
    });
    return selected!;
  }

  Future<void> _connectAndLogin(String tag) async {
    final target = await _discover(tag);
    _targetAddress = target.deviceId;
    await _step('connect.$tag', () async {
      await port.connect(target);
      return {'selectedFromScan': true};
    });
    await _step('query_login.$tag', () async {
      await port.initialize();
      final needsBind = port.state.phase == JwDevicePhase.loginRejected;
      if (needsBind && !config.labAuthorized) {
        _ready();
      }
      if (!needsBind) {
        _ready();
        if (config.labAuthorized) _firstBindResult = 'not_needed';
      }
      final caps = port.state.capabilities;
      _require(caps != null, 'Missing real capability response');
      if (config.expectedFunctions != null) {
        _require(caps!.rawHex == config.expectedFunctions,
            'Function list differs from reference');
      }
      if (config.expectedFactory != null) {
        _require(caps!.factorySwitchRaw == config.expectedFactory,
            'Factory switches differ from reference');
      }
      final digest = await port.identityDigest();
      _require(RegExp(r'^[0-9a-f]{64}$').hasMatch(digest),
          'Invalid identity digest');
      _require((_identity ?? config.expectedIdentitySha256 ?? digest) == digest,
          'Persisted identity changed');
      _identity ??= digest;
      return {
        'phase': port.state.phase.name,
        'functions': caps!.rawHex,
        'factory': caps.factorySwitchRaw,
        'firmware': port.state.info?.firmware,
        'hardware': port.state.info?.hardware,
        'battery': port.state.info?.battery,
        'language': port.state.language,
        'identitySha256': digest,
        if (needsBind && config.labAuthorized) 'needFirstBind': true
      };
    });
    if (port.state.phase == JwDevicePhase.loginRejected &&
        config.labAuthorized) {
      await _step('firstBind.$tag', () async {
        _firstBindResult = 'fail';
        await port.bindFirstTime(confirmedFirstBind: true);
        _firstBindResult = 'pass';
        _ready();
        return {'phase': port.state.phase.name};
      });
    }
    if (_isHistory) _savedHistoryDeviceKey = _historyDeviceKey;
    if (_isConfiguration) _configurationDeviceKey ??= _historyDeviceKey;
  }

  Future<JwHistoryResult> _syncHistoryRound(int index) async {
    late JwHistoryResult completed;
    await _step('history.$index', () async {
      _require(port is JwHistoryAcceptancePort,
          'Production history SDK port unavailable');
      final history = port as JwHistoryAcceptancePort;
      JwHistoryResult? result;
      Object? error;
      var finished = false;
      final running =
          history.syncHistory(config.historyOptions).then<void>((value) {
        result = value;
        finished = true;
      }, onError: (Object e, StackTrace st) {
        error = e;
        finished = true;
      });
      var lastProgress = now();
      while (!finished) {
        if (isCancelled()) {
          await history.cancelHistory();
          await running;
          if (error is JwHistoryException) {
            _historyRounds.add((error as JwHistoryException).result.toJson());
            _historyFailureStage = (error as JwHistoryException).stage;
          }
          throw _Cancelled();
        }
        if (now().difference(lastProgress) >= const Duration(seconds: 5)) {
          lastProgress = now();
          await record({
            'type': 'historyProgress',
            'round': index,
            ...?port.state.historyProgress?.toJson()
          });
        }
        await delay(const Duration(milliseconds: 200));
      }
      await running;
      if (error != null) {
        if (error is JwHistoryException) {
          _historyFailureStage = (error as JwHistoryException).stage;
          _historyRounds.add((error as JwHistoryException).result.toJson());
        }
        throw error!;
      }
      completed = result!;
      final data = result!.toJson();
      _historyRounds.add(data);
      _require(
          result!.wireRoundComplete &&
              result!.localCommitComplete &&
              result!.applicationAckTransportDelivered,
          'Observed history round did not satisfy transport/durable/confirmation gates');
      return data;
    });
    return completed;
  }

  Future<void> _readHistoryInventory() async {
    await _step('history.inventory', () async {
      _require(port is JwHistoryAcceptancePort,
          'Production history SDK port unavailable');
      final inventory =
          await (port as JwHistoryAcceptancePort).historyInventory();
      _historyInventory = inventory.toJson();
      if (config.mode == 'history-restart') {
        final baseline = historyBaseline;
        _require(baseline != null && baseline['inventory'] is Map,
            'Missing persisted history baseline');
        if (baseline!['historyDeviceKey'] != null) {
          _require(baseline['historyDeviceKey'] == _historyDeviceKey,
              'History baseline belongs to a different device');
        }
        final previous = baseline['inventory'] as Map;
        _require(previous['recordIds'] is List,
            'Invalid persisted history baseline');
        final previousIds = (previous['recordIds'] as List).cast<String>();
        _require(
            previousIds.every((id) => RegExp(r'^[0-9a-f]{64}$').hasMatch(id)),
            'Invalid persisted record ID');
        final retained = inventory.recordIds.toSet().containsAll(previousIds);
        _persistedBaselineRetained = retained;
        _exactInventoryDigestMatch = previous['digest'] == inventory.digest;
        _require(retained,
            'Previously persisted history records are missing after independent restart');
      }
      return inventory.toJson();
    });
  }

  bool get _isConfiguration => config.mode.startsWith('configuration');
  static const _configurationContract = JwConfigurationContract.v101S200;
  JwConfigurationAcceptancePort get _configurationPort {
    if (port is! JwConfigurationAcceptancePort) {
      throw StateError('Production configuration SDK port unavailable');
    }
    return port as JwConfigurationAcceptancePort;
  }

  _ConfigurationBaseline _makeConfigurationBaseline(
      JwConfigurationSnapshot snapshot) {
    final state = port.state;
    final payload = <String, Object?>{
      'deviceKey': _configurationDeviceKey,
      'identitySha256': _identity,
      'contract': _configurationContract.name,
      'firmware': state.info?.firmware,
      'hardware': state.info?.hardware,
      'functions': state.capabilities?.rawHex,
      'factory': state.capabilities?.factorySwitchRaw,
      'sources': _configurationSources,
      'configuration': {
        for (final d in JwConfigurationDomain.values)
          d.name: _configurationValueJson(snapshot.values[d]!)
      },
    };
    return _ConfigurationBaseline.parse({
      'schemaVersion': 3,
      'baseline': payload,
      'baselineSha256':
          sha256.convert(utf8.encode(jsonEncode(payload))).toString()
    });
  }

  void _checkConfigurationDevice() {
    final p = _configurationSaved!.payload, state = port.state;
    _require(
        _historyDeviceKey == p['deviceKey'] &&
            _identity == p['identitySha256'] &&
            state.info?.firmware == p['firmware'] &&
            state.info?.hardware == p['hardware'] &&
            state.capabilities?.rawHex == p['functions'] &&
            state.capabilities?.factorySwitchRaw == p['factory'],
        'Configuration baseline device/identity/profile/capabilities mismatch');
  }

  Future<void> _recordConfigurationRestore(
      Map<String, Object?> event, Map<String, Object?> entry) async {
    try {
      await record(event);
    } catch (e) {
      _configurationJournalError = e.toString();
      entry['journalError'] = e.toString();
    }
  }

  Future<void> _configurationReconnect() async {
    _require(!_configurationRecoveryUsed,
        'Configuration recovery already attempted');
    _configurationRecoveryUsed = true;
    await port.disconnect();
    await _connectAndLogin('configuration-recovery');
    _checkConfigurationDevice();
  }

  Future<JwConfigurationValue> _configurationRecoveryRead(
      JwConfigurationDomain domain) async {
    try {
      return await _configurationPort.readConfiguration(domain,
          contract: _configurationContract);
    } catch (_) {
      await _configurationReconnect();
      return _configurationPort.readConfiguration(domain,
          contract: _configurationContract);
    }
  }

  JwConfigurationChange _configurationChangeTo(JwConfigurationValue value) {
    if (value.domain.isScalar) {
      return JwConfigurationChange.scalar(value.domain, value.scalarValue!);
    }
    if (value.domain.isMonitor) {
      return JwConfigurationChange.monitor(value.domain, value.enabled!,
          bloodPressureDisplay: value.bloodPressureDisplay);
    }
    return JwConfigurationChange.temperature(
        displayEnabled: value.displayEnabled,
        compensate: value.compensate,
        celsius: value.celsius);
  }

  JwConfigurationChange _configurationProbeChange(
      JwConfigurationValue original) {
    final d = original.domain;
    if (d == JwConfigurationDomain.screenLightTime) {
      return JwConfigurationChange.scalar(
          d, original.scalarValue == 10 ? 15 : 10);
    }
    if (d == JwConfigurationDomain.screenBrightness) {
      return JwConfigurationChange.scalar(
          d, original.scalarValue == 60 ? 80 : 60);
    }
    if (d.isScalar) {
      return JwConfigurationChange.scalar(d, original.scalarValue == 0 ? 1 : 0);
    }
    if (d.isMonitor) {
      return JwConfigurationChange.monitor(d, !original.enabled!);
    }
    return JwConfigurationChange.temperature(celsius: !original.celsius!);
  }

  bool _configurationRestoreAllowed(JwConfigurationValue current,
      JwConfigurationValue original, JwConfigurationValue target,
      {bool restoreAttempted = false}) {
    if (current.sameValue(original) || current.sameValue(target)) return true;
    if (current.domain != JwConfigurationDomain.bloodPressureAuto) return false;
    JwConfigurationValue coupled(JwConfigurationValue v) =>
        JwConfigurationValue(v.domain, v.raw,
            companionRaw: Uint8List.fromList([v.enabled! ? 0x80 : 0, 0, 0, 0]));
    return current.sameValue(coupled(target)) ||
        (restoreAttempted && current.sameValue(coupled(original)));
  }

  Future<bool> _restoreConfiguration(JwConfigurationValue original,
      JwConfigurationValue target, Map<String, Object?> entry) async {
    _restoringConfiguration = true;
    var restoreAttempted = false;
    try {
      var current = await _configurationRecoveryRead(original.domain);
      _checkConfigurationDevice();
      if (!current.sameValue(original)) {
        _require(
            current.writable &&
                _configurationRestoreAllowed(current, original, target),
            'Configuration restore conflict; external value is preserved');
        // Both restoration SETs were flushed in the initial durable intent.
        await _recordConfigurationRestore({
          'type': 'configurationRestoreIntent',
          'domain': original.domain.name,
          'current': _configurationValueJson(current),
          'original': _configurationValueJson(original)
        }, entry);
        restoreAttempted = true;
        await _configurationPort.setConfigurationVerified(
            _configurationChangeTo(original),
            contract: _configurationContract,
            expectedCurrent: current);
        current = await _configurationPort.readConfiguration(original.domain,
            contract: _configurationContract);
      }
      _require(
          current.sameValue(original), 'Configuration original not restored');
      entry['restored'] = true;
      entry['restorePending'] = false;
      entry['restoredValue'] = _configurationValueJson(current);
      await _recordConfigurationRestore({
        'type': 'configurationRestored',
        'domain': original.domain.name,
        'actual': _configurationValueJson(current)
      }, entry);
      return true;
    } catch (e) {
      // A failed restoration may nevertheless have applied; READ can confirm,
      // with one display-only completion for an exactly known BP intermediate.
      // The main SET is never repeated and third values remain untouched.
      if (restoreAttempted) {
        try {
          final observed = await _configurationRecoveryRead(original.domain);
          _checkConfigurationDevice();
          entry['restoreObserved'] = _configurationValueJson(observed);
          if (observed.sameValue(original)) {
            entry['restored'] = true;
            entry['restorePending'] = false;
            entry['restorationDeliveryError'] = e.toString();
            return true;
          }
          entry['knownRestoreIntermediate'] = _configurationRestoreAllowed(
              observed, original, target,
              restoreAttempted: true);
          final canCompleteDisplay = e is JwConfigurationException &&
              e.writeSubmitted == true &&
              original.domain == JwConfigurationDomain.bloodPressureAuto &&
              observed.writable &&
              jwConfigurationBytesEqual(observed.raw, original.raw) &&
              observed.sameValue(JwConfigurationValue(
                  original.domain, original.raw,
                  companionRaw: Uint8List.fromList(
                      [original.enabled! ? 0x80 : 0, 0, 0, 0])));
          if (canCompleteDisplay) {
            await _recordConfigurationRestore({
              'type': 'configurationRestoreCompanionIntent',
              'domain': original.domain.name,
              'current': _configurationValueJson(observed),
              'original': _configurationValueJson(original),
              'mainSetRepeated': false
            }, entry);
            // Exactly one bounded compensation. Fresh expectedCurrent and
            // preflight run again; equal main bytes mean the SDK sends only 25.
            await _configurationPort.setConfigurationVerified(
                _configurationChangeTo(original),
                contract: _configurationContract,
                expectedCurrent: observed);
            final confirmed = await _configurationPort.readConfiguration(
                original.domain,
                contract: _configurationContract);
            _checkConfigurationDevice();
            _require(confirmed.sameValue(original),
                'BP companion completion did not restore original');
            entry['restoreCompanionCompleted'] = true;
            entry['restored'] = true;
            entry['restorePending'] = false;
            entry['restoredValue'] = _configurationValueJson(confirmed);
            entry['restorationDeliveryError'] = e.toString();
            await _recordConfigurationRestore({
              'type': 'configurationRestored',
              'domain': original.domain.name,
              'actual': _configurationValueJson(confirmed)
            }, entry);
            return true;
          }
        } catch (readError) {
          entry['restoreReadError'] = readError.toString();
        }
      }
      _configurationRestorePending = true;
      entry['restored'] = false;
      entry['restorePending'] = true;
      entry['restoreError'] = e.toString();
      await _recordConfigurationRestore({
        'type': 'configurationRestorePending',
        'domain': original.domain.name,
        'error': e.toString()
      }, entry);
      return false;
    } finally {
      _restoringConfiguration = false;
    }
  }

  Future<void> _verifyAllConfigurationOriginal() async {
    final actual = await _configurationPort.readConfigurationSnapshot(
        contract: _configurationContract);
    _checkConfigurationDevice();
    _configurationRestored = JwConfigurationDomain.values.every((d) =>
        actual.values[d]!.sameValue(_configurationSaved!.snapshot.values[d]!));
    _require(_configurationRestored == true,
        'Another configuration domain differs from baseline; no overwrite');
    await record({
      'type': 'configurationFullSnapshotVerified',
      'baselineSha256': _configurationSaved!.digest,
      'domains': 8,
      'bpDisplayVerified': true
    });
  }

  Future<void> _configurationProbe(JwConfigurationDomain domain) async {
    final original = _configurationSaved!.snapshot.values[domain]!,
        change = _configurationProbeChange(
            _configurationSaved!.snapshot.values[domain]!);
    final target = JwConfigurationCodec.target(original, change);
    final entry =
        _configurationDomains.firstWhere((e) => e['domain'] == domain.name);
    Object? primaryError;
    var attempted = false;
    await _step('configuration.${domain.name}', () async {
      try {
        _cancel();
        _checkConfigurationDevice();
        final main = JwConfigurationCodec.writeRequest(target),
            restore = JwConfigurationCodec.writeRequest(original);
        await record({
          'type': 'configurationIntent',
          'domain': domain.name,
          'baselineSha256': _configurationSaved!.digest,
          'before': _configurationValueJson(original),
          'target': _configurationValueJson(target),
          'probeSet': _configurationHex(main.value),
          'restoreSet': _configurationHex(restore.value),
          if (original.companionRaw != null)
            'probeAndRestoreDisplaySet':
                _configurationHex(original.companionRaw!),
          'restoreCommandsAlreadyJournaled': true,
          'monitorSamplingMayPauseOrResume': domain.isMonitor,
          'sampleDeletionPerformed': false
        });
        attempted = true;
        _configurationRestored = false;
        entry['startedUtc'] = now().toUtc().toIso8601String();
        final result = await _configurationPort.setConfigurationVerified(change,
            contract: _configurationContract, expectedCurrent: original);
        _require(result.observed.sameValue(target),
            'SDK probe result differs from intended target');
        entry['probeVerified'] = true;
        entry['before'] = _configurationValueJson(result.before);
        entry['target'] = _configurationValueJson(result.observed);
        await record({
          'type': 'configurationProbeVerified',
          'domain': domain.name,
          'actual': _configurationValueJson(result.observed)
        });
        _cancel();
      } catch (e) {
        primaryError = e;
        entry['error'] = e.toString();
        if (e is JwConfigurationException) {
          entry['failureStage'] = e.stage;
          entry['writeSubmitted'] = e.writeSubmitted;
          if (e.writeSubmitted == false) {
            // The SDK proves refusal before transport; this value belongs to
            // another operation, even when it equals our intended probe.
            attempted = false;
            entry['restoreNotRequired'] = true;
            entry['restorePending'] = false;
          }
        }
      } finally {
        if (attempted) {
          final restored = await _restoreConfiguration(original, target, entry);
          entry['finishedUtc'] = now().toUtc().toIso8601String();
          if (restored) {
            try {
              await _verifyAllConfigurationOriginal();
            } catch (e) {
              primaryError ??= e;
              entry['fullSnapshotError'] = e.toString();
            }
          } else {
            primaryError ??= StateError('Configuration restoration pending');
          }
        }
      }
      if (_configurationJournalError != null) {
        primaryError ??= StateError(
            'Configuration event persistence failed: $_configurationJournalError');
      }
      entry['status'] = primaryError == null
          ? 'pass'
          : primaryError is _Cancelled
              ? 'cancelled'
              : primaryError is JwConfigurationException &&
                      (primaryError as JwConfigurationException).stage ==
                          'unsupported'
                  ? 'unsupported'
                  : 'fail';
      if (primaryError != null) throw primaryError!;
      return {...entry};
    });
  }

  Future<void> _runConfigurationRead() async {
    Object? failure;
    var unsupported = false;
    JwConfigurationPreflight? preflight;
    try {
      preflight = await _configurationPort.readConfigurationPreflight(
          contract: _configurationContract);
    } catch (e) {
      failure = e;
      unsupported = e is JwConfigurationException && e.stage == 'unsupported';
    }
    final values = <JwConfigurationDomain, JwConfigurationValue>{};
    for (final d in JwConfigurationDomain.values) {
      _cancel();
      final entry = <String, Object?>{'domain': d.name};
      _configurationDomains.add(entry);
      try {
        final value = await _configurationPort.readConfiguration(d,
            contract: _configurationContract);
        values[d] = value;
        entry.addAll({
          'status': value.writable ? 'pass' : 'readOnly',
          'actual': _configurationValueJson(value),
          'writable': value.writable,
          if (d.isMonitor) 'intervalMinutes': null,
          if (d.isMonitor) 'intervalSemantics': 'deviceManagedFlag'
        });
        if (!value.writable) unsupported = true;
      } catch (e) {
        entry['status'] =
            e is JwConfigurationException && e.stage == 'unsupported'
                ? 'unsupported'
                : 'fail';
        entry['error'] = e.toString();
        failure ??= e;
        unsupported = unsupported || entry['status'] == 'unsupported';
      }
      await record({'type': 'configurationRead', ...entry});
    }
    _configurationReadyForProbe = values.length == 8 &&
        values.values.every((v) => v.writable) &&
        preflight?.eligible == true;
    if (values.length == 8 && values.values.every((v) => v.writable)) {
      _configurationSaved =
          _makeConfigurationBaseline(JwConfigurationSnapshot(values));
      if (saveConfigurationBaseline != null) {
        await saveConfigurationBaseline!(_configurationSaved!.envelope);
      }
    }
    if (unsupported) {
      throw JwConfigurationException(
          stage: 'unsupported',
          cause:
              'Some configuration/preflight values are unsupported or read-only');
    }
    if (failure != null) throw failure;
  }

  Future<void> _runConfiguration() async {
    if (config.mode == 'configuration-read') {
      await _runConfigurationRead();
      return;
    }
    if (config.mode == 'configuration-restart') {
      _checkConfigurationDevice();
      final actual = await _configurationPort.readConfigurationSnapshot(
          contract: _configurationContract);
      for (final d in JwConfigurationDomain.values) {
        _configurationDomains.add({
          'domain': d.name,
          'status': actual.values[d]!
                  .sameValue(_configurationSaved!.snapshot.values[d]!)
              ? 'pass'
              : 'fail',
          'actual': _configurationValueJson(actual.values[d]!)
        });
      }
      _configurationRestored =
          _configurationDomains.every((e) => e['status'] == 'pass');
      _require(_configurationRestored == true,
          'Independent configuration restart differs from baseline');
      return;
    }
    final preflight = await _configurationPort.readConfigurationPreflight(
        contract: _configurationContract);
    _require(preflight.eligible,
        'Configuration preflight is not eligible for probes');
    final snapshot = await _configurationPort.readConfigurationSnapshot(
        contract: _configurationContract);
    for (final value in snapshot.values.values) {
      if (!value.writable) {
        throw JwConfigurationException(
            domain: value.domain,
            stage: 'unsupported',
            raw: value.raw,
            cause: 'Original raw configuration is not recoverable');
      }
    }
    _configurationSaved = _makeConfigurationBaseline(snapshot);
    _configurationReadyForProbe = true;
    _require(saveConfigurationBaseline != null,
        'Durable configuration baseline writer unavailable');
    await saveConfigurationBaseline!(_configurationSaved!.envelope);
    await record({
      'type': 'configurationBaselineFlushed',
      'baselineSha256': _configurationSaved!.digest,
      'deviceKey': _configurationDeviceKey,
      'domains': 8
    });
    _configurationRestored = true;
    const order = [
      JwConfigurationDomain.hourSystem,
      JwConfigurationDomain.distanceUnit,
      JwConfigurationDomain.screenLightTime,
      JwConfigurationDomain.screenBrightness,
      JwConfigurationDomain.temperatureConfig,
      JwConfigurationDomain.heartRateAuto,
      JwConfigurationDomain.bloodOxygenAuto,
      JwConfigurationDomain.bloodPressureAuto
    ];
    _configurationDomains.addAll([
      for (final d in order)
        {
          'domain': d.name,
          'status': 'notRun',
          'probeVerified': false,
          'restored': null,
          'restorePending': false
        }
    ]);
    for (final d in order) {
      _cancel();
      await _configurationProbe(d);
    }
  }

  Future<Map<String, Object?>> run() async {
    if (config.mode.startsWith('remaining-')) {
      if (port is! JwRemainingAcceptancePort) {
        throw StateError('Production remaining port required');
      }
      return JwRemainingAcceptanceRunner(
              port: port as JwRemainingAcceptancePort,
              config: config,
              record: record,
              delay: delay,
              isCancelled: isCancelled)
          .run();
    }
    final start = now();
    var status = 'pass', code = 0;
    String? error;
    try {
      if (_isReplay) {
        _require(port is JwHistoryReplayAcceptancePort,
            'Production history replay port unavailable');
        _replay = JwHistoryReplayRun(port as JwHistoryReplayAcceptancePort,
            config, historyBaseline, record,
            checkCancellation: _cancel);
        await _step('historyReplay.identity', () async {
          await _replay!.prepare();
          return {};
        });
      }
      if (config.mode == 'configuration-restart') {
        _require(configurationBaseline != null,
            'Configuration restart baseline missing');
        _configurationSaved =
            _ConfigurationBaseline.parse(configurationBaseline!);
      }
      if (_isReadOnly) {
        _require(port is JwReadOnlyAcceptancePort,
            'Production readonly SDK port unavailable');
        _readOnly = _ReadOnlyRun(
            port as JwReadOnlyAcceptancePort, config, readOnlyBaseline);
        await _step('readOnlyIdentity', () async {
          await _readOnly!.prepare();
          return {};
        });
      }
      await _connectAndLogin('initial');
      if (_isReadOnly) {
        _readOnly!.checkDevice(_historyDeviceKey, _identity!);
        await _readOnly!.queryAll(_step);
      }
      if (_isReplay) {
        _replay!.checkDevice(_historyDeviceKey, _identity!);
        await _step('historyReplay.proof', () async {
          await _replay!.run(_syncHistoryRound);
          return _replay!.evidence;
        });
      }
      if (_isConfiguration) await _runConfiguration();
      if (_isHistory) {
        if (config.mode == 'history') {
          for (var round = 1; round <= config.historyRounds; round++) {
            if (round > 1) {
              await _step('disconnect.history$round', () async {
                await port.disconnect();
                return {};
              });
              await _connectAndLogin('history$round');
            }
            await _syncHistoryRound(round);
          }
        }
        await _readHistoryInventory();
      }
      if (config.mode == 'full') {
        await _step('language', () async {
          final original = port.state.language;
          _require(
              port.state.capabilities?.languages == true &&
                  original != null &&
                  original >= 0 &&
                  original <= 2,
              'Original language/capability unavailable; no setting permitted');
          final changed = original == 0 ? 1 : 0;
          try {
            await port.setLanguage(changed);
            _ready();
            _require(
                port.state.language == changed, 'Language readback mismatch');
          } finally {
            await port.setLanguage(original!);
            _ready();
            _require(port.state.language == original,
                'Original language restoration failed');
            await record({
              'type': 'languageRestored',
              'original': original,
              'actual': port.state.language
            });
          }
          return {
            'original': original,
            'changed': changed,
            'restored': port.state.language
          };
        });
        JwHeartRateSample? sample;
        await _step('heart', () async {
          _require(port.state.capabilities?.heartRate == true,
              'Real-time heart capability absent');
          try {
            await port.setHeartRateStreaming(true);
            _ready();
            _require(
                port.state.heartRateStreaming, 'Heart start not confirmed');
            final deadline = now().add(config.heartTimeout);
            while (now().isBefore(deadline)) {
              _cancel();
              _ready();
              sample = port.state.lastHeartRate;
              if (sample != null && sample!.bpm > 0) break;
              await delay(const Duration(milliseconds: 200));
            }
            _require(sample != null && sample!.bpm > 0,
                'No valid real heart sample');
          } finally {
            await port.setHeartRateStreaming(false);
            _ready();
            _require(
                !port.state.heartRateStreaming &&
                    port.state.lastHeartRate == null,
                'Heart stop not confirmed');
            await record({'type': 'heartStopped', 'confirmed': true});
          }
          return {
            'bpm': sample!.bpm,
            'deviceDate': sample!.date.toIso8601String(),
            'stopped': true
          };
        });
        await _step('time', () async {
          final local = now();
          final d = sample!.date;
          _require(
              d.year == local.year &&
                  d.month == local.month &&
                  d.day == local.day,
              'Device date differs; avoid time write across day/pedometer rollover');
          await record({
            'type': 'timeRequest',
            'local': local.toIso8601String(),
            'utc': local.toUtc().toIso8601String(),
            'utcOffsetMinutes': local.timeZoneOffset.inMinutes
          });
          await port.syncTime(local);
          _ready();
          _require(port.state.timeSubmitted,
              'Time transport delivery not confirmed');
          return {
            'localRequested': local.toIso8601String(),
            'transportDelivered': true,
            'deviceClockNeedsTraceVerification': true
          };
        });
        for (var round = 1; round <= config.reconnectRounds; round++) {
          await _step('disconnect.$round', () async {
            await port.disconnect();
            return {};
          });
          await _connectAndLogin('reconnect$round');
        }
      }
    } catch (e) {
      status = e is _Cancelled
          ? 'cancelled'
          : e is JwConfigurationException && e.stage == 'unsupported'
              ? 'unsupported'
              : 'fail';
      code = e is _Cancelled ? 2 : 1;
      error = e.toString();
    } finally {
      try {
        try {
          try {
            await _replay?.finish();
          } finally {
            port.stopScan();
            await port.disconnect();
          }
        } finally {
          await port.close();
        }
        _steps.add({'name': 'cleanup', 'status': 'pass'});
      } catch (e) {
        if (code == 0) {
          code = 1;
          status = 'fail';
        }
        error ??= 'Cleanup failed: $e';
        _steps
            .add({'name': 'cleanup', 'status': 'fail', 'error': e.toString()});
      }
    }
    if (_readOnly != null) {
      try {
        _readOnlyAudit = await _readOnly!.finish(record, success: code == 0);
        if (_readOnlyAudit!['status'] == 'fail') {
          code = 1;
          status = 'fail';
          error ??= _readOnlyAudit!['error'] as String?;
        }
      } catch (e) {
        code = 1;
        status = 'fail';
        error ??= 'Read-only audit flush failed: $e';
      }
    }
    final result = <String, Object?>{
      'schemaVersion': _isReplay
          ? 6
          : _isReadOnly
              ? 4
              : _isConfiguration
                  ? 3
                  : _isHistory
                      ? 2
                      : 1,
      'mode': config.mode,
      'status': status,
      'exitCode': code,
      'startedUtc': start.toUtc().toIso8601String(),
      'finishedUtc': now().toUtc().toIso8601String(),
      'elapsedMs': now().difference(start).inMilliseconds,
      'identitySha256': _identity,
      'steps': _steps,
      'firstBind': _firstBindResult,
      if (_isReadOnly) ...{
        'readOnlyDevice': _readOnly?.device,
        'readOnlyResults': _readOnly?.results ?? [],
        'readOnlyWireAudit': _readOnlyAudit,
        'readOnlyStaticRetained': _readOnly?.staticRetained,
        'businessSettersInvoked': false,
        'firmwareProfileAttestsSourceSha': false,
      },
      if (_isConfiguration) ...{
        'configurationDeviceKey': _configurationDeviceKey,
        'configurationDomains': _configurationDomains,
        'configurationBaselineSha256': _configurationSaved?.digest,
        'configurationRestored': _configurationRestored,
        'configurationReadyForProbe': _configurationReadyForProbe,
        'restorePending': _configurationRestorePending,
        'recoveryAttempted': _configurationRecoveryUsed,
        'samplingDataDeleted': false,
        'monitorIntervalSemantics': 'deviceManagedFlag_not_minutes',
        'firmwareProfileAttestsSourceSha': false,
        if (_configurationJournalError != null)
          'journalError': _configurationJournalError,
      },
      'discoveryTiming': 'observation_not_15_second_gate',
      if (_isHistory) ...{
        'historyDeviceKey': _savedHistoryDeviceKey,
        'historyRounds': _historyRounds,
        'inventory': _historyInventory,
        'deviceDatasetExhaustive': false,
        'nonemptyObservedTypes': JwHistoryType.values
            .where((t) => _historyRounds.any((r) =>
                ((r['counts'] as Map? ?? {})[t.name] as Map? ?? {})['received']
                    is int &&
                (((r['counts'] as Map)[t.name] as Map)['received'] as int) > 0))
            .map((t) => t.name)
            .toList(),
        'firmwareLimitations': JwHistoryResult.firmwareLimitations,
        if (_historyFailureStage != null) 'failureStage': _historyFailureStage,
        if (_persistedBaselineRetained != null)
          'persistedBaselineRetained': _persistedBaselineRetained,
        if (_exactInventoryDigestMatch != null)
          'exactInventoryDigestMatch': _exactInventoryDigestMatch,
      },
      if (_isReplay) ...?_replay?.evidence,
      if (error != null) 'error': error
    };
    try {
      await record({'type': 'finished', 'status': status, 'exitCode': code});
    } catch (e) {
      if (!_isConfiguration && !_isReadOnly) rethrow;
      result['status'] = 'fail';
      result['exitCode'] = 1;
      result['journalError'] = e.toString();
    }
    return result;
  }
}

abstract interface class JwRemainingAcceptancePort
    implements JwReadOnlyAcceptancePort {
  JwDeviceRepository get remainingRepository;
  Stream<JwImmediateAlertAttempt> get immediateAlertAttempts;
}
