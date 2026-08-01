import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../providers/ble_provider.dart';
import '../../providers/remote_control_provider.dart';
import '../../providers/wifi_provider.dart';
import '../../services/config_store.dart';
import '../../services/encoder.dart';
import '../../services/remote_control_session.dart';
import '../../services/stream_protocol.dart';
import '../../services/stream_transport.dart';
import '../../services/wifi_transport.dart';
import 'widgets/encoder_settings_sheet.dart';

// iPhone-camera-style palette for the dark capture UI.
const Color _kAccent = Color(0xFFFFCC00); // iOS yellow
const Color _kRec = Color(0xFFFF3B30); // iOS red
const Color _kDone = Color(0xFF34C759); // iOS green

/// Encoding test bench.
///
/// Before wiring camera streaming to the BLE transport, this page validates the
/// native Camera2 → MediaCodec H.264 pipeline in isolation: pick parameters from
/// the bottom-sheet menu, start/stop encoding, and inspect the raw `.h264`
/// elementary stream written to the app's external files dir.
class StreamPage extends ConsumerStatefulWidget {
  final String deviceName;
  final String deviceId;

  const StreamPage({
    super.key,
    required this.deviceName,
    required this.deviceId,
  });

  @override
  ConsumerState<StreamPage> createState() => _StreamPageState();
}

class _StreamPageState extends ConsumerState<StreamPage>
    with WidgetsBindingObserver {
  final EncoderService _encoder = EncoderService();

  EncoderConfig _config = const EncoderConfig();
  CameraInfo? _camera;
  EncoderStats _stats = const EncoderStats();
  EncoderResult? _result;

  bool _encoding = false;
  bool _permissionDenied = false;
  String? _error;
  bool _facingFront = false;

  /// Latest captured JPEG bytes (single-slot demo cache). Populated by
  /// [_takePicture] — invoked via a hidden long-press on the shutter, and in
  /// future by a `0x0F CAPTURE` sub-command from the paired device. Released in
  /// [dispose] so the page doesn't hold pixel data after being torn down.
  Uint8List? _lastShot;
  bool _capturing = false;

  /// Camera-style shutter flash overlay opacity — pulsed briefly on capture as
  /// visual feedback that a photo was taken. Driven by [_flashCapture].
  double _flashOpacity = 0;
  Timer? _flashTimer;

  /// Latest native diagnostic line (swap/crop/matrix). Hidden unless [_showDiag]
  /// is toggled on; shown as a non-intrusive overlay at the top of the preview.
  String? _diag;
  bool _showDiag = false;

  /// Exposure compensation (EV stops) and tap-to-focus reticle state.
  double _ev = 0;
  Offset? _focusPoint;
  bool _focusVisible = false; // focus reticle box
  bool _showEv = false; // EV indicator (with the box, or while scrubbing)
  Timer? _focusTimer;
  int _focusSeq = 0; // bumped each tap to restart the shrink animation
  double _evDragStartEv = 0;
  double _evDragStartY = 0;

  /// Pinch-to-zoom (digital / center-crop) state. [_zoom] mirrors the live GL
  /// crop factor; the pill overlay is shown briefly while pinching.
  static const double _kMinZoom = 1.0;
  static const double _kMaxZoom = 4.0; // matches the settings-sheet crop range
  /// iPhone-style discrete zoom presets shown as a pill at the preview bottom.
  /// Range stops short of [_kMaxZoom] so pinch still has headroom past 2×.
  static const List<double> _kZoomSteps = [1.0, 2.0];
  double _zoom = 1.0;
  double _zoomStart = 1.0;
  bool _showZoom = false;
  bool _pinching = false; // ≥2 fingers down this gesture → zoom, not EV
  Timer? _zoomTimer;

  /// The 0x0F control session for this connection (BLE only P0). Only used
  /// to route inbound CAPTURE / SET_ZOOM into the same code paths used by the
  /// local shutter / pinch, and to push STATE_REPORT after local changes.
  RemoteControlSession? _remoteSession;

  /// Actual (camera-supported) size the native layer encoded at, reported on
  /// `started`. May differ from the requested resolution after snapping.
  int _actualW = 0;
  int _actualH = 0;

  /// Encoded-preview (encode→decode→display) state + its decoded texture.
  bool _encodedPreview = false;
  int _decodedTextureId = -1;
  int _decodedW = 0;
  int _decodedH = 0;

  /// Streaming (投屏) session over the selected transport. Frames encoded
  /// natively are forwarded here in order via a small bounded queue.
  StreamSession? _session;
  StreamSubscription<Uint8List>? _notifySub;

  /// WiFi projection: encoded frames go straight to the TCP client (framed with
  /// the 6-byte WiFi header — no L2 / credits / handshake). The client itself is
  /// owned by [WifiManager] and reused across runs.
  bool _wifiMode = false;
  TcpVideoClient? _wifiClient;

  final List<(Uint8List, bool)> _sendQueue = []; // (frame, isKey)
  bool _sending = false;
  bool _streaming = false; // this run projects (vs. record-only for H.264)
  int _chunkSize = 0; // transport per-KS_FRAME payload budget (for diagnostics)
  static const int _kMaxSendQueue = 6;

  /// Stats for frames actually transmitted (drops under backpressure excluded).
  int _sentFrames = 0;
  int _sentKeys = 0;
  int _sentBytes = 0;
  int _sentKeyBytes = 0; // key (I) frame bytes, for the H.264 I/P average
  final Stopwatch _sendClock = Stopwatch();

  /// Size of the latest frame (encoded, or transmitted while streaming), shown
  /// in the top-left info chip and refreshed on [_infoTimer].
  int _lastFrameBytes = 0;
  Timer? _infoTimer;

  /// ~1 Hz snapshots of cumulative frame accounting — (epochMs, frames, keys,
  /// bytes, keyBytes) — so the info-chip average can cover just a recent window
  /// (last 5 s, or one I-frame interval for H.264) instead of the whole run.
  final List<(int, int, int, int, int)> _frameSnaps = [];

  /// Rolling measurement of the *actual* transmitted rate + key-frame spacing,
  /// so we can confirm whether the run honours the configured fps / I-interval.
  int _tickFrames = 0; // _sentFrames at the previous 1s tick
  int _tickMs = 0; // _sendClock ms at the previous 1s tick
  int _lastKeyIndex = -1; // _sentFrames when the last key frame went out
  int _lastKeyMs = 0; // _sendClock ms when the last key frame went out

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _encoder
      ..onCamera = (info) {
        if (!mounted) return;
        setState(() {
          _camera = info;
          _facingFront = info.facingFront;
          _error = null;
          _ev = _ev.clamp(info.evMin, info.evMax);
        });
        _remoteSession?.reportSnapshot(
          recording: false,
          facing: _facingFront ? 1 : 0,
          zoom: _zoom,
          hasLastShot: _lastShot != null,
          lastShotId: 0,
        );
      }
      ..onStats = (stats) {
        if (!mounted) return;
        setState(() {
          _stats = stats;
          // While streaming, onFrame tracks the transmitted size (fresher);
          // otherwise use the native encoded last-frame size.
          if (!_streaming) _lastFrameBytes = stats.lastBytes;
        });
      }
      ..onStarted = (path, w, h) {
        if (!mounted) return;
        setState(() {
          _encoding = true;
          _result = null;
          _stats = const EncoderStats();
          _lastFrameBytes = 0;
          _frameSnaps.clear();
          _actualW = w;
          _actualH = h;
        });
        _startInfoTimer();
      }
      ..onStopped = (result) {
        _teardownSession();
        _stopInfoTimer();
        if (!mounted) return;
        setState(() {
          _encoding = false;
          _streaming = false;
          _lastFrameBytes = 0;
          _result = result;
        });
      }
      ..onError = (message) {
        _teardownSession();
        _stopInfoTimer();
        if (!mounted) return;
        setState(() {
          _error = message;
          _encoding = false;
          _streaming = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
      ..onInfo = (message) {
        if (!mounted || message.isEmpty) return;
        // Stash diagnostics silently; only rendered when the toggle is on.
        setState(() => _diag = message);
      }
      ..onPreview = (encoded, textureId, w, h) {
        if (!mounted) return;
        setState(() {
          _encodedPreview = encoded;
          _decodedTextureId = textureId;
          _decodedW = w;
          _decodedH = h;
        });
      }
      ..onFrame = _onEncodedFrame;

    _encoder.listen();
    _bootstrapCamera();

    // 挂 0x0F remote-control handler。CAPTURE 复用 _takePicture 的同一路径,
    // SET_ZOOM 走同一个 clamp + _persistConfig 路径,让本地 pinch 与远程指令看
    // 到同一份状态。
    final session = ref.read(remoteControlSessionProvider);
    _remoteSession = session;
    session.registerHandlers(
      capture: _handleRemoteCapture,
      zoom: _handleRemoteZoom,
    );
  }

  Future<void> _bootstrapCamera() async {
    // Restore the last-used encoding parameters, but always reset zoom to 1×
    // on entry — digital zoom is a per-session choice, not a preference. Users
    // start every screen fresh at full field of view.
    final saved = await EncoderConfigStore.load();
    if (mounted) {
      setState(() {
        _config = saved.copyWith(cropZoom: _kMinZoom);
        _zoom = _kMinZoom;
      });
    }

    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }
    if (mounted) setState(() => _permissionDenied = false);
    await _encoder.openCamera(_config, facingFront: _facingFront);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_permissionDenied && _camera == null) {
        _encoder.openCamera(_config, facingFront: _facingFront);
      }
    } else {
      // Releasing in the background also stops any in-flight encode natively.
      if (_encoding) _encoder.stopEncoding();
      _teardownSession();
      _stopInfoTimer();
      _encoder.closeCamera();
      if (mounted) {
        setState(() {
          _camera = null;
          _encoding = false;
          _streaming = false;
          _encodedPreview = false;
          _decodedTextureId = -1;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusTimer?.cancel();
    _zoomTimer?.cancel();
    _flashTimer?.cancel();
    _stopInfoTimer();
    _teardownSession();
    _encoder.dispose();
    _lastShot = null;
    _remoteSession?.registerHandlers(capture: null, zoom: null);
    _remoteSession = null;
    super.dispose();
  }

  Future<void> _openSettings() async {
    final updated = await EncoderSettingsSheet.show(context, _config);
    if (updated != null && mounted) {
      setState(() {
        _config = updated;
        _zoom = updated.cropZoom.clamp(_kMinZoom, _kMaxZoom);
      });
      // Push to the live preview and persist for next time.
      _encoder.setConfig(updated);
      _persistConfig(updated);
      _remoteSession?.reportZoom(_zoom);
    }
  }

  /// Persist encoder config without leaking the current digital-zoom factor —
  /// zoom is intentionally NOT remembered across page entries (see
  /// [_bootstrapCamera]). All three save sites (settings sheet, pinch end,
  /// discrete-step tap) funnel through here.
  void _persistConfig(EncoderConfig cfg) {
    EncoderConfigStore.save(cfg.copyWith(cropZoom: _kMinZoom));
  }

  /// The stream-protocol codec for a format (all three are now streamable).
  int _streamCodec(EncoderFormat f) => switch (f) {
        EncoderFormat.mvs1 => StreamCodec.msv1,
        EncoderFormat.jpeg => StreamCodec.jpeg,
        EncoderFormat.h264 => StreamCodec.h264,
      };

  /// Native encode dimensions (mirror the rounding done in [CameraEncoder]) so
  /// the KS_OPEN size matches the frames we forward.
  (int, int) _encDims(EncoderConfig c) {
    var w = c.width, h = c.height;
    if (c.format == EncoderFormat.mvs1) {
      w &= ~3;
      h &= ~3;
      if (w < 4) w = 4;
      if (h < 4) h = 4;
    } else {
      w &= ~1;
      h &= ~1;
    }
    return (w, h);
  }

  StreamTransport _transportFor(StreamTransportKind kind) => switch (kind) {
        StreamTransportKind.ble =>
          BleStreamTransport(ref.read(bleManagerProvider)),
        StreamTransportKind.wifi => WifiStreamTransport(),
      };

  /// Shutter: start/stop projection. MSV1/JPEG stream over the transport (and
  /// optionally record); H.264 is a file-recording test only.
  Future<void> _toggleProjection() async {
    if (_encoding) {
      _encoder.stopEncoding(); // onStopped tears the session down
      _session?.close();
      return;
    }
    setState(() {
      _result = null;
      _error = null;
    });

    // WiFi rides a plain framed TCP byte stream (no L2 handshake / credits);
    // route it through the dedicated path.
    if (_config.transport == StreamTransportKind.wifi) {
      await _startWifiProjection();
      return;
    }

    final codec = _streamCodec(_config.format);
    final transport = _transportFor(_config.transport);
    if (!transport.isAvailable) {
      if (_config.recordToFile) {
        _flash('未连接可投屏设备，仅本地录制');
        setState(() => _streaming = false);
        _encoder.startEncoding(_config, stream: false);
      } else {
        _flash(_config.transport == StreamTransportKind.wifi
            ? 'WiFi 投屏即将支持'
            : '未连接可投屏设备（需支持流服务 FFC4/FFC5）');
      }
      return;
    }

    // Open the session first so the initial key frame isn't dropped.
    _teardownSession();
    final session = StreamSession(
      send: transport.send,
      chunkSize: () => transport.chunkSize,
    );
    _session = session;
    _chunkSize = transport.chunkSize;
    _notifySub = transport.notifications.listen(session.onNotify);

    final (w, h) = _encDims(_config);
    final ok = await session.open(codec, w, h, _config.fps);
    if (!mounted) return;
    if (!ok) {
      _teardownSession();
      _flash('投屏握手失败或超时');
      return;
    }
    debugPrint('流/会话已开 codec=0x${codec.toRadixString(16)} ${w}x$h '
        'flowOn=${session.flowOn} 初始信用=${session.credits} chunk=$_chunkSize');

    _sendQueue.clear();
    _sending = false;
    _sentFrames = 0;
    _sentKeys = 0;
    _sentBytes = 0;
    _sentKeyBytes = 0;
    _tickFrames = 0;
    _tickMs = 0;
    _lastKeyIndex = -1;
    _lastKeyMs = 0;
    _sendClock
      ..reset()
      ..start();
    setState(() => _streaming = true);
    _encoder.startEncoding(_config, stream: true);
  }

  /// Begin a WiFi projection over the TCP video link established by the WiFi
  /// setup page. Unlike BLE, there is no session handshake — frames are wrapped
  /// with the 6-byte WiFi header and written straight to the socket.
  Future<void> _startWifiProjection() async {
    final wifi = ref.read(wifiManagerProvider);
    if (!wifi.isConnected) {
      if (_config.recordToFile) {
        _flash('WiFi 未连接，仅本地录制');
        setState(() => _streaming = false);
        _encoder.startEncoding(_config, stream: false);
      } else {
        _flash('WiFi 未连接：请先在「WiFi 配网」页完成连接');
      }
      return;
    }

    _teardownSession();
    _wifiMode = true;
    _wifiClient = wifi.client;
    _chunkSize = 0; // WiFi sends whole frames; no per-write chunk budget

    _sendQueue.clear();
    _sending = false;
    _sentFrames = 0;
    _sentKeys = 0;
    _sentBytes = 0;
    _sentKeyBytes = 0;
    _tickFrames = 0;
    _tickMs = 0;
    _lastKeyIndex = -1;
    _lastKeyMs = 0;
    _sendClock
      ..reset()
      ..start();
    setState(() => _streaming = true);
    debugPrint('流/WiFi 投屏开始 ${_config.format.label} '
        '${_config.width}x${_config.height}@${_config.fps} → '
        '${_wifiClient?.host}:${_wifiClient?.port}');
    _encoder.startEncoding(_config, stream: true);
  }

  /// Whether the active transport sink can accept a frame right now.
  bool get _sinkOpen => _wifiMode
      ? (_wifiClient?.isConnected ?? false)
      : (_session?.isOpen ?? false);

  /// Send one frame over the active transport (BLE session or WiFi TCP client).
  Future<bool> _sendOneFrame(Uint8List frame) {
    if (_wifiMode) {
      return _wifiClient?.sendFrame(frame) ?? Future<bool>.value(false);
    }
    return _session?.sendFrame(frame) ?? Future<bool>.value(false);
  }

  /// Forward one encoded frame in order, dropping the backlog and re-syncing
  /// with a fresh key frame when the transport can't keep up.
  void _onEncodedFrame(Uint8List data, bool key) {
    if (!_sinkOpen) return;
    final chunks = _chunkSize > 0 ? (data.length / _chunkSize).ceil() : -1;
    debugPrint('流/编码帧 ${key ? "I" : "P"} ${data.length}B · $chunks片 '
        '· 队列=${_sendQueue.length} 信用=${_session?.credits}');
    _lastFrameBytes = data.length; // shown (on a timer) in the info chip
    // H.264 production is paced natively (permit per transmitted frame) and must
    // never drop a P-frame — that breaks the chain. Only self-contained-ish
    // codecs (MSV1/JPEG) drop + re-sync under backpressure.
    if (_config.format != EncoderFormat.h264 &&
        _sendQueue.length >= _kMaxSendQueue) {
      _sendQueue.clear();
      _encoder.requestKeyframe();
    }
    _sendQueue.add((data, key));
    _pumpSend();
  }

  /// Refresh the info chip on a fixed cadence so the current frame size updates
  /// steadily regardless of frame rate.
  void _startInfoTimer() {
    _infoTimer?.cancel();
    _infoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_streaming && _sendClock.isRunning) {
        final nowMs = _sendClock.elapsedMilliseconds;
        final df = _sentFrames - _tickFrames;
        final dt = (nowMs - _tickMs) / 1000.0;
        if (dt > 0) {
          debugPrint('流/发送速率 ${(df / dt).toStringAsFixed(1)} fps '
              '(设定 ${_config.fps} fps)');
        }
        _tickFrames = _sentFrames;
        _tickMs = nowMs;
      }
      _snapshotFrameTotals();
      if (mounted) setState(() {});
    });
  }

  void _stopInfoTimer() {
    _infoTimer?.cancel();
    _infoTimer = null;
  }

  Future<void> _pumpSend() async {
    if (_sending) return;
    _sending = true;
    try {
      while (_sendQueue.isNotEmpty && _sinkOpen) {
        final (frame, isKey) = _sendQueue.removeAt(0);
        bool ok = false;
        try {
          ok = await _sendOneFrame(frame);
        } catch (_) {}
        if (ok) {
          _sentFrames++;
          _sentBytes += frame.length;
          if (isKey) {
            _sentKeys++;
            _sentKeyBytes += frame.length;
            final nowMs = _sendClock.elapsedMilliseconds;
            if (_lastKeyIndex >= 0) {
              final df = _sentFrames - _lastKeyIndex;
              final dt = (nowMs - _lastKeyMs) / 1000.0;
              debugPrint('流/关键帧间隔 $df 帧 / ${dt.toStringAsFixed(2)}s '
                  '(设定 I间隔=${_config.iFrameIntervalSec}s, fps=${_config.fps})');
            }
            _lastKeyIndex = _sentFrames;
            _lastKeyMs = nowMs;
          }
          debugPrint('流/已发 ${isKey ? "I" : "P"} ${frame.length}B '
              '· 累计=$_sentFrames 信用=${_session?.credits}');
          if (mounted) setState(() {}); // refresh the sent-frame stats
        } else {
          debugPrint('流/发送失败 ${frame.length}B · '
              'flowOn=${_session?.flowOn} credits=${_session?.credits}');
        }
        // H.264 is paced natively (one permit per frame). Replenish the permit
        // UNCONDITIONALLY — even on a failed send — so a single credit-wait
        // timeout or write hiccup can't permanently starve the encoder feed.
        // The periodic IDR re-syncs the device after any gap.
        if (_config.format == EncoderFormat.h264) {
          _encoder.requestEncoderFrame();
        }
      }
    } finally {
      _sending = false;
    }
  }

  void _teardownSession() {
    _notifySub?.cancel();
    _notifySub = null;
    _sendQueue.clear();
    _sending = false;
    _sendClock.stop();
    _session?.close();
    _session = null;
    // WiFi: the TCP client is owned by WifiManager and reused across runs — just
    // detach here (don't close the socket, so the next projection reuses it).
    _wifiMode = false;
    _wifiClient = null;
  }

  void _flash(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _flipCamera() async {
    if (_encoding) return;
    setState(() {
      _facingFront = !_facingFront;
      _camera = null;
      _ev = 0; // native resets exposure compensation on reopen
      _focusVisible = false;
      _encodedPreview = false; // native releases the decoded texture on reopen
      _decodedTextureId = -1;
    });
    await _encoder.openCamera(_config, facingFront: _facingFront);
    _remoteSession?.reportFacing(_facingFront ? 1 : 0);
    _remoteSession?.reportZoom(_kMinZoom);
  }

  /// A complete tap focuses (and meters) at [pos] within a [w]×[h] preview.
  void _setFocus(Offset pos, double w, double h) {
    final nx = (pos.dx / w).clamp(0.0, 1.0);
    final ny = (pos.dy / h).clamp(0.0, 1.0);
    _encoder.focusAt(nx, ny);
    _focusTimer?.cancel();
    setState(() {
      _focusPoint = pos;
      _focusVisible = true;
      _showEv = _camera?.evSupported ?? false;
      _focusSeq++;
    });
    _scheduleHide();
  }

  void _scheduleHide() {
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) {
        setState(() {
          _focusVisible = false;
          _showEv = false;
        });
      }
    });
  }

  /// One recognizer handles both gestures (Flutter forbids mixing scale with
  /// vertical-drag): a two-finger pinch zooms, a one-finger vertical scrub is an
  /// EV adjustment. Anchors both starting values on the first pointer down.
  void _onScaleStart(ScaleStartDetails d) {
    _zoomStart = _zoom;
    _pinching = d.pointerCount >= 2;
    _evDragStartEv = _ev;
    _evDragStartY = d.localFocalPoint.dy;
    _focusTimer?.cancel();
    if (_pinching) {
      _zoomTimer?.cancel();
      setState(() => _showZoom = true);
    } else if (_camera?.evSupported ?? false) {
      setState(() {
        if (!_focusVisible) _focusPoint = d.localFocalPoint;
        _showEv = true;
      });
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d, double previewHeight) {
    // A second finger arriving mid-gesture promotes this to a pinch for good.
    if (d.pointerCount >= 2) _pinching = true;

    if (_pinching) {
      final z = (_zoomStart * d.scale).clamp(_kMinZoom, _kMaxZoom).toDouble();
      _zoomTimer?.cancel();
      setState(() {
        _zoom = z;
        _showZoom = true;
      });
      _encoder.setZoom(z);
      return;
    }

    // One-finger vertical scrub → exposure compensation.
    final info = _camera;
    if (info == null || !info.evSupported) return;
    final range = info.evMax - info.evMin;
    final delta = _evDragStartY - d.localFocalPoint.dy; // up = brighter
    final ev = (_evDragStartEv + (delta / previewHeight) * range)
        .clamp(info.evMin, info.evMax);
    _focusTimer?.cancel(); // keep the overlay up while scrubbing
    setState(() => _ev = ev);
    _encoder.setEv(ev);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_pinching) {
      // Mirror the settled zoom into [_config] so live setConfig round-trips
      // see it; [_persistConfig] scrubs it back to 1× before persisting since
      // zoom is a per-session choice, not a saved preference.
      _config = _config.copyWith(cropZoom: _zoom);
      _persistConfig(_config);
      _remoteSession?.reportZoom(_zoom);
      _zoomTimer?.cancel();
      _zoomTimer = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _showZoom = false);
      });
    } else {
      _scheduleHide();
    }
    _pinching = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _buildPreview()),
                  // Encoding info chip — top-left of the preview.
                  Positioned(top: 10, left: 10, child: _buildInfoChip()),
                  // Diagnostic overlay — top of the preview, never overlaps the
                  // bottom controls and doesn't shift the preview layout.
                  if (_showDiag && _diag != null)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        color: Colors.black54,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: Text(
                          _diag!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
            iconSize: 20,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Center(
              child: _encoding ? _buildTopStatus() : _buildPreviewToggle(),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.bug_report_outlined,
              color: _showDiag ? _kAccent : Colors.white54,
            ),
            iconSize: 20,
            tooltip: '诊断信息',
            onPressed: () => setState(() => _showDiag = !_showDiag),
          ),
        ],
      ),
    );
  }

  /// Segmented 原画 / 编码 preview switch (encoded preview = encode→decode→show).
  Widget _buildPreviewToggle() {
    Widget seg(String text, bool selected, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? _kAccent : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg('原画', !_encodedPreview, () => _setEncodedPreview(false)),
          seg('编码', _encodedPreview, () => _setEncodedPreview(true)),
        ],
      ),
    );
  }

  void _setEncodedPreview(bool encoded) {
    // Optimistic; native confirms via onPreview (and may revert for H.264).
    setState(() => _encodedPreview = encoded);
    _encoder.setPreviewMode(encoded);
  }

  /// Short projection-channel tag shown first in the info chip.
  String _transportTag(EncoderConfig c) =>
      c.transport == StreamTransportKind.wifi ? 'WiFi' : 'BLE';

  /// Current cumulative frame accounting — (frames, keys, bytes, keyBytes) —
  /// from the active source: transmitted sums while streaming (matching the
  /// transmitted "当前帧"), otherwise the native encoded stats.
  (int, int, int, int) _frameTotals() => _streaming
      ? (_sentFrames, _sentKeys, _sentBytes, _sentKeyBytes)
      : (_stats.frames, _stats.keyframes, _stats.bytes, _stats.keyBytes);

  /// Record a timestamped snapshot of [_frameTotals] for the rolling-window
  /// average, dropping any older than the longest window we might report.
  void _snapshotFrameTotals() {
    final (frames, keys, bytes, keyBytes) = _frameTotals();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _frameSnaps.add((nowMs, frames, keys, bytes, keyBytes));
    const retainMs = 60 * 1000;
    while (_frameSnaps.length > 2 && nowMs - _frameSnaps.first.$1 > retainMs) {
      _frameSnaps.removeAt(0);
    }
  }

  /// Average frame size over a recent window for the info chip, or null before
  /// any frame lands in the window. The window is the last 5 s, or one I-frame
  /// interval for H.264 (so it tracks the current GOP rather than the whole
  /// run); it's measured as the delta of [_frameTotals] against a ~windowMs-old
  /// snapshot, falling back to the run start until the window fills. H.264 is
  /// split into average I-frame / P-frame; other formats report one average.
  String? _avgFrameText() {
    final isH264 = _config.format == EncoderFormat.h264;
    final windowMs = (isH264 ? _config.iFrameIntervalSec : 5) * 1000;
    final (frames, keys, bytes, keyBytes) = _frameTotals();
    // Baseline = newest snapshot at least windowMs old; if none is that old the
    // window hasn't filled yet, so measure from the run start (zeros).
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    int bFrames = 0, bKeys = 0, bBytes = 0, bKeyBytes = 0;
    for (final s in _frameSnaps) {
      if (nowMs - s.$1 < windowMs) break; // ordered old→new; rest are in-window
      bFrames = s.$2;
      bKeys = s.$3;
      bBytes = s.$4;
      bKeyBytes = s.$5;
    }
    final dFrames = frames - bFrames;
    if (dFrames <= 0) return null;
    final dKeys = keys - bKeys;
    final dBytes = bytes - bBytes;
    final dKeyBytes = keyBytes - bKeyBytes;
    if (isH264) {
      final dP = dFrames - dKeys;
      final parts = <String>[];
      if (dKeys > 0) parts.add('I ${_formatBytes(dKeyBytes ~/ dKeys)}');
      if (dP > 0) parts.add('P ${_formatBytes((dBytes - dKeyBytes) ~/ dP)}');
      return parts.isEmpty ? null : '平均 ${parts.join(' · ')}';
    }
    return '平均 ${_formatBytes(dBytes ~/ dFrames)}';
  }

  /// Compact info chip (channel · format · resolution · fps) pinned to the
  /// preview's top-left. Shows the actual encoded size while recording.
  Widget _buildInfoChip() {
    final c = _config;
    final w = _encoding && _actualW > 0 ? _actualW : c.width;
    final h = _encoding && _actualH > 0 ? _actualH : c.height;
    final showFrame = _encoding && _lastFrameBytes > 0;
    final avg = showFrame ? _avgFrameText() : null;
    final frameLine = avg == null
        ? '当前帧 ${_formatBytes(_lastFrameBytes)}'
        : '当前帧 ${_formatBytes(_lastFrameBytes)} · $avg';
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              // Projection channel first, then the encoding params — all on one
              // line, visible before transmission starts.
              '${_transportTag(c)} · ${c.format.label} · $w×$h · ${c.fps}fps',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (showFrame)
              Text(
                frameLine,
                style: const TextStyle(
                  color: _kAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Recording pill shown in the top bar while encoding.
  Widget _buildTopStatus() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: _kRec.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: _kRec,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _streaming ? '投屏中' : '录制中',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ── Preview ─────────────────────────────────────────────────────────────

  Widget _buildPreview() {
    if (_permissionDenied) {
      return _centerInfo(
        icon: Icons.no_photography_outlined,
        text: '相机权限被拒绝',
        action: TextButton.icon(
          onPressed: () => openAppSettings(),
          icon: const Icon(Icons.settings, color: _kAccent),
          label: const Text('前往设置', style: TextStyle(color: _kAccent)),
        ),
      );
    }

    final info = _camera;
    if (info == null || info.textureId < 0) {
      return _centerInfo(
        icon: Icons.videocam_outlined,
        text: '正在启动摄像头…',
        action: const SizedBox(
          width: 28,
          height: 28,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
        ),
      );
    }

    // Encoded preview: show the decode-round-trip texture (compression quality)
    // instead of the raw camera texture.
    if (_encodedPreview && _decodedTextureId >= 0) {
      final dw = _decodedW.toDouble();
      final dh = _decodedH.toDouble();
      final dAspect = (dw <= 0 || dh <= 0) ? 1.0 : dw / dh;
      return Center(
        child: AspectRatio(
          aspectRatio: dAspect,
          child: Texture(textureId: _decodedTextureId),
        ),
      );
    }

    // The GL stage bakes rotation/crop/scale into the preview texture, so it is
    // already upright at the output aspect ratio — render it directly.
    final w = info.previewWidth.toDouble();
    final h = info.previewHeight.toDouble();
    final aspect = (w <= 0 || h <= 0) ? 1.0 : w / h;

    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: LayoutBuilder(
          builder: (ctx, constraints) {
            final cw = constraints.maxWidth;
            final ch = constraints.maxHeight;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              // A complete tap focuses; the scale recognizer covers both a
              // two-finger pinch (zoom) and a one-finger vertical scrub (EV).
              onTapUp: info.focusSupported
                  ? (d) => _setFocus(d.localPosition, cw, ch)
                  : null,
              onScaleStart: _onScaleStart,
              onScaleUpdate: (d) => _onScaleUpdate(d, ch),
              onScaleEnd: _onScaleEnd,
              child: Stack(
                children: [
                  Positioned.fill(child: Texture(textureId: info.textureId)),
                  // Shutter flash overlay — camera-style visual feedback on
                  // capture. IgnorePointer so it never eats touches.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _flashOpacity,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        child: const ColoredBox(color: Colors.white),
                      ),
                    ),
                  ),
                  if ((_focusVisible || _showEv) && _focusPoint != null)
                    ..._buildFocusOverlay(info, cw),
                  if (_showZoom)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 16,
                      child: Center(child: _buildZoomPill()),
                    ),
                  // Discrete zoom-step pill, iPhone-camera style. Always
                  // visible at the bottom-center of the preview; the
                  // transient numeric pill floats above it while pinching.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 16,
                    child: Center(child: _buildZoomSteps()),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// The focus reticle (with shrink animation) plus, when EV is supported, a
  /// vertical EV indicator hugging the box's right (or left near the edge).
  List<Widget> _buildFocusOverlay(CameraInfo info, double cw) {
    const box = 70.0;
    final fp = _focusPoint!;
    final evOnLeft = fp.dx > cw - 120;
    final t = info.evSupported && info.evMax > info.evMin
        ? (_ev - info.evMin) / (info.evMax - info.evMin)
        : 0.5;

    return [
      // Animated shrinking reticle (only for a tap-triggered focus).
      if (_focusVisible)
        Positioned(
          left: fp.dx - box / 2,
          top: fp.dy - box / 2,
          child: TweenAnimationBuilder<double>(
            key: ValueKey(_focusSeq),
            tween: Tween(begin: 1.5, end: 1.0),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
            builder: (_, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: const _FocusReticle(),
          ),
        ),
      // EV indicator: track the same height as the box, sun thumb by EV value.
      if (_showEv && info.evSupported)
        Positioned(
          left: evOnLeft ? fp.dx - box / 2 - 34 : fp.dx + box / 2 + 8,
          top: fp.dy - box / 2,
          child: IgnorePointer(
            child: SizedBox(
              width: 26,
              height: box,
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  Container(width: 2, color: Colors.white38),
                  Positioned(
                    top: (1 - t) * (box - 22),
                    child: const Icon(
                      Icons.wb_sunny,
                      color: _kAccent,
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  /// iPhone-style zoom readout (e.g. "1.0×"), shown briefly while pinching.
  Widget _buildZoomPill() {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          '${_zoom.toStringAsFixed(1)}×',
          style: const TextStyle(
            color: _kAccent,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  /// Tap one of the discrete zoom-step buttons: jump [_zoom] to that step,
  /// push it to the native layer, persist for next launch, and briefly show
  /// the numeric readout pill so the change is confirmed.
  void _onZoomStepTap(double step) {
    final z = step.clamp(_kMinZoom, _kMaxZoom).toDouble();
    _zoomTimer?.cancel();
    setState(() {
      _zoom = z;
      _showZoom = true;
    });
    _encoder.setZoom(z);
    _config = _config.copyWith(cropZoom: z);
    _persistConfig(_config);
    _remoteSession?.reportZoom(z);
    _zoomTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showZoom = false);
    });
  }

  /// iPhone-camera-style discrete zoom pill — one small circle per preset in
  /// [_kZoomSteps]. The circle closest to the current [_zoom] is filled with
  /// the accent yellow (like the selected 1× lens on iOS); others are
  /// semi-transparent black chips.
  Widget _buildZoomSteps() {
    // "Selected" = the step nearest to the current zoom (within a small
    // tolerance so floating-point drift after pinch doesn't leave every step
    // unselected). Ties go to the smaller step.
    int selectedIdx = -1;
    double bestDelta = 0.05;
    for (var i = 0; i < _kZoomSteps.length; i++) {
      final d = (_zoom - _kZoomSteps[i]).abs();
      if (d < bestDelta) {
        bestDelta = d;
        selectedIdx = i;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _kZoomSteps.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _ZoomStepButton(
              step: _kZoomSteps[i],
              selected: i == selectedIdx,
              onTap: () => _onZoomStepTap(_kZoomSteps[i]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _centerInfo({
    required IconData icon,
    required String text,
    required Widget action,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.white38),
          const SizedBox(height: 16),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
          const SizedBox(height: 20),
          action,
        ],
      ),
    );
  }

  // ── Bottom bar ────────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(28, 14, 28, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStatusLine(),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _circleButton(
                    Icons.flip_camera_ios_outlined,
                    onTap: _flipCamera,
                    enabled: !_encoding,
                  ),
                  const SizedBox(width: 12),
                  _buildThumbnail(),
                ],
              ),
              _buildShutter(),
              _circleButton(
                Icons.tune,
                onTap: _openSettings,
                enabled: !_encoding,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// iOS-style record button: white ring with a white circle that morphs into a
  /// red rounded square while encoding. A hidden long-press (~800ms) triggers a
  /// single-shot JPEG capture — future 0x0F `CAPTURE` sub-commands from the
  /// device share the same [_takePicture] code path.
  Widget _buildShutter() {
    final ready = _camera != null;
    final ring = ready ? Colors.white : Colors.white38;
    return GestureDetector(
      onTap: ready ? _toggleProjection : null,
      onLongPress: ready ? _takePicture : null,
      child: Container(
        width: 74,
        height: 74,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: ring, width: 4),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: _encoding ? 30 : 58,
            height: _encoding ? 30 : 58,
            decoration: BoxDecoration(
              color: _encoding ? _kRec : ring,
              borderRadius: BorderRadius.circular(_encoding ? 8 : 40),
            ),
          ),
        ),
      ),
    );
  }

  Widget _circleButton(
    IconData icon, {
    required VoidCallback onTap,
    required bool enabled,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.12),
        ),
        child: Icon(
          icon,
          size: 24,
          color: enabled ? Colors.white : Colors.white38,
        ),
      ),
    );
  }

  /// iPhone-camera-style thumbnail button next to the flip control. Shows the
  /// most recent [_lastShot] JPEG, or a dimmed placeholder when nothing has
  /// been captured yet. Tapping opens the full-screen preview.
  Widget _buildThumbnail() {
    final shot = _lastShot;
    final enabled = shot != null;
    return GestureDetector(
      onTap: enabled ? _openLastShotPreview : null,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: Colors.white.withValues(alpha: 0.12),
          border: Border.all(
            color: Colors.white.withValues(alpha: enabled ? 0.6 : 0.2),
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: shot != null
            ? Image.memory(shot, fit: BoxFit.cover, gaplessPlayback: true)
            : const Icon(
                Icons.photo_outlined,
                size: 22,
                color: Colors.white38,
              ),
      ),
    );
  }

  /// Remote CAPTURE (device → app): mirror the shutter long-press path,
  /// return the freshly allocated shot id on success.
  Future<int?> _handleRemoteCapture() async {
    final session = _remoteSession;
    if (session == null || !mounted) return null;
    final id = session.allocateShotId();
    // 先跑本地拍照(包含 flash + _lastShot 更新),再让 session 发 STATE_REPORT。
    await _takePicture();
    if (!mounted || _lastShot == null) return null;
    session.reportCaptureDone(id);
    return id;
  }

  /// Remote SET_ZOOM (device → app): reuse the preset-button code path,
  /// return false if the value falls outside the clamp range.
  Future<bool> _handleRemoteZoom(double zoom) async {
    if (!mounted) return false;
    if (zoom < _kMinZoom - 0.001 || zoom > _kMaxZoom + 0.001) return false;
    final clamped = zoom.clamp(_kMinZoom, _kMaxZoom).toDouble();
    _zoomTimer?.cancel();
    setState(() {
      _zoom = clamped;
      _showZoom = true;
    });
    _encoder.setZoom(clamped);
    _config = _config.copyWith(cropZoom: clamped);
    _persistConfig(_config);
    _zoomTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showZoom = false);
    });
    _remoteSession?.reportZoom(clamped);
    return true;
  }

  /// Take a single JPEG snapshot of the current GL frame and stash it in
  /// [_lastShot]. Shared entry point for the shutter long-press (dev entry)
  /// and — later — the 0x0F `CAPTURE` sub-command dispatched from the device.
  Future<void> _takePicture() async {
    if (_capturing) return;
    setState(() => _capturing = true);
    _flashCapture();
    try {
      final bytes = await _encoder.takePicture();
      if (!mounted) return;
      if (bytes != null && bytes.isNotEmpty) {
        setState(() => _lastShot = bytes);
      } else {
        setState(() => _error = '拍照失败');
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// Camera-style shutter flash: snap the overlay to full-opacity white, then
  /// let [AnimatedOpacity] fade it back out. Timer resets any in-flight fade
  /// so back-to-back captures still flash cleanly.
  void _flashCapture() {
    _flashTimer?.cancel();
    setState(() => _flashOpacity = 1.0);
    // First tick after the frame renders the opaque overlay, then trigger the
    // fade — without the delay the AnimatedOpacity's transition target would
    // change in the same build and the tween wouldn't run.
    _flashTimer = Timer(const Duration(milliseconds: 60), () {
      if (!mounted) return;
      setState(() => _flashOpacity = 0);
    });
  }

  void _openLastShotPreview() {
    final shot = _lastShot;
    if (shot == null) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => _LastShotViewer(bytes: shot),
      ),
    );
  }

  Widget _buildStatusLine() {
    if (_encoding) {
      // While projecting, report frames actually sent (not merely encoded).
      if (_streaming) {
        final secs = _sendClock.elapsedMilliseconds / 1000.0;
        final fps = secs > 0 ? _sentFrames / secs : 0.0;
        return Text(
          '${_config.transport.label}投屏 · ${fps.toStringAsFixed(1)} fps · '
          '已发送 $_sentFrames 帧 · I:$_sentKeys · ${_formatBytes(_sentBytes)}',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
          textAlign: TextAlign.center,
        );
      }
      return Text(
        '${_stats.fps.toStringAsFixed(1)} fps · ${_stats.frames} 帧 · '
        'I:${_stats.keyframes} · ${_formatBytes(_stats.bytes)}',
        style: const TextStyle(color: Colors.white70, fontSize: 13),
        textAlign: TextAlign.center,
      );
    }

    final r = _result;
    if (r != null) {
      final saved = r.path != null;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            saved
                ? '已保存 · ${r.frames} 帧 (I帧 ${r.keyframes}) · ${_formatBytes(r.bytes)}'
                : '投屏结束 · 已发送 $_sentFrames 帧 · ${_formatBytes(_sentBytes)}',
            style: const TextStyle(
              color: _kDone,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          if (saved) ...[
            const SizedBox(height: 3),
            Text(
              r.path!,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      );
    }

    return Text(
      _error ?? '点击快门开始投屏',
      style: TextStyle(
        color: _error != null ? _kRec : Colors.white54,
        fontSize: 13,
      ),
      textAlign: TextAlign.center,
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

/// Yellow tap-to-focus reticle (iOS-style square) shown briefly at the tap.
class _FocusReticle extends StatelessWidget {
  const _FocusReticle();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: 70,
        height: 70,
        decoration: BoxDecoration(
          border: Border.all(color: _kAccent, width: 1.5),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

/// One step in the iPhone-style discrete zoom pill. Selected = accent-yellow
/// filled circle with a smaller black `1×` label; unselected = compact chip
/// with the label expressed as `1` (no ×) so the row stays visually tight,
/// matching the iOS Camera lens picker.
class _ZoomStepButton extends StatelessWidget {
  final double step;
  final bool selected;
  final VoidCallback onTap;

  const _ZoomStepButton({
    required this.step,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Integer steps show as "1" / "2" / "3"; keep a decimal for other values
    // (future-proofing if a 0.5× lens is ever added).
    final label = step == step.roundToDouble()
        ? step.toInt().toString()
        : step.toStringAsFixed(1);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: selected ? 34 : 28,
        height: selected ? 34 : 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? _kAccent : Colors.white.withValues(alpha: 0.14),
        ),
        child: Text(
          selected ? '$label×' : label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontSize: selected ? 12 : 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// Full-screen preview for the most recent [_lastShot] — iPhone-camera style:
/// black background, centered image with pinch/pan via [InteractiveViewer],
/// close button in the top-right.
class _LastShotViewer extends StatelessWidget {
  const _LastShotViewer({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1.0,
                maxScale: 5.0,
                child: Center(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: Material(
                color: Colors.white.withValues(alpha: 0.15),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(context).pop(),
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(Icons.close, color: Colors.white, size: 22),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
