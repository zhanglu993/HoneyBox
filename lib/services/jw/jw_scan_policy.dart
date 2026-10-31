import '../../providers/ble_provider.dart';
import 'jw_gatt_profile.dart';

abstract final class JwScanPolicy {
  static bool isCandidate(
      {required Set<String> serviceUuids,
      required Map<int, List<int>> manufacturerData}) {
    final uuids = serviceUuids.map(JwGattProfile.normalize).toSet();
    if (uuids.contains('0000fd50-0000-1000-8000-00805f9b34fb') ||
        uuids.contains(JwGattProfile.service)) {
      return true;
    }
    // flutter_blue_plus separates the little-endian company ID from its data.
    return manufacturerData.entries.any(
        (e) => (e.key == 0x07d0 || e.key == 0xfec5) && e.value.length >= 6);
  }

  static bool matches(
      {required String query,
      required bool isDefaultWatchFilter,
      required ScanDevice device,
      bool onlyNamed = false,
      bool onlyConnectable = false}) {
    final name = device.name.trim().toLowerCase();
    if (onlyConnectable && !device.connectable) return false;
    if (onlyNamed && (name.isEmpty || name == 'n/a' || name == '未知设备')) {
      return false;
    }
    final q = query.trim().toLowerCase();
    return q.isEmpty ||
        (isDefaultWatchFilter && device.jwCandidate) ||
        device.name.toLowerCase().contains(q) ||
        device.deviceId.toLowerCase().contains(q);
  }
}
