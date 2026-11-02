import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../providers/transfer_provider.dart';
import '../../services/converter.dart';
import '../../services/media_task_gate.dart';
import 'video_example_thumbnail.dart';
import 'video_thumbnail_policy.dart';
import '../../services/video_preview_player.dart';
import '../../services/raster.dart';
import '../../services/resource_pack.dart';
import '../../services/l2_file_transfer.dart';
import '../../services/file_cache.dart';
import '../shared/cache_ui.dart';
import '../shared/color_picker_dialog.dart';
import '../shared/example_assets.dart';
import '../shared/file_send_layout.dart';
import '../shared/preview_frame.dart';
import '../shared/thumbnail_export.dart';

/// Page for converting a picked video **or GIF** to a device-playable
/// AVI(CVID) and sending it over BLE. Flow: pick (mp4/mov or GIF) → frame the
/// first frame in a fixed circular pinch-zoom viewport matching the round
/// 360×360 screen (whatever is framed is encoded; outside-frame area =
/// background) → size 240/360/480 → fps 10/15/20/24 → quality LOW/MED/HIGH →
/// background color (the letterbox fill, and the fill under transparent GIF
/// pixels) → convert (native Cinepak) → send TYPE.video. The preview also
/// offers play/pause/stop to preview the clip's motion before converting:
/// real videos play the original via a native MediaPlayer texture, GIFs cycle a
/// few extracted frames — both inside the same circular framing viewport.
class VideoPage extends ConsumerStatefulWidget {
  final String deviceName;
  final String deviceId;

  const VideoPage({
    super.key,
    required this.deviceName,
    required this.deviceId,
  });

  @override
  ConsumerState<VideoPage> createState() => _VideoPageState();
}

const List<int> _sizePresets = [240, 360, 466, 480];
const List<int> _fpsPresets = [10, 15, 20, 24];
const List<(String, int)> _qualityPresets = [
  ('LOW', 15),
  ('MED', 60),
  ('HIGH', 95)
];

// Background colors for transparent GIFs (opaque ARGB). Black first (default,
// matches the miniprogram), then white and a few accents.
const List<int> _bgColors = [
  0xFF000000,
  0xFFFFFFFF,
  0xFFFF3B30,
  0xFF34C759,
  0xFF007AFF,
  0xFFFFCC00,
];

const double _previewMaxHRatio =
    0.5; // circular viewport max height = 50% screen

enum _ConvStatus { idle, converting, ready, error }

// Motion-preview transport state for the in-page player.
enum _PlayState { stopped, playing, paused }

class _VideoPageState extends ConsumerState<VideoPage> {
  final _picker = ImagePicker();
  final _converter = ConverterService();
  final _mediaGate = MediaTaskGate();
  int _mediaLoadSeq = 0;
  VideoThumbnailFailureKind? _thumbnailFailure;

  // Captured while mounted so dispose() never touches `ref` (see initState).
  late final TransferProgressNotifier _transfer;

  String? _selectedName;
  String? _srcPath;
  String _fileName = 'video.avi';
  int _sourceSize = 0;

  // First-frame preview base (source-frame pixel dims in _srcW/_srcH).
  ui.Image? _thumb;
  int _srcW = 0;
  int _srcH = 0;
  bool _isGif =
      false; // GIF source → preview via extracted frames, not MediaPlayer

  // Conversion options.
  int _size = 360;
  int _fps = 10;
  int _quality = 60;
  int _bgColor = 0xFF000000; // GIF transparent bg + viewport letterbox fill
  // Preview-only: fills the square corners outside the circle, extracted from
  // the first frame via Palette. Never affects the converted resource.
  Color? _previewBg;
  // Debounces the (background) preview-color extraction so it runs only after
  // the user stops pinch-zooming / panning, not on every interaction-end.
  final _bgDebounce = Debouncer(const Duration(milliseconds: 350));

  // Pinch-zoom viewport crop (mirrors the image page): the fixed square frame
  // maps to the full output — whatever is framed is what gets encoded. On load
  // the whole first frame fits (contain); pinch-zoom / pan reframes it.
  final TransformationController _tc = TransformationController();
  double _vp = 0; // square viewport side in px (set during layout)
  int _viewportPointers = 0; // >0 → freeze page scroll while framing

  // Conversion result / state.
  Uint8List? _avi;
  int _binSize = 0;
  int _frameCount = 0;
  double _convProgress = 0;
  _ConvStatus _conv = _ConvStatus.idle;
  String? _convError;
  int _rebuildSeq = 0;
  // Guards the async thumbnail/package build in _send against re-entrant taps.
  bool _packaging = false;

  // Cache mode: when a cached AVI is loaded, the picker/convert UI is replaced
  // by a read-only panel and the send button re-sends the cached bytes as-is.
  CacheEntry? _cacheEntry;
  Uint8List? _cacheBytes;
  bool get _cacheMode => _cacheEntry != null;

  // Motion preview. Real videos play the original through [_player] (native
  // MediaPlayer → Flutter texture). GIFs (which MediaPlayer can't play) fall
  // back to a short set of downscaled frames cycled by [_playTimer]. Both are
  // lazily initialised on first Play. [_loadingFrames] covers either warm-up.
  final NativeVideoPlayer _player = NativeVideoPlayer();
  List<ui.Image>? _frames;
  int _frameIdx = 0;
  int _frameIntervalMs = 100;
  _PlayState _play = _PlayState.stopped;
  bool _loadingFrames = false;
  Timer? _playTimer;

  // Playback clock for the preview's bottom-left time label (current / total).
  // While playing it's sampled: real videos read MediaPlayer.currentPosition,
  // GIFs derive it from the cycling frame index.
  final ValueNotifier<int> _positionMs = ValueNotifier<int>(0);
  Timer? _posTimer;

  @override
  void initState() {
    super.initState();
    // Capture the notifier while the element is still mounted. Using `ref`
    // inside dispose() throws (the element is already defunct there), which
    // would abort ConsumerStatefulElement.unmount() before it closes this
    // page's provider subscription — leaking a defunct listener that then
    // crashes on the next state write (markNeedsBuild on a defunct element).
    _transfer = ref.read(transferProgressProvider.notifier);
  }

  @override
  void dispose() {
    // Stop any in-flight send and clear stale status so re-entering starts
    // clean, via the captured notifier (never `ref` here). resetForDispose
    // defers the actual state write to a microtask so it lands after unmount
    // has closed this element's own subscription.
    _transfer.resetForDispose();
    _rebuildSeq++;
    _mediaLoadSeq++;
    _mediaGate.dispose();
    _converter.cancel();
    _playTimer?.cancel();
    _posTimer?.cancel();
    _disposeFrames();
    unawaited(_player.dispose()); // release native player + texture
    _tc.dispose();
    _thumb?.dispose();
    _bgDebounce.dispose();
    _positionMs.dispose();
    super.dispose();
  }

  bool get _sending =>
      ref.read(transferProgressProvider).status == TransferStatus.sending;

  bool get _isBusy => _conv == _ConvStatus.converting || _sending;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Pick source (video or GIF) ─────────────────────────────────────────────
  Future<void> _showPickSheet() async {
    if (_isBusy) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('视频 (mp4 / mov)'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.gif_box_outlined),
              title: const Text('GIF 动图'),
              onTap: () => Navigator.pop(ctx, 'gif'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'video') {
      await _pickVideo();
    } else if (choice == 'gif') {
      await _pickGif();
    }
  }

  Future<void> _pickVideo() async {
    try {
      final video = await _picker.pickVideo(source: ImageSource.gallery);
      if (video == null) return;
      final len = await File(video.path).length();
      await _loadMedia(
        path: video.path,
        name: video.name,
        size: len,
        isGifSource: false,
      );
    } catch (e) {
      _snack('选择视频失败: $e');
    }
  }

  Future<void> _pickGif() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gif'],
      );
      if (result == null || result.files.isEmpty) return;
      final f = result.files.first;
      final path = f.path;
      if (path == null) {
        _snack('无法读取文件路径');
        return;
      }
      // Verify the GIF magic — album pickers can hand back a static image.
      final raf = await File(path).open();
      Uint8List head;
      try {
        head = await raf.read(3);
      } finally {
        await raf.close();
      }
      final ok = head.length >= 3 &&
          head[0] == 0x47 &&
          head[1] == 0x49 &&
          head[2] == 0x46;
      if (!ok) {
        _snack('这不是 GIF 动图（可能已被转为静态图）');
        return;
      }
      await _loadMedia(
        path: path,
        name: f.name,
        size: f.size,
        isGifSource: true,
      );
    } catch (e) {
      _snack('选择 GIF 失败: $e');
    }
  }

  // Shared: load the crop-preview thumbnail and reset all state for a new pick.
  Future<void> _loadMedia({
    required String path,
    required String name,
    required int size,
    required bool isGifSource,
  }) async {
    final loadToken = ++_mediaLoadSeq;
    ui.Image? thumb;
    int tw = 0;
    int th = 0;
    bool? decodedIsGif;
    VideoThumbnailFailureKind? thumbnailFailure;
    try {
      final t = await _mediaGate.run(
        () => _converter.getVideoThumbnail(path),
        priority: MediaTaskPriority.interactive,
        shouldStart: () => mounted && loadToken == _mediaLoadSeq,
      );
      decodedIsGif = t.isGif;
      thumb = await decodeUiImage(t.bytes);
      tw = t.width;
      th = t.height;
    } on PlatformException catch (error) {
      thumbnailFailure = classifyVideoThumbnailFailure(error);
    } catch (error) {
      thumbnailFailure = classifyVideoThumbnailFailure(error);
    }
    final isGif = resolveVideoSourceIsGif(
      knownGif: isGifSource,
      decodedIsGif: decodedIsGif,
    );

    if (!mounted || loadToken != _mediaLoadSeq) {
      thumb?.dispose();
      return;
    }

    _stopPlayback();
    _disposeFrames(); // old clip's frames no longer match the new source
    await _player.dispose(); // release the previous source's video player
    if (!mounted || loadToken != _mediaLoadSeq) {
      thumb?.dispose();
      return;
    }
    final base =
        name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;

    _thumb?.dispose();
    setState(() {
      _selectedName = name;
      _srcPath = path;
      _sourceSize = size;
      _fileName = '$base.avi';
      _thumb = thumb;
      _srcW = tw;
      _srcH = th;
      _isGif = isGif;
      _thumbnailFailure = thumbnailFailure;
      _avi = null;
      _binSize = 0;
      _frameCount = 0;
      _convProgress = 0;
      _conv = _ConvStatus.idle;
      _convError = null;
      _loadingFrames = false;
      _tc.value = Matrix4.identity(); // reset zoom/pan to contain-fit
    });
    ref.read(transferProgressProvider.notifier).reset();
    _extractPreviewBg();
  }

  // Derive the preview's outside-circle fill from the first frame (Palette).
  // Preview-only — does not touch _bgColor or the conversion pipeline.
  Future<void> _extractPreviewBg() async {
    // Never compute while a finger is on the preview (pan/scale in progress);
    // it resumes after the gesture ends via the debounced onInteractionEnd.
    if (_viewportPointers > 0) return;
    final image = _thumb;
    if (image == null) {
      if (mounted && _previewBg != null) setState(() => _previewBg = null);
      return;
    }
    final region = framedSourceRect(_vp, _srcW, _srcH, _tc.value);
    final color = await extractPreviewBg(image, region: region);
    if (!mounted || _thumb != image) return;
    setState(() => _previewBg = color);
  }

  // ── Convert ────────────────────────────────────────────────────────────────
  // Normalized source rect (relative to the source frame) that the square
  // viewport currently frames, derived from the pinch-zoom transform. Inverts
  // the image page's `output = src*scale + t` mapping, so nx/ny may be negative
  // and nw/nh may exceed 1 (letterbox); the native side fills outside the frame
  // with the background. Returns null when there's no preview to frame.
  CropN? _cropForConvert() {
    if (_thumb == null || _vp <= 0 || _srcW <= 0 || _srcH <= 0) return null;
    final double v = _vp;
    final double s0 = min(v / _srcW, v / _srcH); // contain scale in v×v box
    final double lx = (v - _srcW * s0) / 2;
    final double ly = (v - _srcH * s0) / 2;
    final m = _tc.value;
    final double k = m.getMaxScaleOnAxis();
    final double denom = k * s0;
    if (denom <= 0) return null;
    final double mtx = m.storage[12];
    final double mty = m.storage[13];
    return (
      nx: -(k * lx + mtx) / (denom * _srcW),
      ny: -(k * ly + mty) / (denom * _srcH),
      nw: v / (denom * _srcW),
      nh: v / (denom * _srcH),
    );
  }

  Future<void> _convert() async {
    final path = _srcPath;
    if (path == null || _isBusy) return;
    _stopPlayback(); // halt the motion preview while converting
    final int token = ++_rebuildSeq;
    setState(() {
      _conv = _ConvStatus.converting;
      _convProgress = 0;
      _binSize = 0;
      _frameCount = 0;
      _convError = null;
      _avi = null;
    });
    try {
      final res = await _mediaGate.run(
        () => _converter.convertVideo(
          path: path,
          width: _size,
          height: _size,
          fps: _fps,
          quality: _quality,
          cropMode: 'cover', // only used as the no-preview fallback
          crop: _cropForConvert(),
          bgColor: _bgColor,
          onProgress: (done, total) {
            if (token != _rebuildSeq || !mounted) return;
            setState(() {
              _convProgress = total > 0 ? (done / total).clamp(0.0, 0.99) : 0;
              _frameCount = done;
            });
          },
        ),
        priority: MediaTaskPriority.interactive,
        shouldStart: () => mounted && token == _rebuildSeq,
      );
      if (token != _rebuildSeq || !mounted) return;
      setState(() {
        _avi = res.avi;
        _binSize = res.avi.length;
        _frameCount = res.frameCount;
        _convProgress = 1;
        _conv = _ConvStatus.ready;
      });
    } on PlatformException catch (e) {
      if (token != _rebuildSeq || !mounted) return;
      if (e.code == 'cancelled') {
        setState(() => _conv = _ConvStatus.idle);
        return;
      }
      setState(() {
        _conv = _ConvStatus.error;
        _convError = e.message ?? '转换失败';
      });
    } catch (e) {
      if (token != _rebuildSeq || !mounted) return;
      setState(() {
        _conv = _ConvStatus.error;
        _convError = '$e';
      });
    }
  }

  void _cancelConvert() {
    _rebuildSeq++;
    _converter.cancel();
    setState(() {
      _conv = _ConvStatus.idle;
      _convProgress = 0;
    });
  }

  // Any option/crop change drops the converted result back to "needs convert".
  void _invalidate() {
    if (_avi == null && _conv == _ConvStatus.idle && _convError == null) return;
    _rebuildSeq++;
    setState(() {
      _avi = null;
      _binSize = 0;
      _frameCount = 0;
      _convProgress = 0;
      _convError = null;
      _conv = _ConvStatus.idle;
    });
  }

  void _onSizeTap(int s) {
    if (_isBusy || s == _size) return;
    setState(() => _size = s);
    _invalidate();
  }

  void _onFpsTap(int f) {
    if (_isBusy || f == _fps) return;
    setState(() => _fps = f);
    _invalidate();
  }

  void _onQualityTap(int q) {
    if (_isBusy || q == _quality) return;
    setState(() => _quality = q);
    _invalidate();
  }

  void _onBgTap(int c) {
    if (_isBusy || c == _bgColor) return;
    setState(() => _bgColor = c);
    _invalidate();
  }

  void _onResetView() {
    if (_isBusy) return;
    _tc.value = Matrix4.identity();
    _invalidate();
  }

  // ── Send ───────────────────────────────────────────────────────────────────
  // Wrap the converted AVI + a thumbnail into a resource package: resource[0] is
  // the AVI(CVID), resource[1] a 160 circular ARGB8565 thumbnail of the framed
  // first frame (the first frame rendered through the same viewport transform
  // the native converter applied). The device reads the kind from the package
  // header's type (ResourceType.video); TYPE.video stays as the transport tag.
  Future<void> _send() async {
    final avi = _avi;
    final thumbSrc = _thumb;
    if (avi == null ||
        thumbSrc == null ||
        _conv != _ConvStatus.ready ||
        _sending ||
        _packaging ||
        _vp <= 0 ||
        _srcW <= 0 ||
        _srcH <= 0) {
      return;
    }
    _packaging = true;
    try {
      // Reproduce the converter's framing of the first frame (mirrors the image
      // page's src→output affine map) into a _size² RGBA, then a round thumbnail.
      final double v = _vp;
      final double s0 = min(v / _srcW, v / _srcH);
      final double lx = (v - _srcW * s0) / 2;
      final double ly = (v - _srcH * s0) / 2;
      final m = _tc.value;
      final double k = m.getMaxScaleOnAxis();
      final double f = _size / v;
      final ui.Image content = await renderViewportImage(
        thumbSrc,
        outSize: _size,
        scale: k * s0 * f,
        tx: (k * lx + m.storage[12]) * f,
        ty: (k * ly + m.storage[13]) * f,
        bgColor: _bgColor,
      );
      final Uint8List thumb;
      try {
        thumb = await generateThumbnailArgb8565Bin(content);
      } finally {
        content.dispose();
      }
      if (!mounted) return;
      // Header bg = the colour that fills the preview area outside the circle
      // (extracted from the first frame); fall back to the chosen background.
      final int bgArgb = _previewBg?.toARGB32() ?? _bgColor;
      final Uint8List pkg = buildResourcePack(
        type: ResourceType.video,
        bgColor: bgArgb,
        resources: [avi],
        thumbnail: thumb,
      );
      ref.read(transferProgressProvider.notifier).send(
            TYPE.video,
            pkg,
            _fileName,
            cache: CacheSpec(CacheKind.video, {
              'src':
                  _isGif ? 'gif' : 'video', // distinguishes GIF/视频/轮播 in cache
              'size': '$_size',
              'fps': '$_fps',
              'q': '$_quality',
              'frames': '$_frameCount',
            }),
          );
    } catch (e) {
      _snack('打包失败: $e');
    } finally {
      _packaging = false;
    }
  }

  // ── Export thumbnail ─────────────────────────────────────────────────────
  // Save just the first-frame badge (the converted circular ARGB8565 thumbnail,
  // resource[1]) to a user-picked file. Same framing math as _send, but it
  // needs only the first frame + viewport — so it works before/without encoding
  // the AVI. The filename carries the header/bg colour as a hex suffix.
  Future<void> _exportThumbnail() async {
    final thumbSrc = _thumb;
    if (thumbSrc == null ||
        _vp <= 0 ||
        _srcW <= 0 ||
        _srcH <= 0 ||
        _isBusy ||
        _packaging) {
      return;
    }
    _packaging = true; // reuse the re-entrancy guard
    try {
      final double v = _vp;
      final double s0 = min(v / _srcW, v / _srcH);
      final double lx = (v - _srcW * s0) / 2;
      final double ly = (v - _srcH * s0) / 2;
      final m = _tc.value;
      final double k = m.getMaxScaleOnAxis();
      final double f = _size / v;
      final ui.Image content = await renderViewportImage(
        thumbSrc,
        outSize: _size,
        scale: k * s0 * f,
        tx: (k * lx + m.storage[12]) * f,
        ty: (k * ly + m.storage[13]) * f,
        bgColor: _bgColor,
      );
      final int bgArgb = _previewBg?.toARGB32() ?? _bgColor;
      final Uint8List thumb;
      try {
        thumb = await generateThumbnailArgb8565Bin(content);
      } finally {
        content.dispose();
      }
      if (!mounted) return;
      await exportThumbnailBin(
        context,
        bin: thumb,
        sourceName: _fileName,
        bgColor: bgArgb,
      );
    } catch (e) {
      _snack('导出失败: $e');
    } finally {
      _packaging = false;
    }
  }

  // ── Cache load / send ────────────────────────────────────────────────────
  Future<void> _loadCache() async {
    if (_isBusy) return;
    // Show 视频/GIF caches only; carousels (src=slideshow) live on their own page.
    final entry = await showCachePicker(
      context,
      CacheKind.video,
      where: (e) => e.params['src'] != 'slideshow',
    );
    if (entry == null || !mounted) return;
    try {
      final bytes = await entry.file.readAsBytes();
      if (!mounted) return;
      _stopPlayback(); // halt any motion preview before swapping to the panel
      setState(() {
        _cacheEntry = entry;
        _cacheBytes = bytes;
      });
      ref.read(transferProgressProvider.notifier).reset();
    } catch (e) {
      _snack('读取缓存失败: $e');
    }
  }

  void _clearCache() {
    setState(() {
      _cacheEntry = null;
      _cacheBytes = null;
    });
  }

  // Re-send the loaded cache bytes unchanged; no cache: arg so it isn't re-cached.
  // The cache holds the whole resource package (or a legacy bare AVI); either way
  // resend it verbatim — no trailing byte, no repackaging.
  void _sendCache() {
    final bytes = _cacheBytes;
    final entry = _cacheEntry;
    if (bytes == null || entry == null || _sending) return;
    ref.read(transferProgressProvider.notifier).send(
          entry.kind.fileType,
          bytes,
          entry.kind.deviceName,
        );
  }

  // ── Motion preview (play / pause / stop) ────────────────────────────────────
  // Lazily fetch a short set of downscaled frames for the current source. Frames
  // are tied to the source path (not the crop) — the framing transform is
  // applied live on top when they're displayed, so they stay valid while reframing.
  // Video: create the native MediaPlayer texture for the current source (lazy,
  // on first Play). Completes when the first frame is renderable.
  Future<void> _ensurePlayer() async {
    if (_player.isReady || _loadingFrames) return;
    final path = _srcPath;
    if (path == null) return;
    setState(() => _loadingFrames = true);
    try {
      await _player.open(path);
      if (!mounted || _srcPath != path) {
        await _player.dispose();
        if (mounted) setState(() => _loadingFrames = false);
        return;
      }
      setState(() => _loadingFrames = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingFrames = false);
      _snack('预览播放失败: $e');
    }
  }

  Future<void> _ensureFrames() async {
    if (_frames != null || _loadingFrames) return;
    final path = _srcPath;
    if (path == null) return;
    setState(() => _loadingFrames = true);
    try {
      final preview = await _mediaGate.run(
        () => _converter.getVideoFrames(path),
        priority: MediaTaskPriority.interactive,
        shouldStart: () => mounted && _srcPath == path,
      );
      final imgs = <ui.Image>[];
      for (final png in preview.frames) {
        imgs.add(await decodeUiImage(png));
      }
      if (!mounted || _srcPath != path) {
        for (final im in imgs) {
          im.dispose();
        }
        if (mounted) setState(() => _loadingFrames = false);
        return;
      }
      setState(() {
        _frames = imgs;
        _frameIntervalMs = preview.intervalMs;
        _loadingFrames = false;
      });
    } on MediaTaskCancelled {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingFrames = false);
      _snack('预览播放失败: $e');
    }
  }

  void _startTimer() {
    _playTimer?.cancel();
    final frames = _frames;
    if (frames == null || frames.isEmpty) return;
    _playTimer = Timer.periodic(
      Duration(milliseconds: _frameIntervalMs.clamp(30, 500)),
      (_) {
        if (!mounted) return;
        setState(() => _frameIdx = (_frameIdx + 1) % frames.length);
      },
    );
  }

  // Drive the current-position clock while playing. Real videos poll the native
  // player; GIFs derive position from the cycling frame index. 250ms is plenty
  // for an mm:ss readout and keeps the channel traffic light.
  void _startPosTimer() {
    _posTimer?.cancel();
    _posTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (!mounted) return;
      if (_isGif) {
        final frames = _frames;
        if (frames != null && frames.isNotEmpty) {
          _positionMs.value = (_frameIdx % frames.length) * _frameIntervalMs;
        }
      } else if (_player.isReady) {
        final pos = await _player.position();
        if (!mounted) return;
        _positionMs.value = pos;
      }
    });
  }

  Future<void> _onPlayPause() async {
    if (_conv == _ConvStatus.converting) return;
    if (_isGif) {
      // GIF: cycle extracted frames (Flutter exposes no GIF frame control).
      if (_play == _PlayState.playing) {
        _playTimer?.cancel();
        _posTimer?.cancel();
        setState(() => _play = _PlayState.paused);
        return;
      }
      if (_frames == null) {
        await _ensureFrames();
        if (!mounted || _frames == null) return;
      }
      setState(() => _play = _PlayState.playing);
      _startTimer();
      _startPosTimer();
      return;
    }
    // Video: play the original through the native texture player.
    if (_play == _PlayState.playing) {
      await _player.pause();
      if (!mounted) return;
      _posTimer?.cancel();
      final pos = await _player.position(); // settle on the exact pause point
      if (!mounted) return;
      _positionMs.value = pos;
      setState(() => _play = _PlayState.paused);
      return;
    }
    if (!_player.isReady) {
      await _ensurePlayer();
      if (!mounted || !_player.isReady) return;
    }
    await _player.play();
    if (!mounted) return;
    setState(() => _play = _PlayState.playing);
    _startPosTimer();
  }

  void _onStop() {
    _playTimer?.cancel();
    _playTimer = null;
    _posTimer?.cancel();
    _posTimer = null;
    if (!_isGif && _player.isReady) {
      unawaited(_player.pause());
      unawaited(
          _player.seekTo(0)); // rewind so the next Play starts from the top
    }
    _positionMs.value = 0;
    setState(() {
      _play = _PlayState.stopped;
      _frameIdx = 0; // stop returns to the first frame (the still thumbnail)
    });
  }

  // Halt playback without a setState (callers wrap their own / are disposing).
  void _stopPlayback() {
    _playTimer?.cancel();
    _playTimer = null;
    _posTimer?.cancel();
    _posTimer = null;
    if (!_isGif && _player.isReady) {
      unawaited(_player.pause());
      unawaited(_player.seekTo(0));
    }
    _positionMs.value = 0;
    _play = _PlayState.stopped;
    _frameIdx = 0;
  }

  void _disposeFrames() {
    final frames = _frames;
    _frames = null;
    if (frames != null) {
      for (final im in frames) {
        im.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final transferState = ref.watch(transferProgressProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sending = transferState.status == TransferStatus.sending;

    return Scaffold(
      appBar: AppBar(
        title: const Text('发送视频'),
        actions: [
          if (_srcPath != null && !_cacheMode) ...[
            IconButton(
              onPressed: (_thumb == null ||
                      _vp <= 0 ||
                      _srcW <= 0 ||
                      _srcH <= 0 ||
                      _isBusy ||
                      _packaging)
                  ? null
                  : _exportThumbnail,
              icon: const Icon(Icons.save_alt),
              tooltip: '导出缩略图',
            ),
            IconButton(
              onPressed: _isBusy ? null : _showPickSheet,
              icon: const Icon(Icons.folder_open),
              tooltip: '重新选择',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              // Freeze page scroll while the user is framing inside the preview
              // (pinch-zoom / pan) so the gesture never leaks into scrolling.
              physics: _viewportPointers > 0
                  ? const NeverScrollableScrollPhysics()
                  : null,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _cacheMode
                    ? [
                        CacheLoadedPanel(
                          entry: _cacheEntry!,
                          onChange: _loadCache,
                          onClear: _clearCache,
                        ),
                      ]
                    : [
                        // Always show the "loaded" layout; the preview viewport
                        // just stays empty (tap to pick) until a source is set.
                        if (_srcPath == null)
                          _buildEmptyPreview(theme, cs)
                        else if (_thumb != null) ...[
                          _buildPreview(theme, cs),
                          const SizedBox(height: 8),
                          _buildViewControls(theme, cs),
                        ] else
                          _buildNoPreview(theme, cs),
                        const SizedBox(height: 10),
                        _buildExamples(theme, cs, enabled: !_isBusy),
                        const SizedBox(height: 16),
                        _buildChipRow(
                            theme,
                            '尺寸',
                            _sizePresets,
                            (s) => s == _size,
                            (s) => _onSizeTap(s),
                            (s) => '$s'),
                        const SizedBox(height: 8),
                        _buildChipRow(theme, '帧率', _fpsPresets,
                            (f) => f == _fps, (f) => _onFpsTap(f), (f) => '$f'),
                        const SizedBox(height: 8),
                        _buildQualityRow(theme),
                        const SizedBox(height: 8),
                        _buildBgColorRow(theme, cs),
                        const SizedBox(height: 12),
                        _buildConvInfo(theme, cs),
                      ],
              ),
            ),
          ),
          _buildBottomBar(theme, cs, transferState, sending),
        ],
      ),
    );
  }

  // Pinned bottom bar: transfer progress + status + action, always visible
  // (does not scroll with the page content).
  Widget _buildBottomBar(
      ThemeData theme, ColorScheme cs, TransferState state, bool sending) {
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border:
            Border(top: BorderSide(color: cs.outline.withValues(alpha: 0.3))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (sending)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(
                    value: state.progress,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              _buildStatus(theme, cs, state),
              const SizedBox(height: 12),
              _buildAction(theme, cs, sending),
            ],
          ),
        ),
      ),
    );
  }

  // Empty circular viewport shown before a source is picked — tap to pick.
  Widget _buildEmptyPreview(ThemeData theme, ColorScheme cs) {
    final double maxH = MediaQuery.of(context).size.height * _previewMaxHRatio;
    return LayoutBuilder(
      builder: (context, constraints) {
        final double v = min(constraints.maxWidth, maxH);
        final double d = v - 2 * kPreviewMargin; // circle floats with a margin
        _vp = d;
        return Center(
          child: GestureDetector(
            onTap: _isBusy ? null : _showPickSheet,
            child: SizedBox(
              width: v,
              height: v,
              child: previewCircle(
                size: d,
                bg: null,
                child: ColoredBox(
                  color: cs.surfaceContainerHighest,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.movie_creation_outlined,
                            size: 44, color: cs.outline),
                        const SizedBox(height: 8),
                        Text('点击选择视频或 GIF',
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: cs.outline)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // A horizontal strip of round example thumbnails under the preview; tapping
  // one loads that bundled video / GIF directly.
  Widget _buildExamples(ThemeData theme, ColorScheme cs,
      {required bool enabled}) {
    final items = [...ExampleAssets.gifs, ...ExampleAssets.videos];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('示例', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        ExampleStrip(
          count: items.length,
          enabled: enabled,
          thumbBuilder: (i) {
            final path = items[i];
            if (path.toLowerCase().endsWith('.gif')) {
              return Image.asset(path, fit: BoxFit.cover, cacheWidth: 120);
            }
            return VideoExampleThumbnail(
              key: ValueKey(path),
              sourceKey: path,
              load: () => _loadExampleThumbnail(path),
            );
          },
          onTap: (i) => _loadExampleVideo(items[i]),
        ),
      ],
    );
  }

  Future<ui.Image> _loadExampleThumbnail(String assetPath) async {
    final file = await materializeAsset(assetPath);
    final thumbnail = await _mediaGate.run(
      () => _converter.getVideoThumbnail(file.path),
      priority: MediaTaskPriority.background,
    );
    return decodeUiImage(thumbnail.bytes);
  }

  // Load one of the bundled example clips (video/*.mov or gif/*.gif). It's
  // copied to a temp file first because the native thumbnail/convert path needs
  // a real file path; _loadMedia then handles the thumbnail + GIF detection.
  Future<void> _loadExampleVideo(String assetPath) async {
    if (_isBusy) return;
    try {
      final file = await materializeAsset(assetPath);
      final size = await file.length();
      await _loadMedia(
        path: file.path,
        name: assetPath.split('/').last,
        size: size,
        isGifSource: assetPath.toLowerCase().endsWith('.gif'),
      );
    } catch (e) {
      _snack('加载示例失败: $e');
    }
  }

  Widget _buildNoPreview(ThemeData theme, ColorScheme cs) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(Icons.movie_outlined, size: 40, color: cs.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(_selectedName ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
              videoThumbnailFailureMessage(
                _thumbnailFailure ?? VideoThumbnailFailureKind.other,
              ),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  // Fixed circular viewport representing the device's round 360×360 screen: the
  // first frame is pinch-zoomed / panned underneath (contain-fit on load). The
  // encoded bitmap stays square (crop math unchanged) — the circle just marks
  // what the round screen shows. The bottom-right corner hosts play/pause/stop
  // for a motion preview: while playing, a few downscaled frames cycle (looping)
  // under the same framing transform; stop returns to the first frame.
  Widget _buildPreview(ThemeData theme, ColorScheme cs) {
    final double maxH = MediaQuery.of(context).size.height * _previewMaxHRatio;
    return LayoutBuilder(
      builder: (context, constraints) {
        final double v = min(constraints.maxWidth, maxH);
        final double d = v - 2 * kPreviewMargin; // circle floats with a margin
        _vp = d;
        return Center(
          child: SizedBox(
            width: v,
            height: v,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    // Track fingers on the viewport so page scroll can be frozen
                    // while the frame is being pinch-zoomed / panned.
                    onPointerDown: (_) {
                      // A new touch starts: drop any pending extraction so
                      // nothing computes while the finger is down.
                      _bgDebounce.cancel();
                      setState(() => _viewportPointers++);
                    },
                    onPointerUp: (_) => setState(() => _viewportPointers =
                        (_viewportPointers - 1).clamp(0, 99)),
                    onPointerCancel: (_) => setState(() => _viewportPointers =
                        (_viewportPointers - 1).clamp(0, 99)),
                    child: previewCircle(
                      size: d,
                      bg: _previewBg,
                      child: Stack(
                        children: [
                          Positioned.fill(
                              child: ColoredBox(color: Color(_bgColor))),
                          InteractiveViewer(
                            transformationController: _tc,
                            minScale: 1.0,
                            maxScale: 8.0,
                            clipBehavior: Clip.hardEdge,
                            // Reframing invalidates the converted result
                            // (re-convert is native/expensive → manual).
                            onInteractionEnd: (_) {
                              _invalidate();
                              _bgDebounce.run(_extractPreviewBg);
                            },
                            child: SizedBox(
                              width: d,
                              height: d,
                              child: _buildMediaContent(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: kPreviewMargin,
                  bottom: kPreviewMargin,
                  child: _buildPlayControls(cs),
                ),
                // Bottom-left: current / total time, shown once the player
                // (video) or the extracted frames (GIF) are ready.
                if ((_isGif && _frames != null) || (!_isGif && _player.isReady))
                  Positioned(
                    left: kPreviewMargin,
                    bottom: kPreviewMargin,
                    child: _buildTimeLabel(),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // The pixels shown inside the framing viewport. Stopped → the still first
  // frame. Playing/paused → the live video texture (real videos) or the cycling
  // extracted frames (GIFs). Every branch is contain-fit into the same v×v box
  // that hosts the still thumb, so the pinch-zoom transform and crop math
  // (`_cropForConvert`) are identical regardless of the source.
  Widget _buildMediaContent() {
    if (_play != _PlayState.stopped) {
      if (_isGif) {
        final frames = _frames;
        if (frames != null && frames.isNotEmpty) {
          return RawImage(
              image: frames[_frameIdx % frames.length], fit: BoxFit.contain);
        }
      } else if (_player.isReady && _srcW > 0 && _srcH > 0) {
        // Real video via the native MediaPlayer texture, laid out at the source
        // aspect so it frames exactly like the still thumbnail.
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: _srcW.toDouble(),
            height: _srcH.toDouble(),
            child: Texture(textureId: _player.textureId),
          ),
        );
      }
    }
    return RawImage(image: _thumb, fit: BoxFit.contain);
  }

  // Translucent play/pause + stop pill, floated over the preview's bottom-right.
  // Disabled while converting; the play slot shows a spinner while frames load.
  Widget _buildPlayControls(ColorScheme cs) {
    final bool canPlay = _conv != _ConvStatus.converting;
    final bool isPlaying = _play == _PlayState.playing;
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _loadingFrames
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                )
              : IconButton(
                  onPressed: canPlay ? _onPlayPause : null,
                  icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                  iconSize: 22,
                  color: Colors.white,
                  disabledColor: Colors.white38,
                  visualDensity: VisualDensity.compact,
                  tooltip: isPlaying ? '暂停' : '播放',
                ),
          IconButton(
            onPressed: canPlay && _play != _PlayState.stopped ? _onStop : null,
            icon: const Icon(Icons.stop),
            iconSize: 22,
            color: Colors.white,
            disabledColor: Colors.white38,
            visualDensity: VisualDensity.compact,
            tooltip: '停止',
          ),
        ],
      ),
    );
  }

  // mm:ss for the time label; clamps negatives to 0.
  String _fmtTime(int ms) {
    final totalSec = (ms < 0 ? 0 : ms) ~/ 1000;
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // Translucent "current / total" time pill for the preview's bottom-left.
  // Total is the video duration (or the GIF preview's cycle length); current
  // updates while playing via [_positionMs].
  Widget _buildTimeLabel() {
    final int total =
        _isGif ? (_frames?.length ?? 0) * _frameIntervalMs : _player.durationMs;
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: ValueListenableBuilder<int>(
          valueListenable: _positionMs,
          builder: (_, pos, __) => Text(
            '${_fmtTime(pos)} / ${_fmtTime(total)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: [ui.FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildViewControls(ThemeData theme, ColorScheme cs) {
    return Row(
      children: [
        Icon(Icons.pinch_outlined, size: 18, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text('双指缩放 / 拖动取景，圆内即屏幕显示区域',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant)),
        ),
        TextButton.icon(
          onPressed: _isBusy ? null : _onResetView,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重置'),
        ),
      ],
    );
  }

  Widget _buildChipRow(
    ThemeData theme,
    String label,
    List<int> presets,
    bool Function(int) selected,
    void Function(int) onTap,
    String Function(int) fmt,
  ) {
    return Row(
      children: [
        SizedBox(
            width: 40, child: Text(label, style: theme.textTheme.titleSmall)),
        const SizedBox(width: 8),
        ...presets.map((v) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PresetChip(
                label: fmt(v),
                selected: selected(v),
                onTap: _isBusy ? null : () => onTap(v),
              ),
            )),
      ],
    );
  }

  Widget _buildQualityRow(ThemeData theme) {
    return Row(
      children: [
        SizedBox(
            width: 40, child: Text('质量', style: theme.textTheme.titleSmall)),
        const SizedBox(width: 8),
        ..._qualityPresets.map((q) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PresetChip(
                label: q.$1,
                selected: _quality == q.$2,
                onTap: _isBusy ? null : () => _onQualityTap(q.$2),
              ),
            )),
      ],
    );
  }

  // Background fill: composited under transparent GIF pixels, and used as the
  // letterbox color when the frame is zoomed out inside the circular viewport.
  Widget _buildBgColorRow(ThemeData theme, ColorScheme cs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: SizedBox(
              width: 40, child: Text('背景', style: theme.textTheme.titleSmall)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ColorSwatchStrip(
            presets: _bgColors,
            selected: _bgColor,
            onChanged: _onBgTap,
            enabled: !_isBusy,
          ),
        ),
      ],
    );
  }

  Widget _buildConvInfo(ThemeData theme, ColorScheme cs) {
    if (_srcPath == null) {
      return Text('点击上方预览区选择视频 / GIF，或选择下方示例',
          style:
              theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant));
    }
    String right;
    if (_conv == _ConvStatus.converting) {
      final pct = (_convProgress * 100).toInt();
      right = '转换中 $pct% · $_frameCount 帧';
    } else if (_conv == _ConvStatus.ready) {
      right = '$_size×$_size · $_frameCount 帧 · ${formatFileSize(_binSize)}';
    } else {
      right = '待转换';
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('源文件 ${formatFileSize(_sourceSize)}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: cs.onSurfaceVariant)),
        Flexible(
          child: Text(right,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _buildStatus(ThemeData theme, ColorScheme cs, TransferState state) {
    if (_conv == _ConvStatus.error) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 20, color: cs.error),
          const SizedBox(width: 6),
          Flexible(
            child: Text(_convError ?? '转换失败',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: cs.error, fontWeight: FontWeight.w600)),
          ),
        ],
      );
    }
    switch (state.status) {
      case TransferStatus.idle:
        return const SizedBox.shrink();
      case TransferStatus.sending:
        final pct = (state.progress * 100).toInt();
        return Text('$pct% · ${state.speedKBs} KB/s',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: cs.primary));
      case TransferStatus.done:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, size: 20, color: cs.secondary),
            const SizedBox(width: 6),
            Text('发送成功',
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.secondary, fontWeight: FontWeight.w600)),
          ],
        );
      case TransferStatus.error:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 20, color: cs.error),
            const SizedBox(width: 6),
            Flexible(
              child: Text(state.errorMessage ?? '发送失败',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: cs.error, fontWeight: FontWeight.w600)),
            ),
          ],
        );
    }
  }

  Widget _buildAction(ThemeData theme, ColorScheme cs, bool sending) {
    if (sending) {
      return FilledButton.icon(
        onPressed: () => ref.read(transferProgressProvider.notifier).abort(),
        icon: const Icon(Icons.close),
        label: const Text('取消'),
        style: FilledButton.styleFrom(
          backgroundColor: cs.error,
          foregroundColor: cs.onError,
          minimumSize: const Size.fromHeight(48),
        ),
      );
    }
    if (_conv == _ConvStatus.converting) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(
              value: _convProgress > 0 ? _convProgress : null,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _cancelConvert,
            icon: const Icon(Icons.close),
            label: const Text('取消转换'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      );
    }
    // Cache mode: re-send the loaded cache bytes as-is.
    if (_cacheMode) {
      return _withLoadButton(FilledButton.icon(
        onPressed: _cacheBytes != null ? _sendCache : null,
        icon: const Icon(Icons.send),
        label: const Text('发送缓存'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ));
    }
    if (_conv == _ConvStatus.ready) {
      return _withLoadButton(FilledButton.icon(
        onPressed: _send,
        icon: const Icon(Icons.send),
        label: const Text('发送到设备'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ));
    }
    // idle or error → convert.
    return _withLoadButton(FilledButton.icon(
      onPressed: _srcPath != null ? _convert : null,
      icon: const Icon(Icons.transform),
      label: const Text('转换为视频'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
    ));
  }

  // Circular "load cache" button sits to the left of the primary action.
  Widget _withLoadButton(Widget primary) {
    return Row(
      children: [
        CacheLoadButton(onPressed: _loadCache),
        const SizedBox(width: 12),
        Expanded(child: primary),
      ],
    );
  }
}
