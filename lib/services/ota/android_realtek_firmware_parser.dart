import 'dart:io';

import 'package:flutter/services.dart';

import 'firmware_inspection.dart';
import 'ota_preflight.dart';
import 'ota_chip_defaults.dart';
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
    // 出处：固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核。
    // 设备拒绝带 512B MP 头的文件；SDK 是否剥离须由调用方验证。
    // Dart 启动时保持原文件，不自行剥离。
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
    final deviceIc = capabilities.otaDeviceInfo?.icType ??
        capabilities.icType ??
        capabilities.expectedIcType;
    final expectedIc = deviceIc ?? profile?.icType;
    final chip = header.icType == null || expectedIc == null
        ? OtaCheckStatus.unknown
        : header.icType == expectedIc
            ? OtaCheckStatus.pass
            : OtaCheckStatus.block;
    final mismatch = profile != null &&
        ((capabilities.otaDeviceInfo != null &&
                capabilities.otaDeviceInfo!.icType != profile.icType) ||
            header.icType != profile.icType ||
            header.imageId == null ||
            !profile.acceptsImageId(header.imageId!) ||
            header.customerName != profile.customerName ||
            (profile.allowedCommitIds != null &&
                !profile.allowedCommitIds!.contains(header.commitId)) ||
            (profile.flashAddress != null &&
                header.flashAddress != profile.flashAddress) ||
            header.payloadLength == null ||
            header.imageSize != header.payloadLength! + 1024);
    final compatible = format == OtaCheckStatus.block ||
            chip == OtaCheckStatus.block || mismatch
        ? OtaCheckStatus.block
        : format == OtaCheckStatus.unknown
            ? OtaCheckStatus.unknown
            : chip == OtaCheckStatus.unknown
                ? OtaCheckStatus.warn
                : OtaCheckStatus.pass;
    final defaultIc = deviceIc ?? header.icType;
    final genericLimit = genericAppBankSizeByIcType[defaultIc];
    final limit = profile?.appBankSize ??
        capabilities.deviceReportedCapacity ??
        capabilities.capacity ??
        genericLimit;
    final limitSource = profile?.appBankSize != null
        ? '档案'
        : capabilities.deviceReportedCapacity != null || capabilities.capacity != null
            ? '设备上报'
            : '芯片通用默认';
    // 出处：固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核。
    // FFF1 临时容量仅在 multi 位有效；APP bank 容量仍以档案为准。
    final info = capabilities.otaDeviceInfo;
    final multiLimit = info != null && info.modeBits & 0x10 != 0
        ? info.tempBankSizeBytes
        : null;
    final tooLargeForMulti = multiLimit != null &&
        header.imageSize != null &&
        header.imageSize! > multiLimit;
    final tooLargeForProfileTemp = profile?.tempBankSize != null &&
        header.imageSize != null &&
        header.imageSize! > profile!.tempBankSize!;
    final capacity = tooLargeForMulti || tooLargeForProfileTemp
        ? OtaCheckStatus.block
        : header.imageSize == null || limit == null || limit <= 0
            ? OtaCheckStatus.warn
            : header.imageSize! > limit
                ? OtaCheckStatus.block
                : limitSource == '芯片通用默认' && deviceIc == null
                    ? OtaCheckStatus.warn
                    : OtaCheckStatus.pass;
    final current = capabilities.currentVersion;
    final target = header.version;
    final comparable = current != null &&
        current >= 0 &&
        current <= 0xffffffff &&
        target != null;
    final older = comparable && target < current;
    final same = comparable && target == current;
    final version = !comparable
        ? OtaCheckStatus.warn
        : older || same
            ? (profile?.allowDowngrade == false
                ? OtaCheckStatus.block
                : OtaCheckStatus.warn)
            : OtaCheckStatus.pass;
    final versionExplanation = !comparable
        ? '无法读取设备当前版本,无法判断是否降级'
        : older
            ? '降级：当前 ${formatOtaVersion(current)} → 目标 ${formatOtaVersion(target)}'
            : same
                ? '版本相同,重复升级：当前 ${formatOtaVersion(current)} → 目标 ${formatOtaVersion(target)}'
                : '升级：当前 ${formatOtaVersion(current)} → 目标 ${formatOtaVersion(target)}';
    final batteryValue = capabilities.batteryPercent;
    final charging = capabilities.charging;
    final threshold = profile == null ? 30 : profile.batteryMinPercent;
    final source = profile?.batterySource;
    final noBatteryCheck =
        profile != null && (threshold == null || source == BatterySource.none);
    final hasChargingSource =
        profile == null || source == BatterySource.bwps || source == BatterySource.basAndBwps;
    final isCharging = hasChargingSource && charging == true;
    final validBattery =
        batteryValue != null && batteryValue >= 0 && batteryValue <= 100;
    final battery = noBatteryCheck ||
            isCharging ||
            (validBattery && threshold != null && batteryValue >= threshold)
        ? OtaCheckStatus.pass
        : OtaCheckStatus.warn;
    final batteryExplanation = noBatteryCheck
        ? '档案未启用电量检查'
        : isCharging
            ? '设备正在充电或已充满'
            : hasChargingSource &&
                    charging == null &&
                    validBattery &&
                    threshold != null &&
                    batteryValue < threshold
                ? '电量 $batteryValue% 低于 $threshold%，无法读取充电状态，设备在未充电时可能拒绝进入升级模式'
                : !validBattery
                    ? '无法读取电量，请注意设备电量及充电状态'
                    : threshold == null
                        ? '无法确定电量阈值'
                        : batteryValue < threshold
                            ? (hasChargingSource && charging == false
                                ? '电量 $batteryValue% 低于 $threshold%，已读到未充电，设备可能拒绝进入升级模式'
                                : '电量 $batteryValue% 低于 $threshold%，设备可能拒绝进入升级模式')
                            : '电量 $batteryValue%，达到阈值 $threshold%';
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
              '芯片检查：${chip.name}；${capabilities.otaDeviceInfo != null || capabilities.icType != null ? '设备上报' : capabilities.expectedIcType != null ? '所选芯片' : profile != null ? '匹配档案（非设备读回）' : '无设备芯片信息'}'),
          OtaCheck(
              'compatibility',
              compatible,
              profile == null
                  ? '兼容性：${compatible.name}；通用检查（${chip == OtaCheckStatus.pass ? '固件头芯片 ${header.icType} 与设备一致' : chip == OtaCheckStatus.block ? '固件头芯片与设备不一致' : '设备芯片未知'}），未使用设备档案'
                  : '兼容性：${compatible.name}；档案：${profile.displayName}${infoIcMismatch(capabilities, profile) ? '；FFF1 芯片类型不匹配' : ''}'),
          OtaCheck(
              'capacity',
              capacity,
              '容量：${capacity.name}；${tooLargeForMulti ? 'FFF1 multi 临时容量不足' : tooLargeForProfileTemp ? '档案临时容量不足' : limit == null || limit <= 0 ? '容量限制未知' : '$limitSource：$limit 字节${limitSource == '芯片通用默认' && deviceIc == null ? '，设备芯片未确认' : ''}'}'),
          OtaCheck('version', version, versionExplanation),
          OtaCheck('battery', battery, profile == null
              ? '$batteryExplanation；通用电量阈值 30%'
              : batteryExplanation),
        ]);
  }
}

bool infoIcMismatch(
        DeviceCapabilities capabilities, OtaDeviceProfile profile) =>
    capabilities.otaDeviceInfo != null &&
    capabilities.otaDeviceInfo!.icType != profile.icType;

String formatOtaVersion(int value) =>
    '0x${value.toRadixString(16).padLeft(8, '0')} (${value & 0xf}.${(value >> 4) & 0xff}.${(value >> 12) & 0x7fff})';
