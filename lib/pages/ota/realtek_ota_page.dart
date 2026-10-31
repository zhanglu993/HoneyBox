import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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

final otaPlatformProvider = Provider<OtaPlatform>((ref) =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? AndroidRealtekOtaPlatform()
        : const UnsupportedOtaPlatform());

final otaProfileRegistryProvider =
    Provider<OtaProfileRegistry>((ref) => const OtaProfileRegistry());

final firmwareParserProvider = Provider<FirmwareParser>((ref) =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? AndroidRealtekFirmwareParser(
            registry: ref.watch(otaProfileRegistryProvider))
        : _UnknownParser());
final otaDeviceProbeProvider = Provider<DeviceProbe>((ref) =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? const FlutterBlueDeviceProbe() : const UnknownDeviceProbe());
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

class _RealtekOtaPageState extends ConsumerState<RealtekOtaPage> {
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
  bool _preparing = false;
  int _sessionSequence = 0;
  OtaSession? _session;
  DeviceCapabilities? _capabilities;
  bool _disposed = false;
  List<OtaCheck> _checks = const [];

  String _batteryFailureHint() {
    final caps = _capabilities;
    final profiles = ref.read(otaProfileRegistryProvider).profiles;
    if (caps?.charging != false || profiles.length != 1) return '';
    final profile = profiles.single;
    final threshold = profile.batteryMinPercent;
    if (threshold == null || (profile.batterySource != BatterySource.bwps &&
        profile.batterySource != BatterySource.basAndBwps)) return '';
    final value = caps?.batteryPercent;
    if (value != null && value > 0 && value <= 100 && value >= threshold) return '';
    return '；设备可能因电量低于 $threshold% 且未充电而拒绝进入升级模式,请充电后重试';
  }


  @override
  void initState() {
    super.initState();
    _platform = ref.read(otaPlatformProvider);
    if (_platform.supported) {
      _subscription = _platform.events.listen((event) {
        if (!mounted) return;
        final session = _session;
        if (session == null || event['sessionId'] is! String) return;
        if (event['sessionId'] != session.id) return;
        final disconnected = event['disconnected'] == true ||
            event['message'] == '设备已断开';
        if (disconnected) {
          final _disconnectHint = session.phase == OtaPhase.preparing || session.phase == OtaPhase.connecting ? _batteryFailureHint() : '';
          if (!session.disconnect(event['sessionId'] as String)) return;
          setState(() {
            _ready = false;
            if (session.outcome == null) {
              _status = '设备正在重启，等待重新连接';
            } else {
              _status = '设备已断开${session.failureDescription == '设备已断开' && (session.phase == OtaPhase.finished) ? _disconnectHint : ''}';
              _running = false;
            }
          });
          if (session.outcome != null) {
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
        // The current native bridge reports these SDK states as messages.
        if (!done && event['phase'] == null) {
          if (event['progress'] is num && session.phase == OtaPhase.connecting) {
            session.apply(OtaEvent(sessionId: session.id, phase: OtaPhase.transferring));
          } else if (event['message'] == '正在激活固件' &&
              session.phase == OtaPhase.transferring) {
            session.apply(OtaEvent(sessionId: session.id, phase: OtaPhase.validating));
            session.apply(OtaEvent(sessionId: session.id, phase: OtaPhase.activating));
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
        if (!session.apply(OtaEvent(
          sessionId: event['sessionId'] as String,
          phase: phase,
          outcome: outcome,
          progress: progress is num ? progress.toDouble() / 100 : null,
          rawType: event['errorType'] is int ? event['errorType'] as int : null,
          rawCode: event['errorCode'] is int ? event['errorCode'] as int : null,
        ))) {
          return;
        }
        setState(() {
          if (message is String && session.failureDescription != '阶段超时') {
            _status = message + (done && outcome == OtaOutcome.failed &&
                (previousPhase == OtaPhase.preparing || previousPhase == OtaPhase.connecting)
                ? _batteryFailureHint() : '');
          }
          if (progress is num) _progress = session.progress;
          if (done) _running = false;
          if (event['ready'] == true) _ready = true;
          if (done) _ready = false;
          if (session.rawType != null || session.rawCode != null) {
            _errorDetails =
                'SDK 错误类型：${session.rawType ?? '未知'}，错误码：${session.rawCode ?? '未知'}';
          }
          if (done) {
            _pendingVerification = event['outcome'] == 'pendingVerification';
          }
        });
        if (done) ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
      }, onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _ready = false;
          _status = _running
              ? '升级状态通信中断，设备可能仍在写入。请勿断电，等待设备状态确认：$error'
              : '连接状态通信失败：$error';
        });
      });
      unawaited(_prepare());
    }
  }

  Future<void> _prepare() async {
    if (_preparing || _running || (_session != null && _session!.outcome == null)) {
      if (mounted) setState(() => _status = 'OTA 会话正在进行，请先结束当前会话');
      return;
    }
    setState(() {
      _preparing = true;
      _ready = false;
    });
    try {
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
        probe = await ref.read(otaDeviceProbeProvider).probe(widget.device.deviceId)
            .timeout(const Duration(seconds: 35));
      } catch (error) {
        probe = const DeviceProbeResult();
        if (mounted) setState(() => _errorDetails = '设备预读取失败或超时，设备信息未知：$error');
      }
      final capabilities = DeviceCapabilities(
          confirmed: probe.currentVersion != null || probe.otaDeviceInfo != null,
          icType: probe.otaDeviceInfo?.icType,
          currentVersion: probe.currentVersion,
          otaDeviceInfo: probe.otaDeviceInfo,
          batteryPercent: probe.batteryPercent,
          charging: probe.charging,
          expectedIcType: configured.expectedIcType,
          deviceReportedCapacity: configured.deviceReportedCapacity);
      if (_disposed) return;
      _capabilities = capabilities;
      final session = OtaSession(
          '${DateTime.now().microsecondsSinceEpoch}-${_sessionSequence++}',
          onTimeout: (timedOut) {
        if (!mounted || _session != timedOut) return;
        setState(() {
          _status = '阶段超时${timedOut.timedOutPhase == OtaPhase.preparing || timedOut.timedOutPhase == OtaPhase.connecting ? _batteryFailureHint() : ''}';
          _running = false;
          _ready = false;
        });
        ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
      });
      _session = session;
      session.apply(OtaEvent(sessionId: session.id, phase: OtaPhase.preparing));
      await _platform.prepare(widget.device.deviceId, sessionId: session.id);
    } catch (error) {
      final session = _session;
      if (session != null && session.outcome == null) {
        session.apply(OtaEvent(sessionId: session.id, phase: OtaPhase.finished,
            outcome: OtaOutcome.failed));
      }
      if (mounted) setState(() => _status = '连接失败：$error${_batteryFailureHint()}');
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _session?.dispose();
    _subscription?.cancel();
    if (_session != null) {
      unawaited(_platform.close().catchError((Object _) {}));
    }
    super.dispose();
  }

  Future<void> _choose() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (!mounted || result == null) return;
      final file = result.files.single;
      setState(() {
        _path = file.path;
        _name = file.name;
        _status = file.path == null ? '无法读取所选文件' : '已选择固件';
        _progress = null;
        _checks = const [];
      });
    } catch (error) {
      if (mounted) setState(() => _status = '选择文件失败：$error');
    }
  }

  Future<void> _start() async {
    if (_path == null || _running || _preparing || !_ready) return;
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
      if (session != _session || session?.outcome != null || !_ready) {
        setState(() => _running = false);
        ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
        return;
      }
      setState(() => _checks = inspection.report.checks);
      if (!inspection.report.canStart) {
        setState(() {
          _running = false;
          _status = inspection.report.checks
              .where((check) => check.status != OtaCheckStatus.pass)
              .map((check) => check.explanation)
              .join('；');
        });
        ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
        return;
      }
      final warnings = inspection.report.checks
          .where((check) => check.status == OtaCheckStatus.warn).toList();
      if (warnings.isNotEmpty) {
        final confirmed = await showDialog<bool>(context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('升级风险提示'),
            content: SingleChildScrollView(child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: warnings.map((check) => Text(check.explanation)).toList(),
            )),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认继续')),
            ],
          ));
        if (!mounted) return;
        if (confirmed != true) {
          setState(() { _running = false; _status = '已取消升级'; });
          ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
          return;
        }
      }
      final started = await inspection.startIfSafe(() async {
        if (!mounted ||
            session != _session ||
            session?.outcome != null ||
            !_ready) {
          throw StateError('设备连接状态已改变');
        }
        for (final phase in [OtaPhase.checking, OtaPhase.awaitingConfirmation,
          OtaPhase.connecting]) {
          if (!session!.apply(OtaEvent(sessionId: session.id, phase: phase))) {
            throw StateError('OTA 会话阶段无效');
          }
        }
        await _platform.start(path);
      });
      if (!started && mounted) {
        setState(() {
          _running = false;
          _status = '固件检查后发生变化或无法读取，请重新选择固件';
        });
        ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
      }
    } catch (error) {
      final session = _session;
      final connectionFailure = session?.phase == OtaPhase.connecting;
      if (session != null && session.outcome == null &&
          session.phase == OtaPhase.connecting) {
        session.apply(OtaEvent(sessionId: session.id, phase: OtaPhase.finished,
            outcome: OtaOutcome.failed));
      }
      if (mounted) {
        setState(() {
          _running = false;
          _status = '启动失败：$error${connectionFailure ? _batteryFailureHint() : ''}';
        });
      }
      ref.read(rtl8762OtaInProgressProvider.notifier).state = false;
    }
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
                  const SizedBox(height: 12),
                  Text(_name ?? '尚未选择固件'),
                  OutlinedButton(
                      onPressed: _running ? null : _choose,
                      child: const Text('选择固件')),
                  FilledButton(
                      onPressed: !_running &&
                              !_preparing &&
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
                      leading: Icon(check.status == OtaCheckStatus.warn ? Icons.warning_amber :
                          check.status == OtaCheckStatus.pass ? Icons.check_circle : Icons.error,
                          color: check.status == OtaCheckStatus.warn ? Colors.amber.shade700 :
                              check.status == OtaCheckStatus.pass ? Colors.green : Colors.red),
                      title: Text(check.explanation),
                    ),
                  if (_pendingVerification)
                    const Text('结果待核验：SDK 已报告完成，尚未确认设备运行的新固件版本。'),
                  if (_errorDetails != null) SelectableText(_errorDetails!),
                  if (!_running && _platform.supported)
                    OutlinedButton(
                      onPressed: _preparing ? null : _prepare,
                      child: const Text('重新连接'),
                    ),
                ],
              )),
        ),
      );
}
