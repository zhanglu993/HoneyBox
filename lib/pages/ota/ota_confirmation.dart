import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/ota/ota_preflight.dart';
import '../../services/ota/android_realtek_firmware_parser.dart'
    show formatOtaVersion;

class OtaConfirmationData {
  final String deviceName, deviceId, fileName;
  final int fileSize;
  final String? sha256;
  final int? currentVersion, targetVersion;
  final List<OtaCheck> checks;
  OtaConfirmationData(
      {required this.deviceName,
      required this.deviceId,
      required this.fileName,
      required this.fileSize,
      this.sha256,
      this.currentVersion,
      this.targetVersion,
      required Iterable<OtaCheck> checks})
      : checks = List.unmodifiable(checks);
  bool get hasWarn => checks.any((c) => c.status == OtaCheckStatus.warn);
  bool get canStart => PreflightReport(checks).canStart;
}

Future<bool> showOtaConfirmation(
        BuildContext context, OtaConfirmationData data) async =>
    await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (_) => OtaConfirmationSheet(data: data)) ??
    false;

class OtaConfirmationSheet extends StatefulWidget {
  final OtaConfirmationData data;
  const OtaConfirmationSheet({super.key, required this.data});
  @override
  State<OtaConfirmationSheet> createState() => _OtaConfirmationSheetState();
}

class _OtaConfirmationSheetState extends State<OtaConfirmationSheet> {
  bool acknowledged = false;
  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final digest = data.sha256;
    String version(int? v) => v == null ? '未知' : formatOtaVersion(v);
    return SafeArea(
        child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .85,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Text('升级前确认', style: Theme.of(context).textTheme.titleLarge),
              Text('设备：${data.deviceName}（${data.deviceId}）'),
              Text('固件：${data.fileName}（${data.fileSize} 字节）'),
              Text(
                  '版本：${version(data.currentVersion)} → ${version(data.targetVersion)}'),
              ExpansionTile(
                  title: Text(
                      'SHA-256：${digest == null ? '未知' : digest.substring(0, digest.length < 12 ? digest.length : 12)}'),
                  children: [
                    if (digest != null) SelectableText(digest),
                    if (digest != null)
                      TextButton(
                          onPressed: () =>
                              Clipboard.setData(ClipboardData(text: digest)),
                          child: const Text('复制完整摘要'))
                  ]),
              for (final check in data.checks)
                Semantics(
                    label: '${switch (check.status) {
                      OtaCheckStatus.pass => '通过',
                      OtaCheckStatus.warn => '警告',
                      OtaCheckStatus.block => '阻断',
                      OtaCheckStatus.unknown => '未知'
                    }}：${check.explanation}',
                    child: ListTile(
                        leading: Icon(switch (check.status) {
                          OtaCheckStatus.pass => Icons.check_circle,
                          OtaCheckStatus.warn => Icons.warning_amber,
                          OtaCheckStatus.block => Icons.block,
                          OtaCheckStatus.unknown => Icons.help_outline
                        }),
                        title: Text('${switch (check.status) {
                          OtaCheckStatus.pass => '通过',
                          OtaCheckStatus.warn => '警告',
                          OtaCheckStatus.block => '阻断',
                          OtaCheckStatus.unknown => '未知'
                        }}：${check.explanation}'))),
              if (data.canStart && data.hasWarn)
                CheckboxListTile(
                    value: acknowledged,
                    onChanged: (v) => setState(() => acknowledged = v ?? false),
                    title: const Text('我已了解风险')),
              if (data.canStart)
                FilledButton(
                    onPressed: !data.hasWarn || acknowledged
                        ? () => Navigator.pop(context, true)
                        : null,
                    child: const Text('确认升级')),
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
            ])));
  }
}
