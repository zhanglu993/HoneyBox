import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_chunk_calibrator.dart';
import 'ble_gatt_profile.dart';
import 'ble_link_tuning.dart';
import 'ble_mtu.dart';
import 'ble_write_pacer.dart';
import 'ble_write_queue.dart';
import 'ble_write_stats.dart';
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

class _BleConnectionResources {
  const _BleConnectionResources({
    required this.device,
    required this.mtu,
    required this.writeQueue,
    required this.connectionStateSub,
    this.commandTx,
    this.commandRx,
    this.streamTx,
    this.streamRx,
    this.commandNotificationSub,
    this.streamNotificationSub,
    this.l1,
    this.session,
  });

  final BluetoothDevice device;
  final int mtu;
  final BleWriteQueue writeQueue;
  final StreamSubscription<BluetoothConnectionState> connectionStateSub;
  final BleGattEndpoint<BluetoothCharacteristic>? commandTx;
  final BluetoothCharacteristic? commandRx;
  final BleGattEndpoint<BluetoothCharacteristic>? streamTx;
  final BluetoothCharacteristic? streamRx;
  final StreamSubscription<List<int>>? commandNotificationSub;
  final StreamSubscription<List<int>>? streamNotificationSub;
  final L1Engine? l1;
  final FileTransferSession? session;

  bool get commandReady =>
      commandTx != null && commandRx != null && l1 != null && session != null;

  bool get streamReady =>
      streamTx != null && streamRx != null && streamNotificationSub != null;
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
  FileTransferSession? get session => _connectionOwner.value?.session;

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
  bool get commandAvailable => _connectionOwner.value?.commandReady ?? false;

  /// The negotiated ATT MTU (defaults to 23 before connection).
  int get mtu => _connectionOwner.value?.mtu ?? kMinAttMtu;

  /// Bytes of frame data per KS_FRAME write. Derived from the negotiated ATT
  /// MTU where the platform reports one, otherwise discovered by probing.
  int get streamChunkSize =>
      _chunkCalibrator?.chunkSize ?? streamChunkSizeForMtu(mtu);

  /// Report that a stream write was rejected. Returns true when the write
  /// budget was reduced, so the caller should retry the same payload smaller.
  bool shrinkStreamChunk() {
    final calibrator = _chunkCalibrator;
    if (calibrator == null || !calibrator.recordRejection()) return false;
    debugPrint('BleManager: stream write rejected, '
        'chunk shrunk to ${calibrator.chunkSize}');
    return true;
  }

  // --------------------------------------------------------------------------
  // BLE objects
  // --------------------------------------------------------------------------

  final _connectionOwner = BleConnectionOwner<_BleConnectionResources>();
  BluetoothDevice? _connectingDevice;
  int? _connectingGeneration;
  bool _streamAvailable = false;

  /// Per-connection stream write budget. Non-null once a connection resolved
  /// its MTU (or decided to probe for it); cleared when that connection ends.
  BleChunkCalibrator? _chunkCalibrator;

  /// Latency/throughput sampling for FFC4 writes.
  final BleWriteStats _streamWriteStats = BleWriteStats();

  /// Monotonic clock the stream pacer measures against.
  final Stopwatch _streamClock = Stopwatch()..start();

  /// How many FFC5 notifications this connection has delivered.
  int _streamNotifyCount = 0;

  /// Backpressure for platforms whose unacknowledged writes return before the
  /// controller has actually sent anything. Null where the stack paces itself.
  BleWritePacer? _streamPacer;

  /// Host-side connection-interval preference, where the platform offers one.
  final BleLinkTuning _linkTuning = BleLinkTuning();
  String? _tunedRemoteId;

  /// Broadcasts raw L2 messages received on the Stream Service (FFC5).
  final _streamNotifyController = StreamController<Uint8List>.broadcast();

  /// Broadcasts availability only after the FFC5 subscription is active.
  final _streamAvailabilityController = StreamController<bool>.broadcast();

  /// Broadcasts inbound L2 command-channel frames (FFC2 → L1 → L2 payload).
  final _commandNotifyController = StreamController<Uint8List>.broadcast();

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<ScanResult>>? _scanErrorSub;

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
  }

  /// Release all resources. No methods should be called after this.
  void dispose() {
    if (_disposed) return;
    _cleanup();
    _disposed = true;
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
    final connectionGeneration =
        _connectionOwner.replace(_retireConnectionResources);
    _setState(BleState.connecting);
    _deviceId = deviceId;
    _deviceName = deviceName;
    final device = BluetoothDevice(remoteId: DeviceIdentifier(deviceId));
    _connectingDevice = device;
    _connectingGeneration = connectionGeneration;

    StreamSubscription<BluetoothConnectionState>? connectionStateSub;
    StreamSubscription<List<int>>? commandNotificationSub;
    StreamSubscription<List<int>>? streamNotificationSub;
    L1Engine? l1;
    FileTransferSession? transferSession;
    var setupReleased = false;
    var published = false;

    late final BleWriteQueue writeQueue;
    writeQueue = BleWriteQueue(
      onFatalError: (Object _, StackTrace __) {
        _connectionOwner.runIfCurrent(
          connectionGeneration,
          () => _onDisconnected(connectionGeneration),
        );
      },
    );

    Future<void> releaseSetup() async {
      if (setupReleased || published) return;
      setupReleased = true;
      await commandNotificationSub?.cancel();
      await streamNotificationSub?.cancel();
      await connectionStateSub?.cancel();
      l1?.reset();
      writeQueue.dispose();
    }

    Future<bool> keepCurrent() async {
      if (_connectionOwner.isCurrent(connectionGeneration)) return true;
      await releaseSetup();
      try {
        await device.disconnect();
      } catch (e) {
        debugPrint('BleManager: stale connection disconnect failed: $e');
      }
      return false;
    }

    try {
      debugPrint('BleManager: connecting to $deviceName ($deviceId)');

      // Connect with timeout.
      // flutter_blue_plus 2.x requires an explicit License declaration.
      // HoneyBox is an internal debugging tool and uses the nonprofit tier.
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 10),
      );
      if (!await keepCurrent()) {
        return false;
      }
      debugPrint('BleManager: connected, discovering services');

      // Listen for disconnection (AFTER connect succeeds, skip initial state).
      connectionStateSub = device.connectionState.skip(1).listen(
        (BluetoothConnectionState cs) {
          if (!_connectionOwner.isCurrent(connectionGeneration)) return;
          if (cs == BluetoothConnectionState.disconnected) {
            debugPrint('BleManager: link dropped after '
                '$_streamNotifyCount FFC5 notifications');
            _onDisconnected(connectionGeneration);
          }
        },
      );

      // Discover services and try to find BLE characteristics
      await device.discoverServices();
      if (!await keepCurrent()) {
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
      final commandTx = profile.commandReady ? profile.commandTx : null;
      final commandRx = profile.commandReady ? profile.commandRx : null;
      var streamTx = profile.streamReady ? profile.streamTx : null;
      var streamRx = profile.streamReady ? profile.streamRx : null;

      // Resolve the MTU exactly once after discovery, regardless of which pair
      // is available. Both protocols use the actual negotiated value.
      var mtu = kMinAttMtu;
      if (Platform.isAndroid) {
        try {
          mtu = await device.requestMtu(512);
        } catch (e) {
          debugPrint('BleManager: requestMtu failed, using default MTU: $e');
        }
      } else {
        // flutter_blue_plus gates BluetoothDevice.requestMtu to Android, so
        // asking through it here would throw and pin the link at 23 bytes —
        // seven bytes of frame payload per write, which stalls projection.
        mtu = await negotiatePlatformMtu(device.remoteId);
      }
      // A platform that reports nothing usable leaves the MTU at the spec
      // floor even though the link almost certainly negotiated more. Probe
      // upward from an optimistic chunk and let rejected writes calibrate it.
      final reportedChunk = streamChunkSizeForMtu(mtu);
      final probing = mtu <= kMinAttMtu;
      _chunkCalibrator = BleChunkCalibrator(
        initial: probing ? kProbeStreamChunk : reportedChunk,
      );
      // Android's stack blocks each unacknowledged write until the controller
      // has room; Windows accepts them in ~1.5ms and silently drops whatever
      // the connection event cannot carry. Measured against this link, a 60ms
      // connection event carries a handful of packets, so space the writes to
      // a rate the radio can actually sustain.
      final pacingBitrate = resolveStreamPacingBitrate(Platform.environment);
      _streamPacer = Platform.isAndroid
          ? null
          : BleWritePacer(
              minSpacing: spacingForBitrate(
                chunkBytes: streamChunkSize,
                bitsPerSecond: pacingBitrate,
              ),
            );
      debugPrint('BleManager: mtu=$mtu streamChunk=$streamChunkSize'
          '${probing ? ' (probing; platform reported no MTU)' : ''}'
          '${_streamPacer == null ? '' : ' pacing=${_streamPacer!.minSpacing.inMicroseconds / 1000}ms@${pacingBitrate}bps'}');

      // Windows leaves the link on a 30-60ms interval by default, which caps
      // projection well below the encoder's budget. Ask for the fast profile;
      // a refusal only means the link stays at the system default.
      if (_linkTuning.isSupported) {
        final remoteId = device.remoteId.str;
        if (await _linkTuning.requestThroughput(remoteId)) {
          _tunedRemoteId = remoteId;
          debugPrint('BleManager: requested throughput-optimized link');
        }
        if (!await keepCurrent()) {
          return false;
        }
      }
      if (!await keepCurrent()) {
        return false;
      }

      if (commandTx != null && commandRx != null) {
        await commandRx.setNotifyValue(true);
        if (!await keepCurrent()) {
          return false;
        }

        final engine = L1Engine(
          writeFn: (Uint8List chunk) => _enqueueWrite(
            connectionGeneration,
            writeQueue,
            commandTx,
            chunk,
          ),
        )..setMtu(mtu);
        l1 = engine;
        // Route any inbound command-channel L2 frame not consumed by a file
        // transfer (e.g. WiFi provisioning CMD 0x0D) to command listeners.
        engine.onL2Data = (payload) {
          if (!_disposed && _connectionOwner.isCurrent(connectionGeneration)) {
            _commandNotifyController.add(payload);
          }
        };

        commandNotificationSub = commandRx.onValueReceived.listen((data) {
          if (_connectionOwner.isCurrent(connectionGeneration)) {
            engine.onNotified(Uint8List.fromList(data));
          }
        });

        transferSession = FileTransferSession(
          sendL2: (Uint8List frame) => engine.sendL2(frame),
          attachToL1: (FileTransferSession s) {
            engine.attach(s);
            engine.onAck = (int seq, bool ok) => s.onL1Ack(seq, ok);
          },
          detachFromL1: () {
            engine.detach();
            engine.onAck = null;
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
      if (streamTx != null && streamRx != null) {
        try {
          await streamRx.setNotifyValue(true);
          if (!await keepCurrent()) {
            return false;
          }
          streamNotificationSub = streamRx.onValueReceived.listen((data) {
            if (!_disposed &&
                _connectionOwner.isCurrent(connectionGeneration)) {
              // Counting every FFC5 notification separates "the device went
              // quiet" from "only some message types stopped arriving".
              _streamNotifyCount++;
              if (_streamNotifyCount <= 4 || _streamNotifyCount % 10 == 0) {
                final key = data.length > 2 ? data[2] : -1;
                debugPrint('BleManager: FFC5 #$_streamNotifyCount '
                    'len=${data.length} key=0x${key.toRadixString(16)}');
              }
              _streamNotifyController.add(Uint8List.fromList(data));
            }
          });
          debugPrint('BleManager: Stream Service ready (FFC4/FFC5)');
        } catch (e) {
          // A stale setup may only release its own local resources. It must not
          // cancel or clear a replacement connection's published stream pair.
          if (!await keepCurrent()) return false;
          debugPrint('BleManager: Stream Service FFC5 subscribe failed: $e');
          await streamNotificationSub?.cancel();
          streamNotificationSub = null;
          streamTx = null;
          streamRx = null;
        }
      }

      if (!await keepCurrent()) return false;
      final resources = _BleConnectionResources(
        device: device,
        mtu: mtu,
        writeQueue: writeQueue,
        connectionStateSub: connectionStateSub,
        commandTx: commandTx,
        commandRx: commandRx,
        streamTx: streamTx,
        streamRx: streamRx,
        commandNotificationSub: commandNotificationSub,
        streamNotificationSub: streamNotificationSub,
        l1: l1,
        session: transferSession,
      );
      if (!_connectionOwner.publish(connectionGeneration, resources)) {
        await keepCurrent();
        return false;
      }
      published = true;

      var connected = false;
      _connectionOwner.runIfCurrent(connectionGeneration, () {
        if (_connectingGeneration == connectionGeneration &&
            identical(_connectingDevice, device)) {
          _connectingGeneration = null;
          _connectingDevice = null;
        }
        _setStreamAvailable(resources.streamReady);
        _setState(BleState.connected);
        final streamState = resources.streamReady ? 'on' : 'off';
        debugPrint('BleManager: ready, mtu=$mtu, stream=$streamState');
        connected = true;
      });
      return connected;
    } catch (e) {
      debugPrint('BleManager: connect failed: $e');
      await releaseSetup();
      try {
        await device.disconnect();
      } catch (disconnectError) {
        debugPrint('BleManager: failed connection disconnect error: '
            '$disconnectError');
      }
      final cleared = _connectionOwner.clearIfCurrent(
        connectionGeneration,
        _retireConnectionResources,
      );
      if (cleared) {
        _clearConnectingDevice(connectionGeneration, device);
        _deviceId = null;
        _deviceName = null;
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
    final connectionGeneration = _connectionOwner.generation;
    final device = _connectionOwner.value?.device ??
        (_connectingGeneration == connectionGeneration
            ? _connectingDevice
            : null);
    _setState(BleState.disconnecting);
    await device?.disconnect();
    _onDisconnected(connectionGeneration);
  }

  // --------------------------------------------------------------------------
  // Write queue (L1 → characteristic)
  // --------------------------------------------------------------------------

  Future<void> _write(
    BleWriteQueue writeQueue,
    BleGattEndpoint<BluetoothCharacteristic> endpoint,
    Uint8List bytes,
  ) {
    return writeQueue.enqueue(
      () => endpoint.value.write(
        bytes,
        withoutResponse: endpoint.withoutResponse,
      ),
    );
  }

  /// Enqueue a raw L1 chunk for delivery over the FFC1 characteristic.
  void _enqueueWrite(
    int connectionGeneration,
    BleWriteQueue writeQueue,
    BleGattEndpoint<BluetoothCharacteristic> endpoint,
    Uint8List chunk,
  ) {
    if (_disposed || !_connectionOwner.isCurrent(connectionGeneration)) {
      return;
    }
    // L1 exposes a synchronous writer. The queue owns fatal-error teardown, so
    // suppress this mirrored Future error after enqueueing it.
    unawaited(
      _write(writeQueue, endpoint, chunk).catchError((Object _) {}),
    );
  }

  /// Send one raw L2 stream message over the FFC4 characteristic (no L1, no
  /// fragmentation — the caller keeps each message within one ATT write).
  /// Shares the serial queue so it never races other GATT writes.
  Future<void> writeStream(Uint8List l2) {
    final connection = _connectionOwner.value;
    final endpoint = connection?.streamTx;
    if (_disposed || connection == null || !connection.streamReady) {
      return Future.error(StateError('Stream Service 未就绪'));
    }
    return _writeStreamPaced(connection.writeQueue, endpoint!, l2);
  }

  Future<void> _writeStreamPaced(
    BleWriteQueue writeQueue,
    BleGattEndpoint<BluetoothCharacteristic> endpoint,
    Uint8List l2,
  ) async {
    final pacer = _streamPacer;
    if (pacer != null) {
      final delay = pacer.delayBefore(_streamClock.elapsed);
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      pacer.recordWrite(_streamClock.elapsed);
    }
    final started = Stopwatch()..start();
    return _write(writeQueue, endpoint, l2).then((_) {
      started.stop();
      // Only a write that filled the probed chunk confirms it; KS_OPEN and
      // friends are far smaller and succeed on any link.
      _chunkCalibrator?.recordSuccess(l2.length);
      // The queue is serial, so each write's wall time is the link's
      // per-packet cost; the window report says whether the controller is
      // pushing one packet per connection event or several.
      final report = _streamWriteStats.record(
        bytes: l2.length,
        elapsed: started.elapsed,
      );
      if (report != null) debugPrint('BleManager: stream write $report');
    });
  }

  /// Send one L2 command frame over the L1 command channel (FFC1). L1 handles
  /// framing, CRC, and MTU chunking. Returns the assigned L1 sequence number, or
  /// null if the command channel isn't ready. Used by WiFi provisioning
  /// (CMD 0x0D); file transfers use [FileTransferSession] instead.
  int? sendCommand(Uint8List l2) {
    final connection = _connectionOwner.value;
    if (_disposed || connection == null || !connection.commandReady) {
      return null;
    }
    return connection.l1!.sendL2(l2);
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

  void _setStreamAvailable(bool available) {
    if (_streamAvailable == available) return;
    _streamAvailable = available;
    if (!_disposed) {
      _streamAvailabilityController.add(available);
    }
  }

  void _clearConnectingDevice(
    int connectionGeneration,
    BluetoothDevice device,
  ) {
    if (_connectingGeneration == connectionGeneration &&
        identical(_connectingDevice, device)) {
      _connectingGeneration = null;
      _connectingDevice = null;
    }
  }

  void _retireConnectionResources(_BleConnectionResources? resources) {
    if (resources == null) return;
    // The owner invokes retirement before clearing its active value, so stream
    // consumers observe false before the active pair disappears.
    if (resources.streamReady) _setStreamAvailable(false);
    // The probed write budget, its sampling and its pacing belong to the
    // retired link.
    _chunkCalibrator = null;
    _streamWriteStats.reset();
    _streamPacer?.reset();
    _streamPacer = null;
    _streamNotifyCount = 0;
    final tuned = _tunedRemoteId;
    if (tuned != null) {
      _tunedRemoteId = null;
      unawaited(_linkTuning.release(tuned));
    }
    resources.session?.abort();
    resources.writeQueue.abort(StateError('BLE connection ended'));
    resources.writeQueue.dispose();
    unawaited(resources.commandNotificationSub?.cancel());
    unawaited(resources.streamNotificationSub?.cancel());
    unawaited(resources.connectionStateSub.cancel());
    resources.l1?.reset();
    unawaited(
      resources.device.disconnect().catchError((Object _) {}),
    );
  }

  void _onDisconnected(int connectionGeneration) {
    final cleared = _connectionOwner.clearIfCurrent(
      connectionGeneration,
      _retireConnectionResources,
    );
    if (!cleared) return;
    final connectingDevice = _connectingDevice;
    if (connectingDevice != null) {
      _clearConnectingDevice(connectionGeneration, connectingDevice);
    }
    _deviceId = null;
    _deviceName = null;
    _setState(BleState.disconnected);
  }

  void _cleanup() {
    _scanActive = false;
    final connectionGeneration = _connectionOwner.generation;
    _connectionOwner.clearIfCurrent(
      connectionGeneration,
      _retireConnectionResources,
    );

    final connectingDevice = _connectingDevice;
    if (_connectingGeneration == connectionGeneration &&
        connectingDevice != null) {
      _clearConnectingDevice(connectionGeneration, connectingDevice);
      unawaited(connectingDevice.disconnect().catchError((Object _) {}));
    }

    _scanSub?.cancel();
    _scanSub = null;
    _scanErrorSub?.cancel();
    _scanErrorSub = null;

    _deviceId = null;
    _deviceName = null;
  }
}
