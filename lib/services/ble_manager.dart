import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'android_ble_permissions.dart';

import 'jw/jw_gatt_profile.dart';
import 'jw/jw_raw_channel.dart';
import 'jw/jw_transport.dart';
import 'l1_engine.dart';
import 'l2_file_transfer.dart';

// ---------------------------------------------------------------------------
// BLE UUIDs
// ---------------------------------------------------------------------------

const String _txUuid = 'FFC1';
const String _rxUuid = 'FFC2';

// Separate Stream Service (UUID 484D5354-…): raw L2 video streaming, no L1.
// Write FFC4 (KS_OPEN/FRAME/CLOSE), notify FFC5 (KS_ACK/CREDIT/REPORT).
const String _streamTxUuid = 'FFC4';
const String _streamRxUuid = 'FFC5';

// Navigation Projection Service: control (FFD1/FFD2, with L1) + data (FFD3/FFD4, raw L2).
const String _naviCtrlTxUuid = 'FFD1';
const String _naviCtrlRxUuid = 'FFD2';
const String _naviDataTxUuid = 'FFD3';
const String _naviDataRxUuid = 'FFD4';

/// Short-UUID → role, used only to annotate the GATT dump logged right after
/// service discovery (see [BleManager._logGattTable]). Anything not listed
/// prints without an annotation — the dump is a debugging aid, so unknown
/// characteristics must still show up.
const Map<String, String> _knownCharRoles = {
  _txUuid: 'command tx (L1)',
  _rxUuid: 'command rx (L1 notify)',
  _streamTxUuid: 'stream tx (KS_OPEN/FRAME/CLOSE)',
  _streamRxUuid: 'stream rx (KS_ACK/CREDIT/REPORT)',
  _naviCtrlTxUuid: 'navi ctrl tx (L1)',
  _naviCtrlRxUuid: 'navi ctrl rx (L1 notify)',
  _naviDataTxUuid: 'navi data tx (raw L2 JPEG)',
  _naviDataRxUuid: 'navi data rx (raw L2 notify)',
};

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
  bool get streamAvailable => _streamTxChar != null && _streamRxChar != null;

  /// Raw L2 messages received on the Stream Service notify (FFC5).
  Stream<Uint8List> get streamNotifications => _streamNotifyController.stream;

  /// Inbound L2 command-channel frames (FFC2, after L1 de-framing). Carries any
  /// L2 payload not consumed by a file transfer — notably WiFi provisioning
  /// (CMD 0x0D) responses. Each event is one complete L2 frame payload.
  Stream<Uint8List> get commandNotifications => _commandNotifyController.stream;

  /// Whether the command channel (FFC1/FFC2 + L1 engine) is ready. Required for
  /// WiFi provisioning, which rides the command channel.
  bool get commandAvailable => _l1 != null && _txChar != null;

  /// The negotiated ATT MTU (defaults to 23 before connection).
  int get mtu => _mtu;

  /// Bytes of frame data per KS_FRAME write = `(MTU − 3) − 13` (L2 + KS header,
  /// no L1). Floored at 1.
  int get streamChunkSize {
    final cs = (_mtu - 3) - 13;
    return cs < 1 ? 1 : cs;
  }

  /// Whether the device exposes the Navigation Projection Service (FFD1-FFD4).
  bool get naviProjAvailable =>
      _naviCtrlTxChar != null &&
      _naviCtrlRxChar != null &&
      _naviDataTxChar != null &&
      _naviDataRxChar != null;

  /// Raw L2 messages received on the navi data notify (FFD4).
  Stream<Uint8List> get naviDataNotifications =>
      _naviDataNotifyController.stream;

  /// Bytes of JPEG frame data per NAVI_FRAME write = `(MTU − 3) − 13`.
  int get naviDataChunkSize {
    final cs = (_mtu - 3) - 13;
    return cs < 1 ? 1 : cs;
  }

  /// The navi control channel L1 engine (FFD1/FFD2). Non-null when
  /// [naviProjAvailable] is true.
  L1Engine? get naviL1 => _naviL1;

  /// L2 frames from the navi control channel (FFD2 → L1 de-framing).
  Stream<Uint8List> get naviCtrlNotifications => _naviCtrlL2Controller.stream;

  // --------------------------------------------------------------------------
  // BLE objects
  // --------------------------------------------------------------------------

  JwRawChannel? _jwTransport;
  JwTransport? get jwTransport => _jwTransport;
  StreamController<Uint8List>? _jwNotifyController;
  StreamController<void>? _jwDisconnectController;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar; // FFC1 - write
  BluetoothCharacteristic? _rxChar; // FFC2 - notify
  BluetoothCharacteristic? _streamTxChar; // FFC4 - stream write
  BluetoothCharacteristic? _streamRxChar; // FFC5 - stream notify
  StreamSubscription<List<int>>? _streamNotificationSub;

  // Navigation Projection Service
  BluetoothCharacteristic? _naviCtrlTxChar; // FFD1 - write (L1 chunks)
  BluetoothCharacteristic? _naviCtrlRxChar; // FFD2 - notify (L1 chunks)
  BluetoothCharacteristic? _naviDataTxChar; // FFD3 - writeWithoutResponse
  BluetoothCharacteristic? _naviDataRxChar; // FFD4 - notify
  StreamSubscription<List<int>>? _naviCtrlRxSub;
  StreamSubscription<List<int>>? _naviDataRxSub;

  int _mtu = 23;

  /// Broadcasts raw L2 messages received on the Stream Service (FFC5).
  final _streamNotifyController = StreamController<Uint8List>.broadcast();

  /// Broadcasts inbound L2 command-channel frames (FFC2 → L1 → L2 payload).
  final _commandNotifyController = StreamController<Uint8List>.broadcast();

  /// Broadcasts raw L2 messages received on the navi data channel (FFD4).
  final _naviDataNotifyController = StreamController<Uint8List>.broadcast();

  /// Broadcasts L2 frames from the navi control channel (FFD2 → L1 → L2 payload).
  final _naviCtrlL2Controller = StreamController<Uint8List>.broadcast();

  StreamSubscription<List<int>>? _notificationSub;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<ScanResult>>? _scanErrorSub;

  // --------------------------------------------------------------------------
  // Protocol stack
  // --------------------------------------------------------------------------

  L1Engine? _l1;
  FileTransferSession? _session;

  /// Separate L1 engine for the navi control channel (FFD1/FFD2).
  L1Engine? _naviL1;

  /// Serial write queue of (characteristic, bytes). GATT writes can't run
  /// concurrently on one connection, so L1 (FFC1, FFD1), stream (FFC4), and
  /// navi data (FFD3) writes share this single queue.
  final List<(BluetoothCharacteristic, Uint8List)> _writeQueue = [];
  bool _writing = false;

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
  int _scanGeneration = 0;
  Completer<BluetoothAdapterState?>? _adapterWait;
  StreamSubscription<BluetoothAdapterState>? _adapterWaitSub;

  // --------------------------------------------------------------------------
  // Construction / disposal
  // --------------------------------------------------------------------------

  BleManager() {
    // flutter_blue_plus logs every scan result and BLE operation at its default
    // (verbose) level, flooding logcat during continuous scanning — most
    // noticeably when the scanner resumes right after a disconnect. Silence the
    // plugin's own logger; the app-level debugPrint diagnostics below are kept.
    FlutterBluePlus.setLogLevel(LogLevel.none);
  }

  /// Release all resources. No methods should be called after this.
  void dispose() {
    _disposed = true;
    _cleanup();
    _stateController.close();
    _streamNotifyController.close();
    _commandNotifyController.close();
    _naviDataNotifyController.close();
    _naviCtrlL2Controller.close();
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
    return requestAndroidBlePermissions();
  }

  Future<BluetoothAdapterState?> _waitForIosAdapter() async {
    final wait = Completer<BluetoothAdapterState?>();
    _adapterWait = wait;
    _adapterWaitSub = FlutterBluePlus.adapterState.listen((state) {
      if (state != BluetoothAdapterState.unknown &&
          state != BluetoothAdapterState.turningOn &&
          !wait.isCompleted) {
        wait.complete(state);
      }
    }, onError: (Object error, StackTrace stack) {
      if (!wait.isCompleted) wait.completeError(error, stack);
    });
    try {
      return await wait.future;
    } finally {
      if (identical(_adapterWait, wait)) _cancelAdapterWait();
    }
  }

  void _cancelAdapterWait() {
    _adapterWaitSub?.cancel();
    _adapterWaitSub = null;
    final wait = _adapterWait;
    _adapterWait = null;
    if (wait != null && !wait.isCompleted) wait.complete(null);
  }

  /// Start scanning for BLE devices. Each discovered device is reported via
  /// [onDeviceFound].
  Future<void> startScan(
    void Function(ScanResult) onDeviceFound, {
    String? serviceUuid,
  }) async {
    if (_disposed) return;
    stopScan();
    final generation = _scanGeneration;

    final allowed = await _ensureBlePermissions();
    if (_disposed || generation != _scanGeneration) return;
    if (!allowed) {
      // Report failed startup even if the manager was already disconnected.
      if (_state == BleState.disconnected && !_disposed) {
        _stateController.add(BleState.disconnected);
      } else {
        _setState(BleState.disconnected);
      }
      return;
    }

    _setState(BleState.scanning);
    _scanActive = true;

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final adapterState = await _waitForIosAdapter();
        if (_disposed || generation != _scanGeneration) return;
        if (adapterState != BluetoothAdapterState.on) {
          stopScan();
          return;
        }
      } catch (error) {
        if (!_disposed && generation == _scanGeneration) {
          debugPrint('BLE adapter initialization failed: $error');
          stopScan();
        }
        return;
      }
    }

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
          withServices: serviceUuid == null ? const [] : [Guid(serviceUuid)],
          oneByOne: true,
          androidScanMode: AndroidScanMode.lowLatency,
          androidUsesFineLocation: true,
        );
      } else {
        await FlutterBluePlus.startScan(
          withServices: serviceUuid == null ? const [] : [Guid(serviceUuid)],
          oneByOne: true,
        );
      }
    } catch (e) {
      if (_disposed || generation != _scanGeneration) return;
      stopScan();
      _setState(BleState.disconnected);
    }
  }

  /// Stop an ongoing scan.
  void stopScan() {
    _scanGeneration++;
    _cancelAdapterWait();
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
  Future<bool> connect(String deviceId, String deviceName,
      {bool allowJw = false}) async {
    if (_disposed) return false;
    stopScan();
    _setState(BleState.connecting);
    _deviceId = deviceId;
    _deviceName = deviceName;

    try {
      debugPrint('BleManager: connecting to $deviceName ($deviceId)');
      _device = BluetoothDevice(remoteId: DeviceIdentifier(deviceId));

      // Connect with timeout.
      // flutter_blue_plus 2.x requires an explicit License declaration.
      // HoneyBox is an internal debugging tool and uses the nonprofit tier.
      await _device!.connect(
        license: License.nonprofit,
        timeout: Duration(seconds: allowJw ? 20 : 10),
      );
      debugPrint('BleManager: connected, discovering services');

      // Listen for disconnection (AFTER connect succeeds, skip initial state).
      _connectionStateSub = _device!.connectionState.skip(1).listen(
        (BluetoothConnectionState cs) {
          if (cs == BluetoothConnectionState.disconnected) {
            _onDisconnected();
          }
        },
      );

      // Discover services and try to find BLE characteristics
      await _device!.discoverServices();

      final services = _device!.servicesList;
      _logGattTable(services);
      // Select JW before touching any legacy characteristic or protocol engine.
      for (final service in services) {
        final chars = {
          for (final c in service.characteristics)
            JwGattProfile.normalize(c.uuid.toString()): c
        };
        final tx = chars[JwGattProfile.tx];
        final rx = chars[JwGattProfile.rx];
        if (!JwGattProfile.matches(service.uuid.toString(), chars.keys.toSet(),
            txWrite: tx?.properties.write ?? false,
            rxNotify: rx?.properties.notify ?? false,
            allowJw: allowJw)) {
          continue;
        }
        final device = _device!;
        try {
          _mtu = await device.requestMtu(247);
        } catch (_) {
          _mtu = 23;
        }
        final notifications = StreamController<Uint8List>.broadcast(sync: true);
        final disconnected = StreamController<void>.broadcast(sync: true);
        _jwNotifyController = notifications;
        _jwDisconnectController = disconnected;
        BluetoothCharacteristic? alert;
        for (final service in services) {
          if (JwGattProfile.normalize(service.uuid.toString()) !=
              JwGattProfile.normalize('1802')) {
            continue;
          }
          for (final c in service.characteristics) {
            if (JwGattProfile.normalize(c.uuid.toString()) ==
                    JwGattProfile.normalize('2a06') &&
                (c.properties.write || c.properties.writeWithoutResponse)) {
              alert = c;
            }
          }
        }
        final alertEndpoint = alert;
        late final JwRawChannel port;
        port = JwRawChannel(
            mtu: _mtu,
            notifications: notifications.stream,
            disconnected: disconnected.stream,
            subscribeFn: () async {
              _notificationSub = rx!.onValueReceived.listen((bytes) {
                if (!_disposed &&
                    _jwTransport == port &&
                    !notifications.isClosed) {
                  notifications.add(Uint8List.fromList(bytes));
                }
              });
              try {
                if (!await rx.setNotifyValue(true)) {
                  throw StateError('FF03 subscription refused');
                }
              } catch (_) {
                await _notificationSub?.cancel();
                _notificationSub = null;
                rethrow;
              }
            },
            writeFn: (bytes, {required bool withResponse}) async {
              await tx!.write(bytes, withoutResponse: !withResponse);
            },
            readFn: (uuid) async {
              for (final s in services) {
                for (final c in s.characteristics) {
                  if (JwGattProfile.normalize(c.uuid.toString()) ==
                      JwGattProfile.normalize(uuid)) {
                    return Uint8List.fromList(await c.read());
                  }
                }
              }
              return null;
            },
            disconnectFn: () async {
              // Deferred close of an old session must not own a new connection.
              if (_jwTransport != port || !identical(_device, device)) return;
              await disconnect();
            },
            immediateAlertWithResponse:
                alertEndpoint?.properties.write ?? false,
            immediateAlertWriteFn: alertEndpoint == null
                ? null
                : (bytes) async {
                    await alertEndpoint.write(bytes,
                        withoutResponse: !alertEndpoint.properties.write);
                  });
        _jwTransport = port;
        await port.subscribe();
        debugPrint(
            'BleManager: JW FF03 ready; FF02 response writes, MTU=$_mtu');
        _setState(BleState.connected);
        return true;
      }
      for (final s in services) {
        for (final c in s.characteristics) {
          final uuid = c.uuid.toString().toUpperCase();
          if (uuid.contains(_txUuid)) {
            _txChar = c;
            debugPrint('BleManager: ✓ found FFC1 (command tx)');
          }
          if (uuid.contains(_rxUuid) &&
              (c.properties.notify || c.properties.indicate)) {
            _rxChar = c;
            debugPrint('BleManager: ✓ found FFC2 (command rx)');
          }
          // Separate Stream Service characteristics (raw L2 video streaming).
          if (uuid.contains(_streamTxUuid) &&
              (c.properties.write || c.properties.writeWithoutResponse)) {
            _streamTxChar = c;
            debugPrint('BleManager: ✓ found FFC4 (stream tx)');
          }
          if (uuid.contains(_streamRxUuid) &&
              (c.properties.notify || c.properties.indicate)) {
            _streamRxChar = c;
            debugPrint('BleManager: ✓ found FFC5 (stream rx)');
          }
          // Navigation Projection Service characteristics.
          if (uuid.contains(_naviCtrlTxUuid) &&
              (c.properties.write || c.properties.writeWithoutResponse)) {
            _naviCtrlTxChar = c;
            debugPrint('BleManager: ✓ found FFD1 (navi ctrl tx)');
          }
          if (uuid.contains(_naviCtrlRxUuid) &&
              (c.properties.notify || c.properties.indicate)) {
            _naviCtrlRxChar = c;
            debugPrint('BleManager: ✓ found FFD2 (navi ctrl rx)');
          }
          if (uuid.contains(_naviDataTxUuid) &&
              c.properties.writeWithoutResponse) {
            _naviDataTxChar = c;
            debugPrint('BleManager: ✓ found FFD3 (navi data tx)');
          }
          if (uuid.contains(_naviDataRxUuid) &&
              (c.properties.notify || c.properties.indicate)) {
            _naviDataRxChar = c;
            debugPrint('BleManager: ✓ found FFD4 (navi data rx)');
          }
        }
      }

      if (_txChar == null || _rxChar == null) {
        final missing = [
          if (_txChar == null) '$_txUuid (tx)',
          if (_rxChar == null) '$_rxUuid (rx, needs notify/indicate)',
        ].join(' + ');
        debugPrint(
          'BleManager: command characteristics not found — missing $missing; '
          'continuing with GATT connection only (see GATT table above)',
        );
        _setState(BleState.connected);
        return true;
      }

      // Set up notify, MTU, and protocol stack.
      var mtu = 23;
      try {
        mtu = await _device!.requestMtu(512);
      } catch (e) {
        debugPrint('BleManager: requestMtu failed, using default MTU: $e');
      }
      _mtu = mtu;

      await _rxChar!.setNotifyValue(true);
      _notificationSub = _rxChar!.onValueReceived.listen(
        (data) {
          _l1?.onNotified(Uint8List.fromList(data));
        },
      );

      _l1 = L1Engine(writeFn: _enqueueWrite);
      _l1!.setMtu(mtu);
      // Route any inbound command-channel L2 frame not consumed by a file
      // transfer (e.g. WiFi provisioning CMD 0x0D) to command listeners.
      _l1!.onL2Data = (payload) {
        if (!_disposed) _commandNotifyController.add(payload);
      };

      _session = FileTransferSession(
        sendL2: (Uint8List frame) => _l1!.sendL2(frame),
        attachToL1: (FileTransferSession s) {
          _l1!.attach(s);
          _l1!.onAck = (int seq, bool ok) => s.onL1Ack(seq, ok);
        },
        detachFromL1: () {
          _l1!.detach();
          _l1!.onAck = null;
        },
        onLog: (String message) => debugPrint('L2: $message'),
      );

      // Enable the Stream Service notify (FFC5) if the device exposes it.
      if (_streamTxChar != null && _streamRxChar != null) {
        try {
          await _streamRxChar!.setNotifyValue(true);
          _streamNotificationSub =
              _streamRxChar!.onValueReceived.listen((data) {
            if (!_disposed) {
              _streamNotifyController.add(Uint8List.fromList(data));
            }
          });
          debugPrint('BleManager: Stream Service ready (FFC4/FFC5)');
        } catch (e) {
          debugPrint('BleManager: Stream Service FFC5 subscribe failed: $e');
          _streamTxChar = null;
          _streamRxChar = null;
        }
      } else {
        _streamTxChar = null;
        _streamRxChar = null;
      }

      // Enable the Navigation Projection Service if the device exposes it.
      if (naviProjAvailable) {
        try {
          // Set up navi control channel (FFD1/FFD2) with its own L1 engine.
          await _naviCtrlRxChar!.setNotifyValue(true);
          _naviCtrlRxSub = _naviCtrlRxChar!.onValueReceived.listen((data) {
            _naviL1?.onNotified(Uint8List.fromList(data));
          });

          _naviL1 = L1Engine(writeFn: _enqueueNaviCtrlWrite);
          _naviL1!.setMtu(mtu);
          // Navi control L2 payloads — dispatched by NaviProjectionSession.
          // We expose them via a shared field so the session can register.
          _naviL1!.onL2Data = (payload) {
            if (!_disposed) _naviCtrlL2Controller.add(payload);
          };

          // Set up navi data channel (FFD4 notify).
          await _naviDataRxChar!.setNotifyValue(true);
          _naviDataRxSub = _naviDataRxChar!.onValueReceived.listen((data) {
            if (!_disposed) {
              _naviDataNotifyController.add(Uint8List.fromList(data));
            }
          });

          debugPrint('BleManager: Navi Projection ready (FFD1-FFD4)');
        } catch (e) {
          debugPrint('BleManager: Navi Projection setup failed: $e');
          _naviCtrlTxChar = null;
          _naviCtrlRxChar = null;
          _naviDataTxChar = null;
          _naviDataRxChar = null;
          _naviL1 = null;
        }
      }

      _setState(BleState.connected);
      debugPrint('BleManager: ready, mtu=$mtu, '
          'command=${commandAvailable ? "on" : "off"}, '
          'stream=${streamAvailable ? "on" : "off"}, '
          'naviProj=${naviProjAvailable ? "on" : "off"}');
      return true;
    } catch (e) {
      debugPrint('BleManager: connect failed: $e');
      await _device?.disconnect();
      _cleanup();
      _setState(BleState.disconnected);
      return false;
    }
  }

  /// Dumps the full discovered GATT table — every service with its
  /// characteristics, their properties and descriptors. Runs once per connect,
  /// right after `discoverServices()`, before any characteristic matching, so
  /// the log shows what the device *actually* exposes even when the expected
  /// FFC1/FFC2 pair is missing and the connection degrades to GATT-only.
  ///
  /// Known UUIDs get a role annotation from [_knownCharRoles]; unknown ones
  /// print bare, which is the point — this dump is how new firmware
  /// characteristics get noticed.
  void _logGattTable(List<BluetoothService> services) {
    var charCount = 0;
    for (final s in services) {
      charCount += s.characteristics.length;
    }
    debugPrint('BleManager: ── GATT table ─────────────────────────────────');
    debugPrint('BleManager: device  $_deviceName ($_deviceId)');
    debugPrint(
      'BleManager: ${services.length} service(s), $charCount characteristic(s)',
    );

    for (final s in services) {
      debugPrint(
        'BleManager: ┌ service ${s.uuid} '
        '(${s.characteristics.length} char, primary=${s.isPrimary})',
      );
      for (final c in s.characteristics) {
        final short = c.uuid.toString().toUpperCase();
        final role = _knownCharRoles.entries
            .firstWhere(
              (e) => short.contains(e.key),
              orElse: () => const MapEntry('', ''),
            )
            .value;
        final props = <String>[
          if (c.properties.read) 'read',
          if (c.properties.write) 'write',
          if (c.properties.writeWithoutResponse) 'writeNR',
          if (c.properties.notify) 'notify',
          if (c.properties.indicate) 'indicate',
        ];
        debugPrint(
          'BleManager: │  char ${c.uuid} '
          '[${props.isEmpty ? 'none' : props.join(',')}]'
          '${role.isEmpty ? '' : '  ← $role'}',
        );
        for (final d in c.descriptors) {
          debugPrint('BleManager: │    descriptor ${d.uuid}');
        }
      }
      debugPrint('BleManager: └');
    }
    debugPrint('BleManager: ───────────────────────────────────────────────');
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

  /// Enqueue a raw L1 chunk for delivery over the FFC1 characteristic.
  void _enqueueWrite(Uint8List chunk) {
    if (_disposed || _txChar == null) return;
    _writeQueue.add((_txChar!, chunk));
    if (!_writing) {
      _flushQueue();
    }
  }

  /// Send one raw L2 stream message over the FFC4 characteristic (no L1, no
  /// fragmentation — the caller keeps each message within one ATT write).
  /// Shares the serial queue so it never races other GATT writes.
  Future<void> writeStream(Uint8List l2) {
    final char = _streamTxChar;
    if (_disposed || char == null) {
      return Future.error(StateError('Stream Service 未就绪'));
    }
    final completer = Completer<void>();
    _writeQueue.add((char, l2));
    _streamWriteCompleters[l2] = completer;
    if (!_writing) {
      _flushQueue();
    }
    return completer.future;
  }

  /// Send one L2 command frame over the L1 command channel (FFC1). L1 handles
  /// framing, CRC, and MTU chunking. Returns the assigned L1 sequence number, or
  /// null if the command channel isn't ready. Used by WiFi provisioning
  /// (CMD 0x0D); file transfers use [FileTransferSession] instead.
  int? sendCommand(Uint8List l2) {
    if (_disposed || _l1 == null || _txChar == null) return null;
    return _l1!.sendL2(l2);
  }

  // ── Navigation Projection write helpers ──

  /// Enqueue a raw L1 chunk for delivery over the FFD1 characteristic.
  void _enqueueNaviCtrlWrite(Uint8List chunk) {
    if (_disposed || _naviCtrlTxChar == null) {
      debugPrint(
          'BleManager: navi ctrl enqueue SKIP disposed=$_disposed char=${_naviCtrlTxChar != null}');
      return;
    }
    debugPrint(
        'BleManager: navi ctrl enqueue ${chunk.length}B, queue depth=${_writeQueue.length}');
    _writeQueue.add((_naviCtrlTxChar!, chunk));
    if (!_writing) {
      _flushQueue();
    }
  }

  /// Send one L2 command frame over the navi control channel (FFD1/FFD2, with
  /// L1 framing). Returns the assigned L1 sequence number, or null if the navi
  /// control channel isn't ready.
  int? sendNaviControl(Uint8List l2) {
    debugPrint(
        'BleManager: sendNaviControl l2=${l2.length}B disposed=$_disposed '
        'naviL1=${_naviL1 != null} ctrlTx=${_naviCtrlTxChar != null}');
    if (_disposed || _naviL1 == null || _naviCtrlTxChar == null) return null;
    final seq = _naviL1!.sendL2(l2);
    debugPrint('BleManager: sendNaviControl → L1 seq=$seq');
    return seq;
  }

  /// Send one raw L2 data message over the FFD3 characteristic (no L1).
  /// Shares the serial write queue with all other GATT writes.
  Future<void> writeNaviData(Uint8List l2) {
    final char = _naviDataTxChar;
    if (_disposed || char == null) {
      debugPrint(
          'BleManager: writeNaviData FAIL disposed=$_disposed char=${char != null}');
      return Future.error(StateError('导航投屏数据通道未就绪'));
    }
    debugPrint(
        'BleManager: writeNaviData ${l2.length}B, queue depth=${_writeQueue.length}');
    final completer = Completer<void>();
    _writeQueue.add((char, l2));
    _naviDataCompleters[l2] = completer;
    if (!_writing) {
      _flushQueue();
    }
    return completer.future;
  }

  /// Resolves the future returned by [writeStream] once the write completes.
  final Map<Uint8List, Completer<void>> _streamWriteCompleters = {};

  /// Resolves the future returned by [writeNaviData] once the write completes.
  final Map<Uint8List, Completer<void>> _naviDataCompleters = {};

  /// Flush queued writes sequentially using `write(withoutResponse: true)`.
  void _flushQueue() {
    if (_disposed || _writeQueue.isEmpty) {
      _writing = false;
      return;
    }

    _writing = true;
    final (char, bytes) = _writeQueue.removeAt(0);
    final completer = _streamWriteCompleters.remove(bytes) ??
        _naviDataCompleters.remove(bytes);
    final isNavi =
        (identical(char, _naviCtrlTxChar) || identical(char, _naviDataTxChar));

    debugPrint('BleManager: _flushQueue write ${bytes.length}B to '
        '${char.characteristicUuid} (navi=$isNavi, remQueue=${_writeQueue.length})');

    char.write(bytes, withoutResponse: true).then((_) {
      completer?.complete();
      _flushQueue();
    }).catchError((Object error) {
      debugPrint('BleManager: _flushQueue write FAILED: $error');
      completer?.completeError(error);
      // Write failure on the navi data channel (FFD3) is not fatal — the
      // control channel (FFD1/FFD2) and other connections stay intact.
      // Only treat command-channel (FFC1) failure as a dropped connection.
      if (!isNavi) {
        _writing = false;
        _writeQueue.clear();
        _streamWriteCompleters.clear();
        _naviDataCompleters.clear();
        _onDisconnected();
      } else {
        // Drain the failed entry and continue with the rest of the queue.
        _flushQueue();
      }
    });
  }

  // --------------------------------------------------------------------------
  // Internal
  // --------------------------------------------------------------------------

  void _setState(BleState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_disposed) {
      _stateController.add(newState);
    }
  }

  void _onDisconnected() {
    if (_state == BleState.disconnected) return;
    _session?.abort();
    _cleanup();
    _setState(BleState.disconnected);
  }

  void _cleanup() {
    _scanGeneration++;
    _cancelAdapterWait();
    if (_jwDisconnectController != null && !_jwDisconnectController!.isClosed) {
      _jwDisconnectController!.add(null);
    }
    _jwTransport?.invalidate();
    _jwTransport = null;
    _jwNotifyController?.close();
    _jwDisconnectController?.close();
    _jwNotifyController = null;
    _jwDisconnectController = null;
    _scanActive = false;
    _notificationSub?.cancel();
    _notificationSub = null;
    _streamNotificationSub?.cancel();
    _streamNotificationSub = null;
    _naviCtrlRxSub?.cancel();
    _naviCtrlRxSub = null;
    _naviDataRxSub?.cancel();
    _naviDataRxSub = null;
    _connectionStateSub?.cancel();
    _connectionStateSub = null;
    _scanSub?.cancel();
    _scanSub = null;
    _scanErrorSub?.cancel();
    _scanErrorSub = null;

    _session = null;
    _l1?.reset();
    _l1 = null;
    _naviL1?.reset();
    _naviL1 = null;
    _txChar = null;
    _rxChar = null;
    _streamTxChar = null;
    _streamRxChar = null;
    _naviCtrlTxChar = null;
    _naviCtrlRxChar = null;
    _naviDataTxChar = null;
    _naviDataRxChar = null;
    _device = null;
    _mtu = 23;

    _writeQueue.clear();
    _streamWriteCompleters.clear();
    _naviDataCompleters.clear();
    _writing = false;
    _deviceId = null;
    _deviceName = null;
  }
}
