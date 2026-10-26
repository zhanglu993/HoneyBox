import 'dart:async';
import 'package:honeybox/services/capture/capture_polar.dart';

// Exercise BleManager's actual flutter_blue_plus binding without a radio.
// The interface is provided by flutter_blue_plus's existing dependency.
// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

final class CaptureTestPlatform extends FlutterBluePlusPlatform {
  bool polar = false;
  int polarStatus = 0;
  final writes = <BmWriteCharacteristicRequest>[];
  final written = StreamController<BmCharacteristicData>.broadcast();
  @override
  Stream<BmCharacteristicData> get onCharacteristicWritten => written.stream;
  final mtus = StreamController<BmMtuChangedResponse>.broadcast();
  @override
  Stream<BmMtuChangedResponse> get onMtuChanged => mtus.stream;
  final connections = StreamController<BmConnectionStateResponse>.broadcast();
  final services = StreamController<BmDiscoverServicesResult>.broadcast();
  final disconnectedIds = <String>[];
  final descriptors = StreamController<BmDescriptorData>.broadcast();
  final notifications = StreamController<BmCharacteristicData>.broadcast();
  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived =>
      notifications.stream;

  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged =>
      connections.stream;
  @override
  Stream<BmDiscoverServicesResult> get onDiscoveredServices => services.stream;
  @override
  Stream<BmDescriptorData> get onDescriptorWritten => descriptors.stream;
  @override
  Future<BmBluetoothAdapterState> getAdapterState(
          BmBluetoothAdapterStateRequest request) async =>
      BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on);

  void emitState(DeviceIdentifier id, BmConnectionStateEnum state) {
    connections.add(BmConnectionStateResponse(
        remoteId: id,
        connectionState: state,
        disconnectReasonCode: null,
        disconnectReasonString: null));
  }

  @override
  Future<bool> connect(BmConnectRequest request) async {
    emitState(request.remoteId, BmConnectionStateEnum.connected);
    mtus.add(BmMtuChangedResponse(
        remoteId: request.remoteId,
        mtu: 247,
        success: true,
        errorCode: 0,
        errorString: ''));
    return true;
  }

  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    disconnectedIds.add(request.remoteId.str);
    emitState(request.remoteId, BmConnectionStateEnum.disconnected);
    return true;
  }

  @override
  Future<bool> discoverServices(BmDiscoverServicesRequest request) async {
    final id = request.remoteId;
    final uuid = Guid('e0ff');
    BmBluetoothCharacteristic characteristic(String value,
            {bool write = false,
            bool notify = false,
            bool indicate = false,
            Guid? service,
            Guid? primary,
            int instance = 0}) =>
        BmBluetoothCharacteristic(
            remoteId: id,
            primaryServiceUuid: primary,
            serviceUuid: service ?? uuid,
            characteristicUuid: Guid(value),
            instanceId: instance,
            descriptors: [],
            properties: BmCharacteristicProperties(
                broadcast: false,
                read: false,
                writeWithoutResponse: false,
                write: write,
                notify: notify,
                indicate: indicate,
                authenticatedSignedWrites: false,
                extendedProperties: false,
                notifyEncryptionRequired: false,
                indicateEncryptionRequired: false));
    services.add(BmDiscoverServicesResult(
        remoteId: id,
        services: [
          if (polar) ...[
            BmBluetoothService(
                remoteId: id,
                primaryServiceUuid: null,
                serviceUuid: Guid('180d'),
                characteristics: [
                  characteristic('2a37', service: Guid('180d'), notify: true)
                ]),
            BmBluetoothService(
                remoteId: id,
                primaryServiceUuid: null,
                serviceUuid: Guid(polarService),
                characteristics: [
                  characteristic(polarControl,
                      service: Guid(polarService), indicate: true, write: true),
                  characteristic(polarData,
                      service: Guid(polarService), notify: true)
                ]),
          ],
          if (!polar) ...[
            BmBluetoothService(
                remoteId: id,
                primaryServiceUuid: null,
                serviceUuid: uuid,
                characteristics: [
                  characteristic('FF03', notify: true, instance: 1)
                ]),
            BmBluetoothService(
                remoteId: id,
                primaryServiceUuid: null,
                serviceUuid: uuid,
                characteristics: [
                  characteristic('FF02', write: true),
                  characteristic('FF03', notify: true)
                ]),
            BmBluetoothService(
                remoteId: id,
                primaryServiceUuid: uuid,
                serviceUuid: Guid('180d'),
                characteristics: [
                  characteristic('2a37',
                      notify: true, service: Guid('180d'), primary: uuid),
                ])
          ],
        ],
        success: true,
        errorCode: 0,
        errorString: ''));
    return true;
  }

  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest request) async {
    descriptors.add(BmDescriptorData(
        remoteId: request.remoteId,
        primaryServiceUuid: request.primaryServiceUuid,
        serviceUuid: request.serviceUuid,
        characteristicUuid: request.characteristicUuid,
        instanceId: request.instanceId,
        descriptorUuid: Guid('2902'),
        value: [1, 0],
        success: true,
        errorCode: 0,
        errorString: ''));
    return true;
  }

  @override
  Future<bool> writeCharacteristic(BmWriteCharacteristicRequest request) async {
    writes.add(request);
    BmCharacteristicData packet(List<int> value) => BmCharacteristicData(
        remoteId: request.remoteId,
        primaryServiceUuid: request.primaryServiceUuid,
        serviceUuid: request.serviceUuid,
        characteristicUuid: request.characteristicUuid,
        instanceId: request.instanceId,
        value: value,
        success: true,
        errorCode: 0,
        errorString: '');
    written.add(packet(request.value));
    if (request.characteristicUuid.str == polarControl) {
      notifications.add(
          packet([0xf0, request.value[0], request.value[1], polarStatus, 0]));
      if (request.value[0] == 2 && request.value[1] == 0 && polarStatus == 0) {
        notifications.add(BmCharacteristicData(
            remoteId: request.remoteId,
            primaryServiceUuid: null,
            serviceUuid: Guid(polarService),
            characteristicUuid: Guid(polarData),
            instanceId: 0,
            value: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0],
            success: true,
            errorCode: 0,
            errorString: ''));
      }
    }
    return true;
  }

  Future<void> close() async {
    await connections.close();
    await services.close();
    await descriptors.close();
    await notifications.close();
    await written.close();
    await mtus.close();
  }
}
