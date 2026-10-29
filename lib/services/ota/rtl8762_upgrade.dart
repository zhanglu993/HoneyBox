import 'dart:typed_data';
import 'rtl_dfu_protocol.dart';
import 'rtl_dfu_transfer.dart';
import 'rtl8762_reconnect.dart';
import 's200_firmware_image.dart';

class Rtl8762NormalInfo {
  final Uint8List identity;
  final Uint8List capabilities;
  final int batteryPercent;
  const Rtl8762NormalInfo(
      {required this.identity,
      required this.capabilities,
      required this.batteryPercent});
}

class Rtl8762Postcheck {
  final Uint8List identity;
  final int version;
  const Rtl8762Postcheck({required this.identity, required this.version});
}

/// Platform BLE adapter: discovery and connections are intentionally outside the protocol.
abstract interface class Rtl8762Device {
  Future<Rtl8762NormalInfo> inspectNormal();
  Future<RtlDfuTransport> enterDfu(Uint8List identity);
  int get maximumWriteSize;
  Future<void> activate();
  Future<Rtl8762Postcheck> reconnectNormal(Uint8List identity);
  Future<void> close();
}

/// The currently validated profile is RTL8762D with S200's 400 KiB layout.
class Rtl8762Upgrade {
  final Rtl8762Device device;
  final Uint8List Function(Uint8List) encrypt;
  Rtl8762Upgrade(this.device, this.encrypt);

  Future<void> run(Uint8List source,
      {void Function(String phase, int done, int total)? onProgress}) async {
    final image = S200FirmwareImage.parse(source);
    try {
      onProgress?.call('检查设备', 0, image.imageBytes.length);
      final info = await device.inspectNormal();
      final caps = RtlDfuCapabilities.parse(info.capabilities);
      if (info.identity.length != 6 ||
          caps.icType != 9 ||
          caps.flags & 7 != 7 ||
          caps.temporaryCapacity < image.imageBytes.length ||
          info.batteryPercent < 30 ||
          info.batteryPercent > 100) {
        throw const FormatException('设备身份、OTA 能力、容量或电量不符合 RTL8762D S200 要求');
      }
      final identity = Uint8List.fromList(info.identity);
      onProgress?.call('连接升级模式', 0, image.imageBytes.length);
      final transport = await device.enterDfu(identity);
      final ic = await transport.command(0x0b, Uint8List(0));
      if (ic.length != 4 ||
          ic[0] != 0x10 ||
          ic[1] != 0x0b ||
          ic[2] != 1 ||
          ic[3] != 9) {
        throw const FormatException('升级模式芯片类型不匹配');
      }
      final id = Uint8List(2);
      ByteData.sublistView(id).setUint16(0, 0x2793, Endian.little);
      final target = RtlDfuProtocol.targetInfo(await transport.command(6, id));
      if (target.offset != 0) throw const FormatException('设备存在未完成的升级，暂不支持续传');
      final buffer =
          RtlDfuProtocol.bufferInfo(await transport.command(9, Uint8List(0)));
      if (buffer.size != 2048 ||
          buffer.mtu < 23 ||
          device.maximumWriteSize <= 0) {
        throw const FormatException('设备不支持已验证的 RTL8762D 缓冲传输');
      }
      final packet = [buffer.mtu - 3, device.maximumWriteSize, 244]
          .reduce((a, b) => a < b ? a : b);
      await RtlDfuTransfer(transport, encrypt).transfer(
          image: image.imageBytes,
          imageId: 0x2793,
          blockSize: buffer.size,
          packetSize: packet,
          onProgress: (done, total) => onProgress?.call('传输固件', done, total));
      onProgress?.call(
          '激活固件', image.imageBytes.length, image.imageBytes.length);
      await device.activate();
      onProgress?.call(
          '重新连接并验证', image.imageBytes.length, image.imageBytes.length);
      final post =
          await retryRtl8762Reconnect(() => device.reconnectNormal(identity));
      if (post.identity.length != identity.length ||
          !List.generate(
                  identity.length, (i) => identity[i] == post.identity[i])
              .every((same) => same) ||
          post.version != image.version) {
        throw const FormatException('激活后设备身份或固件版本不匹配');
      }
    } finally {
      await device.close();
    }
  }
}
