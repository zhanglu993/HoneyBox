import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ota_device_profile.dart';
import 'bwps_codec.dart';

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
  Stream<List<int>>? get bwpsNotifications;
  Future<void> enableBwpsNotifications();
  Future<void> disableBwpsNotifications();
  Future<void> writeBwps(List<int> value);
  Future<void> disconnect();
}

class FlutterBlueDeviceProbe implements DeviceProbe {
  final DeviceProbeConnection Function(String) connectionFactory;
  final Duration timeout, bwpsTimeout, disconnectTimeout;
  const FlutterBlueDeviceProbe({this.connectionFactory = _connection,
    this.timeout = const Duration(seconds: 25),
    this.bwpsTimeout = const Duration(seconds: 3),
    this.disconnectTimeout = const Duration(seconds: 5)});
  static DeviceProbeConnection _connection(String id) => _BlueConnection(id);
  @override
  Future<DeviceProbeResult> probe(String deviceId, {OtaDeviceProfile? profile}) async {
    final connection = connectionFactory(deviceId);
    if (connection.isConnected) return const DeviceProbeResult();
    int? version, battery;
    bool? charging;
    OtaDeviceInfoRecord? info;
    var active = true;
    StreamSubscription<List<int>>? subscription;
    var notificationsEnabled = false;
    Future<void> run() async {
      await connection.connect();
      if (!active) return;
      final entries = await connection.discover();
      if (!active) return;
      Future<List<int>?> read(List<String> ids) async {
        for (final entry in entries.entries) {
          if (ids.contains(entry.key.toLowerCase())) {
            try { return await entry.value(); } catch (_) { return null; }
          }
        }
        return null;
      }
      final v = await read(['0000ffd4-0000-1000-8000-00805f9b34fb']);
      if (!active) return;
      if (v?.length == 4) version = ByteData.sublistView(Uint8List.fromList(v!)).getUint32(0, Endian.little);
      // 出处：固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核。
      // OTA 服务为 0000d0ff-3c17-d293-8e48-14fe2e4da212，FFD1/FFD4/FFF1 使用标准 16 位基址；保留旧 FFF1 匹配兼容性。
      final rawInfo = await read(['0000fff1-0000-1000-8000-00805f9b34fb', '0000fff1-3c17-d293-8e48-14fe2e4da212']);
      if (!active) return;
      if (rawInfo != null) info = OtaDeviceInfoRecord.parse(Uint8List.fromList(rawInfo));
      final source = profile?.batterySource;
      if (source != BatterySource.none && source != BatterySource.bwps) {
        final rawBattery = await read(['00002a19-0000-1000-8000-00805f9b34fb']);
        if (!active) return;
        if (rawBattery?.length == 1 && rawBattery![0] > 0 && rawBattery[0] <= 100) battery = rawBattery[0];
      }
      // 档案未知（固件尚未选择）时同样尝试 BWPS：服务不存在则直接跳过。
      if (source != null && source != BatterySource.bwps && source != BatterySource.basAndBwps) return;
      final stream = connection.bwpsNotifications;
      if (stream == null) return;
      final response = Completer<({int chargerStatus, int percent})>();
      subscription = stream.listen((data) {
        try {
          final frame = parseFrame(Uint8List.fromList(data));
          if (frame.version != 0x40) return; // ACK 不代表电池响应。
          final parsed = parseBatteryResponse(frame.payload);
          if (parsed != null && !response.isCompleted) response.complete(parsed);
        } on FormatException { /* 坏帧不作为充电状态。 */ }
      }, onError: (Object error) { /* 等待超时，保留其他字段。 */ });
      try {
        notificationsEnabled = true;
        await connection.enableBwpsNotifications();
        if (!active) return;
        await connection.writeBwps(buildBatteryRequest());
        if (!active) return;
        final result = await response.future.timeout(bwpsTimeout);
        if (!active) return;
        // 状态 2 表示满电，也按充电状态 true 处理。
        charging = result.chargerStatus == 1 || result.chargerStatus == 2;
        if (battery == null) battery = result.percent;
      } catch (_) { // 服务、写入、坏帧或无响应均保持未知。
      }
    }
    try {
      try { await run().timeout(timeout); } on TimeoutException { /* 保留已读字段。 */ }
    } finally {
      active = false;
      try {
        await subscription?.cancel().timeout(disconnectTimeout);
        if (notificationsEnabled) await connection.disableBwpsNotifications().timeout(disconnectTimeout);
      } catch (error) {
        // 清理失败仍须尝试断开。
        print('BWPS 订阅清理失败: $error');
      }
      try {
        await connection.disconnect().timeout(disconnectTimeout);
      } catch (error) {
        print('设备预读取断开失败: $error');
        rethrow;
      }
    }
    return DeviceProbeResult(currentVersion: version, otaDeviceInfo: info,
        batteryPercent: battery, charging: charging);
  }
}

class _BlueConnection implements DeviceProbeConnection {
  final BluetoothDevice device;
  BluetoothCharacteristic? _bwpsWrite, _bwpsNotify;
  _BlueConnection(String id) : device = BluetoothDevice.fromId(id);
  @override bool get isConnected => device.isConnected;
  @override Future<void> connect() => device.connect(license: License.nonprofit, timeout: const Duration(seconds: 20));
  @override Future<Map<String, Future<List<int>> Function()>> discover() async {
    final services = await device.discoverServices().timeout(const Duration(seconds: 20));
    final result = <String, Future<List<int>> Function()>{};
    for (final service in services) {
      // 出处：固件仓库只读分析 2026-10-31，调用方提供，未在本仓库复核。
      // BWPS 服务 000001ff-3c17-d293-8e48-14fe2e4da212；FF02/FF03 为标准 16 位基址，写入无需加密或绑定。
      if (service.uuid.str128.toLowerCase() == '000001ff-3c17-d293-8e48-14fe2e4da212') {
        for (final characteristic in service.characteristics) {
          final uuid = characteristic.uuid.str128.toLowerCase();
          if (uuid == '0000ff02-0000-1000-8000-00805f9b34fb') _bwpsWrite = characteristic;
          if (uuid == '0000ff03-0000-1000-8000-00805f9b34fb') _bwpsNotify = characteristic;
        }
      }
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.str128.toLowerCase();
        if (uuid == '00002a19-0000-1000-8000-00805f9b34fb' &&
            service.uuid.str128.toLowerCase() != '0000180f-0000-1000-8000-00805f9b34fb') continue;
        result[uuid] = () => characteristic.read().timeout(const Duration(seconds: 10));
      }
    }
    return result;
  }
  @override Stream<List<int>>? get bwpsNotifications =>
      _bwpsWrite == null || _bwpsNotify == null ? null : _bwpsNotify!.onValueReceived;
  @override Future<void> enableBwpsNotifications() async { await _bwpsNotify!.setNotifyValue(true); }
  @override Future<void> disableBwpsNotifications() async { await _bwpsNotify!.setNotifyValue(false); }
  @override Future<void> writeBwps(List<int> value) => _bwpsWrite!.write(value, withoutResponse: false);
  @override Future<void> disconnect() => device.disconnect();
}
