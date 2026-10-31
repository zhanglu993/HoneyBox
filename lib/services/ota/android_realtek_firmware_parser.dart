import 'package:flutter/services.dart';

import 'firmware_inspection.dart';
import 'ota_preflight.dart';

/// The channel returns SDK evidence, not a guarantee of authenticity.
class AndroidRealtekFirmwareParser implements FirmwareParser {
  final MethodChannel channel;
  const AndroidRealtekFirmwareParser({
    this.channel = const MethodChannel('honeybox/realtek-ota'),
  });

  @override
  Future<FirmwareParseResult> parse(String path, DeviceCapabilities capabilities) async {
    Map<Object?, Object?>? raw;
    try {
      raw = await channel.invokeMapMethod<Object?, Object?>('inspectFirmware', {'path': path});
    } on PlatformException catch (e) {
      return FirmwareParseResult(rawStatus: {'errorCode': e.code, 'details': e.details},
          checks: [const OtaCheck('format', OtaCheckStatus.unknown, 'SDK 解析调用失败')]);
    } on MissingPluginException {
      return FirmwareParseResult(checks: [
        const OtaCheck('format', OtaCheckStatus.unknown, 'SDK 解析不可用')]);
    }
    final data = raw ?? const <Object?, Object?>{};
    final status = data['status'];
    final error = data['errorCode'];
    final format = error != null || (status is int && status != 4096)
        ? OtaCheckStatus.block
        : status == 4096 && data['updateEnabled'] == true && data['formatVerified'] == true
            ? OtaCheckStatus.pass : OtaCheckStatus.unknown;
    final rawImages = data['images'];
    final images = rawImages is List ? rawImages.whereType<Map>().toList() : <Map>[];
    final ic = data['icType'];
    final deviceReady = capabilities.confirmed && capabilities.icType != null &&
        capabilities.currentVersion != null && capabilities.capacity != null &&
        capabilities.imageId != null;
    final single = images.length == 1 ? images.first : null;
    final id = single?['imageId'];
    final size = single?['size'];
    final version = single?['version'];
    final targetVersion = data['version'];
    final validImage = single != null && id is int && id > 0 && size is int && size > 0 &&
        version is int && version >= 0 && targetVersion is int && targetVersion == version;
    final chip = !deviceReady || ic is! int || ic <= 0 ? OtaCheckStatus.unknown
        : ic == capabilities.icType ? OtaCheckStatus.pass : OtaCheckStatus.block;
    final compatible = format == OtaCheckStatus.pass && deviceReady &&
        capabilities.layoutConfirmed && validImage &&
        id == capabilities.imageId && chip == OtaCheckStatus.pass
        ? OtaCheckStatus.pass : OtaCheckStatus.unknown;
    final capacity = !deviceReady || !validImage || id != capabilities.imageId ||
        data['capacityCheckAvailable'] != true || capabilities.capacity! <= 0
        ? OtaCheckStatus.unknown
        : size > capabilities.capacity! ? OtaCheckStatus.block : OtaCheckStatus.pass;
    final versionStatus = !deviceReady || !validImage || id != capabilities.imageId ||
        data['versionCheckAvailable'] != true ? OtaCheckStatus.unknown
        : version > capabilities.currentVersion! ? OtaCheckStatus.pass : OtaCheckStatus.block;
    return FirmwareParseResult(rawStatus: data, type: data['type'] is String
        ? data['type'] as String : (format == OtaCheckStatus.pass ? 'Realtek' : null),
      images: images.map((image) => image.toString()), checks: [
        OtaCheck('format', format, 'SDK 固件格式检查：${format.name}'),
        OtaCheck('chip', chip, '芯片检查：${chip.name}'),
        OtaCheck('compatibility', compatible, '设备和镜像兼容性：${compatible.name}'),
        OtaCheck('capacity', capacity, '镜像容量检查：${capacity.name}'),
        OtaCheck('version', versionStatus, '版本检查（同版及降级禁止）：${versionStatus.name}'),
      ]);
  }
}
