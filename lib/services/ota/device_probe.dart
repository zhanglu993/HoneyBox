import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ota_device_profile.dart';

/// 出处：固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核。
class OtaDeviceInfoRecord {
  final int icType, otaVersion, secureVersion, modeBits, maxBuffer, imgIndicator;
  final int? tempBankSizeBytes;
  const OtaDeviceInfoRecord({required this.icType, required this.otaVersion,
    required this.secureVersion, required this.modeBits, required this.maxBuffer,
    required this.tempBankSizeBytes, required this.imgIndicator});
  static OtaDeviceInfoRecord? parse(Uint8List bytes) {
    if (bytes.length != 12) return null;
    final data = ByteData.sublistView(bytes);
    final mode = bytes[3];
    return OtaDeviceInfoRecord(icType: bytes[0], otaVersion: bytes[1],
      secureVersion: bytes[2], modeBits: mode,
      maxBuffer: data.getUint16(4, Endian.little),
      tempBankSizeBytes: mode & 0x10 != 0 ? bytes[6] * 4096 : null,
      imgIndicator: data.getUint32(8, Endian.little));
  }
}

class DeviceProbeResult {
  final int? currentVersion, batteryPercent;
  final bool? charging;
  final OtaDeviceInfoRecord? otaDeviceInfo;
  const DeviceProbeResult({this.currentVersion, this.batteryPercent, this.charging, this.otaDeviceInfo});
}

abstract interface class DeviceProbe {
  Future<DeviceProbeResult> probe(String deviceId, {OtaDeviceProfile? profile});
}
class UnknownDeviceProbe implements DeviceProbe {
  const UnknownDeviceProbe();
  @override Future<DeviceProbeResult> probe(String deviceId, {OtaDeviceProfile? profile}) async => const DeviceProbeResult();
}

/// Injectable transport; keys are characteristic UUIDs in canonical form.
abstract interface class DeviceProbeConnection {
  bool get isConnected;
  Future<void> connect();
  Future<Map<String, Future<List<int>> Function()>> discover();
  Future<void> disconnect();
}

class FlutterBlueDeviceProbe implements DeviceProbe {
  final DeviceProbeConnection Function(String) connectionFactory;
  const FlutterBlueDeviceProbe({this.connectionFactory = _connection});
  static DeviceProbeConnection _connection(String id) => _BlueConnection(id);
  @override
  Future<DeviceProbeResult> probe(String deviceId, {OtaDeviceProfile? profile}) async {
    final connection = connectionFactory(deviceId);
    if (connection.isConnected) return const DeviceProbeResult();
    try {
      await connection.connect();
      final entries = await connection.discover();
      Future<List<int>?> read(List<String> ids) async {
        for (final entry in entries.entries) {
          if (ids.contains(entry.key.toLowerCase())) {
            try { return await entry.value(); } on TimeoutException { rethrow; } catch (_) { return null; }
          }
        }
        return null;
      }
      final version = await read(['0000ffd4-0000-1000-8000-00805f9b34fb']);
      final info = await read(['0000fff1-0000-1000-8000-00805f9b34fb', '0000fff1-3c17-d293-8e48-14fe2e4da212']);
      final source = profile?.batterySource;
      final battery = source == BatterySource.none || source == BatterySource.bwps
          ? null : await read(['00002a19-0000-1000-8000-00805f9b34fb']);
      // BWPS 暂未实现：CRC16 算法及 FF02 的加密/绑定要求未经核实。
      return DeviceProbeResult(
        currentVersion: version?.length == 4 ? ByteData.sublistView(Uint8List.fromList(version!)).getUint32(0, Endian.little) : null,
        otaDeviceInfo: info == null ? null : OtaDeviceInfoRecord.parse(Uint8List.fromList(info)),
        batteryPercent: battery?.length == 1 && battery![0] > 0 && battery[0] <= 100 ? battery[0] : null);
    } finally {
      await connection.disconnect();
    }
  }
}

class _BlueConnection implements DeviceProbeConnection {
  final BluetoothDevice device;
  _BlueConnection(String id) : device = BluetoothDevice.fromId(id);
  @override bool get isConnected => device.isConnected;
  @override Future<void> connect() => device.connect(license: License.nonprofit, timeout: const Duration(seconds: 20));
  @override Future<Map<String, Future<List<int>> Function()>> discover() async {
    final services = await device.discoverServices().timeout(const Duration(seconds: 20));
    final result = <String, Future<List<int>> Function()>{};
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.str128.toLowerCase();
        if (uuid == '00002a19-0000-1000-8000-00805f9b34fb' &&
            service.uuid.str128.toLowerCase() != '0000180f-0000-1000-8000-00805f9b34fb') continue;
        result[uuid] = () => characteristic.read().timeout(const Duration(seconds: 10));
      }
    }
    return result;
  }
  @override Future<void> disconnect() => device.disconnect();
}
