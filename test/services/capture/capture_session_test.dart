import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeybox/services/capture/capture_models.dart';
import 'package:honeybox/services/capture/capture_session.dart';
import 'package:honeybox/services/capture/capture_polar.dart';
import 'package:honeybox/services/capture/capture_store.dart';

const channel = CaptureChannel(service: 'e0ff', characteristic: 'ffe1');

class FakeConnection implements CaptureConnection {
  final disconnects = StreamController<void>.broadcast(sync: true);
  final callbacks = <CaptureChannel, void Function(List<int>)>{};
  @override
  int? mtu = 247;
  final writes = <String>[];
  void Function(CaptureChannel, List<int>)? onWrite;
  @override
  Future<void> write(CaptureChannel c, List<int> bytes,
      {required bool withResponse}) async {
    writes.add(bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
    onWrite?.call(c, bytes);
  }

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
  int flushes = 0;
  @override
  Future<void> flush() async {
    flushes++;
  }

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
      'reconnect keeps file, resubscribes, reruns start and flushes periodically',
      () async {
    final connections = <FakeConnection>[];
    final recording = MemoryRecording();
    var opens = 0;
    final s = CaptureSession(
        profile: CaptureProfile(
            id: 'A',
            name: 'A',
            channels: [channel],
            startCommands: [CaptureCommand(channel: channel, hex: '01')],
            stopCommands: [CaptureCommand(channel: channel, hex: '02')]),
        createConnection: () {
          final c = FakeConnection();
          connections.add(c);
          return c;
        },
        openRecording: (_) async {
          opens++;
          return recording;
        },
        retryDelays: const [Duration(milliseconds: 2)],
        flushInterval: const Duration(milliseconds: 5));
    await s.start();
    connections.first.callbacks[channel]!([9]);
    connections.first.disconnects.add(null);
    await settle();
    expect(connections.length, 2);
    expect(s.phase, CapturePhase.recording);
    connections.last.callbacks[channel]!([10]);
    await settle();
    expect(recording.flushes, greaterThan(0));
    await s.stop();
    expect(opens, 1);
    expect(s.reconnectCount, 1);
    expect(connections.map((c) => c.writes), [
      ['01'],
      ['01', '02']
    ]);
    expect(recording.packets.where((p) => p.event == null).map((p) => p.hex),
        ['09', '0a']);
    expect(recording.packets.where((p) => p.event == 'disconnected').length, 1);
    expect(recording.packets.where((p) => p.event == 'reconnected').length, 1);
    expect(recording.packets.map((p) => p.sequence),
        orderedEquals(List.generate(recording.packets.length, (i) => i + 1)));
    expect(recording.closed, isTrue);
    s.dispose();
  });
  test('silent connection is dropped and reconnected by the watchdog',
      () async {
    final connections = <FakeConnection>[];
    final recording = MemoryRecording();
    final s = CaptureSession(
        profile: CaptureProfile(id: 'A', name: 'A', channels: [channel]),
        createConnection: () {
          final c = FakeConnection();
          connections.add(c);
          return c;
        },
        openRecording: (_) async => recording,
        retryDelays: const [Duration.zero],
        staleReconnect: const Duration(milliseconds: 200));
    await s.start();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final drop = recording.packets.firstWhere((p) => p.event == 'disconnected');
    expect(drop.details['reason'], contains('无数据'));
    expect(connections.length, greaterThanOrEqualTo(2));
    expect(connections.first.closed, isTrue);
    expect(s.reconnectCount, greaterThanOrEqualTo(1));
    await s.stop();
    s.dispose();
  });
  test('backoff restarts from the first delay after a good reconnect',
      () async {
    final connections = <FakeConnection>[];
    final s = CaptureSession(
        profile: CaptureProfile(id: 'A', name: 'A', channels: [channel]),
        createConnection: () {
          final c = FakeConnection();
          connections.add(c);
          return c;
        },
        openRecording: (_) async => MemoryRecording(),
        retryDelays: const [Duration.zero, Duration(seconds: 30)]);
    await s.start();
    for (var i = 0; i < 2; i++) {
      connections.last.disconnects.add(null);
      await settle();
    }
    expect(connections.length, 3);
    expect(s.phase, CapturePhase.recording);
    expect(s.reconnectCount, 2);
    await s.stop();
    s.dispose();
  });
  for (final status in [0, 6, 10, 3]) {
    test('CP response status $status is checked and recorded', () async {
      final c = FakeConnection();
      final r = MemoryRecording();
      c.onWrite = (channel, bytes) {
        c.callbacks[channel]!([0xf0, bytes[0], bytes[1], status, 0]);
      };
      final s = CaptureSession(
          profile: CaptureProfile(id: 'P', name: 'P', channels: [
            channel
          ], startCommands: [
            CaptureCommand(channel: channel, hex: '0200', polarResponse: true)
          ]),
          createConnection: () => c,
          openRecording: (_) async => r);
      await s.start();
      expect(
          s.phase,
          status == 0 || status == 6
              ? CapturePhase.recording
              : CapturePhase.failed);
      if (status == 10) expect(s.error, contains('invalid_mtu'));
      await s.stop();
      expect(
          r.packets.any((p) => p.event == 'write' && p.hex == '0200'), isTrue);
      expect(
          r.packets.any((p) => p.event == null && p.bytes[0] == 0xf0), isTrue);
      s.dispose();
    });
  }
  test('MTU below 232 fails before PMD writes', () async {
    final c = FakeConnection()..mtu = 23;
    final s = CaptureSession(
        profile: CaptureProfile(
            id: 'P', name: 'P', channels: [channel], minimumMtu: 232),
        createConnection: () => c,
        openRecording: (_) async => MemoryRecording());
    await s.start();
    expect(s.phase, CapturePhase.failed);
    expect(s.error, contains('MTU 23'));
    expect(c.writes, isEmpty);
    s.dispose();
  });
  test('unknown MTU defers to the device response', () async {
    final c = FakeConnection()..mtu = null;
    final s = CaptureSession(
        profile: CaptureProfile(
            id: 'P',
            name: 'P',
            channels: [channel],
            minimumMtu: 232,
            startCommands: [CaptureCommand(channel: channel, hex: '01')]),
        createConnection: () => c,
        openRecording: (_) async => MemoryRecording());
    await s.start();
    expect(s.phase, CapturePhase.recording);
    expect(c.writes, isNotEmpty);
    await s.stop();
    s.dispose();
  });
  test('Polar data channel without start commands asks for the preset',
      () async {
    final c = FakeConnection();
    final s = CaptureSession(
        profile: CaptureProfile(id: 'P', name: 'P', channels: [
          const CaptureChannel(service: polarService, characteristic: polarData)
        ]),
        createConnection: () => c,
        openRecording: (_) async => MemoryRecording());
    await s.start();
    expect(s.phase, CapturePhase.failed);
    expect(s.error, contains('Polar H10'));
    expect(c.writes, isEmpty);
    s.dispose();
  });
  test(
      'first packet barrier accepts early data and Stop cancels a pending wait',
      () async {
    final c = FakeConnection();
    c.onWrite = (_, __) => c.callbacks[channel]!([0]);
    final s = CaptureSession(
        profile: CaptureProfile(id: 'A', name: 'A', channels: [
          channel
        ], startCommands: [
          CaptureCommand(channel: channel, hex: '01'),
          CaptureCommand(
              waitChannel: channel, prefix: '00', timeoutSeconds: 60),
          CaptureCommand(channel: channel, hex: '02')
        ]),
        createConnection: () => c,
        openRecording: (_) async => MemoryRecording());
    await s.start();
    expect(c.writes, ['01', '02']);
    await s.stop();
    s.dispose();
    final waiting = CaptureSession(
        profile: CaptureProfile(id: 'A', name: 'A', channels: [
          channel
        ], startCommands: [
          CaptureCommand(waitChannel: channel, timeoutSeconds: 60)
        ]),
        createConnection: () => FakeConnection(),
        openRecording: (_) async => MemoryRecording());
    final started = waiting.start();
    await settle();
    await waiting.stop().timeout(const Duration(seconds: 1));
    await started;
    expect(waiting.phase, CapturePhase.idle);
    waiting.dispose();
  });

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
    expect(
        ar.packets.where((p) => p.event == null).map((p) => p.hex), ['00ff']);
    expect(br.packets.map((p) => p.hex), ['07', '08']);
    expect(br.packets.every((p) => p.deviceId == 'B'), isTrue);
    expect(sa.error, contains('断开'));
    expect(sa.phase, CapturePhase.reconnecting);
    expect(ar.closed, isFalse);
    await sa.stop();
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
    expect(s.phase, CapturePhase.reconnecting);
    expect(connection.closed, isTrue);
    expect(recording.closed, isFalse);
    await s.stop();
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
