import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'capture_models.dart';
import 'capture_polar.dart';
import 'capture_store.dart';

abstract interface class CaptureConnection {
  Stream<void> get disconnected;
  // null when the platform cannot report it; the device response decides.
  int? get mtu;
  Future<void> connect();
  Future<void> subscribe(
      CaptureChannel channel, void Function(List<int>) receive);
  Future<void> write(CaptureChannel channel, List<int> bytes,
      {required bool withResponse});
  Future<void> close();
}

enum CapturePhase { idle, starting, recording, reconnecting, stopping, failed }

/// Owns one file across connection attempts; disk errors remain terminal.
class CaptureSession extends ChangeNotifier {
  final CaptureProfile profile;
  final CaptureConnection Function() createConnection;
  final Future<CaptureRecording> Function(CaptureProfile) openRecording;
  final List<Duration> retryDelays;
  final Duration flushInterval;
  // Connected but silent this long counts as lost; null disables.
  final Duration? staleReconnect;
  CapturePhase phase = CapturePhase.idle;
  String? error;
  File? file;
  int packetCount = 0, byteCount = 0, reconnectCount = 0;
  final List<CapturePacket> recent = [];
  DateTime? lastPacketAt, recordingSince;
  // Newest packet, or the current connection's start if nothing came since.
  DateTime? get lastActivity {
    final a = lastPacketAt, b = recordingSince;
    if (a == null || b == null) return a ?? b;
    return a.isAfter(b) ? a : b;
  }

  bool get busy => [
        CapturePhase.starting,
        CapturePhase.recording,
        CapturePhase.reconnecting,
        CapturePhase.stopping
      ].contains(phase);
  CaptureConnection? _connection;
  CaptureRecording? _recording;
  StreamSubscription<void>? _disconnect;
  Future<void> _runner = Future.value(), _writes = Future.value();
  Completer<void> _cancel = Completer<void>(), _lost = Completer<void>();
  final _packets = StreamController<CapturePacket>.broadcast(sync: true);
  final _seen = <String>{};
  bool _disposed = false, _diskFailed = false, _acceptPackets = false;
  bool _subscriptionsReady = false;
  int _sequence = 0, _pending = 0;
  Timer? _refresh, _flush;
  bool _flushPending = false;

  CaptureSession(
      {required this.profile,
      required this.createConnection,
      required this.openRecording,
      this.retryDelays = const [
        Duration(seconds: 2),
        Duration(seconds: 5),
        Duration(seconds: 10),
        Duration(seconds: 30)
      ],
      this.flushInterval = const Duration(seconds: 1),
      this.staleReconnect = const Duration(seconds: 60)});

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _checkCancelled() {
    if (_cancel.isCompleted) throw const _Cancelled();
  }

  Future<void> start() {
    if (busy || _disposed) return Future.value();
    phase = CapturePhase.starting;
    error = null;
    file = null;
    packetCount = byteCount = reconnectCount = _sequence = 0;
    recent.clear();
    lastPacketAt = null;
    _cancel = Completer<void>();
    _diskFailed = false;
    final ready = Completer<void>();
    _runner = _run(ready);
    _notify();
    return ready.future;
  }

  Future<void> _run(Completer<void> ready) async {
    var attempts = 0;
    try {
      // Own the attempt before the first await so immediate Stop cleans it up.
      _connection = createConnection();
      if (profile.startCommands.isEmpty &&
          profile.channels.any((c) => c.characteristic == polarData)) {
        throw const CaptureConfigurationException(
            'Polar ECG/ACC 未配置启动命令，请用「选择 Polar H10」预设重新配置');
      }
      _recording = await openRecording(profile);
      file = _recording!.file;
      _acceptPackets = true;
      _flush = Timer.periodic(flushInterval, (_) {
        if (_flushPending || _diskFailed) return;
        _flushPending = true;
        _enqueue(() => _recording!.flush())
            .whenComplete(() => _flushPending = false);
      });
      while (!_cancel.isCompleted) {
        _lost = Completer<void>();
        _seen.clear();
        try {
          final connection = _connection ?? createConnection();
          _connection = connection;
          _subscriptionsReady = false;
          _disconnect = connection.disconnected.listen((_) {
            if (!_lost.isCompleted) _lost.complete();
          }, onError: (Object _) {
            if (!_lost.isCompleted) _lost.complete();
          });
          await connection.connect();
          _checkCancelled();
          if (_lost.isCompleted) throw StateError('设备连接已断开');
          final mtu = connection.mtu;
          if (mtu != null && mtu < profile.minimumMtu) {
            throw CaptureConfigurationException(
                '协商 MTU $mtu，Polar ECG/ACC 需要 MTU ≥ ${profile.minimumMtu}');
          }
          if (attempts > 0) {
            reconnectCount++;
            await _event('reconnected',
                details: {'reconnectCount': reconnectCount});
          }
          for (final c in profile.channels) {
            await connection.subscribe(c, (bytes) => _receive(c, bytes));
            _checkCancelled();
            if (_lost.isCompleted) throw StateError('订阅时设备连接已断开');
          }
          _subscriptionsReady = true;
          await _commands(profile.startCommands);
          _checkCancelled();
          error = null;
          phase = CapturePhase.recording;
          recordingSince = DateTime.now();
          // Backoff restarts after every successful connection.
          attempts = 0;
          if (!ready.isCompleted) ready.complete();
          _notify();
          var stale = false;
          final limit = staleReconnect;
          final watchdog = limit == null
              ? null
              : Timer.periodic(limit ~/ 4, (_) {
                  final last = lastActivity!;
                  if (DateTime.now().difference(last) >= limit &&
                      !_lost.isCompleted) {
                    stale = true;
                    _lost.complete();
                  }
                });
          try {
            await Future.any([_lost.future, _cancel.future]);
          } finally {
            watchdog?.cancel();
          }
          _checkCancelled();
          if (stale) {
            throw StateError('超过 ${limit!.inSeconds} 秒无数据，主动重连');
          }
          throw StateError('设备连接已断开');
        } catch (e) {
          if (e is _Cancelled || _cancel.isCompleted) break;
          if (e is CaptureConfigurationException) rethrow;
          error = '连接中断，正在重试：$e';
          await _event('disconnected',
              details: {'reason': '$e', 'attempt': attempts + 1});
          await _closeConnection();
          phase = CapturePhase.reconnecting;
          if (!ready.isCompleted) ready.complete();
          _notify();
          final delay = retryDelays.isEmpty
              ? Duration.zero
              : retryDelays[attempts.clamp(0, retryDelays.length - 1)];
          attempts++;
          // A timer is cancelled on Stop, including a 30-second backoff.
          final elapsed = Completer<void>();
          final timer = Timer(delay, elapsed.complete);
          await Future.any([elapsed.future, _cancel.future]);
          timer.cancel();
        }
      }
    } catch (e) {
      if (!_diskFailed) error = '无法采集：$e';
    } finally {
      _flush?.cancel();
      _flush = null;
      if (_subscriptionsReady && _connection != null && !_lost.isCompleted) {
        // Keep CP indications in the file until stop commands finish.
        for (final command in profile.stopCommands) {
          try {
            await _commands([command], stopping: true);
          } catch (e) {
            error ??= '停止命令失败：$e';
          }
        }
      }
      _acceptPackets = false;
      await _closeConnection();
      await _writes;
      try {
        await _recording?.close();
      } catch (e) {
        error ??= '文件关闭失败：$e';
      }
      _recording = null;
      _refresh?.cancel();
      _refresh = null;
      phase = error == null ? CapturePhase.idle : CapturePhase.failed;
      if (!ready.isCompleted) ready.complete();
      _notify();
    }
  }

  Future<void> _closeConnection() async {
    await _disconnect?.cancel();
    _disconnect = null;
    final c = _connection;
    _connection = null;
    _subscriptionsReady = false;
    try {
      await c?.close();
    } catch (_) {/* Next attempt uses a new connection. */}
  }

  Future<void> _commands(List<CaptureCommand> commands,
      {bool stopping = false}) async {
    for (final command in commands) {
      if (!stopping) _checkCancelled();
      if (command.waitChannel != null) {
        final key =
            '${command.waitChannel!.key}/${command.prefix.toLowerCase()}';
        if (_seen.contains(key)) continue;
        await _waitPacket(
            (p) =>
                p.channel == command.waitChannel &&
                p.hex.startsWith(command.prefix.toLowerCase()),
            command.timeoutSeconds,
            stopping: stopping);
      } else {
        _seen.clear();
        final bytes = command.bytes;
        final response = Completer<CapturePacket>();
        StreamSubscription<CapturePacket>? sub;
        if (command.polarResponse) {
          sub = _packets.stream.listen((p) {
            if (p.channel == command.channel &&
                p.bytes.length >= 5 &&
                p.bytes[0] == 0xf0 &&
                p.bytes[1] == bytes[0] &&
                p.bytes[2] == bytes[1] &&
                !response.isCompleted) {
              response.complete(p);
            }
          });
        }
        try {
          await _event('write',
              channel: command.channel,
              bytes: bytes,
              details: {'withResponse': command.withResponse});
          if (!stopping) _checkCancelled();
          await _connection!.write(command.channel!, bytes,
              withResponse: command.withResponse);
          await _event('write_complete',
              channel: command.channel, bytes: bytes);
          if (command.polarResponse) {
            final packet = await _guard(response.future, command.timeoutSeconds,
                stopping: stopping);
            checkPolarResponse(packet.bytes);
          }
        } catch (e) {
          await _event('write_error',
              channel: command.channel,
              bytes: bytes,
              details: {'reason': '$e'});
          rethrow;
        } finally {
          await sub?.cancel();
        }
      }
    }
  }

  Future<T> _guard<T>(Future<T> future, int seconds, {bool stopping = false}) =>
      Future.any<T>([
        future,
        _lost.future.then<T>((_) => throw StateError('设备连接已断开')),
        if (!stopping) _cancel.future.then<T>((_) => throw const _Cancelled()),
      ]).timeout(Duration(seconds: seconds),
          onTimeout: () => throw TimeoutException('等待设备数据超时（$seconds 秒）'));

  Future<CapturePacket> _waitPacket(
      bool Function(CapturePacket) match, int seconds,
      {bool stopping = false}) async {
    final result = Completer<CapturePacket>();
    final sub = _packets.stream.listen((p) {
      if (match(p) && !result.isCompleted) result.complete(p);
    });
    try {
      return await _guard(result.future, seconds, stopping: stopping);
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _event(String event,
      {CaptureChannel? channel,
      List<int> bytes = const [],
      Map<String, dynamic> details = const {}}) {
    if (_recording == null || _diskFailed) return Future.value();
    final packet = CapturePacket(
        deviceId: profile.id,
        channel: channel ?? profile.channels.first,
        sequence: ++_sequence,
        time: DateTime.now().toUtc(),
        bytes: bytes,
        event: event,
        details: details);
    return _enqueue(() => _recording!.append(packet));
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _pending++;
    _writes = _writes.then((_) async {
      if (!_diskFailed) await action();
    }).catchError((Object e) {
      _diskFailed = true;
      unawaited(stop(error: '数据写入失败：$e'));
    }).whenComplete(() => _pending--);
    return _writes;
  }

  void _receive(CaptureChannel channel, List<int> bytes) {
    if (!_acceptPackets || _recording == null || _diskFailed) return;
    if (_pending >= 4096) {
      unawaited(stop(error: '写入队列已满，采集已停止，请降低设备数据速率'));
      return;
    }
    final packet = CapturePacket(
        deviceId: profile.id,
        channel: channel,
        sequence: ++_sequence,
        time: DateTime.now().toUtc(),
        bytes: bytes);
    for (final step
        in profile.startCommands.where((c) => c.waitChannel == channel)) {
      if (packet.hex.startsWith(step.prefix.toLowerCase())) {
        _seen.add('${channel.key}/${step.prefix.toLowerCase()}');
      }
    }
    _packets.add(packet);
    unawaited(_enqueue(() async {
      await _recording!.append(packet);
      packetCount++;
      byteCount += bytes.length;
      lastPacketAt = packet.time;
      recent.add(packet);
      if (recent.length > 30) recent.removeAt(0);
      _refresh ??= Timer(const Duration(milliseconds: 200), () {
        _refresh = null;
        _notify();
      });
    }));
  }

  Future<void> stop({String? error}) {
    if (error != null) {
      this.error = error;
    } else if (phase == CapturePhase.reconnecting) {
      this.error = null;
    }
    if (!_cancel.isCompleted) _cancel.complete();
    if (busy) {
      phase = CapturePhase.stopping;
      _notify();
    }
    return _runner;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    _refresh?.cancel();
    unawaited(_runner.then((_) => _packets.close()));
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
