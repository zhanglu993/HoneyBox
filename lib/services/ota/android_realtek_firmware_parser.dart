import 'dart:io';

import 'package:flutter/services.dart';

import 'firmware_inspection.dart';
import 'ota_preflight.dart';
import 'realtek_image_header.dart';
import 'ota_device_profile.dart';

/// SDK inspection is cross-checked against the independently parsed bytes.
class AndroidRealtekFirmwareParser implements FirmwareParser {
  final MethodChannel channel;
  final OtaProfileRegistry registry;
  const AndroidRealtekFirmwareParser({
    this.channel = const MethodChannel('honeybox/realtek-ota'),
    this.registry = const OtaProfileRegistry(),
  });

  @override
  Future<FirmwareParseResult> parse(
      String path, DeviceCapabilities capabilities) async {
    final header = RealtekImageHeader.parse(await File(path).readAsBytes());
    Map<Object?, Object?>? raw;
    try {
      raw = await channel
          .invokeMapMethod<Object?, Object?>('inspectFirmware', {'path': path});
    } on PlatformException catch (e) {
      raw = {'channelError': e.code, 'details': e.details};
    } on MissingPluginException {
      raw = {'channelError': 'missing_plugin'};
    }
    final data = raw ?? const <Object?, Object?>{};
    final rawImages = data['images'];
    final images =
        rawImages is List ? rawImages.whereType<Map>().toList() : <Map>[];
    final single = images.length == 1 ? images.first : null;
    final sdkFields = single != null &&
        single['imageId'] is int &&
        single['binId'] is int &&
        single['version'] is int &&
        single['size'] is int;
    // SDK 预解析 331452 = 文件长 - 512 - 12，已处理 MP 头；启动仍传原文件。
    // 出处：固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核。
    final sdkMismatch = sdkFields &&
        header.imageId != null &&
        (single['imageId'] != header.imageId ||
            single['binId'] != header.binId ||
            single['version'] != header.version ||
            single['size'] != header.imageSize! - 12);
    final status = data['status'];
    final sdkError =
        data['errorCode'] != null || (status is int && status != 4096);
    final format =
        header.status == RealtekHeaderStatus.block || sdkError || sdkMismatch
            ? OtaCheckStatus.block
            : header.status == RealtekHeaderStatus.pass &&
                    status == 4096 &&
                    sdkFields
                ? OtaCheckStatus.pass
                : OtaCheckStatus.unknown;
    final match = registry.match(header);
    final profile = match.profile;
    final expectedIc =
        capabilities.icType ?? capabilities.expectedIcType ?? profile?.icType;
    final chip = header.icType == null || expectedIc == null
        ? OtaCheckStatus.unknown
        : header.icType == expectedIc
            ? OtaCheckStatus.pass
            : OtaCheckStatus.block;
    final mismatch = profile != null &&
        (header.icType != profile.icType ||
            header.imageId == null ||
            !profile.acceptsImageId(header.imageId!) ||
            header.customerName != profile.customerName ||
            (profile.allowedCommitIds != null &&
                !profile.allowedCommitIds!.contains(header.commitId)) ||
            (profile.flashAddress != null &&
                header.flashAddress != profile.flashAddress) ||
            header.payloadLength == null ||
            header.imageSize != header.payloadLength! + 1024);
    final compatible = profile == null
        ? OtaCheckStatus.unknown
        : mismatch || format == OtaCheckStatus.block
            ? OtaCheckStatus.block
            : format == OtaCheckStatus.pass
                ? OtaCheckStatus.pass
                : OtaCheckStatus.unknown;
    final limit = capabilities.deviceReportedCapacity ?? profile?.appBankSize;
    final capacity = profile == null ||
            header.imageSize == null ||
            limit == null ||
            limit <= 0
        ? OtaCheckStatus.unknown
        : header.imageSize! <= limit
            ? OtaCheckStatus.pass
            : OtaCheckStatus.block;
    // 出处：固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核。
    // FFD4 的 git_ver 为 u32；patch_header_check.h 位段中 0x30000010
    // 表示 0.1.0.6。设备不阻止同版或降级，主机按原始 u32 比较。
    // DIS 固件字符串为 T006，硬件为 H001；它们不替代 FFD4。
    final current = capabilities.currentVersion;
    final target = header.version;
    final comparable = current != null &&
        current >= 0 &&
        current <= 0xffffffff &&
        target != null;
    final older = comparable && target <= current;
    final overridden = older && capabilities.allowSameOrOlderVersion;
    final version = !comparable
        ? OtaCheckStatus.unknown
        : !older || overridden
            ? OtaCheckStatus.pass
            : OtaCheckStatus.block;
    final batteryValue = capabilities.batteryPercent;
    final charging = capabilities.charging;
    final threshold = profile?.batteryMinPercent;
    final battery = threshold == null
        ? OtaCheckStatus.pass
        : batteryValue == null || batteryValue < 0 || batteryValue > 100
            ? OtaCheckStatus.unknown
            : batteryValue >= threshold
                ? OtaCheckStatus.pass
                : !profile!.batteryRequiresChargingBelowMin
                    ? OtaCheckStatus.block
                    : charging == true
                        ? OtaCheckStatus.pass
                        : charging == false
                            ? OtaCheckStatus.block
                            : OtaCheckStatus.unknown;
    const missingProfile =
        '未找到匹配的设备档案,请在 OTA 档案注册表中添加(icType/imageId/customerName)';
    return FirmwareParseResult(
        rawStatus: data,
        type: data['type'] is String
            ? data['type'] as String
            : (format == OtaCheckStatus.pass ? 'Realtek' : null),
        images: images.map((image) => image.toString()),
        checks: [
          OtaCheck('format', format,
              '固件格式：${format.name}；${header.reason}${sdkMismatch ? '；SDK 镜像字段不一致' : ''}'),
          OtaCheck(
              'chip',
              chip,
              '芯片检查：${chip.name}；${capabilities.icType != null ? '设备上报' : capabilities.expectedIcType != null ? '所选芯片' : '匹配档案（非设备读回）'}'),
          OtaCheck(
              'compatibility',
              compatible,
              profile == null
                  ? '$missingProfile；匹配结果：${match.status.name}'
                  : '兼容性：${compatible.name}；档案：${profile.displayName}'),
          OtaCheck(
              'capacity',
              capacity,
              profile == null
                  ? missingProfile
                  : '容量：${capacity.name}；${capabilities.deviceReportedCapacity != null ? '设备上报' : '设备档案'}'),
          OtaCheck(
              'version',
              version,
              '版本：${version.name}；${!comparable ? '设备版本未知' : older ? (overridden ? '同版或降级已显式 override' : '同版或降级被阻断') : '目标版本高于设备'}'),
          OtaCheck(
              'battery',
              battery,
              battery == OtaCheckStatus.unknown
                  ? '警告：电量或充电状态未知，请确认后重新检查'
                  : threshold == null
                      ? '档案未配置电量阈值，不检查电量'
                      : '电量：${battery.name}；阈值 $threshold%'),
        ]);
  }
}
