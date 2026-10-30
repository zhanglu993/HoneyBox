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
      required ScanDevice device}) {
    final q = query.trim().toLowerCase();
    final hexQuery = q.replaceAll(RegExp(r'[:\-\s]'), '');
    final isFullHexSequence = RegExp(r'^[0-9a-f]{12}$').hasMatch(hexQuery);
    final matchesAdvertisement = isFullHexSequence &&
        device.manufacturerData.values.any((bytes) {
          final hex =
              bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
          for (var i = 0; i + hexQuery.length <= hex.length; i += 2) {
            if (hex.substring(i, i + hexQuery.length) == hexQuery) return true;
          }
          return false;
        });
    if (isFullHexSequence) {
      return matchesAdvertisement ||
          device.deviceId.toLowerCase().replaceAll(RegExp(r'[:\-\s]'), '') ==
              hexQuery;
    }
    return q.isEmpty ||
        (isDefaultWatchFilter && device.jwCandidate) ||
        device.name.toLowerCase().contains(q) ||
        device.deviceId.toLowerCase().contains(q);
  }
}
