import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/ble_manager.dart';

void main() {
  test('waits for the Apple adapter to leave its initial unknown state',
      () async {
    final states = Stream<BluetoothAdapterState>.fromIterable([
      BluetoothAdapterState.unknown,
      BluetoothAdapterState.on,
    ]);
    expect(await waitForAppleBleAdapter(states), BluetoothAdapterState.on);
  });

  test('returns a definitive powered-off state without waiting forever',
      () async {
    final states =
        Stream<BluetoothAdapterState>.value(BluetoothAdapterState.off);
    expect(await waitForAppleBleAdapter(states), BluetoothAdapterState.off);
  });
}
