import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_gatt_profile.dart';
import 'ble_write_queue.dart';
import 'l1_engine.dart';
import 'l2_file_transfer.dart';

// ---------------------------------------------------------------------------
// Connection state
// ---------------------------------------------------------------------------

/// High-level BLE connection state.
enum BleState {
  disconnected,
  scanning,
  connecting,
  connected,
  disconnecting,
}

// ---------------------------------------------------------------------------
// BleManager
// ---------------------------------------------------------------------------

/// Manages the BLE connection lifecycle and wires the [L1Engine] /
/// [FileTransferSession] protocol stack to the `flutter_blue_plus` BLE
/// peripheral.
class BleManager {
  // --------------------------------------------------------------------------
  // Observable state
  // --------------------------------------------------------------------------

  BleState _state = BleState.disconnected;
  String? _deviceId;
  String? _deviceName;

  /// Stream controller that fires whenever [_state] changes.
  final _stateController = StreamController<BleState>.broadcast();

  /// Listen to this stream to react to connection state changes.
  Stream<BleState> get onStateChanged => _stateController.stream;

  BleState get state => _state;
  String? get deviceId => _deviceId;
  String? get deviceName => _deviceName;

  /// The active file-transfer session, if one exists.
  FileTransferSession? get session => _session;

  /// Whether the device exposes the separate Stream Service (FFC4/FFC5) for
  /// real-time video streaming. False → streaming unavailable (old firmware).
  bool get streamAvailable => _streamAvailable;

  /// Fires when a subscribed FFC4/FFC5 pair becomes ready or is cleared.
  Stream<bool> get onStreamAvailabilityChanged =>
      _streamAvailabilityController.stream;

  /// Raw L2 messages received on the Stream Service notify (FFC5).
  Stream<Uint8List> get streamNotifications => _streamNotifyController.stream;

  /// Inbound L2 command-channel frames (FFC2, after L1 de-framing). Carries any
  /// L2 payload not consumed by a file transfer — notably WiFi provisioning
  /// (CMD 0x0D) responses. Each event is one complete L2 frame payload.
  Stream<Uint8List> get commandNotifications => _commandNotifyController.stream;

  /// Whether the command channel (FFC1/FFC2 + L1 engine) is ready. Required for
  /// WiFi provisioning, which rides the command channel.
  bool get commandAvailable =>
      _l1 != null && _commandTx != null && _commandRxChar != null;

  /// The negotiated ATT MTU (defaults to 23 before connection).
  int get mtu => _mtu;

  /// Bytes of frame data per KS_FRAME write = `(MTU − 3) − 13` (L2 + KS header,
  /// no L1). Floored at 1.
  int get streamChunkSize {
    final cs = (_mtu - 3) - 13;
    return cs < 1 ? 1 : cs;
  }

  // --------------------------------------------------------------------------
  // BLE objects
  // --------------------------------------------------------------------------

  BluetoothDevice? _device;
  BleGattEndpoint<BluetoothCharacteristic>? _commandTx; // FFC1 - write
  BluetoothCharacteristic? _commandRxChar; // FFC2 - notify
  BleGattEndpoint<BluetoothCharacteristic>? _streamTx; // FFC4 - stream write
  BluetoothCharacteristic? _streamRxChar; // FFC5 - stream notify
  StreamSubscription<List<int>>? _streamNotificationSub;
  bool _streamAvailable = false;
  int _mtu = 23;
  int _connectionGeneration = 0;

  /// Broadcasts raw L2 messages received on the Stream Service (FFC5).
  final _streamNotifyController = StreamController<Uint8List>.broadcast();

  /// Broadcasts availability only after the FFC5 subscription is active.
  final _streamAvailabilityController = StreamController<bool>.broadcast();

  /// Broadcasts inbound L2 command-channel frames (FFC2 → L1 → L2 payload).
  final _commandNotifyController = StreamController<Uint8List>.broadcast();

  StreamSubscription<List<int>>? _notificationSub;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<ScanResult>>? _scanErrorSub;

  // --------------------------------------------------------------------------
  // Protocol stack
  // --------------------------------------------------------------------------

  L1Engine? _l1;
  FileTransferSession? _session;

  /// GATT writes cannot run concurrently on one connection, so command (FFC1)
  /// and stream (FFC4) writes share one generation-safe physical queue.
  late final BleWriteQueue _writeQueue;

  // --------------------------------------------------------------------------
  // Dispose guard
  // --------------------------------------------------------------------------

  bool _disposed = false;

  /// True only while a scan is meant to be delivering results. Flipped to false
  /// synchronously the instant a scan is stopped or a connect begins — before
  /// the async subscription cancel completes — so buffered `onScanResults`
  /// batches that arrive mid-teardown are dropped instead of mutating providers
  /// whose ScanPage widget is already being disposed (markNeedsBuild crash).
  bool _scanActive = false;

  // --------------------------------------------------------------------------
  // Construction / disposal
  // --------------------------------------------------------------------------

  BleManager() {
    // flutter_blue_plus logs every scan result and BLE operation at its default
    // (verbose) level, flooding logcat during continuous scanning — most
    // noticeably when the scanner resumes right after a disconnect. Silence the
    // plugin's own logger; the app-level debugPrint diagnostics below are kept.
    FlutterBluePlus.setLogLevel(LogLevel.none);
    _writeQueue = BleWriteQueue(
      onFatalError: (Object _, StackTrace __) => _onDisconnected(),
    );
  }

  /// Release all resources. No methods should be called after this.
  void dispose() {
    if (_disposed) return;
    _cleanup();
    _disposed = true;
    _writeQueue.dispose();
    _stateController.close();
    _streamNotifyController.close();
    _streamAvailabilityController.close();
    _commandNotifyController.close();
  }

  // --------------------------------------------------------------------------
  // Scanning
  // --------------------------------------------------------------------------

  /// Request Bluetooth runtime permissions on Android.
  ///
  /// On non-Android platforms (Windows desktop, iOS, etc.) there is no
  /// permission_handler runtime-permission model for BLE, so this is a no-op
  /// that reports success. On Windows the WinRT BLE APIs are accessible
  /// directly from the Win32 process without capability declarations.
  Future<bool> _ensureBlePermissions() async {
    if (!Platform.isAndroid) return true;
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    if (scan.isGranted && connect.isGranted) return true;

    final location = await Permission.locationWhenInUse.request();
    return location.isGranted || location.isLimited;
  }

  /// Start scanning for BLE devices. Each discovered device is reported via
  /// [onDeviceFound].
  Future<void> startScan(void Function(ScanResult) onDeviceFound) async {
    if (_disposed) return;
    stopScan();

    final allowed = await _ensureBlePermissions();
    if (!allowed) {
      _setState(BleState.disconnected);
      return;
    }

    _setState(BleState.scanning);
    _scanActive = true;

    _scanSub = FlutterBluePlus.onScanResults.listen(
      (results) {
        // Drop late/buffered batches once scanning has stopped or a
        // connect/disconnect started — otherwise onDeviceFound → addDevice
        // would notify a ScanPage element that is already defunct.
        if (!_scanActive || _disposed) return;
        for (final result in results) {
          onDeviceFound(result);
        }
      },
      onError: (Object error) {
        _setState(BleState.disconnected);
      },
    );

    // Also handle errors on the scan stream itself.
    _scanErrorSub = FlutterBluePlus.scanResults.listen(
      (_) {},
      onError: (Object error) {
        _setState(BleState.disconnected);
      },
    );

    try {
      // Android-only scan tuning (androidScanMode / androidUsesFineLocation)
      // is not applicable on Windows desktop, so branch the call by platform.
      if (Platform.isAndroid) {
        await FlutterBluePlus.startScan(
          androidScanMode: AndroidScanMode.lowLatency,
          androidUsesFineLocation: true,
        );
      } else {
        await FlutterBluePlus.startScan();
      }
    } catch (e) {
      stopScan();
      _setState(BleState.disconnected);
    }
  }

  /// Stop an ongoing scan.
  void stopScan() {
    _scanActive = false;
    _scanSub?.cancel();
    _scanSub = null;
    _scanErrorSub?.cancel();
    _scanErrorSub = null;
    FlutterBluePlus.stopScan();
    if (_state == BleState.scanning) {
      _setState(BleState.disconnected);
    }
  }

  // --------------------------------------------------------------------------
  // Connection
  // --------------------------------------------------------------------------

  /// Connect to a BLE device and show the UI. Returns true on success.
  Future<bool> connect(String deviceId, String deviceName) async {
    if (_disposed) return false;
    stopScan();
    final connectionGeneration = ++_connectionGeneration;
    _setState(BleState.connecting);
    _deviceId = deviceId;
    _deviceName = deviceName;
    final device = BluetoothDevice(remoteId: DeviceIdentifier(deviceId));
    _device = device;

    try {
      debugPrint('BleManager: connecting to $deviceName ($deviceId)');

      // Connect with timeout.
      // flutter_blue_plus 2.x requires an explicit License declaration.
      // HoneyBox is an internal debugging tool and uses the nonprofit tier.
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 10),
      );
      if (!await _keepConnectionCurrent(connectionGeneration, device)) {
        return false;
      }
      debugPrint('BleManager: connected, discovering services');

      // Listen for disconnection (AFTER connect succeeds, skip initial state).
      _connectionStateSub = device.connectionState.skip(1).listen(
        (BluetoothConnectionState cs) {
          if (connectionGeneration != _connectionGeneration) return;
          if (cs == BluetoothConnectionState.disconnected) {
            _onDisconnected();
          }
        },
      );

      // Discover services and try to find BLE characteristics
      await device.discoverServices();
      if (!await _keepConnectionCurrent(connectionGeneration, device)) {
        return false;
      }

      final characteristics =
          <BleGattCharacteristic<BluetoothCharacteristic>>[];
      final services = device.servicesList;
      for (final s in services) {
        debugPrint('BleManager: service ${s.uuid}');
        for (final c in s.characteristics) {
          debugPrint(
            'BleManager: characteristic ${c.uuid} '
            'write=${c.properties.write} '
            'writeWithoutResponse=${c.properties.writeWithoutResponse} '
            'notify=${c.properties.notify} '
            'indicate=${c.properties.indicate}',
          );
          characteristics.add(BleGattCharacteristic<BluetoothCharacteristic>(
            c,
            c.uuid.toString(),
            write: c.properties.write,
            writeWithoutResponse: c.properties.writeWithoutResponse,
            notify: c.properties.notify,
            indicate: c.properties.indicate,
          ));
        }
      }

      final profile = BleGattProfile.select(characteristics);
      _commandTx = profile.commandTx;
      _commandRxChar = profile.commandRx;
      _streamTx = profile.streamTx;
      _streamRxChar = profile.streamRx;

      // Request MTU exactly once after discovery, regardless of which pair is
      // available. Both protocols use the actual negotiated value.
      var mtu = 23;
      try {
        mtu = await device.requestMtu(512);
      } catch (e) {
        debugPrint('BleManager: requestMtu failed, using default MTU: $e');
      }
      if (!await _keepConnectionCurrent(connectionGeneration, device)) {
        return false;
      }
      _mtu = mtu;

      if (profile.commandReady) {
        final commandRx = _commandRxChar!;
        final l1 = L1Engine(writeFn: _enqueueWrite)..setMtu(mtu);
        _l1 = l1;
        // Route any inbound command-channel L2 frame not consumed by a file
        // transfer (e.g. WiFi provisioning CMD 0x0D) to command listeners.
        l1.onL2Data = (payload) {
          if (!_disposed && connectionGeneration == _connectionGeneration) {
            _commandNotifyController.add(payload);
          }
        };

        await commandRx.setNotifyValue(true);
        if (!await _keepConnectionCurrent(connectionGeneration, device)) {
          return false;
        }
        _notificationSub = commandRx.onValueReceived.listen((data) {
          if (connectionGeneration == _connectionGeneration) {
            l1.onNotified(Uint8List.fromList(data));
          }
        });

        _session = FileTransferSession(
          sendL2: (Uint8List frame) => l1.sendL2(frame),
          attachToL1: (FileTransferSession s) {
            l1.attach(s);
            l1.onAck = (int seq, bool ok) => s.onL1Ack(seq, ok);
          },
          detachFromL1: () {
            l1.detach();
            l1.onAck = null;
          },
          onLog: (String message) => debugPrint('L2: $message'),
        );
      } else {
        debugPrint(
          'BleManager: command characteristics not found; '
          'continuing without L1/file transfer',
        );
      }

      // Enable the Stream Service notify (FFC5) if the device exposes it.
      if (profile.streamReady) {
        final streamRx = _streamRxChar!;
        try {
          await streamRx.setNotifyValue(true);
          if (!await _keepConnectionCurrent(connectionGeneration, device)) {
            return false;
          }
          _streamNotificationSub = streamRx.onValueReceived.listen((data) {
            if (!_disposed && connectionGeneration == _connectionGeneration) {
              _streamNotifyController.add(Uint8List.fromList(data));
            }
          });
          _setStreamAvailable(true);
          debugPrint('BleManager: Stream Service ready (FFC4/FFC5)');
        } catch (e) {
          debugPrint('BleManager: Stream Service FFC5 subscribe failed: $e');
          _streamNotificationSub?.cancel();
          _streamNotificationSub = null;
          _clearStreamPair();
        }
      } else {
        _clearStreamPair();
      }

      _setState(BleState.connected);
      final streamState = streamAvailable ? 'on' : 'off';
      debugPrint('BleManager: ready, mtu=$mtu, stream=$streamState');
      return true;
    } catch (e) {
      debugPrint('BleManager: connect failed: $e');
      await device.disconnect();
      if (connectionGeneration == _connectionGeneration) {
        _cleanup();
        _setState(BleState.disconnected);
      }
      return false;
    }
  }

  /// Gracefully disconnect and clean up.
  Future<void> disconnect() async {
    if (_state == BleState.disconnected || _state == BleState.disconnecting) {
      return;
    }
    _setState(BleState.disconnecting);
    await _device?.disconnect();
    _onDisconnected();
  }

  // --------------------------------------------------------------------------
  // Write queue (L1 → characteristic)
  // --------------------------------------------------------------------------

  Future<void> _write(
    BleGattEndpoint<BluetoothCharacteristic> endpoint,
    Uint8List bytes,
  ) {
    return _writeQueue.enqueue(
      () => endpoint.value.write(
        bytes,
        withoutResponse: endpoint.withoutResponse,
      ),
    );
  }

  /// Enqueue a raw L1 chunk for delivery over the FFC1 characteristic.
  void _enqueueWrite(Uint8List chunk) {
    final endpoint = _commandTx;
    if (_disposed || endpoint == null) return;
    // L1 exposes a synchronous writer. The queue owns fatal-error teardown, so
    // suppress this mirrored Future error after enqueueing it.
    unawaited(_write(endpoint, chunk).catchError((Object _) {}));
  }

  /// Send one raw L2 stream message over the FFC4 characteristic (no L1, no
  /// fragmentation — the caller keeps each message within one ATT write).
  /// Shares the serial queue so it never races other GATT writes.
  Future<void> writeStream(Uint8List l2) {
    final endpoint = _streamTx;
    if (_disposed || !streamAvailable || endpoint == null) {
      return Future.error(StateError('Stream Service 未就绪'));
    }
    return _write(endpoint, l2);
  }

  /// Send one L2 command frame over the L1 command channel (FFC1). L1 handles
  /// framing, CRC, and MTU chunking. Returns the assigned L1 sequence number, or
  /// null if the command channel isn't ready. Used by WiFi provisioning
  /// (CMD 0x0D); file transfers use [FileTransferSession] instead.
  int? sendCommand(Uint8List l2) {
    if (_disposed || _l1 == null || _commandTx == null) return null;
    return _l1!.sendL2(l2);
  }

  // --------------------------------------------------------------------------
  // Internal
  // --------------------------------------------------------------------------

  Future<bool> _keepConnectionCurrent(
    int connectionGeneration,
    BluetoothDevice device,
  ) async {
    if (connectionGeneration == _connectionGeneration) return true;
    try {
      await device.disconnect();
    } catch (e) {
      debugPrint('BleManager: stale connection disconnect failed: $e');
    }
    return false;
  }

  void _setState(BleState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_disposed) {
      _stateController.add(newState);
    }
  }

  void _setStreamAvailable(bool available) {
    if (_streamAvailable == available) return;
    _streamAvailable = available;
    if (!_disposed) {
      _streamAvailabilityController.add(available);
    }
  }

  void _clearStreamPair() {
    // Consumers must observe unavailability before the active endpoints vanish.
    _setStreamAvailable(false);
    _streamTx = null;
    _streamRxChar = null;
  }

  void _onDisconnected() {
    if (_state == BleState.disconnected) return;
    _session?.abort();
    _cleanup();
    _setState(BleState.disconnected);
  }

  void _cleanup() {
    _scanActive = false;
    _connectionGeneration++;
    _writeQueue.abort(StateError('BLE connection ended'));
    _clearStreamPair();
    _notificationSub?.cancel();
    _notificationSub = null;
    _streamNotificationSub?.cancel();
    _streamNotificationSub = null;
    _connectionStateSub?.cancel();
    _connectionStateSub = null;
    _scanSub?.cancel();
    _scanSub = null;
    _scanErrorSub?.cancel();
    _scanErrorSub = null;

    _session = null;
    _l1?.reset();
    _l1 = null;
    _commandTx = null;
    _commandRxChar = null;
    _device = null;
    _mtu = 23;

    _deviceId = null;
    _deviceName = null;
  }
}
