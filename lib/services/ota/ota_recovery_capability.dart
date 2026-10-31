import 'ota_device_profile.dart';
import 'ota_session.dart';

enum RecoveryCapabilityState { proven, unknown, unsupported }

class OtaRecoveryCapabilities {
  final RecoveryCapabilityState restart, resumeOffset, dfuMode, rollback;
  const OtaRecoveryCapabilities(
      {required this.restart,
      required this.resumeOffset,
      required this.dfuMode,
      required this.rollback});

  factory OtaRecoveryCapabilities.forProfile(OtaDeviceProfile? profile) {
    // 仅模拟器验证，真机未证实。
    return const OtaRecoveryCapabilities(
        restart: RecoveryCapabilityState.unknown,
        resumeOffset: RecoveryCapabilityState.unknown,
        dfuMode: RecoveryCapabilityState.unknown,
        rollback: RecoveryCapabilityState.unknown);
  }

  String guidance(OtaPhase? phase) =>
      '重新刷写、续传、回滚和 DFU 恢复未经验证，请保持设备供电，重新连接后核验版本，必要时联系支持。';
}
