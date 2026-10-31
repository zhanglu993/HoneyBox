// Debug-only: runs the native SDK pre-parse on a file pushed into app files dir. No BLE, no writes.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../services/ota/android_realtek_firmware_parser.dart';
import '../services/ota/firmware_inspection.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('OTA inspect')))));
  final dir = await getApplicationSupportDirectory();
  for (final name in ['real.bin', 'SIMULATOR-ONLY-DO-NOT-FLASH.bin']) {
    final f = File('${dir.path}/$name');
    if (!await f.exists()) continue;
    const caps = DeviceCapabilities(expectedIcType: 9);
    final r = await const AndroidRealtekFirmwareParser().parse(f.path, caps);
    final insp = await FirmwareInspection.inspect(
        f.path, caps, const AndroidRealtekFirmwareParser());
    // ignore: avoid_print
    print('OTA_INSPECT_FULL ${jsonEncode({'file': name, 'sha256': insp.sha256, 'canStart': insp.report.canStart, 'checks': insp.report.checks.map((c) => '${c.id}:${c.status.name}:${c.explanation}').toList()})}');
    // ignore: avoid_print
    print('OTA_INSPECT ${jsonEncode({'file': name, 'raw': '${r.rawStatus}', 'checks': r.checks.map((c) => '${c.id}:${c.status.name}').toList()})}');
  }
}
