// Debug-only: runs the production FlutterBlueDeviceProbe against the simulator. Read-only; no OTA writes.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/ota/device_probe.dart';
import '../services/ota/ota_device_profile.dart';

const _address = '04:7F:0E:00:7F:76';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('OTA probe')))));
  await FlutterBluePlus.adapterState
      .where((s) => s == BluetoothAdapterState.on)
      .first;
  final scan = FlutterBluePlus.onScanResults.listen((_) {});
  await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
  await Future<void>.delayed(const Duration(seconds: 15));
  await scan.cancel();
  final r = await const FlutterBlueDeviceProbe()
      .probe(_address, profile: OtaProfileRegistry.defaultProfileById('s200'));
  // ignore: avoid_print
  print('OTA_PROBE version=${r.currentVersion?.toRadixString(16)} battery=${r.batteryPercent} charging=${r.charging} info=${r.otaDeviceInfo?.icType}/${r.otaDeviceInfo?.maxBuffer}/${r.otaDeviceInfo?.tempBankSizeBytes}');
}
