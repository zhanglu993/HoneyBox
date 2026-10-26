import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'capture_models.dart';
import 'capture_store.dart';

abstract interface class CaptureConnection {
  Stream<void> get disconnected;
  Future<void> connect();
  Future<void> subscribe(
      CaptureChannel channel, void Function(List<int>) receive);
  Future<void> close();
}

enum CapturePhase { idle, starting, recording, stopping, failed }

/// Owns one device. All writes are ordered; another device has its own queue.
class CaptureSession extends ChangeNotifier {
  final CaptureProfile profile;
  final CaptureConnection Function() createConnection;
  final Future<CaptureRecording> Function(CaptureProfile) openRecording;
  CapturePhase phase = CapturePhase.idle;
  String? error;
  File? file;
  int packetCount = 0;
  int byteCount = 0;
  final List<CapturePacket> recent = [];
  bool get busy =>
      phase == CapturePhase.starting ||
      phase == CapturePhase.recording ||
      phase == CapturePhase.stopping;
  CaptureConnection? _connection;
  CaptureRecording? _recording;
  StreamSubscription<void>? _disconnect;
  Future<void> _operation = Future.value();
  Future<void> _writes = Future.value();
  bool _cancelled = false;
  bool _disposed = false;
  int _sequence = 0;
  int _pending = 0;
  Timer? _refresh;

  CaptureSession(
      {required this.profile,
      required this.createConnection,
      required this.openRecording});
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() {
    if (busy || _disposed) return _operation;
    phase = CapturePhase.starting;
    error = null;
    file = null;
    packetCount = 0;
    byteCount = 0;
    recent.clear();
    _sequence = 0;
    _cancelled = false;
    _notify();
    return _operation = _start();
  }

  void _checkCancelled() {
    if (_cancelled) throw const _Cancelled();
  }

  Future<void> _start() async {
    try {
      _connection = createConnection();
      _disconnect = _connection!.disconnected.listen((_) {
        unawaited(stop(error: '设备连接已断开，请重新开始采集'));
      }, onError: (Object e) {
        unawaited(stop(error: '连接异常：$e'));
      });
      await _connection!.connect();
      _checkCancelled();
      _recording = await openRecording(profile);
      file = _recording!.file;
      _checkCancelled();
      for (final channel in profile.channels) {
        await _connection!
            .subscribe(channel, (bytes) => _receive(channel, bytes));
        _checkCancelled();
      }
      phase = CapturePhase.recording;
      _notify();
    } catch (e) {
      if (e is! _Cancelled) error ??= '无法开始采集：$e';
      _cancelled = true;
      await _cleanup();
      phase = error == null ? CapturePhase.idle : CapturePhase.failed;
      _notify();
    }
  }

  void _receive(CaptureChannel channel, List<int> bytes) {
    if (_cancelled || _recording == null) return;
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
    final recording = _recording!;
    _pending++;
    _writes = _writes.then((_) async {
      // After a disk error, do not append later packets to an incomplete stream.
      if (error != null && error!.startsWith('数据写入失败')) return;
      await recording.append(packet);
      packetCount++;
      byteCount += packet.bytes.length;
      recent.add(packet);
      if (recent.length > 30) recent.removeAt(0);
      _refresh ??= Timer(const Duration(milliseconds: 200), () {
        _refresh = null;
        _notify();
      });
    }).catchError((Object e) {
      unawaited(stop(error: '数据写入失败：$e'));
    }).whenComplete(() {
      _pending--;
    });
  }

  Future<void> stop({String? error}) {
    if (error != null) this.error ??= error;
    _cancelled = true;
    if (!busy) return _operation;
    if (phase == CapturePhase.stopping) return _operation;
    phase = CapturePhase.stopping;
    _notify();
    return _operation = _operation.then((_) async {
      await _cleanup();
      phase = this.error == null ? CapturePhase.idle : CapturePhase.failed;
      _notify();
    });
  }

  Future<void> _cleanup() async {
    await _disconnect?.cancel();
    _disconnect = null;
    final connection = _connection;
    _connection = null;
    try {
      await connection?.close();
    } catch (e) {
      error ??= '连接关闭失败：$e';
    }
    await _writes;
    final recording = _recording;
    _recording = null;
    try {
      await recording?.close();
    } catch (e) {
      error ??= '文件关闭失败：$e';
    }
    _refresh?.cancel();
    _refresh = null;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    _refresh?.cancel();
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
