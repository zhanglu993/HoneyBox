import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'rtl8762_upgrade.dart';
import 'rtl8762_activation.dart';
import 'rtl_dfu_transfer.dart';

/// FlutterBluePlus is the only platform-facing dependency of RTL8762 OTA.
class Rtl8762FlutterBlueAdapter implements Rtl8762Device, RtlDfuTransport {
  BluetoothDevice _device;
  BluetoothCharacteristic? _control, _data;
  StreamSubscription<List<int>>? _notifications;
  Completer<Uint8List>? _reply;
  bool _ownsConnection = false;
  Rtl8762FlutterBlueAdapter(String deviceId)
      : _device = BluetoothDevice(remoteId: DeviceIdentifier(deviceId));

  static const _otaService = '0000d0ff-3c17-d293-8e48-14fe2e4da212';
  static const _dfuService = '00006287-3c17-d293-8e48-14fe2e4da212';
  static const _cp = '00006487-3c17-d293-8e48-14fe2e4da212';
  static const _payload = '00006387-3c17-d293-8e48-14fe2e4da212';
  static String _standard(String short) =>
      '0000$short-0000-1000-8000-00805f9b34fb';
  List<BluetoothService> _services = [];

  Future<void> _connect() async {
    if (!_device.isConnected) {
      await _device.connect(
          license: License.nonprofit, timeout: const Duration(seconds: 30));
      _ownsConnection = true;
    }
    _services = await _device.discoverServices();
  }

  BluetoothCharacteristic _characteristic(String uuid) {
    for (final service in _services) {
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid.str128 == uuid) {
          return characteristic;
        }
      }
    }
    throw FormatException('设备缺少必要的 OTA 特征: $uuid');
  }

  bool _hasService(String uuid) => _services.any((s) => s.uuid.str128 == uuid);
  @override
  Future<Rtl8762NormalInfo> inspectNormal() async {
    await _connect();
    if (!_hasService(_otaService)) {
      throw const FormatException('设备不支持 RTL8762 OTA');
    }
    final identity =
        Uint8List.fromList(await _characteristic(_standard('ffd2')).read());
    final caps =
        Uint8List.fromList(await _characteristic(_standard('fff1')).read());
    final battery = await _characteristic(_standard('2a19')).read();
    if (battery.length != 1) throw const FormatException('无法读取电量');
    return Rtl8762NormalInfo(
        identity: identity, capabilities: caps, batteryPercent: battery[0]);
  }

  static bool _equal(List<int> a, List<int> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);
  Future<BluetoothDevice> _find(Uint8List identity, {required bool dfu}) async {
    await FlutterBluePlus.stopScan();
    final found = Completer<BluetoothDevice>();
    final started = DateTime.now();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final result in results) {
        if (result.timeStamp.isBefore(started)) continue;
        final bytes =
            result.advertisementData.manufacturerData[dfu ? 0x005d : 0x07d0];
        final match = dfu
            ? bytes != null && _equal(bytes, identity)
            : bytes != null &&
                bytes.length == 11 &&
                _equal(bytes.sublist(0, 5), [6, 0, 1, 0, 60]) &&
                _equal(bytes.sublist(5), identity);
        if (match && !found.isCompleted) found.complete(result.device);
      }
    });
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 45));
      return await found.future.timeout(const Duration(seconds: 45));
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  @override
  Future<RtlDfuTransport> enterDfu(Uint8List identity) async {
    await _characteristic(_standard('ffd1')).write([1], withoutResponse: true);
    await Future<void>.delayed(const Duration(seconds: 3));
    await _device.disconnect();
    _ownsConnection = false;
    _device = await _find(identity, dfu: true);
    await _connect();
    if (!_hasService(_dfuService) || _hasService(_otaService)) {
      throw const FormatException('设备未进入 RTL8762 升级模式');
    }
    _control = _characteristic(_cp);
    _data = _characteristic(_payload);
    _notifications = _control!.onValueReceived.listen((value) {
      if (_reply != null && !_reply!.isCompleted) {
        _reply!.complete(Uint8List.fromList(value));
      }
    });
    await _control!.setNotifyValue(true);
    return this;
  }

  @override
  int get maximumWriteSize => _device.mtuNow > 3 ? _device.mtuNow - 3 : 20;
  @override
  Future<Uint8List> command(int opcode, Uint8List payload) async {
    if (_reply != null) throw StateError('OTA 指令正在执行');
    final reply = Completer<Uint8List>();
    _reply = reply;
    try {
      await _control!.write([opcode, ...payload]);
      return await reply.future
          .timeout(Duration(seconds: opcode == 3 ? 30 : 15));
    } finally {
      _reply = null;
    }
  }

  @override
  Future<void> sendControl(Uint8List data) => _control!.write(data);
  @override
  Future<void> sendData(Uint8List data) =>
      _data!.write(data, withoutResponse: true);
  @override
  Future<void> activate() async {
    final disconnected = Completer<void>();
    final subscription = _device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected &&
          !disconnected.isCompleted) {
        disconnected.complete();
      }
    });
    try {
      await confirmRtl8762Activation(
        write: () => _control!.write([4]),
        waitForDisconnect: () async {
          try {
            await disconnected.future.timeout(const Duration(seconds: 10));
            return true;
          } on TimeoutException {
            return false;
          }
        },
      );
    } finally {
      await subscription.cancel();
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    await _notifications?.cancel();
    _notifications = null;
    if (_ownsConnection && _device.isConnected) await _device.disconnect();
    _ownsConnection = false;
  }

  @override
  Future<Rtl8762Postcheck> reconnectNormal(Uint8List identity) async {
    try {
      _device = await _find(identity, dfu: false);
      await _connect();
      if (!_hasService(_otaService)) {
        throw const FormatException('激活后 OTA 服务不可用');
      }
      final actual =
          Uint8List.fromList(await _characteristic(_standard('ffd2')).read());
      final bytes =
          Uint8List.fromList(await _characteristic(_standard('ffd4')).read());
      if (bytes.length != 4) throw const FormatException('无法读取激活后的固件版本');
      return Rtl8762Postcheck(
          identity: actual,
          version: ByteData.sublistView(bytes).getUint32(0, Endian.little));
    } catch (_) {
      if (_ownsConnection && _device.isConnected) await _device.disconnect();
      _ownsConnection = false;
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    await _notifications?.cancel();
    _notifications = null;
    await FlutterBluePlus.stopScan();
    if (_ownsConnection && _device.isConnected) await _device.disconnect();
  }
}
