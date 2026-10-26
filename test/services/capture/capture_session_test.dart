import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/capture/capture_models.dart';
import 'package:honeybox/services/capture/capture_session.dart';
import 'package:honeybox/services/capture/capture_store.dart';

const channel = CaptureChannel(service: 'e0ff', characteristic: 'ffe1');

class FakeConnection implements CaptureConnection {
  final disconnects = StreamController<void>.broadcast(sync: true);
  final callbacks = <CaptureChannel, void Function(List<int>)>{};
  bool closed = false;
  Completer<void>? connecting;
  CaptureChannel? failChannel;
  @override
  Stream<void> get disconnected => disconnects.stream;
  @override
  Future<void> connect() async {
    await connecting?.future;
  }

  @override
  Future<void> subscribe(
      CaptureChannel c, void Function(List<int>) receive) async {
    if (c == failChannel) throw StateError('subscribe failed');
    callbacks[c] = receive;
  }

  @override
  Future<void> close() async {
    closed = true;
    callbacks.clear();
  }
}

class MemoryRecording implements CaptureRecording {
  final packets = <CapturePacket>[];
  bool closed = false;
  bool fail = false;
  @override
  File get file => File('test.jsonl');
  @override
  Future<void> append(CapturePacket packet) async {
    if (fail) throw const FileSystemException('disk full');
    packets.add(packet);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

CaptureSession session(
        String id, FakeConnection connection, MemoryRecording recording,
        {List<CaptureChannel> channels = const [channel]}) =>
    CaptureSession(
      profile: CaptureProfile(id: id, name: id, channels: channels),
      createConnection: () => connection,
      openRecording: (_) async => recording,
    );
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));
void main() {
  test(
      'two devices record independently and one disconnect does not stop the other',
      () async {
    final a = FakeConnection(), b = FakeConnection();
    final ar = MemoryRecording(), br = MemoryRecording();
    final sa = session('A', a, ar), sb = session('B', b, br);
    await Future.wait([sa.start(), sb.start()]);
    a.callbacks[channel]!([0, 255]);
    b.callbacks[channel]!([7]);
    a.disconnects.add(null);
    await settle();
    b.callbacks[channel]!([8]);
    await sb.stop();
    expect(ar.packets.map((p) => p.hex), ['00ff']);
    expect(br.packets.map((p) => p.hex), ['07', '08']);
    expect(br.packets.every((p) => p.deviceId == 'B'), isTrue);
    expect(sa.error, contains('断开'));
    expect(sa.phase, CapturePhase.failed);
    expect(ar.closed && br.closed, isTrue);
    sa.dispose();
    sb.dispose();
  });
  test('stop while connecting prevents subscription and closes connection',
      () async {
    final connection = FakeConnection()..connecting = Completer<void>();
    final recording = MemoryRecording();
    final s = session('A', connection, recording);
    final start = s.start();
    final stop = s.stop();
    connection.connecting!.complete();
    await Future.wait([start, stop]);
    expect(connection.closed, isTrue);
    expect(recording.packets, isEmpty);
    expect(s.phase, CapturePhase.idle);
    s.dispose();
  });
  test('partial subscribe failure cleans up every resource', () async {
    const second = CaptureChannel(service: '180d', characteristic: '2a37');
    final connection = FakeConnection()..failChannel = second;
    final recording = MemoryRecording();
    final s = session('A', connection, recording, channels: [channel, second]);
    await s.start();
    expect(s.phase, CapturePhase.failed);
    expect(connection.closed, isTrue);
    expect(recording.closed, isTrue);
    expect(connection.callbacks, isEmpty);
    s.dispose();
  });
  test('disk failure stops that session and reports failure', () async {
    final connection = FakeConnection();
    final recording = MemoryRecording()..fail = true;
    final s = session('A', connection, recording);
    await s.start();
    connection.callbacks[channel]!([1]);
    await settle();
    await s.stop();
    expect(s.error, contains('disk full'));
    expect(s.packetCount, 0);
    expect(connection.closed && recording.closed, isTrue);
    s.dispose();
  });
}
