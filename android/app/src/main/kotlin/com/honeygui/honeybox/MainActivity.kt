package com.honeygui.honeybox

import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Hosts the native H.264 encoding-test pipeline ([CameraEncoder]) and bridges it
 * to Dart over a [MethodChannel] (commands) + [EventChannel] (camera-ready,
 * stats, lifecycle, errors).
 */
class MainActivity : FlutterActivity() {
    private val methodChannelName = "ebadge/encoder"
    private val eventChannelName = "ebadge/encoder/events"
    private val wifiChannelName = "ebadge/wifi"
    private val converterChannelName = "ebadge/converter"
    private val systemChannelName = "ebadge/system"
    private val playerChannelName = "ebadge/player"

    private var encoder: CameraEncoder? = null
    private var eventSink: EventChannel.EventSink? = null
    private var hotspot: HotspotManager? = null

    // In-page video preview players (native MediaPlayer → Flutter texture),
    // keyed by their texture id. One at a time in practice, but keyed for safety.
    private var textureRegistry: TextureRegistry? = null
    private val players = mutableMapOf<Long, VideoPreviewPlayer>()

    private val converter = VideoConverter()
    private var converterChannel: MethodChannel? = null
    private val converterExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var convertCancel: AtomicBoolean? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NotificationListener.registerChannels(flutterEngine, applicationContext)

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        textureRegistry = flutterEngine.renderer

        EventChannel(messenger, eventChannelName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )

        val events = object : EncoderEvents {
            override fun onEvent(payload: Map<String, Any?>) {
                eventSink?.success(payload)
            }
        }

        MethodChannel(messenger, methodChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "openCamera" -> {
                    val front = call.argument<Boolean>("facingFront") ?: false
                    ensureEncoder(events).openCamera(front, parseConfig(call))
                    result.success(null)
                }

                "closeCamera" -> {
                    encoder?.closeCamera()
                    result.success(null)
                }

                "setConfig" -> {
                    encoder?.setConfig(parseConfig(call))
                    result.success(null)
                }

                "startEncoding" -> {
                    ensureEncoder(events).startEncoding(parseConfig(call))
                    result.success(null)
                }

                "stopEncoding" -> {
                    encoder?.stopEncoding()
                    result.success(null)
                }

                "focusAt" -> {
                    val x = call.argument<Double>("x") ?: 0.5
                    val y = call.argument<Double>("y") ?: 0.5
                    encoder?.focusAt(x, y)
                    result.success(null)
                }

                "setEv" -> {
                    val ev = call.argument<Double>("ev") ?: 0.0
                    encoder?.setEv(ev)
                    result.success(null)
                }

                "setZoom" -> {
                    val zoom = call.argument<Double>("zoom") ?: 1.0
                    encoder?.setZoom(zoom)
                    result.success(null)
                }

                "setPreviewMode" -> {
                    val encoded = call.argument<Boolean>("encoded") ?: false
                    encoder?.setPreviewMode(encoded)
                    result.success(null)
                }

                "requestKeyframe" -> {
                    encoder?.requestKeyframe()
                    result.success(null)
                }

                "requestEncoderFrame" -> {
                    encoder?.requestEncoderFrame()
                    result.success(null)
                }

                "takePicture" -> {
                    val enc = encoder
                    if (enc == null) {
                        result.error("no_camera", "相机未打开", null)
                    } else {
                        enc.takePicture { bytes, err ->
                            if (bytes != null) {
                                result.success(bytes)
                            } else {
                                result.error("capture_failed", err ?: "拍照失败", null)
                            }
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, wifiChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "startHotspot" -> ensureHotspot().start(result)
                "stopHotspot" -> {
                    hotspot?.stop()
                    result.success(null)
                }
                "isHotspotActive" -> result.success(hotspot?.isActive ?: false)
                else -> result.notImplemented()
            }
        }

        val converterCh = MethodChannel(messenger, converterChannelName)
        converterChannel = converterCh
        converterCh.setMethodCallHandler { call, result ->
            when (call.method) {
                "getVideoThumbnail" -> handleThumbnail(call, result)
                "previewFrames" -> handlePreviewFrames(call, result)
                "convertVideo" -> handleConvertVideo(call, result)
                "encodeScroll" -> handleEncodeScroll(call, result)
                "encodeFrames" -> handleEncodeFrames(call, result)
                "decodeCvid" -> handleDecodeCvid(call, result)
                "cancelConvert" -> {
                    convertCancel?.set(true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, playerChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "create" -> handleCreatePlayer(call, result)
                "play" -> {
                    playerFor(call)?.play()
                    result.success(null)
                }
                "pause" -> {
                    playerFor(call)?.pause()
                    result.success(null)
                }
                "seekTo" -> {
                    playerFor(call)?.seekTo(call.argument<Int>("positionMs") ?: 0)
                    result.success(null)
                }
                "position" -> result.success(playerFor(call)?.position() ?: 0)
                "dispose" -> {
                    val id = (call.argument<Number>("id"))?.toLong()
                    (if (id != null) players.remove(id) else null)?.release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, systemChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "openLocationSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("no_activity", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun handleThumbnail(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("bad_args", "path required", null)
            return
        }
        converterExecutor.execute {
            try {
                val t = converter.thumbnail(path)
                mainHandler.post {
                    result.success(
                        mapOf(
                            "bytes" to t.png,
                            "width" to t.width,
                            "height" to t.height,
                            "isGif" to t.isGif,
                        ),
                    )
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("thumb_failed", e.message ?: "读取视频失败", null) }
            }
        }
    }

    private fun handlePreviewFrames(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("bad_args", "path required", null)
            return
        }
        val maxCount = call.argument<Int>("maxCount") ?: 48
        val maxEdge = call.argument<Int>("maxEdge") ?: 240
        converterExecutor.execute {
            try {
                val clip = converter.previewFrames(path, maxCount, maxEdge)
                mainHandler.post {
                    result.success(
                        mapOf(
                            "frames" to clip.frames,
                            "intervalMs" to clip.intervalMs,
                        ),
                    )
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("preview_failed", e.message ?: "读取预览帧失败", null) }
            }
        }
    }

    // Decode a cached CVID/AVI back into downscaled preview frames (Cinepak is
    // not decodable by any platform player — see [CinepakDecoder]).
    private fun handleDecodeCvid(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("bad_args", "path required", null)
            return
        }
        val maxCount = call.argument<Int>("maxCount") ?: 60
        val maxEdge = call.argument<Int>("maxEdge") ?: 200
        converterExecutor.execute {
            try {
                val bytes = java.io.File(path).readBytes()
                val clip = converter.decodeCvidPreview(bytes, maxCount, maxEdge)
                mainHandler.post {
                    result.success(
                        mapOf(
                            "frames" to clip.frames,
                            "intervalMs" to clip.intervalMs,
                        ),
                    )
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("decode_failed", e.message ?: "解码预览失败", null) }
            }
        }
    }

    private fun handleConvertVideo(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("bad_args", "path required", null)
            return
        }
        val width = call.argument<Int>("width") ?: 360
        val height = call.argument<Int>("height") ?: 360
        val fps = call.argument<Int>("fps") ?: 10
        val quality = call.argument<Int>("quality") ?: 60
        val refine = call.argument<Int>("refine") ?: 3
        val strips = call.argument<Int>("strips") ?: 2
        val skipThresh = call.argument<Int>("skipThresh") ?: 720
        val keyint = call.argument<Int>("keyint") ?: 0
        val cropMode = call.argument<String>("cropMode") ?: "cover"
        val maxFrames = call.argument<Int>("maxFrames") ?: 300
        // bgColor arrives as an int64 (ARGB > 0x7FFFFFFF), so read via Number.
        val bgColor = (call.argument<Number>("bgColor"))?.toInt() ?: 0xFF000000.toInt()
        val cropMap = call.argument<Map<String, Any?>>("crop")
        val crop = if (cropMap != null) {
            doubleArrayOf(
                (cropMap["nx"] as? Number)?.toDouble() ?: 0.0,
                (cropMap["ny"] as? Number)?.toDouble() ?: 0.0,
                (cropMap["nw"] as? Number)?.toDouble() ?: 0.0,
                (cropMap["nh"] as? Number)?.toDouble() ?: 0.0,
            )
        } else {
            null
        }

        val cancel = AtomicBoolean(false)
        convertCancel = cancel
        val channel = converterChannel
        converterExecutor.execute {
            try {
                val res = converter.convert(
                    path, width, height, fps, quality, refine, strips, skipThresh, keyint,
                    cropMode, crop, maxFrames, bgColor, cancel,
                ) { done, total ->
                    mainHandler.post {
                        channel?.invokeMethod("onProgress", mapOf("done" to done, "total" to total))
                    }
                }
                mainHandler.post {
                    result.success(
                        mapOf(
                            "avi" to res.avi,
                            "width" to res.width,
                            "height" to res.height,
                            "frameCount" to res.frameCount,
                            "fps" to res.fps,
                        ),
                    )
                }
            } catch (e: VideoConverter.Cancelled) {
                mainHandler.post { result.error("cancelled", "已取消", null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("convert_failed", e.message ?: "视频转换失败", null) }
            }
        }
    }

    private fun handleEncodeScroll(call: MethodCall, result: MethodChannel.Result) {
        val strip = call.argument<ByteArray>("strip")
        val stripW = call.argument<Int>("stripW") ?: 0
        val stripH = call.argument<Int>("stripH") ?: 0
        if (strip == null || stripW <= 0 || stripH <= 0) {
            result.error("bad_args", "strip/stripW/stripH required", null)
            return
        }
        val size = call.argument<Int>("size") ?: 360
        // bgColor arrives as an int64 (ARGB > 0x7FFFFFFF), so read via Number.
        val bgColor = (call.argument<Number>("bgColor"))?.toInt() ?: 0xFF000000.toInt()
        val speed = call.argument<Int>("speed") ?: 120
        val fps = call.argument<Int>("fps") ?: 15
        val gap = call.argument<Int>("gap") ?: size
        val quality = call.argument<Int>("quality") ?: 80
        val maxFrames = call.argument<Int>("maxFrames") ?: 300

        val cancel = AtomicBoolean(false)
        convertCancel = cancel
        val channel = converterChannel
        converterExecutor.execute {
            try {
                val res = converter.encodeScrollAvi(
                    strip, stripW, stripH, size, bgColor, speed, fps, gap, quality, maxFrames, cancel,
                ) { done, total ->
                    mainHandler.post {
                        channel?.invokeMethod("onProgress", mapOf("done" to done, "total" to total))
                    }
                }
                mainHandler.post {
                    result.success(
                        mapOf(
                            "avi" to res.avi,
                            "width" to res.width,
                            "height" to res.height,
                            "frameCount" to res.frameCount,
                            "fps" to res.fps,
                        ),
                    )
                }
            } catch (e: VideoConverter.Cancelled) {
                mainHandler.post { result.error("cancelled", "已取消", null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("encode_failed", e.message ?: "字幕滚动生成失败", null) }
            }
        }
    }

    // Compose pre-framed RGBA images (each size×size) into a slideshow AVI(CVID).
    private fun handleEncodeFrames(call: MethodCall, result: MethodChannel.Result) {
        val framesRaw = call.argument<List<Any?>>("frames")
        val holdsRaw = call.argument<List<Any?>>("holds")
        if (framesRaw == null || framesRaw.isEmpty() || holdsRaw == null ||
            holdsRaw.size != framesRaw.size
        ) {
            result.error("bad_args", "frames/holds required", null)
            return
        }
        val frames = try {
            framesRaw.map { it as ByteArray }
        } catch (_: Exception) {
            result.error("bad_args", "frames must be byte arrays", null)
            return
        }
        val holds = IntArray(holdsRaw.size) { (holdsRaw[it] as? Number)?.toInt() ?: 1 }
        val size = call.argument<Int>("size") ?: 360
        val fps = call.argument<Int>("fps") ?: 10
        val quality = call.argument<Int>("quality") ?: 60

        val cancel = AtomicBoolean(false)
        convertCancel = cancel
        val channel = converterChannel
        converterExecutor.execute {
            try {
                val res = converter.encodeFrames(frames, holds, size, fps, quality, cancel) { done, total ->
                    mainHandler.post {
                        channel?.invokeMethod("onProgress", mapOf("done" to done, "total" to total))
                    }
                }
                mainHandler.post {
                    result.success(
                        mapOf(
                            "avi" to res.avi,
                            "width" to res.width,
                            "height" to res.height,
                            "frameCount" to res.frameCount,
                            "fps" to res.fps,
                        ),
                    )
                }
            } catch (e: VideoConverter.Cancelled) {
                mainHandler.post { result.error("cancelled", "已取消", null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("encode_failed", e.message ?: "合成失败", null) }
            }
        }
    }

    private fun playerFor(call: MethodCall): VideoPreviewPlayer? {
        val id = (call.argument<Number>("id"))?.toLong() ?: return null
        return players[id]
    }

    // Create a MediaPlayer-backed preview texture for [path]; the result is
    // delivered only once the player is prepared (first frame renderable).
    private fun handleCreatePlayer(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val registry = textureRegistry
        if (path == null || registry == null) {
            result.error("bad_args", "path required", null)
            return
        }
        val entry = registry.createSurfaceTexture()
        val player = VideoPreviewPlayer(entry)
        players[player.textureId] = player
        var done = false
        player.open(
            path,
            onReady = { w, h, dur ->
                if (!done) {
                    done = true
                    result.success(
                        mapOf(
                            "textureId" to player.textureId,
                            "width" to w,
                            "height" to h,
                            "durationMs" to dur,
                        ),
                    )
                }
            },
            onError = { msg ->
                if (!done) {
                    done = true
                    players.remove(player.textureId)
                    player.release()
                    result.error("player_failed", msg, null)
                }
            },
        )
    }

    private fun ensureHotspot(): HotspotManager {
        val existing = hotspot
        if (existing != null) return existing
        val created = HotspotManager(applicationContext)
        hotspot = created
        return created
    }

    private fun parseConfig(call: MethodCall): EncoderConfig = EncoderConfig(
        format = call.argument<String>("format") ?: "h264",
        width = call.argument<Int>("width") ?: 640,
        height = call.argument<Int>("height") ?: 480,
        fps = call.argument<Int>("fps") ?: 15,
        bitrate = call.argument<Int>("bitrate") ?: 2_000_000,
        iFrameIntervalSec = call.argument<Int>("iFrameIntervalSec") ?: 1,
        cropZoom = call.argument<Double>("cropZoom") ?: 1.0,
        msv1Skip = call.argument<Boolean>("msv1Skip") ?: true,
        msv1SkipThr = call.argument<Int>("msv1SkipThr") ?: 0,
        jpegQuality = call.argument<Int>("jpegQuality") ?: 80,
        recordToFile = call.argument<Boolean>("recordToFile") ?: false,
        stream = call.argument<Boolean>("stream") ?: false,
    )

    private fun ensureEncoder(events: EncoderEvents): CameraEncoder {
        val existing = encoder
        if (existing != null) return existing
        val created = CameraEncoder(applicationContext, flutterEngine!!.renderer, events)
        encoder = created
        return created
    }

    override fun onDestroy() {
        encoder?.closeCamera()
        encoder = null
        hotspot?.stop()
        hotspot = null
        players.values.forEach { it.release() }
        players.clear()
        textureRegistry = null
        convertCancel?.set(true)
        converterChannel = null
        converterExecutor.shutdownNow()
        super.onDestroy()
    }
}
