import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Suppresses normal Watch reconnect/scan handling while RTL8762 DFU owns BLE.
final rtl8762OtaInProgressProvider = StateProvider<bool>((ref) => false);
