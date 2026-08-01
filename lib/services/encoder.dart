import 'dart:async';

import 'package:flutter/services.dart';

import 'stream_transport.dart';

/// Supported (and placeholder) encoder formats for the encoding test bench.
///
/// Only [h264] is implemented natively today; [jpeg] and [mvs1] are reserved
/// slots that the native layer rejects with a "not implemented" error.
enum EncoderFormat { h264, jpeg, mvs1 }

extension EncoderFormatX on EncoderFormat {
  /// Wire value sent to the native layer.
  String get wire => switch (this) {
        EncoderFormat.h264 => 'h264',
        EncoderFormat.jpeg => 'jpeg',
        EncoderFormat.mvs1 => 'mvs1',
      };

  String get label => switch (this) {
        EncoderFormat.h264 => 'H.264',
        EncoderFormat.jpeg => 'JPEG',
        EncoderFormat.mvs1 => 'MVS1',
      };

  /// All three codecs are now wired up natively (H.264 via MediaCodec,
  /// MSV1/JPEG via the software encoder).
  bool get implemented => true;

  /// Whether a key-frame interval applies to this format (H.264 IDR interval;
  /// MSV1 periodic key-frame refresh for stream error recovery).
  bool get hasIFrameInterval =>
      this == EncoderFormat.h264 || this == EncoderFormat.mvs1;
}

/// H.264 bitrate slider bounds (bits per second). The upper bound is capped at
/// 300 kbps for Bluetooth screen mirroring — encoded frames must fit within the
/// BLE credit window, so higher rates would stall the link.
const int kH264MinBitrate = 50000;
const int kH264MaxBitrate = 300000;

/// Immutable encoder configuration mirrored by the native [EncoderConfig].
class EncoderConfig {
  final EncoderFormat format;

  /// Output (scaled) resolution.
  final int width;
  final int height;

  /// Center-crop / digital-zoom factor (1.0 = full field of view).
  final double cropZoom;

  final int fps;

  /// Encode quality expressed as a bitrate in bits per second.
  final int bitrate;

  /// I-frame (IDR) interval in seconds — H.264 only.
  final int iFrameIntervalSec;

  /// Preferred streaming transport (BLE today; WiFi reserved).
  final StreamTransportKind transport;

  /// MSV1 inter-frame skip (P-frames) on/off, and its per-pixel RGB555 delta
  /// threshold (0 = only skip identical blocks).
  final bool msv1Skip;
  final int msv1SkipThr;

  /// JPEG quality (1..100).
  final int jpegQuality;

  /// Also save the encoded stream to a local file while projecting.
  final bool recordToFile;

  const EncoderConfig({
    this.format = EncoderFormat.h264,
    this.width = 368,
    this.height = 368,
    this.cropZoom = 1.0,
    this.fps = 15,
    this.bitrate = 150000, // 150 kbps
    this.iFrameIntervalSec = 6,
    this.transport = StreamTransportKind.ble,
    this.msv1Skip = true,
    this.msv1SkipThr = 0,
    this.jpegQuality = 80,
    this.recordToFile = false,
  });

  EncoderConfig copyWith({
    EncoderFormat? format,
    int? width,
    int? height,
    double? cropZoom,
    int? fps,
    int? bitrate,
    int? iFrameIntervalSec,
    StreamTransportKind? transport,
    bool? msv1Skip,
    int? msv1SkipThr,
    int? jpegQuality,
    bool? recordToFile,
  }) {
    return EncoderConfig(
      format: format ?? this.format,
      width: width ?? this.width,
      height: height ?? this.height,
      cropZoom: cropZoom ?? this.cropZoom,
      fps: fps ?? this.fps,
      bitrate: bitrate ?? this.bitrate,
      iFrameIntervalSec: iFrameIntervalSec ?? this.iFrameIntervalSec,
      transport: transport ?? this.transport,
      msv1Skip: msv1Skip ?? this.msv1Skip,
      msv1SkipThr: msv1SkipThr ?? this.msv1SkipThr,
      jpegQuality: jpegQuality ?? this.jpegQuality,
      recordToFile: recordToFile ?? this.recordToFile,
    );
  }

  Map<String, dynamic> toWire() => {
        'format': format.wire,
        'width': width,
        'height': height,
        'cropZoom': cropZoom,
        'fps': fps,
        'bitrate': bitrate,
        'iFrameIntervalSec': iFrameIntervalSec,
        'msv1Skip': msv1Skip,
        'msv1SkipThr': msv1SkipThr,
        'jpegQuality': jpegQuality,
        'recordToFile': recordToFile,
      };

  /// Persisted form (enums stored by index).
  Map<String, dynamic> toJson() => {
        'format': format.index,
        'width': width,
        'height': height,
        'cropZoom': cropZoom,
        'fps': fps,
        'bitrate': bitrate,
        'iFrameIntervalSec': iFrameIntervalSec,
        'transport': transport.index,
        'msv1Skip': msv1Skip,
        'msv1SkipThr': msv1SkipThr,
        'jpegQuality': jpegQuality,
        'recordToFile': recordToFile,
      };

  factory EncoderConfig.fromJson(Map<String, dynamic> json) {
    final fmtIndex = (json['format'] as num?)?.toInt() ?? 0;
    final transIndex = (json['transport'] as num?)?.toInt() ?? 0;
    return EncoderConfig(
      format: (fmtIndex >= 0 && fmtIndex < EncoderFormat.values.length)
          ? EncoderFormat.values[fmtIndex]
          : EncoderFormat.h264,
      width: (json['width'] as num?)?.toInt() ?? 368,
      height: (json['height'] as num?)?.toInt() ?? 368,
      cropZoom: (json['cropZoom'] as num?)?.toDouble() ?? 1.0,
      fps: (json['fps'] as num?)?.toInt() ?? 15,
      // Clamp so a value persisted before the 300 kbps cap snaps into range.
      bitrate: (((json['bitrate'] as num?)?.toInt() ?? 150000)
              .clamp(kH264MinBitrate, kH264MaxBitrate))
          .toInt(),
      iFrameIntervalSec: (json['iFrameIntervalSec'] as num?)?.toInt() ?? 6,
      transport:
          (transIndex >= 0 && transIndex < StreamTransportKind.values.length)
              ? StreamTransportKind.values[transIndex]
              : StreamTransportKind.ble,
      msv1Skip: json['msv1Skip'] as bool? ?? true,
      msv1SkipThr: (json['msv1SkipThr'] as num?)?.toInt() ?? 0,
      jpegQuality: (json['jpegQuality'] as num?)?.toInt() ?? 80,
      recordToFile: json['recordToFile'] as bool? ?? false,
    );
  }
}

/// The camera preview texture descriptor reported by the native layer.
class CameraInfo {
  final int textureId;
  final int previewWidth;
  final int previewHeight;
  final int sensorOrientation;
  final bool facingFront;

  /// Exposure-compensation range in EV stops (0/0 if unsupported).
  final double evMin;
  final double evMax;
  final double evStep;

  /// Whether tap-to-focus metering regions are supported.
  final bool focusSupported;

  const CameraInfo({
    required this.textureId,
    required this.previewWidth,
    required this.previewHeight,
    required this.sensorOrientation,
    required this.facingFront,
    this.evMin = 0,
    this.evMax = 0,
    this.evStep = 0,
    this.focusSupported = false,
  });

  bool get evSupported => evMax > evMin;
}

/// Live encoding statistics streamed from the native encoder.
class EncoderStats {
  final int frames;
  final int keyframes;
  final int bytes;
  final double fps;

  /// Size of the most recently encoded frame, in bytes.
  final int lastBytes;

  /// Cumulative bytes of key (I) frames, so the UI can average I vs P separately.
  final int keyBytes;

  const EncoderStats({
    this.frames = 0,
    this.keyframes = 0,
    this.bytes = 0,
    this.fps = 0,
    this.lastBytes = 0,
    this.keyBytes = 0,
  });
}

/// Result of a finished encoding run.
class EncoderResult {
  final String? path;
  final int frames;
  final int keyframes;
  final int bytes;

  const EncoderResult({
    this.path,
    this.frames = 0,
    this.keyframes = 0,
    this.bytes = 0,
  });
}

/// Dart-side facade over the native Camera2 + MediaCodec encoding pipeline.
///
/// Commands go out over a [MethodChannel]; camera-ready notices, live stats,
/// completion, and errors arrive over an [EventChannel].
class EncoderService {
  static const _method = MethodChannel('ebadge/encoder');
  static const _events = EventChannel('ebadge/encoder/events');

  StreamSubscription<dynamic>? _eventSub;

  // Callbacks — assigned by the page that owns the bench.
  void Function(CameraInfo info)? onCamera;
  void Function(EncoderStats stats)? onStats;
  void Function(String path, int width, int height)? onStarted;
  void Function(EncoderResult result)? onStopped;
  void Function(String message)? onError;
  void Function(String message)? onInfo;

  /// Encoded-preview state change: [encoded] on/off, [textureId] of the decoded
  /// preview texture (-1 when off), and its size.
  void Function(bool encoded, int textureId, int width, int height)? onPreview;

  /// One encoded frame ready to transmit over the stream. [key] marks a
  /// self-contained key frame (MSV1 I-frame / every JPEG frame).
  void Function(Uint8List data, bool key)? onFrame;

  /// Begin listening for native events. Call once before [openCamera].
  void listen() {
    _eventSub ??= _events.receiveBroadcastStream().listen(
          _handleEvent,
          onError: (Object e) => onError?.call('事件流错误: $e'),
        );
  }

  void _handleEvent(dynamic event) {
    if (event is! Map) return;
    final map = event.cast<dynamic, dynamic>();
    switch (map['event'] as String?) {
      case 'camera':
        onCamera?.call(CameraInfo(
          textureId: (map['textureId'] as num).toInt(),
          previewWidth: (map['previewWidth'] as num?)?.toInt() ?? 0,
          previewHeight: (map['previewHeight'] as num?)?.toInt() ?? 0,
          sensorOrientation: (map['sensorOrientation'] as num?)?.toInt() ?? 0,
          facingFront: map['facingFront'] as bool? ?? false,
          evMin: (map['evMin'] as num?)?.toDouble() ?? 0,
          evMax: (map['evMax'] as num?)?.toDouble() ?? 0,
          evStep: (map['evStep'] as num?)?.toDouble() ?? 0,
          focusSupported: map['focusSupported'] as bool? ?? false,
        ));
        break;
      case 'stats':
        onStats?.call(EncoderStats(
          frames: (map['frames'] as num?)?.toInt() ?? 0,
          keyframes: (map['keyframes'] as num?)?.toInt() ?? 0,
          bytes: (map['bytes'] as num?)?.toInt() ?? 0,
          fps: (map['fps'] as num?)?.toDouble() ?? 0,
          lastBytes: (map['lastBytes'] as num?)?.toInt() ?? 0,
          keyBytes: (map['keyBytes'] as num?)?.toInt() ?? 0,
        ));
        break;
      case 'started':
        onStarted?.call(
          map['path'] as String? ?? '',
          (map['width'] as num?)?.toInt() ?? 0,
          (map['height'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'stopped':
        onStopped?.call(EncoderResult(
          path: map['path'] as String?,
          frames: (map['frames'] as num?)?.toInt() ?? 0,
          keyframes: (map['keyframes'] as num?)?.toInt() ?? 0,
          bytes: (map['bytes'] as num?)?.toInt() ?? 0,
        ));
        break;
      case 'error':
        onError?.call(map['message'] as String? ?? '未知错误');
        break;
      case 'info':
        onInfo?.call(map['message'] as String? ?? '');
        break;
      case 'preview':
        onPreview?.call(
          map['encoded'] as bool? ?? false,
          (map['textureId'] as num?)?.toInt() ?? -1,
          (map['width'] as num?)?.toInt() ?? 0,
          (map['height'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'frame':
        final data = map['data'];
        if (data is Uint8List) {
          onFrame?.call(data, map['key'] as bool? ?? false);
        }
        break;
    }
  }

  Future<void> openCamera(EncoderConfig config, {bool facingFront = false}) =>
      _method.invokeMethod('openCamera', {
        'facingFront': facingFront,
        ...config.toWire(),
      });

  Future<void> closeCamera() => _method.invokeMethod('closeCamera');

  /// Push updated parameters (crop/zoom/aspect/fps) to the live preview.
  Future<void> setConfig(EncoderConfig config) =>
      _method.invokeMethod('setConfig', config.toWire());

  /// Start encoding. When [stream] is true the native layer also emits each
  /// encoded frame via [onFrame] for transmission over the active transport.
  Future<void> startEncoding(EncoderConfig config, {bool stream = false}) =>
      _method.invokeMethod('startEncoding', {
        ...config.toWire(),
        'stream': stream,
      });

  Future<void> stopEncoding() => _method.invokeMethod('stopEncoding');

  /// Ask the encoder to emit a fresh key frame (used to re-sync a congested
  /// MSV1 stream without restarting).
  Future<void> requestKeyframe() => _method.invokeMethod('requestKeyframe');

  /// Permit one more paced (H.264 stream) encoder frame. Called after each
  /// frame is transmitted so encoding tracks the transport instead of dropping.
  Future<void> requestEncoderFrame() =>
      _method.invokeMethod('requestEncoderFrame');

  /// Tap-to-focus at normalized [nx],[ny] (0..1) in the displayed preview.
  Future<void> focusAt(double nx, double ny) =>
      _method.invokeMethod('focusAt', {'x': nx, 'y': ny});

  /// Set exposure compensation in EV stops.
  Future<void> setEv(double ev) => _method.invokeMethod('setEv', {'ev': ev});

  /// Live digital zoom (pinch-to-zoom). [zoom] is the center-crop factor
  /// (1.0 = full field of view); affects both preview and encoded output.
  Future<void> setZoom(double zoom) =>
      _method.invokeMethod('setZoom', {'zoom': zoom});

  /// Toggle encoded preview (encode→decode→display; MSV1/JPEG only).
  Future<void> setPreviewMode(bool encoded) =>
      _method.invokeMethod('setPreviewMode', {'encoded': encoded});

  /// Snapshot the current GL frame (post crop/zoom/rotation) and return the
  /// JPEG bytes. Independent of the streaming pipeline — works whether or not
  /// encoding is active. Returns null if the native side signals an error.
  Future<Uint8List?> takePicture() async {
    try {
      final result = await _method.invokeMethod<Uint8List>('takePicture');
      return result;
    } on PlatformException catch (e) {
      onError?.call(e.message ?? '拍照失败');
      return null;
    }
  }

  /// Release the native camera and stop listening for events.
  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await closeCamera();
    } catch (_) {}
  }
}
