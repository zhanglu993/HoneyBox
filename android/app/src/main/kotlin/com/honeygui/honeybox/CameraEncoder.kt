package com.honeygui.honeybox

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Size
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer

/**
 * Encoder configuration passed from Dart.
 *
 * [cropZoom] is a center-crop / digital-zoom factor (1.0 = full field of view).
 * [iFrameIntervalSec] only applies to H.264.
 */
data class EncoderConfig(
    val format: String,        // "h264" | "jpeg" | "mvs1"
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrate: Int,          // bits per second (H.264)
    val iFrameIntervalSec: Int,
    val cropZoom: Double,
    val msv1Skip: Boolean,     // MSV1 inter-frame skip (P-frames)
    val msv1SkipThr: Int,      // MSV1 skip threshold (per-pixel RGB555 delta)
    val jpegQuality: Int,      // JPEG quality 1..100
    val recordToFile: Boolean, // also mux encoded frames into a local file
    val stream: Boolean,       // emit encoded frames to Dart for streaming
)

/** Sink for diagnostic / lifecycle events delivered back to Dart. */
interface EncoderEvents {
    fun onEvent(payload: Map<String, Any?>)
}

/**
 * Camera2 → GL → MediaCodec H.264 encoding pipeline.
 *
 * Camera2 renders into a single OES texture owned by [GlRenderer]. The GL stage
 * draws each frame — crop → uniform-scale → rotation baked in — to the Flutter
 * preview texture and (while encoding) to the MediaCodec input surface. Because
 * GL scales, the encoder output may be **any** resolution, independent of the
 * camera's supported sizes, with crop-then-uniform-scale (等比例) semantics.
 *
 * H.264 is configured for constrained-baseline profile, no B-frames, and a
 * YUV420 internal color format (Surface input). MVS1/JPEG are placeholders.
 */
class CameraEncoder(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val events: EncoderEvents,
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── Camera ────────────────────────────────────────────────────────────
    private val cameraManager =
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var sensorOrientation = 90
    private var lensFacing = CameraCharacteristics.LENS_FACING_BACK
    private var facingFront = false
    private var supportedSizes: Array<Size>? = null
    private var availableFpsRanges: Array<android.util.Range<Int>>? = null
    private var captureSize = Size(1280, 720)

    // ── Focus / exposure ───────────────────────────────────────────────────
    private var sensorActiveArray: android.graphics.Rect? = null
    private var maxAfRegions = 0
    private var maxAeRegions = 0
    private var aeCompRange: android.util.Range<Int>? = null
    private var aeCompStep = 0.0 // EV per compensation step
    private var evSteps = 0
    private var afRegion: android.hardware.camera2.params.MeteringRectangle? = null

    // ── Preview (Flutter texture) ───────────────────────────────────────────
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var previewSurface: Surface? = null
    private var previewSize = Size(1280, 720)

    // ── GL stage ──────────────────────────────────────────────────────────
    private var renderer: GlRenderer? = null

    // ── Encoder ───────────────────────────────────────────────────────────
    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var codecThread: HandlerThread? = null
    private var codecHandler: Handler? = null
    private var outputStream: FileOutputStream? = null
    private var outputFile: File? = null

    @Volatile private var encoding = false
    @Volatile private var finishing = false
    @Volatile private var config: EncoderConfig? = null
    private var encWidth = 0
    private var encHeight = 0

    // ── Software (MSV1 / JPEG) encode state ──────────────────────────────────
    @Volatile private var software = false
    @Volatile private var streaming = false   // emit frames to Dart
    @Volatile private var recordToFile = false // mux frames into a local file
    @Volatile private var forceKeyframe = false // re-sync request (drop skip once)
    // MSV1 periodic key frame so lost-block corruption self-heals (0 = never).
    private var swKeyIntervalFrames = 0
    private var swFramesSinceKey = 0
    private var swMode = "" // "mvs1" | "jpeg"

    // Cached H.264 SPS/PPS (CODEC_CONFIG), prepended to each streamed IDR so a
    // late-joining / re-syncing decoder gets the parameter sets.
    private var h264Csd: ByteArray? = null
    private val swFrames = ArrayList<ByteArray>()
    private val swKeys = ArrayList<Boolean>()
    private var prevRgba: ByteArray? = null
    @Volatile private var swBusy = false
    private var swBytes = 0L
    private var swTruncated = false
    private val swMaxFrames = 600
    private val swMaxBytes = 96L * 1024 * 1024

    // ── Encoded preview (encode→decode→display round trip; MSV1/JPEG only) ──
    @Volatile private var previewEncoded = false
    private var decodedEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var decodedSurface: Surface? = null
    private var decodedArgb: IntArray? = null

    private var frameCount = 0
    private var keyframeCount = 0
    private var totalBytes = 0L
    private var keyframeBytes = 0L // cumulative key (I) frame bytes, for I/P avg
    private var lastFrameBytes = 0
    private var firstPtsUs = -1L
    private var lastPtsUs = 0L

    // -------------------------------------------------------------------------
    // Camera lifecycle
    // -------------------------------------------------------------------------

    fun openCamera(facingFront: Boolean, cfg: EncoderConfig) {
        closeCamera()
        config = cfg
        this.facingFront = facingFront
        startCameraThread()

        try {
            lensFacing = if (facingFront) {
                CameraCharacteristics.LENS_FACING_FRONT
            } else {
                CameraCharacteristics.LENS_FACING_BACK
            }
            val id = pickCameraId(lensFacing) ?: run {
                emitError("未找到摄像头")
                return
            }
            val chars = cameraManager.getCameraCharacteristics(id)
            sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            supportedSizes = map?.getOutputSizes(SurfaceTexture::class.java)
            availableFpsRanges =
                chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            captureSize = chooseSize(supportedSizes, 1280, 720)

            // Focus / exposure capabilities.
            sensorActiveArray =
                chars.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
            maxAfRegions = chars.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0
            maxAeRegions = chars.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0
            aeCompRange =
                chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
            val step = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)
            aeCompStep =
                if (step != null) step.numerator.toDouble() / step.denominator else 0.0
            evSteps = 0
            afRegion = null

            // Flutter preview texture, sized to the output aspect ratio so the
            // preview is WYSIWYG with the encoded frame.
            previewSize = previewSizeFor(cfg.width, cfg.height)
            val entry = textureRegistry.createSurfaceTexture()
            textureEntry = entry
            val st = entry.surfaceTexture()
            st.setDefaultBufferSize(previewSize.width, previewSize.height)
            previewSurface = Surface(st)

            // Spin up the GL stage; it creates the camera input surface.
            val gl = GlRenderer(
                onError = { msg -> emitError(msg) },
                onInfo = { msg -> emitInfo(msg) },
            )
            renderer = gl
            gl.setParams(
                sensorOrientation, facingFront, cfg.width, cfg.height, cfg.cropZoom,
            )
            gl.start(captureSize.width, captureSize.height) { camSurface ->
                gl.setPreviewSurface(previewSurface, previewSize.width, previewSize.height)
                openDevice(id, camSurface)
            }
        } catch (e: Exception) {
            emitError("打开摄像头失败: ${e.message}")
        }
    }

    private fun openDevice(id: String, cameraSurface: Surface) {
        try {
            cameraManager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    cameraDevice = device
                    buildSession(cameraSurface)
                }

                override fun onDisconnected(device: CameraDevice) {
                    device.close()
                    cameraDevice = null
                }

                override fun onError(device: CameraDevice, error: Int) {
                    device.close()
                    cameraDevice = null
                    emitError("摄像头错误: $error")
                }
            }, cameraHandler)
        } catch (e: SecurityException) {
            emitError("缺少相机权限")
        } catch (e: Exception) {
            emitError("打开摄像头失败: ${e.message}")
        }
    }

    private fun buildSession(cameraSurface: Surface) {
        val device = cameraDevice ?: return
        try {
            @Suppress("DEPRECATION")
            device.createCaptureSession(
                listOf(cameraSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        issueRepeating()
                        emitCameraReady()
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        emitError("会话配置失败")
                    }
                },
                cameraHandler,
            )
        } catch (e: Exception) {
            emitError("创建会话失败: ${e.message}")
        }
    }

    /** Apply FPS, exposure compensation, and AF/AE regions to a request. */
    private fun applyRequest(builder: CaptureRequest.Builder) {
        builder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
        builder.set(
            CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
            chooseFpsRange(config?.fps ?: 30),
        )
        aeCompRange?.let {
            builder.set(
                CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION,
                evSteps.coerceIn(it.lower, it.upper),
            )
        }

        val region = afRegion
        if (region != null && maxAfRegions > 0) {
            builder.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_AUTO)
            builder.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(region))
        } else {
            builder.set(
                CaptureRequest.CONTROL_AF_MODE,
                CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO,
            )
        }
        if (region != null && maxAeRegions > 0) {
            builder.set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(region))
        }
    }

    private fun issueRepeating() {
        val device = cameraDevice ?: return
        val session = captureSession ?: return
        val surface = renderer?.cameraSurface() ?: return
        try {
            val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            builder.addTarget(surface)
            applyRequest(builder)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (e: Exception) {
            emitError("启动取景失败: ${e.message}")
        }
    }

    /** Tap-to-focus: [nx],[ny] are normalized [0,1] in the displayed preview. */
    fun focusAt(nx: Double, ny: Double) {
        val active = sensorActiveArray ?: return
        if (maxAfRegions <= 0 && maxAeRegions <= 0) return

        // 1. Undo the GL display crop → full upright-image normalized coords.
        val (fx, fy) = visibleFraction()
        val ux = 0.5 + (nx - 0.5) * fx
        val uy = 0.5 + (ny - 0.5) * fy

        // 2. Undo rotation → sensor-native normalized coords.
        var vx: Double
        var vy: Double
        when (sensorOrientation) {
            90 -> { vx = uy; vy = 1 - ux }
            270 -> { vx = 1 - uy; vy = ux }
            180 -> { vx = 1 - ux; vy = 1 - uy }
            else -> { vx = ux; vy = uy }
        }
        if (facingFront) vx = 1 - vx
        vx = vx.coerceIn(0.0, 1.0)
        vy = vy.coerceIn(0.0, 1.0)

        // 3. Build a small metering rectangle around the point.
        val cx = active.left + (vx * active.width()).toInt()
        val cy = active.top + (vy * active.height()).toInt()
        val half = (active.width() * 0.07).toInt().coerceAtLeast(1)
        val left = (cx - half).coerceIn(active.left, active.right - 1)
        val top = (cy - half).coerceIn(active.top, active.bottom - 1)
        val right = (cx + half).coerceIn(left + 1, active.right)
        val bottom = (cy + half).coerceIn(top + 1, active.bottom)
        afRegion = android.hardware.camera2.params.MeteringRectangle(
            left, top, right - left, bottom - top,
            android.hardware.camera2.params.MeteringRectangle.METERING_WEIGHT_MAX,
        )

        issueRepeating()
        triggerAf()
    }

    /** Fire a one-shot AF trigger for the current region. */
    private fun triggerAf() {
        val device = cameraDevice ?: return
        val session = captureSession ?: return
        val surface = renderer?.cameraSurface() ?: return
        try {
            val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            builder.addTarget(surface)
            applyRequest(builder)
            builder.set(
                CaptureRequest.CONTROL_AF_TRIGGER,
                CameraMetadata.CONTROL_AF_TRIGGER_START,
            )
            session.capture(builder.build(), null, cameraHandler)
        } catch (_: Exception) {
        }
    }

    /** Set exposure compensation in EV stops. */
    fun setEv(ev: Double) {
        evSteps = if (aeCompStep > 0) Math.round(ev / aeCompStep).toInt() else 0
        issueRepeating()
    }

    /**
     * Live digital-zoom (pinch-to-zoom). Updates only the GL center-crop factor —
     * the output aspect is unchanged, so no preview/texture resize is needed. Both
     * the on-screen preview and the encoded/streamed frames follow immediately.
     */
    fun setZoom(zoom: Double) {
        val cfg = config ?: return
        val z = zoom.coerceAtLeast(1.0)
        if (z == cfg.cropZoom) return
        config = cfg.copy(cropZoom = z)
        renderer?.setParams(
            sensorOrientation, facingFront, cfg.width, cfg.height, z,
        )
    }

    /**
     * Snapshot the current GL frame (post crop / zoom / rotation), JPEG-encode
     * it at the preview resolution, and hand the bytes back on [callback] on
     * the main thread. Independent of the streaming pipeline — safe to invoke
     * whether or not encoding is active.
     */
    fun takePicture(callback: (ByteArray?, String?) -> Unit) {
        val gl = renderer
        if (gl == null || cameraDevice == null) {
            mainHandler.post { callback(null, "相机未打开") }
            return
        }
        val w = previewSize.width
        val h = previewSize.height
        // Time out on the main thread if no GL frame arrives (e.g. camera stall
        // right after open). The snapshot request lives on the GL handler; if
        // the callback fires later we just ignore it (already handled).
        val delivered = java.util.concurrent.atomic.AtomicBoolean(false)
        val timeout = Runnable {
            if (delivered.compareAndSet(false, true)) callback(null, "拍照超时")
        }
        mainHandler.postDelayed(timeout, 1500)
        gl.snapshotRgba(w, h) { rgba, rw, rh ->
            if (!delivered.compareAndSet(false, true)) return@snapshotRgba
            mainHandler.removeCallbacks(timeout)
            try {
                val ints = IntArray(rw * rh)
                var i = 0
                var p = 0
                while (i < rw * rh) {
                    val r = rgba[p].toInt() and 0xFF
                    val g = rgba[p + 1].toInt() and 0xFF
                    val b = rgba[p + 2].toInt() and 0xFF
                    val a = rgba[p + 3].toInt() and 0xFF
                    // Bitmap.Config.ARGB_8888 int layout: 0xAARRGGBB.
                    ints[i] = (a shl 24) or (r shl 16) or (g shl 8) or b
                    i++
                    p += 4
                }
                val bmp = Bitmap.createBitmap(ints, rw, rh, Bitmap.Config.ARGB_8888)
                val bos = java.io.ByteArrayOutputStream(rw * rh)
                bmp.compress(Bitmap.CompressFormat.JPEG, 90, bos)
                bmp.recycle()
                val bytes = bos.toByteArray()
                mainHandler.post { callback(bytes, null) }
            } catch (e: Exception) {
                mainHandler.post { callback(null, "JPEG 编码失败: ${e.message}") }
            }
        }
    }

    /** Display-space visible width/height fractions after crop + zoom. */
    private fun visibleFraction(): Pair<Double, Double> {
        val cfg = config ?: return 1.0 to 1.0
        val swap = sensorOrientation % 180 != 0
        val ew = (if (swap) captureSize.height else captureSize.width).toDouble()
        val eh = (if (swap) captureSize.width else captureSize.height).toDouble()
        val outAspect = cfg.width.toDouble() / cfg.height
        var fx: Double
        var fy: Double
        if (ew / eh > outAspect) {
            fx = (eh * outAspect) / ew
            fy = 1.0
        } else {
            fx = 1.0
            fy = (ew / outAspect) / eh
        }
        val zoom = cfg.cropZoom.coerceAtLeast(1.0)
        return (fx / zoom) to (fy / zoom)
    }

    /** Update live params (crop/zoom/aspect/fps) without reopening the camera. */
    fun setConfig(cfg: EncoderConfig) {
        config = cfg
        renderer?.setParams(
            sensorOrientation, facingFront, cfg.width, cfg.height, cfg.cropZoom,
        )

        // If the output aspect changed, resize the preview texture to match.
        val newPreview = previewSizeFor(cfg.width, cfg.height)
        if (newPreview.width != previewSize.width ||
            newPreview.height != previewSize.height
        ) {
            previewSize = newPreview
            textureEntry?.surfaceTexture()?.setDefaultBufferSize(
                newPreview.width, newPreview.height,
            )
            previewSurface?.release()
            val st = textureEntry?.surfaceTexture()
            if (st != null) {
                val s = Surface(st)
                previewSurface = s
                renderer?.setPreviewSurface(s, newPreview.width, newPreview.height)
            }
            emitCameraReady()
        }

        // Re-issue the repeating request so an updated FPS takes effect.
        issueRepeating()

        // Re-evaluate encoded preview against the new codec / resolution.
        if (previewEncoded) setPreviewMode(true)
    }

    fun closeCamera() {
        stopEncodingInternal()
        try {
            captureSession?.close()
        } catch (_: Exception) {
        }
        captureSession = null
        try {
            cameraDevice?.close()
        } catch (_: Exception) {
        }
        cameraDevice = null

        renderer?.release()
        renderer = null

        previewSurface?.release()
        previewSurface = null
        textureEntry?.release()
        textureEntry = null

        previewEncoded = false
        releaseDecodedTexture()

        stopCameraThread()
    }

    // -------------------------------------------------------------------------
    // Encoding lifecycle
    // -------------------------------------------------------------------------

    fun startEncoding(cfg: EncoderConfig) {
        if (encoding) {
            emitError("已在编码中")
            return
        }
        if (cameraDevice == null || renderer == null) {
            emitError("摄像头未就绪")
            return
        }
        when (cfg.format) {
            "h264" -> startH264(cfg)
            "mvs1", "jpeg" -> startSoftware(cfg)
            else -> emitError("${cfg.format.uppercase()} 编码暂未实现")
        }
    }

    private fun startH264(cfg: EncoderConfig) {
        config = cfg
        software = false
        streaming = cfg.stream
        recordToFile = cfg.recordToFile
        h264Csd = null
        encWidth = cfg.width
        encHeight = cfg.height
        renderer?.setParams(
            sensorOrientation, facingFront, cfg.width, cfg.height, cfg.cropZoom,
        )
        try {
            if (cfg.recordToFile) prepareOutputFile(cfg) else outputFile = null
            configureCodec(cfg)
            _resetStats()
            encoding = true
            finishing = false
            codec?.start()
            // Pace the encoder feed to the transport only when streaming (the
            // link, not the camera, sets the rate). Recording-only runs full fps.
            // Seed a small window so MediaCodec's initial buffering can't stall.
            renderer?.setPaceEncoder(cfg.stream, 2)
            // Throttle the encoder feed to the configured fps so the frame-count
            // GOP (iFrameInterval×fps) maps to the intended wall-clock I-interval
            // and the transmitted rate matches the setting. The camera itself
            // often can't hit low fps (AE range floor), so we drop frames here.
            renderer?.setEncoderTargetFps(cfg.fps)
            renderer?.setEncoderSurface(inputSurface, encWidth, encHeight)
            emitStarted()
        } catch (e: Exception) {
            encoding = false
            emitError("启动编码失败: ${e.message}")
            stopEncodingInternal()
        }
    }

    /** MSV1 / JPEG software encode via GL offscreen readback. */
    private fun startSoftware(cfg: EncoderConfig) {
        config = cfg
        software = true
        streaming = cfg.stream
        recordToFile = cfg.recordToFile
        forceKeyframe = false
        // Insert a key frame every iFrameIntervalSec seconds (MSV1 only) so a
        // dropped block can't corrupt the P-frame chain indefinitely.
        swKeyIntervalFrames = if (cfg.format == "mvs1") {
            Math.max(1, cfg.iFrameIntervalSec) * Math.max(1, cfg.fps)
        } else {
            0
        }
        swFramesSinceKey = 0
        swMode = cfg.format
        // MSV1 requires 4-aligned dimensions; JPEG just even.
        var w = cfg.width
        var h = cfg.height
        if (cfg.format == "mvs1") {
            w = w and 3.inv(); h = h and 3.inv()
            if (w < 4) w = 4; if (h < 4) h = 4
        } else {
            w = w and 1.inv(); h = h and 1.inv()
        }
        encWidth = w
        encHeight = h
        renderer?.setParams(
            sensorOrientation, facingFront, cfg.width, cfg.height, cfg.cropZoom,
        )
        try {
            swFrames.clear(); swKeys.clear()
            prevRgba = null; swBusy = false; swBytes = 0L; swTruncated = false
            _resetStats()
            if (cfg.recordToFile) prepareSoftwareOutputFile(cfg) else outputFile = null
            startCodecThread()
            encoding = true
            finishing = false

            updateReadbackState()
            emitStarted()
        } catch (e: Exception) {
            encoding = false
            software = false
            emitError("启动编码失败: ${e.message}")
        }
    }

    /**
     * GL thread: each readback frame is encoded on the codec thread (dropped if
     * busy). Buffers it for the AVI while recording, and/or decodes it back and
     * draws to the decoded-preview texture while encoded preview is on.
     */
    private fun handleRgbaFrame(rgba: ByteArray, w: Int, h: Int, ptsNs: Long) {
        if (swBusy) return
        val ch = codecHandler ?: return
        val recording = encoding && software
        val doPreview = previewEncoded
        if (!recording && !doPreview) return
        swBusy = true
        ch.post {
            try {
                val cfg = config
                val fmt = cfg?.format ?: "mvs1"
                val encoded: ByteArray
                val isKey: Boolean
                if (fmt == "mvs1") {
                    // A key frame is the first frame, a periodic refresh, or a
                    // re-sync request; otherwise a skip (P-)frame when enabled.
                    val periodic =
                        swKeyIntervalFrames > 0 && swFramesSinceKey >= swKeyIntervalFrames
                    val force = forceKeyframe || periodic
                    if (forceKeyframe) forceKeyframe = false
                    val prev = if (cfg?.msv1Skip != false && !force) prevRgba else null
                    encoded = SoftwareCodec.encodeMsv1(rgba, w, h, prev, cfg?.msv1SkipThr ?: 0)
                    isKey = prev == null
                    swFramesSinceKey = if (isKey) 0 else swFramesSinceKey + 1
                    prevRgba = rgba
                } else {
                    encoded = SoftwareCodec.encodeJpeg(rgba, w, h, cfg?.jpegQuality ?: 80)
                    isKey = true
                }
                if (recording) {
                    countFrame(encoded, isKey, ptsNs)
                    if (recordToFile) bufferFrame(encoded, isKey)
                    if (streaming) emitFrame(encoded, isKey)
                }
                if (doPreview) drawEncodedPreview(fmt, encoded, w, h)
            } catch (e: Exception) {
                emitError("软件编码失败: ${e.message}")
            }
            swBusy = false
        }
    }

    /** Decode the just-encoded frame and blit it to the decoded-preview surface. */
    private fun drawEncodedPreview(fmt: String, encoded: ByteArray, w: Int, h: Int) {
        val s = decodedSurface ?: return
        val bmp: Bitmap = try {
            if (fmt == "mvs1") {
                val arr = decodedArgb ?: return
                SoftwareCodec.decodeMsv1(encoded, w, h, arr)
                Bitmap.createBitmap(arr, w, h, Bitmap.Config.ARGB_8888)
            } else {
                BitmapFactory.decodeByteArray(encoded, 0, encoded.size) ?: return
            }
        } catch (_: Exception) {
            return
        }
        try {
            val canvas = s.lockCanvas(null)
            canvas.drawBitmap(bmp, 0f, 0f, null)
            s.unlockCanvasAndPost(canvas)
        } catch (_: Exception) {
        }
        bmp.recycle()
    }

    /** Enable/disable the encoded-preview round trip (MSV1/JPEG only). */
    fun setPreviewMode(encoded: Boolean) {
        val cfg = config
        val softwareFmt = cfg != null && (cfg.format == "mvs1" || cfg.format == "jpeg")
        if (encoded && !softwareFmt) {
            previewEncoded = false
            releaseDecodedTexture()
            updateReadbackState()
            emitInfo("H.264 编码预览暂不支持，仍显示原画")
            emitPreview()
            return
        }
        previewEncoded = encoded && softwareFmt
        if (previewEncoded) {
            var w = cfg!!.width; var h = cfg.height
            if (cfg.format == "mvs1") {
                w = w and 3.inv(); h = h and 3.inv(); if (w < 4) w = 4; if (h < 4) h = 4
            } else {
                w = w and 1.inv(); h = h and 1.inv()
            }
            if (!(encoding && software)) { encWidth = w; encHeight = h }
            ensureDecodedTexture(encWidth, encHeight)
            prevRgba = null
            decodedArgb = IntArray(encWidth * encHeight)
        } else {
            releaseDecodedTexture()
        }
        updateReadbackState()
        emitPreview()
    }

    /** Turn the GL offscreen readback + encode callback on/off as needed. */
    private fun updateReadbackState() {
        val cfg = config
        val softwareFmt = cfg != null && (cfg.format == "mvs1" || cfg.format == "jpeg")
        val wantSw = softwareFmt && ((encoding && software) || previewEncoded)
        if (wantSw) {
            startCodecThread()
            renderer?.onRgbaFrame = { rgba, w, h, pts -> handleRgbaFrame(rgba, w, h, pts) }
            // Throttle the readback feed to the configured fps (mirrors the H.264
            // encoder-surface throttle set in startH264). Without it the software
            // JPEG/MSV1 encoder ran on every camera frame, so the streamed frame
            // rate followed the camera's AE-floor fps rather than the setting.
            renderer?.setEncoderTargetFps(cfg?.fps ?: 0)
            renderer?.setSoftwareReadback(encWidth, encHeight)
        } else {
            renderer?.onRgbaFrame = null
            renderer?.clearSoftwareReadback()
            if (!encoding) stopCodecThread()
        }
    }

    private fun ensureDecodedTexture(w: Int, h: Int) {
        val existing = decodedEntry
        if (existing != null) {
            existing.surfaceTexture().setDefaultBufferSize(w, h)
            decodedSurface?.release()
            decodedSurface = Surface(existing.surfaceTexture())
            return
        }
        val entry = textureRegistry.createSurfaceTexture()
        decodedEntry = entry
        entry.surfaceTexture().setDefaultBufferSize(w, h)
        decodedSurface = Surface(entry.surfaceTexture())
    }

    private fun releaseDecodedTexture() {
        decodedSurface?.release()
        decodedSurface = null
        decodedEntry?.release()
        decodedEntry = null
        decodedArgb = null
    }

    private fun emitPreview() {
        val encoded = previewEncoded
        val id = if (encoded) (decodedEntry?.id() ?: -1L) else -1L
        val w = encWidth
        val h = encHeight
        mainHandler.post {
            events.onEvent(
                mapOf(
                    "event" to "preview",
                    "encoded" to encoded,
                    "textureId" to id,
                    "width" to w,
                    "height" to h,
                ),
            )
        }
    }

    /** Update live stats for one encoded frame (streaming and/or recording). */
    private fun countFrame(encoded: ByteArray, isKey: Boolean, ptsNs: Long) {
        frameCount++
        if (isKey) {
            keyframeCount++
            keyframeBytes += encoded.size
        }
        totalBytes += encoded.size
        lastFrameBytes = encoded.size
        val ptsUs = ptsNs / 1000
        if (firstPtsUs < 0) firstPtsUs = ptsUs
        lastPtsUs = ptsUs
        maybeEmitStats()
    }

    /** Buffer one encoded frame for the AVI mux (record-to-file only). */
    private fun bufferFrame(encoded: ByteArray, isKey: Boolean) {
        swBytes += encoded.size
        if (swBytes <= swMaxBytes && swFrames.size < swMaxFrames) {
            swFrames.add(encoded)
            swKeys.add(isKey)
        } else if (!swTruncated) {
            swTruncated = true
            emitInfo("帧缓冲已达上限，后续帧不再写入文件（编码继续）")
        }
    }

    /** Hand one encoded frame to Dart for transmission over the stream. */
    private fun emitFrame(encoded: ByteArray, isKey: Boolean) {
        mainHandler.post {
            events.onEvent(
                mapOf("event" to "frame", "data" to encoded, "key" to isKey),
            )
        }
    }

    /** Ask the encoder to emit a fresh key frame so a congested / re-synced
     *  stream can recover without a full restart. MSV1 drops skip once; H.264
     *  requests an on-demand sync (IDR) frame from MediaCodec. */
    fun requestKeyframe() {
        forceKeyframe = true
        val c = codec
        if (!software && c != null) {
            try {
                val params = android.os.Bundle()
                params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                c.setParameters(params)
            } catch (_: Exception) {
            }
        }
    }

    /** Permit one more paced encoder frame (H.264 stream: called after each
     *  frame is transmitted, so production tracks the link — never dropping). */
    fun requestEncoderFrame() {
        renderer?.grantEncoderPermit()
    }

    fun stopEncoding() {
        if (!encoding) return
        encoding = false
        if (software) {
            finishSoftware()
            return
        }
        // H.264: stop feeding the encoder, then flush with an EOS signal.
        renderer?.setPaceEncoder(false, 0)
        renderer?.setEncoderSurface(null, 0, 0)
        try {
            codec?.signalEndOfInputStream()
        } catch (e: Exception) {
            finishEncoding()
        }
    }

    /** Stop software encode, mux the buffered frames into an AVI, emit stopped.
     *  Keeps the readback/encode path alive if encoded preview is still on. */
    private fun finishSoftware() {
        software = false
        streaming = false
        val record = recordToFile
        val ch = codecHandler
        val file = if (record) outputFile else null
        val frames = frameCount
        val keyframes = keyframeCount
        val bytes = totalBytes
        if (ch == null) {
            updateReadbackState()
            _emitStopped(file, frames, keyframes, bytes)
            return
        }
        // Runs after any queued encode tasks so all frames are muxed.
        ch.post {
            if (record) {
                try {
                    writeAvi(outputFile)
                } catch (e: Exception) {
                    emitError("写入 AVI 失败: ${e.message}")
                }
            }
            mainHandler.post {
                swFrames.clear(); swKeys.clear()
                updateReadbackState() // stops readback/thread only if preview off
                _emitStopped(file, frames, keyframes, bytes)
            }
        }
    }

    private fun writeAvi(file: File?) {
        if (file == null || swFrames.isEmpty()) return
        val fourcc = if (swMode == "mvs1") "MSVC" else "MJPG"
        val bitCount = if (swMode == "mvs1") 16 else 24
        val fps = config?.fps ?: 15
        val keyFlags = if (swMode == "mvs1") {
            BooleanArray(swKeys.size) { swKeys[it] }
        } else {
            null
        }
        val avi = SoftwareCodec.buildAvi(
            swFrames, encWidth, encHeight, fps, fourcc, bitCount, keyFlags,
        )
        FileOutputStream(file).use { it.write(avi) }
    }

    private fun _resetStats() {
        frameCount = 0
        keyframeCount = 0
        totalBytes = 0L
        keyframeBytes = 0L
        lastFrameBytes = 0
        firstPtsUs = -1L
        lastPtsUs = 0L
    }

    private fun emitStarted() {
        val path = outputFile?.absolutePath
        val w = encWidth
        val h = encHeight
        mainHandler.post {
            events.onEvent(
                mapOf(
                    "event" to "started", "path" to path, "width" to w, "height" to h,
                ),
            )
        }
    }

    private fun _emitStopped(file: File?, frames: Int, keyframes: Int, bytes: Long) {
        events.onEvent(
            mapOf(
                "event" to "stopped",
                "path" to file?.absolutePath,
                "frames" to frames,
                "keyframes" to keyframes,
                "bytes" to bytes,
            ),
        )
    }

    private fun configureCodec(cfg: EncoderConfig) {
        startCodecThread()

        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC, encWidth, encHeight,
        )
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
        )
        format.setInteger(MediaFormat.KEY_BIT_RATE, cfg.bitrate)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, cfg.fps)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, cfg.iFrameIntervalSec)

        // Constrained baseline profile, YUV420 (Surface input), no B-frames.
        format.setInteger(
            MediaFormat.KEY_PROFILE,
            MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedBaseline,
        )
        format.setInteger(
            MediaFormat.KEY_LEVEL,
            MediaCodecInfo.CodecProfileLevel.AVCLevel31,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            format.setInteger(MediaFormat.KEY_LATENCY, 1)
        }
        // CBR bounds per-frame size (esp. the IDR) far better than VBR at the
        // low bitrates used for BLE streaming — VBR lets the key frame spike.
        format.setInteger(
            MediaFormat.KEY_BITRATE_MODE,
            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR,
        )

        val mediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        mediaCodec.setCallback(codecCallback, codecHandler)
        mediaCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = mediaCodec.createInputSurface()
        codec = mediaCodec
    }

    private val codecCallback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {
            // Surface input — no manual input buffers.
        }

        override fun onOutputBufferAvailable(
            mc: MediaCodec,
            index: Int,
            info: MediaCodec.BufferInfo,
        ) {
            try {
                val buffer: ByteBuffer? = mc.getOutputBuffer(index)
                if (buffer != null && info.size > 0) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size)
                    buffer.get(bytes)
                    if (recordToFile) outputStream?.write(bytes)
                    totalBytes += info.size

                    val isConfig =
                        (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isKey =
                        (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                    if (isConfig) {
                        // SPS/PPS — cache to prepend to each streamed IDR.
                        h264Csd = bytes
                    } else {
                        frameCount++
                        if (isKey) {
                            keyframeCount++
                            keyframeBytes += info.size
                        }
                        lastFrameBytes = info.size
                        if (firstPtsUs < 0) firstPtsUs = info.presentationTimeUs
                        lastPtsUs = info.presentationTimeUs
                        if (streaming) {
                            val csd = h264Csd
                            val out = if (isKey && csd != null) csd + bytes else bytes
                            emitFrame(out, isKey)
                        }
                        maybeEmitStats()
                    }
                }
                mc.releaseOutputBuffer(index, false)

                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    finishEncoding()
                }
            } catch (e: Exception) {
                emitError("写入失败: ${e.message}")
            }
        }

        override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
            emitError("编码器错误: ${e.message}")
        }

        override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
            // SPS/PPS arrive as a CODEC_CONFIG output buffer for Annex-B output.
        }
    }

    private fun maybeEmitStats() {
        if (frameCount % 10 != 0) return
        val durSec = if (firstPtsUs >= 0) (lastPtsUs - firstPtsUs) / 1_000_000.0 else 0.0
        val fps = if (durSec > 0) frameCount / durSec else 0.0
        val frames = frameCount
        val keyframes = keyframeCount
        val bytes = totalBytes
        val keyBytes = keyframeBytes
        val lastB = lastFrameBytes
        mainHandler.post {
            events.onEvent(
                mapOf(
                    "event" to "stats",
                    "frames" to frames,
                    "keyframes" to keyframes,
                    "bytes" to bytes,
                    "keyBytes" to keyBytes,
                    "fps" to fps,
                    "lastBytes" to lastB,
                ),
            )
        }
    }

    /** Drained EOS (codec thread) → tear down on the main thread. */
    private fun finishEncoding() {
        if (finishing) return
        finishing = true
        val file = if (recordToFile) outputFile else null
        val frames = frameCount
        val keyframes = keyframeCount
        val bytes = totalBytes
        mainHandler.post {
            stopEncodingInternal()
            events.onEvent(
                mapOf(
                    "event" to "stopped",
                    "path" to file?.absolutePath,
                    "frames" to frames,
                    "keyframes" to keyframes,
                    "bytes" to bytes,
                ),
            )
        }
    }

    private fun stopEncodingInternal() {
        encoding = false
        streaming = false
        // Software encode teardown (abandon any buffered frames — used on
        // error / camera close, not the normal AVI-writing stop path).
        if (software) {
            software = false
            renderer?.onRgbaFrame = null
            renderer?.clearSoftwareReadback()
            swFrames.clear(); swKeys.clear(); prevRgba = null
        }
        renderer?.setPaceEncoder(false, 0)
        renderer?.setEncoderSurface(null, 0, 0)
        try {
            codec?.stop()
        } catch (_: Exception) {
        }
        try {
            codec?.release()
        } catch (_: Exception) {
        }
        codec = null
        inputSurface?.release()
        inputSurface = null

        try {
            outputStream?.flush()
            outputStream?.close()
        } catch (_: Exception) {
        }
        outputStream = null

        stopCodecThread()
    }

    // -------------------------------------------------------------------------
    // Output file
    // -------------------------------------------------------------------------

    private fun prepareOutputFile(cfg: EncoderConfig) {
        val dir = File(context.getExternalFilesDir(null), "encode_test")
        if (!dir.exists()) dir.mkdirs()
        val name = "enc_${encWidth}x${encHeight}_${cfg.fps}fps_${nextSeq()}.h264"
        val file = File(dir, name)
        outputFile = file
        outputStream = FileOutputStream(file)
    }

    /** Software codecs are muxed into an AVI on stop; just pick the path here. */
    private fun prepareSoftwareOutputFile(cfg: EncoderConfig) {
        val dir = File(context.getExternalFilesDir(null), "encode_test")
        if (!dir.exists()) dir.mkdirs()
        val tag = if (cfg.format == "mvs1") "msv1" else "mjpg"
        outputFile = File(dir, "enc_${tag}_${encWidth}x${encHeight}_${cfg.fps}fps_${nextSeq()}.avi")
        outputStream = null
    }

    // -------------------------------------------------------------------------
    // Threads
    // -------------------------------------------------------------------------

    private fun startCameraThread() {
        if (cameraThread != null) return
        cameraThread = HandlerThread("CameraThread").apply { start() }
        cameraHandler = Handler(cameraThread!!.looper)
    }

    private fun stopCameraThread() {
        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null
    }

    private fun startCodecThread() {
        if (codecThread != null) return
        codecThread = HandlerThread("CodecThread").apply { start() }
        codecHandler = Handler(codecThread!!.looper)
    }

    private fun stopCodecThread() {
        codecThread?.quitSafely()
        codecThread = null
        codecHandler = null
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private fun pickCameraId(facing: Int): String? {
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            if (chars.get(CameraCharacteristics.LENS_FACING) == facing) return id
        }
        return cameraManager.cameraIdList.firstOrNull()
    }

    private fun chooseSize(sizes: Array<Size>?, targetW: Int, targetH: Int): Size {
        if (sizes == null || sizes.isEmpty()) return Size(targetW, targetH)
        val targetArea = targetW.toLong() * targetH
        return sizes.minByOrNull {
            Math.abs(it.width.toLong() * it.height - targetArea)
        } ?: sizes[0]
    }

    /** Preview texture size at the output aspect ratio, long side ~1280. */
    private fun previewSizeFor(outW: Int, outH: Int): Size {
        if (outW <= 0 || outH <= 0) return Size(1280, 720)
        val aspect = outW.toDouble() / outH
        var pw: Int
        var ph: Int
        if (aspect >= 1.0) {
            pw = 1280
            ph = (1280 / aspect).toInt()
        } else {
            ph = 1280
            pw = (1280 * aspect).toInt()
        }
        pw = (pw / 2) * 2
        ph = (ph / 2) * 2
        return Size(pw.coerceAtLeast(2), ph.coerceAtLeast(2))
    }

    private fun chooseFpsRange(target: Int): android.util.Range<Int> {
        val ranges = availableFpsRanges
        if (ranges == null || ranges.isEmpty()) {
            return android.util.Range(target, target)
        }
        return ranges.minByOrNull { r ->
            val containsPenalty = if (target in r.lower..r.upper) 0 else 1000
            val fixedBonus = if (r.lower == r.upper) -1 else 0
            containsPenalty + Math.abs(r.upper - target) + fixedBonus
        } ?: android.util.Range(target, target)
    }

    private fun emitCameraReady() {
        val id = textureEntry?.id() ?: -1L
        val pw = previewSize.width
        val ph = previewSize.height
        val range = aeCompRange
        val evMin = if (range != null) range.lower * aeCompStep else 0.0
        val evMax = if (range != null) range.upper * aeCompStep else 0.0
        val focusSupported = maxAfRegions > 0 || maxAeRegions > 0
        mainHandler.post {
            events.onEvent(
                mapOf(
                    "event" to "camera",
                    "textureId" to id,
                    "previewWidth" to pw,
                    "previewHeight" to ph,
                    // Rotation is handled in GL, so the texture is already upright.
                    "sensorOrientation" to 0,
                    "facingFront" to facingFront,
                    "evMin" to evMin,
                    "evMax" to evMax,
                    "evStep" to aeCompStep,
                    "focusSupported" to focusSupported,
                ),
            )
        }
    }

    private fun emitError(message: String) {
        mainHandler.post {
            events.onEvent(mapOf("event" to "error", "message" to message))
        }
    }

    private fun emitInfo(message: String) {
        mainHandler.post {
            events.onEvent(mapOf("event" to "info", "message" to message))
        }
    }

    companion object {
        private var seq = 0
        private fun nextSeq(): Int = ++seq
    }
}
