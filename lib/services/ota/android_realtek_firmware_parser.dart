import 'dart:io';

import 'package:flutter/services.dart';

import 'firmware_inspection.dart';
import 'ota_preflight.dart';
import 'realtek_image_header.dart';

/// SDK inspection is cross-checked against the independently parsed bytes.
class AndroidRealtekFirmwareParser implements FirmwareParser {
  final MethodChannel channel;
  const AndroidRealtekFirmwareParser({
    this.channel = const MethodChannel('honeybox/realtek-ota'),
  });

  @override
  Future<FirmwareParseResult> parse(String path, DeviceCapabilities capabilities) async {
    final header = RealtekImageHeader.parse(await File(path).readAsBytes());
    Map<Object?, Object?>? raw;
    try {
      raw = await channel.invokeMapMethod<Object?, Object?>('inspectFirmware', {'path': path});
    } on PlatformException catch (e) {
      raw = {'channelError': e.code, 'details': e.details};
    } on MissingPluginException {
      raw = {'channelError': 'missing_plugin'};
    }
    final data = raw ?? const <Object?, Object?>{};
    final rawImages = data['images'];
    final images = rawImages is List ? rawImages.whereType<Map>().toList() : <Map>[];
    final single = images.length == 1 ? images.first : null;
    final sdkFields = single != null && single['imageId'] is int && single['binId'] is int &&
        single['version'] is int && single['size'] is int;
    final sdkMismatch = sdkFields && header.imageId != null &&
        (single['imageId'] != header.imageId || single['binId'] != header.binId ||
         single['version'] != header.version || single['size'] != header.imageSize! - 12);
    final status = data['status'];
    final sdkError = data['errorCode'] != null || (status is int && status != 4096);
    final format = header.status == RealtekHeaderStatus.block || sdkError || sdkMismatch
        ? OtaCheckStatus.block
        : header.status == RealtekHeaderStatus.pass && status == 4096 && sdkFields
            ? OtaCheckStatus.pass : OtaCheckStatus.unknown;
    final chip = header.status == RealtekHeaderStatus.block && header.reason.contains('PartNumber')
        ? OtaCheckStatus.block
        : header.icType == null || capabilities.expectedIcType == null
            ? OtaCheckStatus.unknown
            : header.icType == capabilities.expectedIcType ? OtaCheckStatus.pass : OtaCheckStatus.block;
    final deviceReady = capabilities.confirmed && capabilities.imageId != null;
    final imageKnown = header.imageId != null && header.imageSize != null && header.version != null;
    final compatible = format == OtaCheckStatus.pass && deviceReady && imageKnown &&
        capabilities.layoutConfirmed && header.imageId == capabilities.imageId && chip == OtaCheckStatus.pass
        ? OtaCheckStatus.pass : OtaCheckStatus.unknown;
    final canCompare = format == OtaCheckStatus.pass && deviceReady && imageKnown &&
        capabilities.layoutConfirmed && header.imageId == capabilities.imageId && chip == OtaCheckStatus.pass;
    final capacity = !canCompare || capabilities.capacity == null || capabilities.capacity! <= 0
        ? OtaCheckStatus.unknown : header.imageSize! > capabilities.capacity!
            ? OtaCheckStatus.block : OtaCheckStatus.pass;
    // git_ver's sub_version has major[3:0], minor[11:4], revision[26:12],
    // reserve[31:27]. Device encoding is not established; compare raw u32 only
    // when the caller supplies a confirmed comparable device version.
    final current = capabilities.currentVersion;
    final version = !canCompare || current == null || current < 0 || current > 0xffffffff
        ? OtaCheckStatus.unknown : header.version! > current
            ? OtaCheckStatus.pass : OtaCheckStatus.block;
    return FirmwareParseResult(rawStatus: data, type: data['type'] is String
        ? data['type'] as String : (format == OtaCheckStatus.pass ? 'Realtek' : null),
      images: images.map((image) => image.toString()), checks: [
        OtaCheck('format', format, '固件格式：${format.name}；${header.reason}${sdkMismatch ? '；SDK 镜像字段不一致' : ''}'),
        OtaCheck('chip', chip, '目标芯片检查：${chip.name}'),
        OtaCheck('compatibility', compatible, '兼容性：${compatible.name}；需要设备镜像 ID 和布局确认'),
        OtaCheck('capacity', capacity, '容量：${capacity.name}；需要设备 flash bank 容量及布局确认'),
        OtaCheck('version', version, '版本：${version.name}；需要可比较的设备当前版本及布局确认'),
      ]);
  }
}
