import '../../providers/ble_provider.dart';

/// Strongest reported RSSI first. Values outside the BLE -127..-1 dBm range
/// are unavailable measurements and stay after measured devices.
List<ScanDevice> sortedScanDevicesBySignal(List<ScanDevice> devices) {
  final indexed = devices.asMap().entries.toList();
  indexed.sort((a, b) {
    final aSignal =
        a.value.rssi >= -127 && a.value.rssi < 0 ? a.value.rssi : null;
    final bSignal =
        b.value.rssi >= -127 && b.value.rssi < 0 ? b.value.rssi : null;
    if (aSignal == null) return bSignal == null ? a.key.compareTo(b.key) : 1;
    if (bSignal == null) return -1;
    final bySignal = bSignal.compareTo(aSignal);
    return bySignal != 0 ? bySignal : a.key.compareTo(b.key);
  });
  return [for (final entry in indexed) entry.value];
}
