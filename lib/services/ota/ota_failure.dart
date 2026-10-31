import 'device_probe.dart';
import 'ota_session.dart';

enum OtaFailureCategory {
  crc,
  flash,
  connection,
  battery,
  protocol,
  timeout,
  disconnected,
  permission,
  unknown
}

class OtaFailure {
  final OtaFailureCategory category;
  final OtaPhase? phase;
  final int? rawType, rawCode;
  final String? rawMessage, deviceState;
  final bool canRetry;
  final String guidance;
  const OtaFailure(
      {required this.category,
      this.phase,
      this.rawType,
      this.rawCode,
      this.rawMessage,
      this.deviceState,
      required this.canRetry,
      required this.guidance});

  static OtaFailure classify(
      {OtaPhase? phase,
      int? rawType,
      int? rawCode,
      String? message,
      String? deviceState,
      DeviceProbeResult? probe,
      int? batteryMinPercent,
      OtaFailureCategory? confirmedCategory}) {
    var detail = message?.trim() ?? '';
    if (detail.isEmpty) detail = '无详细信息';
    if (detail.length > 500) detail = '${detail.substring(0, 500)}…';
    final battery = probe?.batteryPercent;
    final low = battery != null &&
        battery >= 0 &&
        battery <= 100 &&
        batteryMinPercent != null &&
        battery < batteryMinPercent &&
        probe?.charging == false;
    final category = confirmedCategory ??
        (low ? OtaFailureCategory.battery : OtaFailureCategory.unknown);
    final advice = category == OtaFailureCategory.battery
        ? '检测到电量低且未充电，请充电后重试。'
        : '原因未确认，请检查设备状态后重试。';
    return OtaFailure(
        category: category,
        phase: phase,
        rawType: rawType,
        rawCode: rawCode,
        rawMessage: detail,
        deviceState: deviceState,
        canRetry: phase != OtaPhase.transferring &&
            phase != OtaPhase.validating &&
            phase != OtaPhase.activating &&
            phase != OtaPhase.rebooting &&
            phase != OtaPhase.reconnecting &&
            phase != OtaPhase.verifying,
        guidance: '$advice 错误码 ${rawType ?? '未知'}/${rawCode ?? '未知'}');
  }

  OtaFailure merge(OtaFailure next) {
    final currentSpecific = category != OtaFailureCategory.unknown &&
        category != OtaFailureCategory.connection;
    final nextSpecific = next.category != OtaFailureCategory.unknown &&
        next.category != OtaFailureCategory.connection;
    final chosen = nextSpecific && !currentSpecific ? next : this;
    final type = next.rawType ?? rawType;
    final code = next.rawCode ?? rawCode;
    return OtaFailure(
        category: chosen.category,
        phase: chosen.phase ?? phase ?? next.phase,
        rawType: type,
        rawCode: code,
        rawMessage: next.rawCode != null || next.rawType != null
            ? next.rawMessage
            : chosen.rawMessage,
        deviceState: next.deviceState ?? deviceState,
        canRetry: chosen.canRetry,
        guidance:
            '${chosen.guidance.split(' 错误码 ').first} 错误码 ${type ?? '未知'}/${code ?? '未知'}');
  }
}
