import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Apply the text and signal constraints together; never reorder the BLE cache.
List<ScanResult> filterCaptureScanResults(
  Iterable<ScanResult> source, {
  String query = '',
  int? minimumRssi,
  bool strongestFirst = true,
  bool hideUnnamed = false,
}) {
  final text = query.trim().toLowerCase();
  bool known(ScanResult r) => r.rssi < 0 && r.rssi >= -127;
  final results = source.where((r) {
    if (hideUnnamed &&
        r.device.platformName.trim().isEmpty &&
        r.advertisementData.advName.trim().isEmpty) {
      return false;
    }
    if (minimumRssi != null && (!known(r) || r.rssi < minimumRssi)) {
      return false;
    }
    return '${r.device.platformName} ${r.advertisementData.advName} ${r.device.remoteId.str}'
        .toLowerCase()
        .contains(text);
  }).toList();
  results.sort((a, b) {
    if (known(a) != known(b)) return known(a) ? -1 : 1;
    final signal =
        strongestFirst ? b.rssi.compareTo(a.rssi) : a.rssi.compareTo(b.rssi);
    return signal != 0
        ? signal
        : a.device.remoteId.str.compareTo(b.device.remoteId.str);
  });
  return results;
}
