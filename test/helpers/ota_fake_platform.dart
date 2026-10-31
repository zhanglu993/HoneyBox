import 'dart:async';

import 'package:honeybox/services/ota/ota_platform.dart';

/// Programmable transport for OTA tests; no native calls are made.
class OtaFakePlatform implements OtaPlatform {
  final controller = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final calls = <String>[];
  bool isSupported = true;
  Object? prepareError, startError, closeError;
  Future<void>? prepareDelay, startDelay, closeDelay;
  String? sessionId;
  int get prepares => calls.where((call) => call == 'prepare').length;
  int get starts => calls.where((call) => call == 'start').length;
  @override
  bool get supported => isSupported;
  @override
  Stream<Map<String, Object?>> get events => controller.stream;
  @override
  Future<void> prepare(String deviceId, {String? sessionId}) async {
    calls.add('prepare');
    this.sessionId = sessionId;
    await prepareDelay;
    if (prepareError != null) throw prepareError!;
  }
  @override
  Future<void> start(String filePath) async {
    calls.add('start');
    await startDelay;
    if (startError != null) throw startError!;
  }
  @override
  Future<void> close() async {
    calls.add('close');
    await closeDelay;
    if (closeError != null) throw closeError!;
  }
}
