import 'dart:typed_data';

import 'ble_manager.dart';

/// Which physical transport carries the L2 video stream.
enum StreamTransportKind { ble, wifi }

extension StreamTransportKindX on StreamTransportKind {
  String get label => switch (this) {
        StreamTransportKind.ble => '蓝牙',
        StreamTransportKind.wifi => 'WiFi',
      };
}

/// Transport-agnostic sink/source for the [StreamSession] protocol.
///
/// The protocol layer (`stream_protocol.dart`) only needs to send raw L2
/// messages, learn the per-write payload budget, and receive inbound
/// notifications — so it works over BLE today and WiFi later, unchanged.
abstract class StreamTransport {
  StreamTransportKind get kind;

  /// Whether this transport is ready to carry a stream right now.
  bool get isAvailable;

  /// Emits readiness transitions for this transport only.
  Stream<bool> get availabilityChanges;

  /// Bytes of frame data carried per KS_FRAME write.
  int get chunkSize;

  /// Report that a write was rejected, giving the transport a chance to reduce
  /// [chunkSize]. Returns true when it shrank, so the caller should retry the
  /// same payload in smaller slices. Transports with a known write budget
  /// return false.
  bool shrinkChunkSize() => false;

  /// Send one complete raw L2 message (never fragmented by the caller).
  Future<void> send(Uint8List l2);

  /// Inbound raw L2 messages (KS_ACK / KS_CREDIT / KS_REPORT).
  Stream<Uint8List> get notifications;
}

/// BLE transport over the separate Stream Service (FFC4 write / FFC5 notify).
class BleStreamTransport implements StreamTransport {
  final BleManager manager;

  BleStreamTransport(this.manager);

  @override
  StreamTransportKind get kind => StreamTransportKind.ble;

  @override
  bool get isAvailable => manager.streamAvailable;

  @override
  Stream<bool> get availabilityChanges => manager.onStreamAvailabilityChanged;

  @override
  int get chunkSize => manager.streamChunkSize;

  @override
  bool shrinkChunkSize() => manager.shrinkStreamChunk();

  @override
  Future<void> send(Uint8List l2) => manager.writeStream(l2);

  @override
  Stream<Uint8List> get notifications => manager.streamNotifications;
}

/// Reserved WiFi transport entry. Not implemented yet — selecting it surfaces a
/// clear "coming soon" error rather than silently failing. Kept so the UI can
/// offer WiFi as a future option.
class WifiStreamTransport implements StreamTransport {
  @override
  StreamTransportKind get kind => StreamTransportKind.wifi;

  @override
  bool get isAvailable => false;

  @override
  Stream<bool> get availabilityChanges => const Stream<bool>.empty();

  @override
  int get chunkSize => 1400; // typical UDP/MTU payload; placeholder

  @override
  bool shrinkChunkSize() => false;

  @override
  Future<void> send(Uint8List l2) =>
      Future.error(UnimplementedError('WiFi 流媒体传输即将支持'));

  @override
  Stream<Uint8List> get notifications => const Stream<Uint8List>.empty();
}
