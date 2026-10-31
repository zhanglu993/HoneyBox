import 'dart:convert';

import 'realtek_image_header.dart';

enum BatterySource { bas, bwps, basAndBwps, none }

class OtaDeviceProfile {
  final String id, displayName, evidence;
  final int icType;
  final int? imageId, imageIdMin, imageIdMax;
  final List<int>? imageIds, allowedCommitIds;
  final String? customerName;
  final int? appBankSize, tempBankSize, flashAddress, batteryMinPercent;
  final bool batteryRequiresChargingBelowMin;
  final bool allowDowngrade;
  final BatterySource batterySource;

  const OtaDeviceProfile(
      {required this.id,
      required this.displayName,
      required this.icType,
      this.imageId,
      this.imageIds,
      this.imageIdMin,
      this.imageIdMax,
      this.customerName,
      this.allowedCommitIds,
      this.appBankSize,
      this.tempBankSize,
      this.flashAddress,
      this.batteryMinPercent,
      this.batteryRequiresChargingBelowMin = true,
      this.allowDowngrade = true,
      this.batterySource = BatterySource.none,
      required this.evidence});

  bool acceptsImageId(int value) =>
      imageId == value ||
      (imageIds?.contains(value) ?? false) ||
      (imageIdMin != null &&
          imageIdMax != null &&
          value >= imageIdMin! &&
          value <= imageIdMax!);

  factory OtaDeviceProfile.fromJson(Map<String, dynamic> json) {
    try {
      int? number(String key) {
        final value = json[key];
        if (value == null) return null;
        if (value is! int || value < 0) throw FormatException('$key 必须是非负整数');
        return value;
      }

      String requiredString(String key) {
        final value = json[key];
        if (value is! String || value.trim().isEmpty)
          throw FormatException('$key 必须是非空字符串');
        return value;
      }

      List<int>? numbers(String key) {
        final value = json[key];
        if (value == null) return null;
        if (value is! List ||
            value.isEmpty ||
            value.any((e) => e is! int || e < 0)) {
          throw FormatException('$key 必须是非空非负整数数组');
        }
        return List<int>.unmodifiable(value.cast<int>());
      }

      final customer = json['customerName'];
      final charging = json['batteryRequiresChargingBelowMin'];
      final source = json['batterySource'];
      final allowDowngrade = json['allowDowngrade'];
      if (json.containsKey('allowDowngrade') && allowDowngrade is! bool) {
        throw const FormatException('allowDowngrade 必须是布尔值');
      }
      if (source != null && (source is! String || !BatterySource.values.any((v) => v.name == source))) {
        throw const FormatException('batterySource 无效');
      }
      if (customer != null && (customer is! String || customer.isEmpty))
        throw const FormatException('customerName 必须是非空字符串');
      if (charging != null && charging is! bool)
        throw const FormatException('batteryRequiresChargingBelowMin 必须是布尔值');
      final min = number('imageIdMin'), max = number('imageIdMax');
      final battery = number('batteryMinPercent');
      if ((min == null) != (max == null) || (min != null && min > max!))
        throw const FormatException('imageId 范围无效');
      if (battery != null && battery > 100)
        throw const FormatException('batteryMinPercent 超出范围');
      final imageId = number('imageId'), imageIds = numbers('imageIds');
      if (imageId == null && imageIds == null && min == null)
        throw const FormatException('需要配置 imageId、imageIds 或范围');
      return OtaDeviceProfile(
          id: requiredString('id'),
          displayName: requiredString('displayName'),
          icType:
              number('icType') ?? (throw const FormatException('缺少 icType')),
          imageId: imageId,
          imageIds: imageIds,
          imageIdMin: min,
          imageIdMax: max,
          customerName: customer as String?,
          allowedCommitIds: numbers('allowedCommitIds'),
          appBankSize: number('appBankSize'),
          tempBankSize: number('tempBankSize'),
          flashAddress: number('flashAddress'),
          batteryMinPercent: battery,
          batterySource: source == null ? BatterySource.none : BatterySource.values.firstWhere((v) => v.name == source),
          batteryRequiresChargingBelowMin: charging as bool? ?? true,
          allowDowngrade: allowDowngrade as bool? ?? true,
          evidence: requiredString('evidence'));
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('无效 OTA 档案: $e');
    }
  }
}

enum OtaProfileMatchStatus { matched, none, ambiguous }

class OtaProfileMatch {
  final OtaProfileMatchStatus status;
  final OtaDeviceProfile? profile;
  const OtaProfileMatch(this.status, [this.profile]);
}

class OtaProfileRegistry {
  final List<OtaDeviceProfile> profiles;
  const OtaProfileRegistry([this.profiles = defaultProfiles]);
  static OtaDeviceProfile defaultProfileById(String id) {
    for (final profile in defaultProfiles) {
      if (profile.id == id) return profile;
    }
    throw StateError('未找到默认 OTA 档案: $id');
  }
  static const defaultProfiles = <OtaDeviceProfile>[
    OtaDeviceProfile(
        id: 's200',
        allowDowngrade: true,
        displayName: 'S200',
        icType: 9,
        imageId: 0x2793,
        customerName: 'S200_62#',
        allowedCommitIds: [0xded9c2aa],
        flashAddress: 0x82c000,
        appBankSize: 0x64000,
        tempBankSize: 0x64000,
        batteryMinPercent: 30,
        // 出处：固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核。
        batterySource: BatterySource.basAndBwps,
        batteryRequiresChargingBelowMin: true,
        evidence: '固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核'),
  ];
  factory OtaProfileRegistry.fromJson(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! List) throw const FormatException('档案注册表必须是数组');
      final profiles = decoded.map((e) {
        if (e is! Map<String, dynamic>) throw const FormatException('档案必须是对象');
        return OtaDeviceProfile.fromJson(e);
      }).toList();
      if (profiles.map((p) => p.id).toSet().length != profiles.length)
        throw const FormatException('档案 id 重复');
      return OtaProfileRegistry(List.unmodifiable(profiles));
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('无效 OTA 档案注册表: $e');
    }
  }
  OtaProfileMatch match(RealtekImageHeader header) {
    final candidates = profiles
        .where((p) =>
            (header.icType == null || p.icType == header.icType) &&
            (header.imageId == null || p.acceptsImageId(header.imageId!)) &&
            (header.customerName == null ||
                p.customerName == null ||
                p.customerName == header.customerName))
        .toList();
    if (candidates.isEmpty)
      return const OtaProfileMatch(OtaProfileMatchStatus.none);
    if (candidates.length != 1 ||
        header.icType == null ||
        header.imageId == null ||
        header.customerName == null ||
        candidates.single.customerName == null) {
      return const OtaProfileMatch(OtaProfileMatchStatus.ambiguous);
    }
    return OtaProfileMatch(OtaProfileMatchStatus.matched, candidates.single);
  }
}
