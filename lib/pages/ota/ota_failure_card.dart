import 'package:flutter/material.dart';
import '../../services/ota/ota_failure.dart';
import '../../services/ota/ota_session.dart';
import '../../services/ota/ota_recovery_capability.dart';

const otaMaxRetries = 2;

class OtaFailureCard extends StatelessWidget {
  final OtaFailure failure;
  final int retryCount;
  final VoidCallback? onRetry;
  final Future<void> Function()? onCopy;
  const OtaFailureCard(
      {super.key,
      required this.failure,
      required this.retryCount,
      this.onRetry,
      this.onCopy});
  @override
  Widget build(BuildContext context) {
    final title = switch (failure.category) {
      OtaFailureCategory.crc => 'CRC 校验失败',
      OtaFailureCategory.flash => 'Flash 错误',
      OtaFailureCategory.connection => '连接失败',
      OtaFailureCategory.battery => '电量不足',
      OtaFailureCategory.protocol => '协议错误',
      OtaFailureCategory.timeout => '升级超时',
      OtaFailureCategory.disconnected => '设备已断开',
      OtaFailureCategory.permission => '权限不足',
      OtaFailureCategory.unknown => '升级失败',
    };
    final code = '错误码 ${failure.rawType ?? '未知'}/${failure.rawCode ?? '未知'}';
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(
                  label: '$title，$code',
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium)),
              if (failure.deviceState != null &&
                  failure.deviceState!.isNotEmpty)
                Text(failure.deviceState!),
              Text(failure.guidance),
              if (failure.phase != null &&
                  failure.phase!.index >= OtaPhase.transferring.index)
                Text(OtaRecoveryCapabilities.forProfile(null).guidance(failure.phase)),
              Wrap(spacing: 8, children: [
                OutlinedButton(
                    onPressed: failure.canRetry && retryCount < otaMaxRetries
                        ? onRetry
                        : null,
                    child: const Text('重试')),
                OutlinedButton(onPressed: onCopy, child: const Text('复制诊断日志')),
              ])
            ])));
  }
}
