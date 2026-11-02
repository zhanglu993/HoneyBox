import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

abstract interface class DeviceVersionReader {
  Future<int?> readVersion(String deviceId);
}

/// 独占临时连接，必须在 Realtek SDK prepare 之前调用。
class FlutterBlueDeviceVersionReader implements DeviceVersionReader {
  const FlutterBlueDeviceVersionReader();
  @override
  Future<int?> readVersion(String deviceId) async {
    final device = BluetoothDevice.fromId(deviceId);
    // 不接管其他功能的连接；无法证明独占时保持未知。
    if (device.isConnected) return null;
    try {
      await device.connect(
          license: License.nonprofit, timeout: const Duration(seconds: 20));
      final services = await device.discoverServices();
      for (final service in services) {
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid.str128 ==
              '0000ffd4-0000-1000-8000-00805f9b34fb') {
            final bytes = await characteristic.read();
            if (bytes.length != 4) return null;
            return ByteData.sublistView(Uint8List.fromList(bytes))
                .getUint32(0, Endian.little);
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      // 清理失败必须向上抛出，避免 SDK 和临时连接并发。
      await device.disconnect();
    }
  }
}
