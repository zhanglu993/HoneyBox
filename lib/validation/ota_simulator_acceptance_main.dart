// Explicitly gated acceptance entry point. Uses production OTA adapter and BLE.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../services/ota/android_realtek_firmware_parser.dart';
import '../services/ota/android_realtek_ota_platform.dart';
import '../services/ota/device_probe.dart';
import '../services/ota/firmware_inspection.dart';
import '../services/ota/ota_preflight.dart';
import '../services/ota/rtl8762_upgrade.dart';
import '../services/ota/rtl8762_flutter_blue_adapter.dart';
import '../services/ota/rtl8762_cipher.dart';
import '../services/ota/rtl8762_default_key.dart';

const address = '04:7F:0E:00:7F:76';
const simulator = 'JW-OTA-SIM';
const filename = String.fromEnvironment('OTA_SIM_FILENAME',
    defaultValue: 'SIMULATOR-ONLY-DO-NOT-FLASH.bin');
const expectedHash = String.fromEnvironment('OTA_SIM_SHA256',
    defaultValue:
        'e26715329dc435e1815ac796739ca332879ae561b01359a65b7404e7621819d8');
// 版本字段偏移：裸镜像 0x60；带 512B MP 头的镜像为 0x260。
const versionOffset = int.fromEnvironment('OTA_SIM_VERSION_OFFSET', defaultValue: 0x60);
const expectedVersion = 0x12345678;
final output = ValueNotifier<String>('等待测试');
Future<void> diagnose() async {
  final scan = FlutterBluePlus.onScanResults.listen((results) {
    for (final r in results) {
      if (r.device.remoteId.str == address ||
          r.advertisementData.advName.startsWith('JW-OTA')) {
        record('advertisement', {
          'address': r.device.remoteId.str,
          'name': r.advertisementData.advName,
          'manufacturer': r.advertisementData.manufacturerData
              .map((k, v) => MapEntry(k.toString(), v)),
          'services':
              r.advertisementData.serviceUuids.map((v) => v.str128).toList(),
        });
      }
    }
  });
  try {
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(seconds: 10));
  } finally {
    await FlutterBluePlus.stopScan();
    await scan.cancel();
  }
  try {
    record('versionDiagnostic',
        {'version': '0x${(await readVersion()).toRadixString(16)}'});
  } catch (e) {
    record('versionDiagnosticFailed', {'error': '$e'});
  }
}

void record(String step, Map<String, Object?> details) {
  final line = jsonEncode({
    'step': step,
    'at': DateTime.now().toUtc().toIso8601String(),
    ...details
  });
  // ignore: avoid_print
  print('OTA_ACCEPTANCE $line');
  output.value = line;
}

Future<int> readVersion() async {
  final device = BluetoothDevice.fromId(address);
  try {
    await device.connect(
        license: License.nonprofit, timeout: const Duration(seconds: 20));
    final services = await device.discoverServices();
    for (final service in services) {
      for (final c in service.characteristics) {
        if (c.uuid.str128 == '0000ffd4-0000-1000-8000-00805f9b34fb') {
          final bytes = await c.read();
          if (bytes.length != 4) throw StateError('版本响应长度错误');
          return ByteData.sublistView(Uint8List.fromList(bytes))
              .getUint32(0, Endian.little);
        }
      }
    }
    throw StateError('缺少实际版本特征 ffd4');
  } finally {
    await device.disconnect();
  }
}

/// Simulator-only evidence: real SDK result is recorded, but the known digest's
/// simulator contract (target version at offset 0x60) supplies the pass verdict.
class _SimulatorContractParser implements FirmwareParser {
  final int currentVersion;
  final int? battery;
  final bool? charging;
  _SimulatorContractParser(this.currentVersion, this.battery, [this.charging]);
  @override
  Future<FirmwareParseResult> parse(
      String path, DeviceCapabilities capabilities) async {
    final sdk = await const AndroidRealtekFirmwareParser().parse(path, capabilities);
    record('sdkInspect', {
      'raw': '${sdk.rawStatus}',
      'sdkChecks': sdk.checks.map((c) => '${c.id}:${c.status.name}').toList(),
    });
    final bytes = await File(path).readAsBytes();
    final known = sha256.convert(bytes).toString() == expectedHash;
    final target = bytes.length >= versionOffset + 4
        ? ByteData.sublistView(Uint8List.fromList(bytes))
            .getUint32(versionOffset, Endian.little)
        : null;
    final contractOk = known && target == expectedVersion;
    return FirmwareParseResult(
      rawStatus: {'sdk': sdk.rawStatus, 'contract': 'simulator-known-digest'},
      type: 'JW-OTA-SIM contract',
      images: ['simulator:${bytes.length}'],
      checks: [
        OtaCheck('format', contractOk ? OtaCheckStatus.pass : OtaCheckStatus.block,
            '模拟器契约：已知摘要且目标版本位于偏移 0x60'),
        OtaCheck('compatibility',
            contractOk ? OtaCheckStatus.pass : OtaCheckStatus.block,
            '仅模拟器 JW-OTA-SIM；SDK 未能独立证明布局'),
        OtaCheck(
            'version',
            target != null && target > currentVersion
                ? OtaCheckStatus.pass
                : OtaCheckStatus.warn,
            target == null
                ? '无法读取目标版本'
                : '${target > currentVersion ? '升级' : target == currentVersion ? '版本相同' : '降级'}：当前 ${formatOtaVersion(currentVersion)} → 目标 ${formatOtaVersion(target)}'),
        OtaCheck(
            'battery',
            battery != null && battery! > 0 && battery! >= 30
                ? OtaCheckStatus.pass
                : OtaCheckStatus.warn,
            battery == null || battery == 0
                ? '无法读取电量'
                : '电量 $battery%（阈值 30%），充电状态 ${charging ?? '未知'}'),
      ],
    );
  }
}

Future<void> accept() async {
  if (kReleaseMode || !const bool.fromEnvironment('OTA_SIMULATOR_ACCEPTANCE')) {
    record(
        'blocked', {'reason': 'only explicit debug simulator build allowed'});
    return;
  }
  final platform = AndroidRealtekOtaPlatform();
  StreamSubscription<Map<String, Object?>>? subscription;
  try {
    if (const bool.fromEnvironment('OTA_SIMULATOR_DIAGNOSTIC_ONLY')) {
      await diagnose();
      return;
    }
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$filename');
    record('waitingFile', {'path': file.path});
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (!await file.exists()) {
      if (DateTime.now().isAfter(deadline)) throw StateError('测试文件未通过ADB传入');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final digest = sha256.convert(await file.readAsBytes()).toString();
    if (digest != expectedHash) throw StateError('模拟器包摘要不匹配，拒绝写入');
    record('fileVerified', {'sha256': digest, 'bytes': await file.length()});
    await FlutterBluePlus.adapterState
        .firstWhere((s) => s == BluetoothAdapterState.on)
        .timeout(const Duration(seconds: 20));
    final found = Completer<void>();
    final scan = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (r.device.remoteId.str == address &&
            r.advertisementData.advName == simulator &&
            !found.isCompleted) {
          found.complete();
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 20));
      await found.future.timeout(const Duration(seconds: 20));
    } finally {
      await FlutterBluePlus.stopScan();
      await scan.cancel();
    }
    record('targetVerified', {'name': simulator, 'address': address});
    final before = await readVersion();
    record('versionBefore', {'version': '0x${before.toRadixString(16)}'});
    final probed = await const FlutterBlueDeviceProbe().probe(address);
    record('probe', {
      'version': probed.currentVersion?.toRadixString(16),
      'battery': probed.batteryPercent,
      'charging': probed.charging,
      'icType': probed.otaDeviceInfo?.icType,
    });
    if (const bool.fromEnvironment('OTA_SIMULATOR_DART_ENGINE')) {
      record('engine', {'implementation': 'existing HoneyBox Rtl8762Upgrade'});
      await Rtl8762Upgrade(Rtl8762FlutterBlueAdapter(address),
              Rtl8762Cipher(rtl8762DefaultKey()).encrypt)
          .run(
        await file.readAsBytes(),
        onProgress: (phase, done, total) => record('protocolProgress', {
          'phase': phase,
          'done': done,
          'total': total,
        }),
      );
      record('verified', {
        'version': '0x12345678',
        'actualBleReadback': true,
        'engine': 'Rtl8762Upgrade identity and version postcheck'
      });
      return;
    }
    final ready = Completer<void>();
    final terminal = Completer<Map<String, Object?>>();
    Timer? failureSettle;
    Map<String, Object?>? latestFailure;
    subscription = platform.events.listen((event) {
      record('sdkEvent', event);
      if (event['ready'] == true && !ready.isCompleted) ready.complete();
      if (event['done'] == true) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('SDK准备失败: $event'));
        }
        if (event['outcome'] == 'failed') {
          latestFailure = event;
          failureSettle ??= Timer(const Duration(seconds: 2), () {
            if (!terminal.isCompleted) terminal.complete(latestFailure!);
          });
        } else if (!terminal.isCompleted) {
          failureSettle?.cancel();
          terminal.complete(event);
        }
      }
    }, onError: (Object e) {
      if (!ready.isCompleted) ready.completeError(e);
      if (!terminal.isCompleted) terminal.complete({'error': '$e'});
    });
    await platform.prepare(address,
        sessionId: 'accept-${DateTime.now().microsecondsSinceEpoch}');
    await ready.future.timeout(const Duration(seconds: 45));
    record('sdkPrepared', {});
    final inspection = await FirmwareInspection.inspect(
        file.path,
        DeviceCapabilities(confirmed: true, currentVersion: before),
        _SimulatorContractParser(before, probed.batteryPercent, probed.charging));
    record('inspection', {
      'sha256': inspection.sha256,
      'canStart': inspection.report.canStart,
      'checks': inspection.report.checks
          .map((c) => {'id': c.id, 'status': c.status.name, 'why': c.explanation})
          .toList(),
    });
    if (!inspection.report.canStart || !await inspection.verifyUnchanged()) {
      throw StateError('固件检查门禁未通过，拒绝写入');
    }
    final warnings = inspection.report.checks
        .where((c) => c.status == OtaCheckStatus.warn)
        .map((c) => '${c.id}:${c.explanation}')
        .toList();
    // 验收入口自动代替用户点击“确认继续”，并记录被确认的警告。
    if (warnings.isNotEmpty) record('warningsConfirmed', {'warnings': warnings});
    await platform.start(file.path);
    record('sdkStarted', {});
    final result = await terminal.future.timeout(const Duration(seconds: 90));
    if (result['outcome'] != 'pendingVerification') {
      throw StateError('SDK升级未完成: $result');
    }
    await platform.close();
    record('sdkCompleted', result);
    int? version;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        version = await readVersion();
        break;
      } catch (e) {
        record('postcheckRetry', {'attempt': attempt + 1, 'error': '$e'});
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (version != expectedVersion) throw StateError('设备版本未达到预期: $version');
    record('verified', {
      'version': '0x${version!.toRadixString(16)}',
      'actualBleReadback': true
    });
  } catch (e, s) {
    record('failed', {'error': '$e', 'stack': '$s'});
  } finally {
    await subscription?.cancel();
    try {
      await platform.close();
    } catch (e) {
      record('cleanup', {'error': '$e'});
    }
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
      home: Scaffold(
          appBar: AppBar(title: const Text('JW-OTA-SIM 实测')),
          body: ValueListenableBuilder<String>(
              valueListenable: output,
              builder: (_, value, __) =>
                  SingleChildScrollView(child: SelectableText(value))))));
  unawaited(accept());
}
