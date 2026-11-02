import 'dart:async';

/// Whether a capability is confirmed for the selected platform and device.
enum OtaCapabilityStatus { supported, unsupported, unknown }

/// Values are conservative until confirmed by the platform/SDK and device.
class OtaPlatformCapabilities {
  final OtaCapabilityStatus transport;
  final OtaCapabilityStatus firmwareInspection;
  final OtaCapabilityStatus resume;
  final OtaCapabilityStatus rollback;
  const OtaPlatformCapabilities({
    required this.transport,
    this.firmwareInspection = OtaCapabilityStatus.unknown,
    this.resume = OtaCapabilityStatus.unknown,
    this.rollback = OtaCapabilityStatus.unknown,
  });
}

/// Typed envelope retaining all fields for unknown future SDK events.
class OtaPlatformEvent {
  final String? message;
  final int? progress;
  final bool done;
  final bool ready;
  final int? errorType;
  final int? errorCode;
  final String? sessionId;
  final Map<String, Object?> raw;

  OtaPlatformEvent.fromMap(Map<String, Object?> value)
      : message =
            value['message'] is String ? value['message'] as String : null,
        progress = value['progress'] is int ? value['progress'] as int : null,
        done = value['done'] == true,
        ready = value['ready'] == true,
        errorType =
            value['errorType'] is int ? value['errorType'] as int : null,
        errorCode =
            value['errorCode'] is int ? value['errorCode'] as int : null,
        sessionId =
            value['sessionId'] is String ? value['sessionId'] as String : null,
        raw = Map.unmodifiable(value);
}

/// Platform-neutral transport contract. Device IDs are opaque platform values.
abstract interface class OtaPlatform {
  bool get supported;
  Stream<Map<String, Object?>> get events;
  Future<void> prepare(String deviceId, {String? sessionId});
  Future<void> start(String filePath);
  Future<void> close();
}

extension OtaPlatformContracts on OtaPlatform {
  /// Transport availability alone does not establish device compatibility.
  OtaPlatformCapabilities get capabilities => OtaPlatformCapabilities(
        transport: supported
            ? OtaCapabilityStatus.supported
            : OtaCapabilityStatus.unsupported,
      );

  Stream<OtaPlatformEvent> get typedEvents =>
      events.map(OtaPlatformEvent.fromMap);

  /// Timeout only bounds the caller's wait: it does not cancel native work.
  /// Callers must reconcile the native session before starting another attempt.
  Future<void> prepareWithTimeout(String deviceId, Duration timeout) =>
      prepare(deviceId).timeout(timeout);
}

/// Safe fallback for platforms without a registered implementation.
class UnsupportedOtaPlatform implements OtaPlatform {
  const UnsupportedOtaPlatform();
  @override
  bool get supported => false;
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> prepare(String deviceId, {String? sessionId}) async =>
      throw UnsupportedError('当前平台暂不支持 OTA');
  @override
  Future<void> start(String filePath) async =>
      throw UnsupportedError('当前平台暂不支持 OTA');
  @override
  Future<void> close() async {}
}
