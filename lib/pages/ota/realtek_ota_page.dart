import 'dart:async';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/ble_provider.dart';
import '../../providers/rtl8762_ota_provider.dart';
import '../../services/ota/ota_platform.dart';
import '../../services/ota/android_realtek_ota_platform.dart';
import '../../services/ota/android_realtek_firmware_parser.dart';
import '../../services/ota/firmware_inspection.dart';
import '../../services/ota/ota_preflight.dart';
import '../../services/ota/ota_session.dart';
import '../../services/ota/ota_device_profile.dart';
import '../../services/ota/device_probe.dart';
import '../../services/ota/ota_ownership.dart';
import 'ota_confirmation.dart';
import 'ota_failure_card.dart';
import '../../services/ota/ota_failure.dart';
import '../../services/ota/ota_progress.dart';
import '../../services/ota/ota_repository.dart';
import '../../services/ota/ota_postcheck.dart';

final otaRepositoryProvider = FutureProvider<OtaRepository>((ref) async {
  final directory = await getApplicationDocumentsDirectory();
  return OtaRepository(Directory('${directory.path}/ota_history'));
});

final otaPlatformProvider = Provider<OtaPlatform>((ref) =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? AndroidRealtekOtaPlatform()
        : const UnsupportedOtaPlatform());

final otaBlePermissionProvider =
    Provider<Future<bool?> Function()>((ref) => () async {
          if (kIsWeb || defaultTargetPlatform != TargetPlatform.android)
            return true;
          try {
            final scan = await Permission.bluetoothScan.status;
            final connect = await Permission.bluetoothConnect.status;
            final location = await Permission.locationWhenInUse.status;
            return scan.isGranted && connect.isGranted && location.isGranted;
          } catch (_) {
            return null;
          }
        });

final otaProfileRegistryProvider =
    Provider<OtaProfileRegistry>((ref) => const OtaProfileRegistry());

final firmwareParserProvider = Provider<FirmwareParser>((ref) =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? AndroidRealtekFirmwareParser(
            registry: ref.watch(otaProfileRegistryProvider))
        : _UnknownParser());
final otaDeviceProbeProvider = Provider<DeviceProbe>((ref) =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? const FlutterBlueDeviceProbe()
        : const UnknownDeviceProbe());
final otaPostcheckerProvider = Provider<OtaPostchecker>(
    (ref) => OtaPostchecker(ref.watch(otaDeviceProbeProvider)));
final otaDeviceCapabilitiesProvider =
    Provider<DeviceCapabilities>((ref) => const DeviceCapabilities());

class _UnknownParser implements FirmwareParser {
  @override
  Future<FirmwareParseResult> parse(
          String path, DeviceCapabilities capabilities) async =>
      FirmwareParseResult(checks: [
        const OtaCheck('format', OtaCheckStatus.unknown, '尚不支持固件格式检查'),
        const OtaCheck('compatibility', OtaCheckStatus.unknown, '尚不支持设备兼容性检查'),
      ]);
}

class RealtekOtaPage extends ConsumerStatefulWidget {
  final ScanDevice device;
  const RealtekOtaPage({super.key, required this.device});

  @override
  ConsumerState<RealtekOtaPage> createState() => _RealtekOtaPageState();
}

class _RealtekOtaPageState extends ConsumerState<RealtekOtaPage> with WidgetsBindingObserver {
  late final OtaPlatform _platform;
  StreamSubscription<dynamic>? _subscription;
  String? _path;
  String? _name;
  String _status = '请选择与设备匹配的固件';
  double? _progress;
  bool _running = false;
  bool _ready = false;
  String? _errorDetails;
  bool _pendingVerification = false;
  bool _recoveryLocked = false;
  bool _loadingRecovery = true;
  OtaSessionRecord? _recoveryRecord;
  bool _preparing = false;
  bool _verifying = false;
  int? _targetVersion, _expectedIcType;
  PostcheckResult? _postcheck;
  int _sessionSequence = 0;
  OtaSession? _session;
  DeviceCapabilities? _capabilities;
  bool _disposed = false;
  List<OtaCheck> _checks = const [];
  late final OtaOwnership _ownership;
  bool? _permission;
  bool _ownsOta = false;
  OtaFailure? _failure;
  OtaSessionRecord? _lastRecord;
  OtaProgressTracker _progressTracker = OtaProgressTracker();
  DateTime? _startedAt;
  String _firmwareSha256 = '';
  int _retryCount = 0;
  final List<OtaPhaseEntry> _phaseHistory = [];
  Future<void> _saveQueue = Future.value();

  Future<void> _loadHistory() async {
    try {
      final repository = await ref.read(otaRepositoryProvider.future);
      final active = await repository.loadActive();
      if (active != null && _ownership.owner != OtaOwner.ota) {
        final recovered = OtaSessionRecord(
            sessionId: active.sessionId, startedAt: active.startedAt,
            updatedAt: DateTime.now(), phase: OtaPhase.finished,
            outcome: OtaOutcome.recoveryRequired,
            deviceIdMasked: active.deviceIdMasked, firmwareName: active.firmwareName,
            firmwareSha256: active.firmwareSha256, phaseHistory: active.phaseHistory,
            targetVersion: active.targetVersion, expectedIcType: active.expectedIcType);
        await repository.save(recovered);
        await repository.clearActive();
      }
      final records = await repository.list();
      if (!mounted) return;
      final last = records.isEmpty ? null : records.first;
      setState(() {
        _lastRecord = last;
        if (last != null && (last.outcome == OtaOutcome.recoveryRequired ||
            last.outcome == OtaOutcome.pendingVerification)) {
          _recoveryRecord = last;
          _recoveryLocked = true;
          _pendingVerification = true;
          _targetVersion = last.targetVersion;
          _expectedIcType = last.expectedIcType;
          _status = '上次升级被中断，设备状态未知，请先重新检查设备';
        }
      });
    } catch (_) {
      // A failed recovery read must not permit a potentially unsafe start.
      if (mounted) setState(() {
        _recoveryLocked = true;
        _status = '无法读取升级恢复记录，请检查存储后重新打开页面';
      });
    } finally {
      if (mounted) {
        setState(() => _loadingRecovery = false);
        if (!_recoveryLocked && _platform.supported) unawaited(_prepare());
      }
    }
  }

  void _saveTerminal(OtaPhase previousPhase, {String? message, int? rawType, int? rawCode,
      OtaFailureCategory? category}) {
    final session = _session;
    if (session?.outcome == null) return;
    if (session!.outcome == OtaOutcome.failed) {
      final profiles = ref.read(otaProfileRegistryProvider).profiles;
      final threshold = profiles.length == 1 ? profiles.single.batteryMinPercent : null;
      final next = OtaFailure.classify(phase: previousPhase, rawType: rawType,
          rawCode: rawCode, message: message, confirmedCategory: category,
          probe: DeviceProbeResult(batteryPercent: _capabilities?.batteryPercent,
              charging: _capabilities?.charging), batteryMinPercent: threshold);
      _failure = _failure?.merge(next) ?? next;
    }
    final now = DateTime.now();
    final record = OtaSessionRecord(sessionId: session.id, startedAt: _startedAt ?? now,
        updatedAt: now, phase: session.phase, outcome: session.outcome!, failure: _failure,
        deviceIdMasked: widget.device.deviceId, firmwareName: _name ?? '',
        firmwareSha256: _firmwareSha256, targetVersion: _targetVersion,
        expectedIcType: _expectedIcType,
        phaseHistory: [..._phaseHistory, OtaPhaseEntry(session.phase, now)]);
    final repository = ref.read(otaRepositoryProvider.future);
    _saveQueue = _saveQueue.then((_) async {
      try {
        final repo = await repository;
        await repo.save(record);
        if ((await repo.loadActive())?.sessionId == record.sessionId) {
          await repo.clearActive();
        }
      } catch (_) {}
    });
  }

  Future<void> _copyDiagnostics() async {
    final id = _session?.id;
    if (id == null) return;
    try {
      await _saveQueue;
      final text = await (await ref.read(otaRepositoryProvider.future)).exportSanitized(id);
      if (text != null) await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {}
  }

  void _releaseOwnership() {
    if (_ownsOta) {
      _ownsOta = false;
      _ownership.release(OtaOwner.ota);
    }
  }

  String _batteryFailureHint() {
    final caps = _capabilities;
    final profiles = ref.read(otaProfileRegistryProvider).profiles;
    if (caps?.charging != false || profiles.length != 1) return '';
    final profile = profiles.single;
    final threshold = profile.batteryMinPercent;
    if (threshold == null ||
        (profile.batterySource != BatterySource.bwps &&
            profile.batterySource != BatterySource.basAndBwps)) return '';
    final value = caps?.batteryPercent;
    if (value == null || value < 0 || value > 100 || value >= threshold)
      return '';
    return '；设备可能因电量低于 $threshold% 且未充电而拒绝进入升级模式,请充电后重试';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _platform = ref.read(otaPlatformProvider);
    unawaited(Future.microtask(_loadHistory));
    _ownership = ref.read(otaOwnershipProvider.notifier);
    if (_platform.supported) {
      _subscription = _platform.events.listen((event) {
        if (!mounted) return;
        final session = _session;
        if (session == null || event['sessionId'] is! String) return;
        if (event['sessionId'] != session.id) return;
        final disconnected =
            event['disconnected'] == true || event['message'] == '设备已断开';
        if (disconnected) {
          final _disconnectHint = session.phase == OtaPhase.preparing ||
                  session.phase == OtaPhase.connecting
              ? _batteryFailureHint()
              : '';
          final disconnectPhase = session.phase;
          if (!session.disconnect(event['sessionId'] as String)) return;
          if (session.outcome != null) {
            _saveTerminal(disconnectPhase, message: '设备已断开', category: OtaFailureCategory.disconnected);
          }
          setState(() {
            _ready = false;
            if (session.outcome == null) {
              _status = '设备正在重启，等待重新连接';
            } else {
              _status =
                  '设备已断开${session.failureDescription == '设备已断开' && (session.phase == OtaPhase.finished) ? _disconnectHint : ''}';
              _running = false;
            }
          });
          if (session.outcome != null) {
            _releaseOwnership();
            ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
          }
          return;
        }
        final previousPhase = session.phase;
        final done = event['done'] == true;
        final outcomeName = event['outcome'];
        OtaOutcome? outcome;
        if (outcomeName != null) {
          final name = outcomeName == 'canceled' ? 'cancelled' : outcomeName;
          for (final value in OtaOutcome.values) {
            if (value.name == name) outcome = value;
          }
          if (outcome == null) return;
        }
        if (done && (outcome == null || outcome == OtaOutcome.verified)) {
          outcome = OtaOutcome.pendingVerification;
        }
        // The current native bridge reports these SDK states as messages.
        if (!done && event['phase'] == null) {
          if (event['progress'] is num &&
              session.phase == OtaPhase.connecting) {
            session.apply(
                OtaEvent(sessionId: session.id, phase: OtaPhase.transferring));
          } else if (event['message'] == '正在激活固件' &&
              session.phase == OtaPhase.transferring) {
            session.apply(
                OtaEvent(sessionId: session.id, phase: OtaPhase.validating));
            session.apply(
                OtaEvent(sessionId: session.id, phase: OtaPhase.activating));
          }
        }
        var phase = done ? OtaPhase.finished : session.phase;
        if (event['phase'] != null) {
          final phases = OtaPhase.values.where((p) => p.name == event['phase']);
          if (phases.isEmpty) return;
          phase = phases.first;
        }
        if (done != (phase == OtaPhase.finished)) return;
        final message = event['message'];
        final progress = event['progress'];
        if (progress != null && progress is! num) return;
        final overall = event['overallProgress'];
        final hasProgress = progress is num || overall is num;
        final tracked = hasProgress ? _progressTracker.update(
            imageIndex: event['imageIndex'] is int ? event['imageIndex'] as int : null,
            imageCount: event['imageCount'] is int ? event['imageCount'] as int : null,
            currentPercent: progress is num ? progress : null,
            overallProgress: overall is num ? overall : null) : null;
        if (!session.apply(OtaEvent(
          sessionId: event['sessionId'] as String,
          phase: phase,
          outcome: outcome,
          progress: tracked,
          rawType: event['errorType'] is int ? event['errorType'] as int : null,
          rawCode: event['errorCode'] is int ? event['errorCode'] as int : null,
        ))) {
          return;
        }
        if (phase != previousPhase) _phaseHistory.add(OtaPhaseEntry(phase, DateTime.now()));
        if (done) _saveTerminal(previousPhase, message: message is String ? message : null,
            rawType: event['errorType'] is int ? event['errorType'] as int : null,
            rawCode: event['errorCode'] is int ? event['errorCode'] as int : null);
        setState(() {
          if (message is String && session.failureDescription != '阶段超时') {
            _status = (message.contains('升级成功') ? message.replaceAll('升级成功', 'SDK 报告完成') : message) +
                (done &&
                        outcome == OtaOutcome.failed &&
                        (previousPhase == OtaPhase.preparing ||
                            previousPhase == OtaPhase.connecting)
                    ? _batteryFailureHint()
                    : '');
          }
          if (hasProgress) _progress = session.progress;
          if (done) _running = false;
          if (event['ready'] == true) _ready = true;
          if (done) _ready = false;
          if (done) {
            _pendingVerification = outcome == OtaOutcome.pendingVerification;
          }
        });
        if (done) {
          _releaseOwnership();
          ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
        }
      }, onError: (Object error) {
        if (!mounted) return;
        final wasRunning = _running;
        final session = _session;
        if (session != null && session.outcome == null) {
          session.apply(OtaEvent(
              sessionId: session.id,
              phase: OtaPhase.finished,
              outcome: OtaOutcome.failed));
        }
        _saveTerminal(session?.phase ?? OtaPhase.idle, message: error.toString(), category: OtaFailureCategory.connection);
        setState(() {
          _ready = false;
          _running = false;
          _status = wasRunning
              ? '升级状态通信中断，设备可能仍在写入。请勿断电，等待设备状态确认：$error'
              : '连接状态通信失败：$error';
        });
        _releaseOwnership();
        ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
      });
    }
  }

  Future<void> _prepare() async {
    if (_loadingRecovery || _recoveryLocked || _pendingVerification || _verifying) return;
    if (_preparing ||
        _running ||
        (_session != null && _session!.outcome == null)) {
      if (mounted) setState(() => _status = 'OTA 会话正在进行，请先结束当前会话');
      return;
    }
    _releaseOwnership();
    if (ref.read(connectedDeviceProvider) != null) {
      setState(() => _status = '普通连接正在占用蓝牙，请先断开设备');
      return;
    }
    final acquired = _ownership.acquire(OtaOwner.ota);
    if (!acquired.success) {
      setState(() => _status = acquired.reason!);
      return;
    }
    _ownsOta = true;
    setState(() {
      _preparing = true;
      _ready = false;
    });
    try {
      _permission = await ref.read(otaBlePermissionProvider)();
      if (_disposed) return;
      if (_permission != true) {
        _releaseOwnership();
        setState(() => _status =
            _permission == false ? '蓝牙或附近设备权限未授予' : '蓝牙权限状态未知，请检查系统设置');
        return;
      }
      if (ref.read(connectedDeviceProvider) != null) {
        _releaseOwnership();
        setState(() => _status = '普通连接正在占用蓝牙，请先断开设备');
        return;
      }
      if (mounted) setState(() => _status = '正在连接设备');
      if (_session != null) {
        _session?.dispose();
        _session = null;
        await _platform.close();
      }
      final configured = ref.read(otaDeviceCapabilitiesProvider);
      DeviceProbeResult probe;
      try {
        // 固件尚未选择，无法安全匹配档案。临时连接结束后才交给 SDK。
        probe = await ref
            .read(otaDeviceProbeProvider)
            .probe(widget.device.deviceId)
            .timeout(const Duration(seconds: 35));
      } catch (error) {
        probe = const DeviceProbeResult();
        if (mounted) setState(() => _errorDetails = '设备预读取失败或超时，设备信息未知：$error');
      }
      final capabilities = DeviceCapabilities(
          confirmed:
              probe.currentVersion != null || probe.otaDeviceInfo != null,
          icType: probe.otaDeviceInfo?.icType,
          currentVersion: probe.currentVersion,
          otaDeviceInfo: probe.otaDeviceInfo,
          batteryPercent: probe.batteryPercent,
          charging: probe.charging,
          expectedIcType: configured.expectedIcType,
          deviceReportedCapacity: configured.deviceReportedCapacity);
      if (_disposed) return;
      _capabilities = capabilities;
      _startedAt = DateTime.now();
      _phaseHistory.clear();
      _failure = null;
      _progressTracker = OtaProgressTracker();
      final session = OtaSession(
          '${DateTime.now().microsecondsSinceEpoch}-${_sessionSequence++}',
          onTimeout: (timedOut) {
        if (!mounted || _session != timedOut) return;
        _saveTerminal(timedOut.timedOutPhase ?? OtaPhase.idle, message: '阶段超时', category: OtaFailureCategory.timeout);
        setState(() {
          _status =
              '阶段超时${timedOut.timedOutPhase == OtaPhase.preparing || timedOut.timedOutPhase == OtaPhase.connecting ? _batteryFailureHint() : ''}';
          _running = false;
          _ready = false;
        });
        _releaseOwnership();
        ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
      });
      _session = session;
      session.apply(OtaEvent(sessionId: session.id, phase: OtaPhase.preparing));
      _phaseHistory.add(OtaPhaseEntry(OtaPhase.preparing, DateTime.now()));
      await _platform.prepare(widget.device.deviceId, sessionId: session.id);
    } catch (error) {
      final session = _session;
      if (session != null && session.outcome == null) {
        session.apply(OtaEvent(
            sessionId: session.id,
            phase: OtaPhase.finished,
            outcome: OtaOutcome.failed));
      }
      _saveTerminal(OtaPhase.preparing, message: error.toString());
      _releaseOwnership();
      if (mounted)
        setState(() => _status = '连接失败：$error${_batteryFailureHint()}');
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _session?.checkTimeout();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    if (_ownsOta) {
      _ownsOta = false;
      _ownership.releaseDeferred(OtaOwner.ota);
    }
    _session?.dispose();
    _subscription?.cancel();
    if (_session != null) {
      unawaited(_platform.close().catchError((Object _) {}));
    }
    super.dispose();
  }

  Future<void> _choose() async {
    if (_recoveryLocked || _pendingVerification || _loadingRecovery) return;
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (!mounted || result == null) return;
      final file = result.files.single;
      final restart = file.path != null && (_pendingVerification || _postcheck != null);
      setState(() {
        if (restart) {
          _pendingVerification = false;
          _postcheck = null;
          _targetVersion = null;
          _expectedIcType = null;
        }
        _path = file.path;
        _name = file.name;
        _status = file.path == null ? '无法读取所选文件' : '已选择固件';
        _progress = null;
        _checks = const [];
      });
      if (restart && file.path != null) await _prepare();
    } catch (error) {
      if (mounted) setState(() => _status = '选择文件失败：$error');
    }
  }

  Future<void> _start() async {
    if (_path == null || _running || _preparing || !_ready ||
        _loadingRecovery || _recoveryLocked || _pendingVerification) return;
    setState(() {
      _running = true;
      _progress = null;
      _status = '正在连接设备';
    });
    ref.read(rtl8762OtaInProgressProvider.notifier).state = true;
    try {
      final path = _path!;
      final session = _session;
      final DeviceCapabilities capabilities =
          _capabilities ?? ref.read(otaDeviceCapabilitiesProvider);
      final inspection = await FirmwareInspection.inspect(
          path, capabilities, ref.read(firmwareParserProvider));
      if (!mounted) return;
      _firmwareSha256 = inspection.sha256 ?? '';
      if (session != _session || session?.outcome != null || !_ready) {
        setState(() => _running = false);
        ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
        return;
      }
      final report = addEnvironmentChecks(
          inspection.report,
          EnvironmentStatus(
              blePermissionGranted: _permission,
              ownershipConflict: ref.read(connectedDeviceProvider) != null
                  ? '普通连接正在占用蓝牙，请先断开设备'
                  : _ownership.owner != OtaOwner.ota
                      ? '蓝牙所有权已改变，请重新连接'
                      : null));
      setState(() => _checks = report.checks);
      final raw = inspection.rawStatus;
      final images = raw is Map ? raw['images'] : null;
      final first = images is List && images.length == 1 ? images.first : null;
      final target = first is Map && first['version'] is int
          ? first['version'] as int
          : null;
      final size = await File(path).length().catchError((Object _) => 0);
      if (!mounted) return;
      final confirmed = await showOtaConfirmation(
          context,
          OtaConfirmationData(
              deviceName: widget.device.name,
              deviceId: widget.device.deviceId,
              fileName: _name ?? path,
              fileSize: size,
              sha256: inspection.sha256,
              currentVersion: capabilities.currentVersion,
              targetVersion: target,
              checks: report.checks));
      if (!mounted) return;
      if (!confirmed || !report.canStart) {
        setState(() {
          _running = false;
          _status = report.canStart
              ? '已取消升级'
              : report.checks
                  .where((c) =>
                      c.status == OtaCheckStatus.block ||
                      c.status == OtaCheckStatus.unknown)
                  .map((c) => c.explanation)
                  .join('；');
          _ready = false;
        });
        if (session != null && session.outcome == null) {
          session.apply(OtaEvent(
              sessionId: session.id,
              phase: OtaPhase.finished,
              outcome: OtaOutcome.cancelled));
        }
        _saveTerminal(session?.phase ?? OtaPhase.idle);
        _releaseOwnership();
        ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
        return;
      }
      _targetVersion = target;
      _expectedIcType = capabilities.otaDeviceInfo?.icType;
      _postcheck = null;
      final started = await inspection.startIfSafe(() async {
        final permission = await ref.read(otaBlePermissionProvider)();
        if (!mounted ||
            session != _session ||
            session?.outcome != null ||
            !_ready ||
            _ownership.owner != OtaOwner.ota ||
            ref.read(connectedDeviceProvider) != null ||
            permission != true) {
          throw StateError('设备连接、权限或蓝牙占用状态已改变');
        }
        for (final phase in [
          OtaPhase.checking,
          OtaPhase.awaitingConfirmation,
          OtaPhase.connecting
        ]) {
          if (!session!.apply(OtaEvent(sessionId: session.id, phase: phase))) {
            throw StateError('OTA 会话阶段无效');
          }
          _phaseHistory.add(OtaPhaseEntry(phase, DateTime.now()));
        }
        final now = DateTime.now();
        await (await ref.read(otaRepositoryProvider.future)).saveActive(
            OtaSessionRecord(sessionId: session!.id, startedAt: _startedAt ?? now,
                updatedAt: now, phase: null, outcome: null,
                deviceIdMasked: widget.device.deviceId, firmwareName: _name ?? '',
                firmwareSha256: _firmwareSha256, phaseHistory: [..._phaseHistory],
                targetVersion: _targetVersion, expectedIcType: _expectedIcType));
        if (!mounted || session != _session || session.outcome != null ||
            _ownership.owner != OtaOwner.ota) {
          throw StateError('OTA 会话已结束');
        }
        await _platform.start(path);
      });
      if (!started && mounted) {
        if (session != null && session.outcome == null) {
          session.apply(OtaEvent(
              sessionId: session.id,
              phase: OtaPhase.finished,
              outcome: OtaOutcome.failed));
        }
        _saveTerminal(session?.phase ?? OtaPhase.idle, message: '固件检查后发生变化或无法读取');
        _releaseOwnership();
        _ready = false;
        setState(() {
          _running = false;
          _status = '固件检查后发生变化或无法读取，请重新选择固件';
        });
        ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
      }
    } catch (error) {
      _releaseOwnership();
      _ready = false;
      final session = _session;
      final connectionFailure = session?.phase == OtaPhase.connecting;
      if (session != null && session.outcome == null) {
        session.apply(OtaEvent(
            sessionId: session.id,
            phase: OtaPhase.finished,
            outcome: OtaOutcome.failed));
      }
      _saveTerminal(connectionFailure ? OtaPhase.connecting : OtaPhase.checking, message: error.toString());
      if (mounted) {
        setState(() {
          _running = false;
          _status =
              '启动失败：$error${connectionFailure ? _batteryFailureHint() : ''}';
        });
      }
      ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
    }
  }

  Future<void> _verify() async {
    if (_running || _preparing || _verifying || !_pendingVerification) return;
    setState(() => _verifying = true);
    var acquired = false;
    try {
      PostcheckResult result;
      final currentMask = OtaSessionRecord(sessionId: '', startedAt: DateTime.now(),
          updatedAt: DateTime.now(), phase: null, outcome: null,
          deviceIdMasked: widget.device.deviceId, firmwareName: '',
          firmwareSha256: '', phaseHistory: const []).deviceIdMasked;
      if (_recoveryRecord != null &&
          _recoveryRecord!.deviceIdMasked != currentMask) {
        result = const PostcheckResult(status: PostcheckStatus.unavailable,
            reason: '当前设备与中断的升级记录不一致。', guidance: '请重新选择原设备后核验。');
      } else if (_targetVersion == null || _expectedIcType == null) {
        result = const PostcheckResult(status: PostcheckStatus.unavailable,
            reason: '目标版本未知，无法自动核验。',
            guidance: '请重新连接设备，在设备信息中手动核对固件版本和设备身份。');
      } else if (ref.read(connectedDeviceProvider) != null) {
        result = const PostcheckResult(status: PostcheckStatus.unavailable,
            reason: '普通连接正在占用蓝牙。', guidance: '请先断开普通连接后核验。');
      } else {
        final ownership = _ownership.acquire(OtaOwner.ota);
        acquired = ownership.success;
        if (!acquired) {
          result = PostcheckResult(status: PostcheckStatus.unavailable,
              reason: ownership.reason ?? '蓝牙正在使用。', guidance: '请释放蓝牙后重试核验。');
        } else {
          try {
            await _platform.close();
            result = await ref.read(otaPostcheckerProvider).verifyTarget(
                expectedIdentity: OtaExpectedIdentity(deviceId: widget.device.deviceId,
                    icType: _expectedIcType), expectedVersion: _targetVersion!);
          } catch (_) {
            result = PostcheckResult(status: PostcheckStatus.unavailable,
                reason: '无法连接设备进行核验。',
                guidance: '请重新连接设备，在设备信息中确认版本为 ${formatOtaVersion(_targetVersion!)}，并确认设备身份。');
          }
        }
      }
      if (result.status == PostcheckStatus.mismatch &&
          result.observedIcType != null && result.observedIcType != _expectedIcType) {
        result = PostcheckResult(status: PostcheckStatus.unavailable,
            reason: result.reason, guidance: result.guidance);
      }
      final session = _session;
      if (session != null || _recoveryRecord != null) {
        final now = DateTime.now();
        final prior = _recoveryRecord;
        final record = OtaSessionRecord(sessionId: prior?.sessionId ?? session!.id,
            startedAt: prior?.startedAt ?? _startedAt ?? now, updatedAt: now, phase: OtaPhase.finished,
            outcome: switch (result.status) {
              PostcheckStatus.verified => OtaOutcome.verified,
              PostcheckStatus.mismatch => OtaOutcome.failed,
              PostcheckStatus.unavailable => OtaOutcome.pendingVerification,
            }, deviceIdMasked: prior?.deviceIdMasked ?? widget.device.deviceId,
            firmwareName: prior?.firmwareName ?? _name ?? '',
            firmwareSha256: prior?.firmwareSha256 ?? _firmwareSha256,
            targetVersion: _targetVersion, expectedIcType: _expectedIcType,
            phaseHistory: prior?.phaseHistory ?? [..._phaseHistory]);
        final repository = ref.read(otaRepositoryProvider.future);
        _saveQueue = _saveQueue.then((_) async {
          await (await repository).save(record);
        });
        await _saveQueue;
      }
      if (mounted) setState(() {
        _postcheck = result;
        if (result.status != PostcheckStatus.unavailable) _recoveryLocked = false;
        _pendingVerification = result.status == PostcheckStatus.unavailable;
        _status = switch (result.status) {
          PostcheckStatus.verified => '已核验：设备身份与版本 ${formatOtaVersion(result.observedVersion!)} 一致',
          PostcheckStatus.mismatch => '核验失败：${result.reason}',
          PostcheckStatus.unavailable => '结果待核验：${result.reason}',
        };
      });
    } catch (_) {
      if (mounted) setState(() => _status = '结果待核验：核验失败，请重新连接设备并在设备信息中手动确认版本。');
    } finally {
      if (acquired) _ownership.release(OtaOwner.ota);
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _dismissRecovery() async {
    final prior = _recoveryRecord;
    if (prior != null) {
      try {
        await (await ref.read(otaRepositoryProvider.future)).save(OtaSessionRecord(
            sessionId: prior.sessionId, startedAt: prior.startedAt,
            updatedAt: DateTime.now(), phase: OtaPhase.finished,
            outcome: OtaOutcome.failed, deviceIdMasked: prior.deviceIdMasked,
            firmwareName: prior.firmwareName, firmwareSha256: prior.firmwareSha256,
            phaseHistory: prior.phaseHistory, targetVersion: prior.targetVersion,
            expectedIcType: prior.expectedIcType));
      } catch (_) { return; }
    }
    if (!mounted) return;
    setState(() {
      _recoveryLocked = false;
      _pendingVerification = false;
      _recoveryRecord = null;
      _postcheck = null;
      _status = '请重新选择固件';
    });
    await _prepare();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_running,
        child: Scaffold(
          appBar: AppBar(
              title: const Text('Realtek OTA'),
              automaticallyImplyLeading: !_running),
          body: Padding(
              padding: const EdgeInsets.all(24),
              child: ListView(
                children: [
                  Text('设备：${widget.device.name}'),
                  if (_lastRecord != null) Text('上次升级记录：${_lastRecord!.outcome?.name} ${_lastRecord!.updatedAt}'),
                  const SizedBox(height: 12),
                  Text(_name ?? '尚未选择固件'),
                  OutlinedButton(
                      onPressed: _running || _verifying || _loadingRecovery || _recoveryLocked || _pendingVerification ? null : _choose,
                      child: const Text('选择固件')),
                  FilledButton(
                      onPressed: !_running &&
                              !_preparing &&
                              !_loadingRecovery && !_recoveryLocked && !_pendingVerification &&
                              _ready &&
                              _path != null &&
                              _platform.supported
                          ? _start
                          : null,
                      child: const Text('开始升级')),
                  const SizedBox(height: 20),
                  if (_progress != null)
                    LinearProgressIndicator(value: _progress),
                  Text(_platform.supported ? _status : '当前平台暂不支持 OTA'),
                  for (final check in _checks)
                    ListTile(
                      leading: Icon(
                          check.status == OtaCheckStatus.warn
                              ? Icons.warning_amber
                              : check.status == OtaCheckStatus.pass
                                  ? Icons.check_circle
                                  : Icons.error,
                          color: check.status == OtaCheckStatus.warn
                              ? Colors.amber.shade700
                              : check.status == OtaCheckStatus.pass
                                  ? Colors.green
                                  : Colors.red),
                      title: Text(check.explanation),
                    ),
                  if (_pendingVerification && _postcheck == null)
                    const Text('结果待核验：SDK 已报告完成，尚未确认设备运行的新固件版本。'),
                  if (_postcheck != null && _postcheck!.guidance.isNotEmpty)
                    Text(_postcheck!.guidance),
                  if (_pendingVerification)
                    OutlinedButton(onPressed: _running || _preparing || _verifying ? null : _verify,
                        child: Text(_recoveryLocked ? '重新检查设备' : '核验升级结果')),
                  if (_recoveryLocked && _recoveryRecord != null && !_verifying)
                    OutlinedButton(onPressed: _dismissRecovery,
                        child: Text(_targetVersion == null || _expectedIcType == null
                            ? '我已手动检查设备' : '放弃并重新选择固件')),
                  if (_errorDetails != null) SelectableText(_errorDetails!),
                  if (_failure != null) OtaFailureCard(failure: _failure!, retryCount: _retryCount,
                    onRetry: () { setState(() => _retryCount++); unawaited(_prepare()); },
                    onCopy: _copyDiagnostics),
                  if (!_running && !_pendingVerification && !_verifying && _postcheck == null && _platform.supported)
                    OutlinedButton(
                      onPressed: _preparing || (_failure != null &&
                              (!_failure!.canRetry || _retryCount >= otaMaxRetries))
                          ? null : () {
                              if (_failure != null) setState(() => _retryCount++);
                              unawaited(_prepare());
                            },
                      child: const Text('重新连接'),
                    ),
                ],
              )),
        ),
      );
}
