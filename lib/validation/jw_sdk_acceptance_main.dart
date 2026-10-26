import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/jw_device_provider.dart';
import '../services/jw/jw_codec.dart';
import '../services/jw/jw_configuration.dart';
import '../services/jw/jw_device_repository.dart';
import '../services/jw/jw_identity_store.dart';
import '../services/jw/jw_models.dart';
import '../services/jw/jw_transport.dart';
import '../services/jw/history/jw_history_models.dart';
import '../services/jw/history/jw_history_store.dart';
import 'jw_sdk_acceptance.dart';
import 'jw_history_replay_acceptance.dart';
import '../services/jw/jw_remaining_models.dart';

class JwProductionAcceptancePort
    implements
        JwHistoryAcceptancePort,
        JwHistoryReplayAcceptancePort,
        JwConfigurationAcceptancePort,
        JwReadOnlyAcceptancePort,
        JwRemainingAcceptancePort {
  final ProviderContainer container;
  final Future<void> Function(Map<String, Object?>) record;
  StreamSubscription? _frames;
  ProviderSubscription<JwDeviceState>? _state;
  ProviderSubscription<AsyncValue<JwDeviceRepository?>>? _repositoryKeepAlive;
  StreamSubscription<JwDeviceState>? _readOnlyState;
  JwDeviceRepository? _repository;
  JwHistoryStore? _historyStore;
  final _outgoing = StreamController<JwFrame>.broadcast(sync: true);
  StreamSubscription<JwFrame>? _outgoingSubscription;
  String? _expectedReadOnlyIdentity;
  StreamSubscription<JwImmediateAlertAttempt>? _alertSubscription;
  final _alerts =
      StreamController<JwImmediateAlertAttempt>.broadcast(sync: true);
  @override
  Stream<JwImmediateAlertAttempt> get immediateAlertAttempts => _alerts.stream;
  @override
  JwDeviceRepository get remainingRepository =>
      _repository ?? (throw StateError('Explicit initialization required'));
  @override
  Stream<JwFrame> get outgoingFrames => _outgoing.stream;
  @override
  Future<void> prepareReadOnlyIdentity(String expectedDigest) async {
    final directory = await getApplicationSupportDirectory();
    final store = JwIdentityStore(
        File('${directory.path}${Platform.pathSeparator}jw_identity_v1.json'));
    final identity = await store.loadExisting();
    if (sha256.convert(identity.wireUserId).toString() != expectedDigest) {
      throw const JwIdentityException('Existing identifier digest mismatch');
    }
    _expectedReadOnlyIdentity = expectedDigest;
  }

  bool _historyReplay = false;
  @override
  Future<void> prepareHistoryReplayIdentity(String expectedDigest) async {
    _historyReplay = true;
    await prepareReadOnlyIdentity(expectedDigest);
  }

  @override
  Future<JwSubmission> resetHistoryCursor(
          {required JwConfigurationContract contract}) =>
      remainingRepository.resetHistoryCursor(contract: contract);
  @override
  Future<List<JwHistoryRecord>> historyRecords({String? batchId}) async {
    await historyInventory();
    final store = _historyStore;
    if (store is! FileJwHistoryStore) {
      throw StateError('Production file history journal unavailable');
    }
    return readJwHistoryReplayRecords(
        store, remainingRepository.historyDeviceKey,
        batchId: batchId);
  }

  final _received = <String>{};
  JwProductionAcceptancePort(this.record, {ProviderContainer? container})
      : container = container ?? ProviderContainer() {
    this.container.read(bleManagerProvider);
    // An injected container owns native setup; lifecycle tests supply fake BLE.
    if (container == null) {
      FlutterBluePlus.setLogLevel(LogLevel.none);
    }
  }
  @override
  Future<void> startScan() =>
      container.read(bleNotifierProvider.notifier).startScan();
  @override
  void stopScan() => container.read(bleNotifierProvider.notifier).stopScan();
  @override
  List<ScanDevice> get devices => container.read(scannedDevicesProvider);
  @override
  JwDeviceState get state => _expectedReadOnlyIdentity == null
      ? container.read(jwDeviceProvider)
      : _repository?.state ??
          container.read(jwRepositoryProvider).valueOrNull?.state ??
          const JwDeviceState();
  void _recordState(JwDeviceState next) {
    unawaited(record({
      'type': 'sdkState',
      'phase': next.phase.name,
      'busy': next.operationInProgress,
      'heartStreaming': next.heartRateStreaming,
      if (next.operationError != null) 'error': next.operationError
    }).catchError((Object _) {}));
  }

  @override
  Future<void> connect(ScanDevice target) async {
    if (!await container
        .read(bleNotifierProvider.notifier)
        .connect(target.deviceId, target.name, allowJw: true)) {
      throw StateError('Production BLE connection/GATT selection failed');
    }
    final info = container.read(connectedDeviceProvider);
    final transport = container.read(bleManagerProvider).jwTransport;
    if (info?.isJw != true || transport == null) {
      throw StateError('Full JW GATT/FF03 not ready; no SDK writes');
    }
    await record({
      'type': 'gattReady',
      'mtu': transport.mtu,
      'profile': 'JW full service FF02-write-response FF03-notify'
    });
    _received.clear();
    final decoder = JwFrameDecoder();
    _frames = transport.notifications.listen((bytes) {
      for (final f in decoder.add(bytes)) {
        if (_historyReplay) {
          unawaited(record({
            'type': 'historyReplayWireReceive',
            'seq': f.seq,
            'ack': f.ack,
            'negative': f.error,
            'l2Hex':
                f.payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join()
          }).catchError((Object _) {}));
        }
        if (f.ack) {
          unawaited(
              record({'type': 'wireAck', 'seq': f.seq, 'negative': f.error})
                  .catchError((Object _) {}));
          continue;
        }
        try {
          final m = JwCodec.decodeL2(f.payload);
          for (final field in m.fields) {
            _received.add('${m.command}/${field.key}');
            final safe = (m.command == 2 &&
                    [0x37, 0x50, 0x43, 0x46, 0x4c, 0x55, 0x2c, 0x49, 0x88, 0x77]
                        .contains(field.key)) ||
                (m.command == 6 && field.key == 0x3e) ||
                (m.command == 3 && field.key == 4) ||
                (m.command == 5 &&
                    [0x1a, 0x12, 0x35, 0x3f, 0x24, 0x27, 0x2b, 0x3b]
                        .contains(field.key));
            unawaited(record({
              'type': 'wireReply',
              'seq': f.seq,
              'command': m.command,
              'key': field.key,
              'length': field.value.length,
              if (safe)
                'hex': field.value
                    .map((v) => v.toRadixString(16).padLeft(2, '0'))
                    .join()
            }).catchError((Object _) {}));
          }
        } on FormatException {
          unawaited(record({'type': 'invalidWirePayload', 'seq': f.seq})
              .catchError((Object _) {}));
        }
      }
    });
    if (_expectedReadOnlyIdentity != null) {
      // Keep the same production repository alive without exposing the UI
      // notifier, which schedules unguarded automatic initialization.
      _repositoryKeepAlive = container.listen(jwRepositoryProvider, (_, __) {});
    } else {
      // Existing UI/Phase1-3 initialization behavior remains owned by notifier.
      _state =
          container.listen(jwDeviceProvider, (_, next) => _recordState(next));
    }
  }

  @override
  Future<void> bindFirstTime({required bool confirmedFirstBind}) async {
    final repo = _repository ?? await container.read(jwRepositoryProvider.future);
    if (repo == null) {
      throw StateError('Production JW repository unavailable');
    }
    await repo.bindFirstTime(confirmedFirstBind: confirmedFirstBind);
  }

  @override
  Future<void> initialize() async {
    _repository = await container.read(jwRepositoryProvider.future);
    if (_repository == null) {
      throw StateError('Production JW repository unavailable');
    }
    if (_expectedReadOnlyIdentity != null) {
      _outgoingSubscription =
          _repository!.session.outgoingFrames.listen(_outgoing.add);
      _readOnlyState = _repository!.changes.listen(_recordState);
      final transport = _repository!.transport;
      if (transport is JwImmediateAlertTransport) {
        _alertSubscription = (transport as JwImmediateAlertTransport)
            .immediateAlertAttempts
            .listen(_alerts.add);
      }
      await _repository!.initialize(
          expectedExistingIdentitySha256: _expectedReadOnlyIdentity);
    } else {
      await container.read(jwDeviceProvider.notifier).initialize();
    }
    if (!_received.contains('2/55') ||
        !_received.contains('6/62') ||
        !_received.contains('3/4')) {
      throw StateError('Missing actual 02/37 or 06/3E wire reply');
    }
  }

  @override
  Future<String> identityDigest() async {
    final directory = await getApplicationSupportDirectory();
    final store = JwIdentityStore(
        File('${directory.path}${Platform.pathSeparator}jw_identity_v1.json'));
    final id = _expectedReadOnlyIdentity == null
        ? await store.loadOrCreate()
        : await store.loadExisting();
    if (id.wireUserId.length != 32) {
      throw StateError('Production identity length mismatch');
    }
    return sha256.convert(id.wireUserId).toString();
  }

  @override
  Future<void> setLanguage(int value) =>
      container.read(jwDeviceProvider.notifier).setLanguage(value);
  @override
  Future<void> setHeartRateStreaming(bool enabled) =>
      container.read(jwDeviceProvider.notifier).setHeartRateStreaming(enabled);
  @override
  Future<void> syncTime(DateTime value) =>
      container.read(jwDeviceProvider.notifier).syncTime(value);
  @override
  Future<JwHistoryResult> syncHistory(JwHistoryOptions options) async {
    final repository = _repository;
    if (repository == null) {
      throw StateError('Production history repository unavailable');
    }
    try {
      return await repository.syncHistory(options: options);
    } finally {
      _historyStore = container.read(jwHistoryStoreProvider).valueOrNull;
    }
  }

  @override
  Future<JwHistoryInventory> historyInventory() async {
    final repository = _repository;
    if (repository == null) {
      throw StateError('Production history repository unavailable');
    }
    final inventory = await repository.historyInventory();
    _historyStore = container.read(jwHistoryStoreProvider).valueOrNull;
    return inventory;
  }

  JwDeviceRepository get _configurationRepository =>
      _repository ??
      (throw StateError('Production configuration repository unavailable'));
  @override
  Future<JwConfigurationValue> readConfiguration(JwConfigurationDomain domain,
          {required JwConfigurationContract contract}) =>
      _configurationRepository.readConfiguration(domain, contract: contract);
  @override
  Future<JwConfigurationSnapshot> readConfigurationSnapshot(
          {required JwConfigurationContract contract}) =>
      _configurationRepository.readConfigurationSnapshot(contract: contract);
  @override
  Future<JwConfigurationPreflight> readConfigurationPreflight(
          {required JwConfigurationContract contract}) =>
      _configurationRepository.readConfigurationPreflight(contract: contract);
  @override
  Future<JwConfigurationWriteResult> setConfigurationVerified(
          JwConfigurationChange change,
          {required JwConfigurationContract contract,
          required JwConfigurationValue expectedCurrent}) =>
      _configurationRepository.setConfigurationVerified(change,
          contract: contract, expectedCurrent: expectedCurrent);
  @override
  Future<JwConfigurationWriteResult> setTemperatureUnitVerified(bool celsius,
          {required JwConfigurationContract contract,
          required JwConfigurationValue expectedCurrent}) =>
      _configurationRepository.setTemperatureUnitVerified(celsius,
          contract: contract, expectedCurrent: expectedCurrent);

  @override
  Future<int> queryLanguage() => _configurationRepository.queryLanguage();
  @override
  Future<int> readBatteryLevel() => _configurationRepository.readBatteryLevel();
  @override
  Future<JwHealthStatus> readHealthStatus(
          {required JwConfigurationContract contract}) =>
      _configurationRepository.readHealthStatus(contract: contract);
  @override
  Future<JwTurnOverWristStatus> readTurnOverWrist(
          {required JwConfigurationContract contract}) =>
      _configurationRepository.readTurnOverWrist(contract: contract);
  @override
  Future<JwDisturbStatus> readDisturb(
          {required JwConfigurationContract contract}) =>
      _configurationRepository.readDisturb(contract: contract);
  @override
  Future<JwHeatStressReminderStatus> queryHeatStressReminder(
          {required JwConfigurationContract contract}) =>
      _configurationRepository.queryHeatStressReminder(contract: contract);
  @override
  Future<JwHeartRateReminderDiagnostic> readHeartRateReminderDiagnostic(
          {required JwConfigurationContract contract}) =>
      _configurationRepository.readHeartRateReminderDiagnostic(
          contract: contract);
  @override
  Future<void> cancelHistory() async {
    await _repository?.cancelHistory();
  }

  @override
  Future<void> disconnect() async {
    await _frames?.cancel();
    _frames = null;
    await container.read(bleNotifierProvider.notifier).disconnect();
    await _repository?.dispose();
    await _alertSubscription?.cancel();
    _alertSubscription = null;
    await _outgoingSubscription?.cancel();
    _outgoingSubscription = null;
    await _readOnlyState?.cancel();
    _readOnlyState = null;
    _repositoryKeepAlive?.close();
    _repositoryKeepAlive = null;
    _repository = null;
    _state?.close();
    _state = null;
    // Finish provider autoDispose before the next connection reuses the container.
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> close() async {
    await _historyStore?.close();
    container.dispose();
    await _outgoing.close();
    await _alerts.close();
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home:
          Scaffold(body: Center(child: Text('SDK command-line acceptance')))));
  AcceptanceConfig config;
  try {
    config = AcceptanceConfig.parse(args);
  } catch (e) {
    stderr.writeln(e);
    exit(1);
  }
  final output = Directory(config.outputDirectory);
  await output.create(recursive: true);
  final events = File('${output.path}${Platform.pathSeparator}events.jsonl');
  final cancelled = File('${output.path}${Platform.pathSeparator}cancel');
  var tail = Future<void>.value();
  Future<void> record(Map<String, Object?> event) {
    tail = tail.then((_) => events
        .writeAsString(
            '${jsonEncode({
                  'utc': DateTime.now().toUtc().toIso8601String(),
                  ...event
                })}\n',
            mode: FileMode.append,
            flush: true)
        .then<void>((_) {}));
    return tail;
  }

  await record({
    'type': 'started',
    'pid': pid,
    'platform': Platform.operatingSystem,
    'runtime': Platform.version,
    'driver': 'production BLE/provider/JW SDK',
    'mode': config.mode
  });
  // Let native plugin registration complete; no widget interaction is required.
  await Future<void>.delayed(const Duration(milliseconds: 100));
  Map<String, Object?> result;
  try {
    final baseline = config.historyBaselineFile == null
        ? null
        : (jsonDecode(await File(config.historyBaselineFile!).readAsString())
                as Map)
            .cast<String, Object?>();
    Map<String, Object?>? configurationBaseline;
    if (config.configurationBaselineFile != null) {
      final file = File(config.configurationBaselineFile!);
      if (await file.length() > 1024 * 1024) {
        throw StateError('Configuration baseline exceeds1MiB');
      }
      configurationBaseline = (jsonDecode(await file.readAsString()) as Map)
          .cast<String, Object?>();
    }
    Map<String, Object?>? readOnlyBaseline;
    if (config.readOnlyBaselineFile != null) {
      final file = File(config.readOnlyBaselineFile!);
      if (await file.length() > 1024 * 1024) {
        throw StateError('Read-only baseline exceeds1MiB');
      }
      readOnlyBaseline = (jsonDecode(await file.readAsString()) as Map)
          .cast<String, Object?>();
    }
    final port = JwProductionAcceptancePort(record);
    result = await AcceptanceRunner(
            port: port,
            config: config,
            record: record,
            historyBaseline: baseline,
            configurationBaseline: configurationBaseline,
            readOnlyBaseline: readOnlyBaseline,
            saveConfigurationBaseline: (envelope) async {
              final file = File(
                  '${output.path}${Platform.pathSeparator}configuration-baseline.json');
              if (await file.exists()) {
                throw StateError(
                    'Immutable configuration baseline already exists');
              }
              await file.writeAsString(jsonEncode(envelope), flush: true);
            },
            isCancelled: cancelled.existsSync)
        .run();
  } catch (e) {
    result = {
      'schemaVersion': config.mode.startsWith('configuration')
          ? 3
          : config.mode.startsWith('history')
              ? 2
              : 1,
      'mode': config.mode,
      'status': 'fail',
      'exitCode': 1,
      'error': 'Acceptance host failed: $e'
    };
  }
  try {
    await tail;
  } catch (e) {
    result['status'] = 'fail';
    result['exitCode'] = 1;
    result['journalError'] = e.toString();
  }
  result['nativePid'] = pid;
  await File('${output.path}${Platform.pathSeparator}result.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(result),
          flush: true);
  stdout.writeln(jsonEncode({
    'sdkAcceptance': result['status'],
    'exitCode': result['exitCode'],
    'report': '${output.path}${Platform.pathSeparator}result.json'
  }));
  exit(result['exitCode']! as int);
}
