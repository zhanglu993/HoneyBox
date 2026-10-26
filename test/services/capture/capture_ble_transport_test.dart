// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/capture/capture_ble_transport.dart';
import 'package:honeybox/services/capture/capture_models.dart';
import '../../helpers/capture_ble_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'discovers included services and filters same UUID by device and primary service',
      () async {
    final platform = CaptureTestPlatform();
    FlutterBluePlusPlatform.instance = platform;
    final a = CaptureBleConnection('transport-A'),
        b = CaptureBleConnection('transport-B');
    final disconnects = <String>[];
    final da = a.disconnected.listen((_) => disconnects.add('A'));
    final db = b.disconnected.listen((_) => disconnects.add('B'));
    addTearDown(() async {
      await da.cancel();
      await db.cancel();
      await a.close();
      await b.close();
      await platform.close();
    });
    await Future.wait([a.connect(), b.connect()]);
    expect(disconnects, isEmpty,
        reason: 'initial disconnected replay must not abort new connection');
    expect(a.services.map((s) => s.uuid.str), contains('180d'));
    expect(a.characteristics.where((c) => c.uuid.str == 'ff03').length, 2,
        reason:
            'same service UUID with distinct characteristic instances must remain selectable');
    const c = CaptureChannel(
        service: '180d', characteristic: '2a37', primaryService: 'e0ff');
    final av = <List<int>>[], bv = <List<int>>[];
    await a.subscribe(c, av.add);
    await b.subscribe(c, bv.add);
    void emit(String id, Guid? primary, List<int> value) =>
        platform.notifications.add(BmCharacteristicData(
          remoteId: DeviceIdentifier(id),
          primaryServiceUuid: primary,
          serviceUuid: Guid('180d'),
          characteristicUuid: Guid('2a37'),
          instanceId: 0,
          value: value,
          success: true,
          errorCode: 0,
          errorString: '',
        ));
    emit('transport-A', Guid('e0ff'), [0, 255]);
    emit('transport-B', Guid('e0ff'), [7]);
    emit('transport-A', null, [99]);
    await Future<void>.delayed(Duration.zero);
    expect(av, [
      [0, 255]
    ]);
    expect(bv, [
      [7]
    ]);
    await a.close();
    emit('transport-B', Guid('e0ff'), [8]);
    await Future<void>.delayed(Duration.zero);
    expect(bv, [
      [7],
      [8]
    ]);
    expect(platform.disconnectedIds, ['transport-A']);
  });
}
