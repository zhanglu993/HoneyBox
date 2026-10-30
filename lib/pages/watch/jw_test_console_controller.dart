import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../services/jw/jw_configuration.dart';
import '../../services/jw/history/jw_history_models.dart';
import '../../services/jw/jw_device_repository.dart';
import '../../services/jw/jw_models.dart';
import '../../services/jw/jw_remaining_models.dart';
import '../../services/jw/jw_transport.dart';
import 'jw_test_console_catalog.dart';
import 'jw_test_console_values.dart';

class JwConsoleResult {
  final bool success;
  final String message;
  const JwConsoleResult(this.success, this.message);
}

/// Owns UI evidence for exactly one repository session. Never retains a WidgetRef.
class JwTestConsoleController extends ChangeNotifier {
  final JwDeviceRepository repository;
  late final StreamSubscription<JwDeviceState> _subscription;
  static const contract = JwConfigurationContract.v101S200;
  final results = <String, JwConsoleResult>{};
  final logs = <String>[];
  final current = <String, Object>{};
  final formSources = <String, Object>{};
  Set<String> get _owned => repository.ownedActivities;
  int _disconnectEpoch = 0;
  int _epoch = 0;
  bool _closed = false;
  String? active;
  JwDeviceState get state => repository.state;
  bool get _live =>
      !_closed &&
      ![
        JwDevicePhase.disconnected,
        JwDevicePhase.failed,
        JwDevicePhase.loading,
        JwDevicePhase.loggingIn
      ].contains(state.phase);
  JwTestConsoleController(this.repository) {
    _subscription = repository.changes.listen((state) {
      if (_closed) return;
      if (state.phase == JwDevicePhase.disconnected) _disconnectEpoch++;
      if (!_live) {
        _epoch++;
        active = null;
        results.clear();
        logs.clear();
        current.clear();
        formSources.clear();
      }
      notifyListeners();
    });
  }
  bool _capability(String name) {
    final c = state.capabilities;
    if (name.isEmpty) return true;
    if (c == null) return false;
    return switch (name) {
      'languages' => c.languages,
      'hourSystem' => c.hourSystem,
      'distanceUnit' => c.distanceUnit,
      'screenLightTime' => c.displayTime,
      'screenBrightness' => c.screenBrightness,
      'heartRateAuto' => c.autoHeartRate,
      'bloodOxygenAuto' => c.autoBloodOxygen,
      'bloodPressureAuto' => c.autoBloodPressure && c.factoryBloodPressure,
      'temperatureConfig' => c.temperature && c.factoryTemperature,
      'healthStatus' => c.healthStatus,
      'heartRate' => c.heartRate,
      'bloodOxygen' => c.bloodOxygen,
      'manual-hr' => c.heartRate && c.healthStatus,
      'manual-spo2' => c.bloodOxygen && c.healthStatus,
      'manual-temperature' =>
        c.temperature && c.factoryTemperature && c.healthStatus,
      'manual-bp' =>
        c.bloodPressure && c.factoryBloodPressure && c.healthStatus,
      'turnOverWrist' => c.turnOverWrist,
      'heatStressReminder' => c.heatStressReminder,
      'longSit' => c.longSit,
      'legacyAlarm' => c.legacyAlarm,
      'disturb' => c.disturb,
      'highHeartRateReminder' => c.highHeartRateReminder,
      'exercise' => c.exercise,
      'sportControl' => c.exercise && c.sportControl,
      'camera' => c.camera,
      'findDevice' => c.findDevice,
      _ => false,
    };
  }

  String? disabledReason(String id) {
    final op = jwConsoleOperation(id);
    if (op.blocked != null) return op.blocked;
    if (!_capability(op.capability)) {
      return id.startsWith('manual-bp')
          ? '手动血压不可用：功能位 33 / 工厂开关不满足（与自动血压独立）。'
          : '设备能力 / 工厂开关不支持此项。';
    }
    if (!_live) return '连接不可用，请连接设备。';
    if (active != null || state.operationInProgress) return '已有操作正在执行，请等待。';
    if (op.write && state.phase != JwDevicePhase.loggedIn) return '需先完成协议登录。';
    final t100Read = state.info?.firmware == 'T100' &&
        state.info?.hardware == 'H001' &&
        ([
              'alarm-read',
              'spo2-permission',
              'sport-read',
              'sport-query',
              'sport-cache',
              'health',
              'wrist-read',
              'disturb-read',
              'heat-read',
              'highHr-read'
            ].contains(id) ||
            (id.startsWith('config-') && id.endsWith('-read')));
    if (!t100Read &&
        ![
          'battery',
          'language-read',
          'language-set',
          'time',
          'heart-stream-start',
          'heart-stream-stop'
        ].contains(id) &&
        (state.info?.firmware != 'T005' || state.info?.hardware != 'H001')) {
      return '仅支持明确的 V101 S200 T005/H001 合同。';
    }
    if (id == 'find-stop' && !_owned.contains('find')) {
      return '没有本会话启动的 IAS 提醒。';
    }
    if (id == 'find-start' || id == 'find-stop') {
      final t = repository.transport;
      if (t is! JwImmediateAlertTransport ||
          !(t as JwImmediateAlertTransport).immediateAlertAvailable) {
        return 'IAS 1802/2A06 可写端点不可用。';
      }
    }
    if (id.startsWith('config-') && id.endsWith('-set')) {
      final key = id.substring(0, id.length - 4), value = current[key];
      if (value is! JwConfigurationValue) return '请先单项读取原值。';
      if (!value.writable) return '原值含未知位，不能安全写入。';
    }
    for (final pair in [
      ('wrist-set', 'wrist'),
      ('heat-set', 'heat'),
      ('longSit-set', 'longSit')
    ]) {
      if (id == pair.$1 && !current.containsKey(pair.$2)) return '请先单项读取原值。';
    }
    if (id.startsWith('alarm-') && id != 'alarm-read') {
      final value = current['alarm'];
      if (value is! JwAlarmTable) return '请先读取闹钟整表。';
      if (!value.roundTrippable) return '保留的单次闹钟字段不能安全往返，编辑已锁定。';
      if (id == 'alarm-add' && value.records.length >= 20) {
        return '闹钟整表已达 20 条上限。';
      }
    }
    if (id.startsWith('manual-')) {
      final name = id.split('-')[1];
      if (id.endsWith('-stop') && !_owned.contains('manual-$name')) {
        return '没有本会话启动的测量。';
      }
      if (id.endsWith('-start') && _owned.any((x) => x.startsWith('manual-'))) {
        return '本会话测量仍活动，请先停止。';
      }
    }
    if (id == 'heart-stream-stop' && !state.heartRateStreaming) {
      return '没有本会话实时心率流。';
    }
    if (id == 'heart-stream-start' && state.heartRateStreaming) {
      return '实时心率流已经开启。';
    }
    for (final name in ['photo', 'find']) {
      if (id == '$name-stop' && !_owned.contains(name)) {
        return '没有本会话启动的${name == 'photo' ? '拍照模式' : 'IAS 提醒'}。';
      }
      if (id == '$name-start' && _owned.contains(name)) return '本会话活动尚未停止。';
    }
    if (['sport-pause', 'sport-resume', 'sport-stop'].contains(id) &&
        !_owned.contains('sport')) {
      return '没有本会话启动的运动。';
    }
    if (id == 'sport-start') {
      if (_owned.contains('sport')) return '本会话运动尚未停止。';
      if (repository.getCachedSupportedUkSportTypes() == null) {
        return '请先读取实际支持的运动类型。';
      }
    }
    return null;
  }

  Future<void> run(String id, Map<String, String> parameters) async {
    if (_closed || active != null || state.operationInProgress) return;
    final epoch = _epoch,
        disconnected = _disconnectEpoch,
        reason = disabledReason(id);
    if (reason != null) {
      results[id] = JwConsoleResult(false, reason);
      _log(id, 'disabled', parameters, reason);
      notifyListeners();
      return;
    }
    active = id;
    results.remove(id);
    _log(id, 'start', parameters, '');
    notifyListeners();
    try {
      final result = await _dispatch(id, JwConsoleParameters(parameters));
      if (_closed || epoch != _epoch || !_live) return;
      final message = jwConsoleValue(result);
      results[id] = JwConsoleResult(
          result is! JwSportStatus || result.operationAccepted, message);
      _log(id, 'result', parameters, message);
    } catch (e) {
      // Same-connection terminal errors are diagnostic evidence, not live values.
      // An actual disconnect or disposed/replaced route still discards late evidence.
      final terminalFailure = state.phase == JwDevicePhase.failed &&
          disconnected == _disconnectEpoch;
      if (_closed || (!terminalFailure && (epoch != _epoch || !_live))) return;
      if (id.startsWith('config-')) {
        current.remove(id.replaceFirst(RegExp(r'-(set|read)$'), ''));
      }
      if (id.endsWith('-read')) current.remove(id.substring(0, id.length - 5));
      final message = e is JwCompoundSubmissionException
          ? '部分提交：${e.acknowledged.length} 条命令收到 ACK；剩余失败，未确认应用。 ${e.cause}'
          : terminalFailure
              ? '${e.toString()}；若命令已发出，设备应用状态未确认，请重新连接后核对。'
              : e.toString();
      results[id] = JwConsoleResult(false, message);
      _log(id, e is JwConfigurationException ? e.stage : 'error', parameters,
          message);
      notifyListeners();
    } finally {
      if (!_closed && epoch == _epoch) {
        active = null;
        notifyListeners();
      }
    }
  }

  void _log(
      String id, String stage, Map<String, String> parameters, String result) {
    final privacy = id == 'profile';
    logs.add(
        '${DateTime.now().toLocal().toIso8601String()} $id [$stage] ${privacy ? '参数已隐藏' : parameters.entries.map((e) => '${e.key}=${e.value}').join(', ')} ${privacy ? (stage == 'result' ? '资料 / 目标 ACK 提交结果' : '资料 / 目标状态；参数已隐藏') : result}');
    final last = logs.last;
    if (last.length > 2048) {
      logs[logs.length - 1] = '${last.substring(0, 2047)}…';
    }
    if (logs.length > 80) logs.removeRange(0, logs.length - 80);
  }

  Future<Object?> _dispatch(String id, JwConsoleParameters p) async {
    if (id.startsWith('config-')) {
      final name = id.split('-')[1],
          domain =
              JwConfigurationDomain.values.firstWhere((d) => d.name == name),
          key = 'config-$name';
      if (id.endsWith('-read')) {
        final value =
            await repository.readConfiguration(domain, contract: contract);
        if (_live) current[key] = value;
        return value;
      }
      final change = p.change(domain);
      final result = await repository.setConfigurationVerified(change,
          contract: contract,
          expectedCurrent: current[key] as JwConfigurationValue);
      if (_live) current[key] = result.observed;
      return result;
    }
    if (id.startsWith('manual-')) {
      final name = id.split('-')[1], enabled = id.endsWith('-start');
      final JwSubmission result;
      switch (name) {
        case 'hr':
          result = await repository.controlHeartRateMeasurement(enabled,
              contract: contract);
        case 'spo2':
          result = await repository.controlSpO2Measurement(enabled,
              contract: contract);
        case 'temperature':
          result = await repository.controlTemperatureMeasurement(enabled,
              contract: contract);
        default:
          result = await repository.controlBloodPressureMeasurement(enabled,
              contract: contract);
      }
      return result;
    }
    switch (id) {
      case 'history-reset':
        return repository.resetHistoryCursor(contract: contract);
      case 'history-sync':
        final v = await repository.syncHistory();
        return '同步阶段=${v.phase.name}；${v.phase == JwHistoryPhase.completed ? '完整轮次结束，设备是否覆盖全部保留数据仍需确认' : '未完成'}；本地保存=${v.localCommitComplete}；设备确认传输=${v.applicationAckTransportDelivered}';
      case 'battery':
        return '当前电量=${await repository.readBatteryLevel()}%（新读取）';
      case 'language-read':
        return '当前语言=${await repository.queryLanguage()}（新读取）';
      case 'language-set':
        final value = p.integer('value', 0, 2), before = state.language;
        await repository.setLanguageVerified(value);
        return '原值：$before\n请求值：$value\n读回值：${state.language}\n独立读回一致';
      case 'time':
        await repository.syncTime(DateTime.now());
        return '时间命令收到 ACK，仅提交证据，无时间独立读回。';
      case 'health':
        return repository.readHealthStatus(contract: contract);
      case 'heart-stream-start':
        await repository.setHeartRateStreaming(true);
        return '实时心率流已开启；等待有效 typed 心率通知。';
      case 'heart-stream-stop':
        await repository.setHeartRateStreaming(false);
        return '实时心率流已停止。';
      case 'spo2-permission':
        return repository.checkSpO2MeasureEnable(contract: contract);
      case 'wrist-read':
        final v = await repository.readTurnOverWrist(contract: contract);
        if (_live) current['wrist'] = v;
        return v;
      case 'wrist-set':
        final enabled = p.flag('enabled');
        final v = await repository.setTurnOverWrist(enabled,
            expectedCurrent: current['wrist'] as JwTurnOverWristStatus,
            contract: contract);
        if (_live) current['wrist'] = v.observed;
        return v;
      case 'heat-read':
        final v = await repository.queryHeatStressReminder(contract: contract);
        if (_live) current['heat'] = v;
        return v;
      case 'heat-set':
        final target = p.heat();
        final v = await repository.setHeatStressReminder(target,
            expectedCurrent: current['heat'] as JwHeatStressReminderStatus,
            contract: contract);
        if (_live) current['heat'] = v.observed;
        return v;
      case 'longSit-read':
        final v = await repository.readLongSit(contract: contract);
        if (_live) current['longSit'] = v;
        return v;
      case 'longSit-set':
        final before = current['longSit'] as JwLongSitSettings,
            target = p.longSit(before);
        final v = await repository.setLongSit(target,
            expectedCurrent: before, contract: contract);
        if (_live) current['longSit'] = v.observed;
        return v;
      case 'alarm-read':
        final v = await repository.readAlarm(contract: contract);
        if (_live) current['alarm'] = v;
        return v;
      case 'alarm-add':
        final target = p.alarm();
        final v = await repository.addAlarm(target,
            expectedCurrent: current['alarm'] as JwAlarmTable,
            contract: contract);
        if (_live) current['alarm'] = v.observed;
        return v;
      case 'alarm-delete':
        final before = current['alarm'] as JwAlarmTable,
            index = p.integer('index', 0, before.records.length - 1);
        final v = await repository.deleteAlarm(index,
            expectedCurrent: before, contract: contract);
        if (_live) current['alarm'] = v.observed;
        return v;
      case 'alarm-modify':
        final before = current['alarm'] as JwAlarmTable,
            index = p.integer('index', 0, before.records.length - 1),
            target = p.alarm(before: before.records[index]);
        final v = await repository.modifyAlarm(index, target,
            expectedCurrent: before, contract: contract);
        if (_live) current['alarm'] = v.observed;
        return v;
      case 'disturb-read':
        return repository.readDisturb(contract: contract);
      case 'highHr-read':
        return repository.readHeartRateReminderDiagnostic(contract: contract);
      case 'sport-read':
        return repository.readSupportDeviceSport(contract: contract);
      case 'sport-cache':
        final types = repository.getCachedSupportedUkSportTypes();
        return types == null
            ? '尚无本会话缓存。'
            : '本会话缓存 UK 类型代码：${types.join(', ')}（未重新读取设备）';
      case 'sport-query':
        return repository.queryDeviceSportStatus(contract: contract);
      case 'sport-start':
        final type = p.integer('type', 1, 27);
        if (repository.getCachedSupportedUkSportTypes()?.contains(type) !=
            true) {
          throw const FormatException('UK 类型代码不在实际支持列表');
        }
        final v = await repository.startDeviceSport(type, contract: contract);
        return v;
      case 'sport-pause':
        return repository.pauseDeviceSport(contract: contract);
      case 'sport-resume':
        return repository.resumeDeviceSport(contract: contract);
      case 'sport-stop':
        final v = await repository.stopDeviceSport(contract: contract);
        return v;
      case 'profile':
        final gender = p.integer('gender', 0, 1),
            age = p.integer('age', 0, 127),
            height = p.halfUnit('height', 256),
            weight = p.halfUnit('weight', 512),
            steps = p.optional('steps', 0xffffffff),
            sleep = p.optional('sleep', 65535);
        return repository.syncUserInfo(
            gender: gender,
            age: age,
            heightCm: height,
            weightKg: weight,
            targetSteps: steps,
            targetSleepMinutes: sleep,
            contract: contract);
      case 'photo-start':
      case 'photo-stop':
        final enabled = id.endsWith('-start'),
            v = await repository.setTakePhotoControl(enabled,
                contract: contract);
        return v;
      case 'find-start':
      case 'find-stop':
        final enabled = id.endsWith('-start');
        final v = await repository.findDevice(enabled, contract: contract);
        return v;
      default:
        throw const FormatException('没有可执行的 SDK 合同');
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
