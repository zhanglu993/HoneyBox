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
    final expectedIc = capabilities.otaDeviceInfo?.icType ??
        capabilities.icType ??
        capabilities.expectedIcType ??
        profile?.icType;
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
    final compatible = profile == null
        ? OtaCheckStatus.unknown
        : mismatch || format == OtaCheckStatus.block
            ? OtaCheckStatus.block
            : format == OtaCheckStatus.pass
                ? OtaCheckStatus.pass
                : OtaCheckStatus.unknown;
    final limit = profile?.appBankSize;
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
        : profile == null ||
                header.imageSize == null ||
                limit == null ||
                limit <= 0
            ? OtaCheckStatus.unknown
            : header.imageSize! <= limit
                ? OtaCheckStatus.pass
                : OtaCheckStatus.block;
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
    final threshold = profile?.batteryMinPercent;
    final source = profile?.batterySource;
    final noBatteryCheck =
        profile != null && (threshold == null || source == BatterySource.none);
    final hasChargingSource =
        source == BatterySource.bwps || source == BatterySource.basAndBwps;
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
              '芯片检查：${chip.name}；${capabilities.otaDeviceInfo != null || capabilities.icType != null ? '设备上报' : capabilities.expectedIcType != null ? '所选芯片' : '匹配档案（非设备读回）'}'),
          OtaCheck(
              'compatibility',
              compatible,
              profile == null
                  ? '$missingProfile；匹配结果：${match.status.name}'
                  : '兼容性：${compatible.name}；档案：${profile.displayName}${infoIcMismatch(capabilities, profile) ? '；FFF1 芯片类型不匹配' : ''}'),
          OtaCheck(
              'capacity',
              capacity,
              profile == null
                  ? missingProfile
                  : '容量：${capacity.name}；${tooLargeForMulti ? 'FFF1 multi 临时容量不足' : '设备档案'}'),
          OtaCheck('version', version, versionExplanation),
          OtaCheck('battery', battery, batteryExplanation),
        ]);
  }
}

bool infoIcMismatch(
        DeviceCapabilities capabilities, OtaDeviceProfile profile) =>
    capabilities.otaDeviceInfo != null &&
    capabilities.otaDeviceInfo!.icType != profile.icType;

String formatOtaVersion(int value) =>
    '0x${value.toRadixString(16).padLeft(8, '0')} (${value & 0xf}.${(value >> 4) & 0xff}.${(value >> 12) & 0x7fff})';
