import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'ota_preflight.dart';
import 'device_probe.dart';

/// Device evidence supplied by the adapter; false never authorizes a write.
class DeviceCapabilities {
  final bool confirmed;
  final int? icType;

  /// Configured target family, not a value read from the device.
  final int? expectedIcType;
  final int? currentVersion;
  final OtaDeviceInfoRecord? otaDeviceInfo;
  final int? batteryPercent;
  final bool? charging;
  final int? deviceReportedCapacity;
  final int? capacity;
  final int? imageId;

  /// Evidence that this image layout is compatible with the selected device.
  final bool layoutConfirmed;
  const DeviceCapabilities(
      {this.confirmed = false,
      this.icType,
      this.expectedIcType,
      this.currentVersion,
      this.otaDeviceInfo,
      this.capacity,
      this.imageId,
      this.batteryPercent,
      this.charging,
      this.deviceReportedCapacity,
      this.layoutConfirmed = false});
}

abstract interface class FirmwareParser {
  Future<FirmwareParseResult> parse(
      String path, DeviceCapabilities capabilities);
}

class FirmwareParseResult {
  final Object? rawStatus;
  final String? type;
  final List<String> images;
  final List<OtaCheck> checks;
  FirmwareParseResult(
      {this.rawStatus,
      this.type,
      Iterable<String> images = const [],
      Iterable<OtaCheck> checks = const []})
      : images = List.unmodifiable(images),
        checks = List.unmodifiable(checks);
}

/// An inspection identifies bytes and records evidence; it does not authenticate them.
class FirmwareInspection {
  final String path;
  final String? sha256;
  final String? type;
  final List<String> images;
  final Object? rawStatus;
  final PreflightReport report;
  FirmwareInspection._(this.path, this.sha256, this.type, this.images,
      this.rawStatus, this.report);

  static Future<FirmwareInspection> inspect(String path,
      DeviceCapabilities capabilities, FirmwareParser parser) async {
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) throw const FormatException('固件文件为空');
      final digest = crypto.sha256.convert(bytes).toString();
      final parsed = await parser.parse(path, capabilities);
      final checks = [...parsed.checks];
      if (!capabilities.confirmed) {
        checks.add(const OtaCheck(
            'device_evidence', OtaCheckStatus.unknown, '设备能力缺少证据'));
      }
      if (parsed.type == null || parsed.images.isEmpty) {
        checks.add(
            const OtaCheck('images', OtaCheckStatus.unknown, '固件类型或镜像清单未知'));
      }
      final report = evaluateOtaPreflight(
          requiredChecks: {'format', 'compatibility'}, checks: checks);
      final inspection = FirmwareInspection._(
          path, digest, parsed.type, parsed.images, parsed.rawStatus, report);
      if (!await inspection.verifyUnchanged()) {
        throw const FormatException('校验期间固件已改变');
      }
      return inspection;
    } catch (error) {
      return FirmwareInspection._(
          path,
          null,
          null,
          const [],
          null,
          PreflightReport([
            OtaCheck('read_or_parse', OtaCheckStatus.block, '固件读取或解析失败：$error')
          ]));
    }
  }

  Future<bool> verifyUnchanged() async {
    if (sha256 == null) return false;
    try {
      return (await crypto.sha256.bind(File(path).openRead()).first)
              .toString() ==
          sha256;
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> startIfSafe(Future<void> Function() write) async {
    if (!report.canStart || !await verifyUnchanged()) return false;
    await write();
    return true;
  }
}
