package com.honeygui.honeybox

import android.graphics.SurfaceTexture
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * GL intermediate stage for the camera → encoder pipeline.
 *
 * Camera2 renders into a single OES external texture (the camera
 * [SurfaceTexture]). On every frame this renderer draws that texture — with
 * **crop → uniform-scale → rotation** baked into the texture-coordinate
 * transform — into two EGL window surfaces:
 *   - the Flutter preview texture (always), and
 *   - the MediaCodec input surface (only while encoding).
 *
 * Because the GL stage scales, the encoder output can be any resolution
 * independent of the camera's supported sizes, and crop/scale is uniform
 * (等比例): a centered region matching the output aspect ratio is cropped first,
 * then scaled to fill the output.
 */
class GlRenderer(
    private val onError: (String) -> Unit,
    private val onInfo: (String) -> Unit = {},
) {
    @Volatile private var diagPending = true

    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    private var egl: EglCore? = null
    private var offscreen: EGLSurface? = null

    private var oesTextureId = 0
    private var program = 0
    private var aPositionLoc = 0
    private var aTexCoordLoc = 0
    private var uTexMatrixLoc = 0
    private var uXformLoc = 0

    private var cameraSurfaceTexture: SurfaceTexture? = null
    private var cameraSurface: Surface? = null
    private var cameraW = 1280
    private var cameraH = 720

    private var previewEgl: EGLSurface? = null
    private var previewW = 0
    private var previewH = 0

    private var encoderEgl: EGLSurface? = null
    private var encoderW = 0
    private var encoderH = 0

    // Encoder feed pacing (H.264 streaming): when [paceEncoder] is on, a camera
    // frame is drawn to the encoder surface only while a permit is available —
    // one permit is consumed per encoded frame and replenished by the app after
    // that frame has been fully transmitted. This throttles production to the
    // link (never dropping an already-encoded frame, which would break the H.264
    // P-frame chain). Skipping a camera frame BEFORE encoding is harmless: the
    // next encoded frame is simply a P-frame relative to the previous encoded one.
    @Volatile private var paceEncoder = false
    private val encoderPermits = java.util.concurrent.atomic.AtomicInteger(0)

    // Encode-feed fps throttle: skip camera frames so the active encode feed is fed
    // at most [minEncoderIntervalNs] apart (0 = no throttle → feed every camera
    // frame). Shared by both feeds — the MediaCodec encoder surface (H.264) and the
    // software readback (JPEG/MSV1) — which are mutually exclusive per session but
    // keep independent last-feed accumulators. Measured against camera-frame
    // presentation timestamps (ns), not wall clock.
    @Volatile private var minEncoderIntervalNs = 0L
    private var lastEncoderFeedNs = 0L
    private var lastReadbackFeedNs = 0L

    // Offscreen readback (software MSV1/JPEG encode): render to a pbuffer and
    // glReadPixels the top-down RGBA out to [onRgbaFrame].
    private var readbackEgl: EGLSurface? = null
    private var rbW = 0
    private var rbH = 0
    @Volatile private var softwareMode = false
    private var rbBuffer: ByteBuffer? = null
    var onRgbaFrame: ((ByteArray, Int, Int, Long) -> Unit)? = null

    // One-shot snapshot request. When non-null, the next drawFrame() renders the
    // current camera frame to a temporary pbuffer of size [snapW]×[snapH], reads
    // it back top-down, invokes the callback with the RGBA bytes, then clears
    // the request. Independent of [softwareMode] so single-shot capture works
    // regardless of whether streaming is on.
    private var pendingSnapshot: ((ByteArray, Int, Int) -> Unit)? = null
    private var snapW = 0
    private var snapH = 0

    // Render params (output aspect / crop / rotation), updated via setParams.
    @Volatile private var sensorOrientation = 90
    @Volatile private var mirror = false
    @Volatile private var outAspectW = 4
    @Volatile private var outAspectH = 3
    @Volatile private var cropZoom = 1.0

    private val stMatrix = FloatArray(16)
    private val xform = FloatArray(16)

    private val vertexBuf: FloatBuffer = floatBuffer(
        floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f),
    )
    private val texBuf: FloatBuffer = floatBuffer(
        floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f),
    )

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /** Start the GL thread and create the camera input surface. */
    fun start(captureW: Int, captureH: Int, onCameraSurface: (Surface) -> Unit) {
        cameraW = captureW
        cameraH = captureH
        val t = HandlerThread("GlThread").apply { start() }
        thread = t
        val h = Handler(t.looper)
        handler = h
        h.post {
            try {
                val core = EglCore()
                egl = core
                offscreen = core.createOffscreenSurface(1, 1)
                core.makeCurrent(offscreen!!)

                oesTextureId = createOesTexture()
                program = buildProgram()
                aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
                aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTexCoord")
                uTexMatrixLoc = GLES20.glGetUniformLocation(program, "uTexMatrix")
                uXformLoc = GLES20.glGetUniformLocation(program, "uXform")

                val st = SurfaceTexture(oesTextureId)
                st.setDefaultBufferSize(cameraW, cameraH)
                st.setOnFrameAvailableListener({ h.post { drawFrame() } }, h)
                cameraSurfaceTexture = st
                val surface = Surface(st)
                cameraSurface = surface
                onCameraSurface(surface)
            } catch (e: Exception) {
                onError("GL 初始化失败: ${e.message}")
            }
        }
    }

    fun setParams(
        sensorOrientation: Int,
        mirror: Boolean,
        outAspectW: Int,
        outAspectH: Int,
        cropZoom: Double,
    ) {
        this.sensorOrientation = ((sensorOrientation % 360) + 360) % 360
        this.mirror = mirror
        if (outAspectW > 0 && outAspectH > 0) {
            this.outAspectW = outAspectW
            this.outAspectH = outAspectH
        }
        this.cropZoom = cropZoom.coerceAtLeast(1.0)
        diagPending = true
    }

    fun setPreviewSurface(surface: Surface?, w: Int, h: Int) {
        val h2 = handler ?: return
        h2.post {
            try {
                previewEgl?.let { egl?.releaseSurface(it) }
                previewEgl = null
                if (surface != null) {
                    previewEgl = egl?.createWindowSurface(surface)
                    previewW = w
                    previewH = h
                }
            } catch (e: Exception) {
                onError("预览 Surface 创建失败: ${e.message}")
            }
        }
    }

    fun setEncoderSurface(surface: Surface?, w: Int, h: Int) {
        val h2 = handler ?: return
        h2.post {
            try {
                encoderEgl?.let { egl?.releaseSurface(it) }
                encoderEgl = null
                if (surface != null) {
                    encoderEgl = egl?.createWindowSurface(surface)
                    encoderW = w
                    encoderH = h
                }
            } catch (e: Exception) {
                onError("编码 Surface 创建失败: ${e.message}")
            }
        }
    }

    fun cameraSurface(): Surface? = cameraSurface

    /** Enable/disable encoder-feed pacing and seed the initial permit window. */
    fun setPaceEncoder(enabled: Boolean, initialPermits: Int) {
        paceEncoder = enabled
        encoderPermits.set(if (enabled) initialPermits else 0)
    }

    /** Cap both encode feeds (encoder surface + software readback) at [fps] fps (0 = no throttle). */
    fun setEncoderTargetFps(fps: Int) {
        minEncoderIntervalNs = if (fps > 0) (1_000_000_000L / fps) else 0L
        lastEncoderFeedNs = 0L
        lastReadbackFeedNs = 0L
    }

    /** Replenish one permit (call after a paced frame has been transmitted). */
    fun grantEncoderPermit() {
        if (paceEncoder) encoderPermits.incrementAndGet()
    }

    /** Enable offscreen readback at [w]×[h] for software encoding. */
    fun setSoftwareReadback(w: Int, h: Int) {
        val hh = handler ?: return
        hh.post {
            try {
                readbackEgl?.let { egl?.releaseSurface(it) }
                readbackEgl = egl?.createOffscreenSurface(w, h)
                rbW = w
                rbH = h
                rbBuffer = ByteBuffer.allocateDirect(w * h * 4)
                    .order(ByteOrder.nativeOrder())
                softwareMode = true
            } catch (e: Exception) {
                onError("离屏缓冲创建失败: ${e.message}")
            }
        }
    }

    fun clearSoftwareReadback() {
        softwareMode = false
        val hh = handler ?: return
        hh.post {
            readbackEgl?.let { egl?.releaseSurface(it) }
            readbackEgl = null
            rbBuffer = null
        }
    }

    /**
     * One-shot snapshot: on the next drawn camera frame, render at [w]×[h] into
     * a temporary offscreen pbuffer, read back top-down RGBA, and invoke
     * [callback] on the GL thread with (rgba, w, h). The pbuffer is released
     * before the callback returns. Overwrites any pending snapshot.
     *
     * Independent of [softwareMode] — safe to call whether or not streaming is
     * active. If no camera frame arrives within a reasonable window, the caller
     * should time out on its side (this method does not schedule its own timer).
     */
    fun snapshotRgba(w: Int, h: Int, callback: (ByteArray, Int, Int) -> Unit) {
        val hh = handler ?: return
        hh.post {
            pendingSnapshot = callback
            snapW = w
            snapH = h
        }
    }

    fun release() {
        val h = handler
        val t = thread
        handler = null
        thread = null
        h?.post {
            try {
                previewEgl?.let { egl?.releaseSurface(it) }
                encoderEgl?.let { egl?.releaseSurface(it) }
                readbackEgl?.let { egl?.releaseSurface(it) }
                offscreen?.let { egl?.releaseSurface(it) }
                cameraSurfaceTexture?.release()
                cameraSurface?.release()
                if (program != 0) GLES20.glDeleteProgram(program)
                egl?.release()
            } catch (_: Exception) {
            }
            t?.quitSafely()
        }
    }

    // -------------------------------------------------------------------------
    // Rendering
    // -------------------------------------------------------------------------

    private fun drawFrame() {
        val core = egl ?: return
        val st = cameraSurfaceTexture ?: return
        try {
            core.makeCurrent(offscreen!!)
            st.updateTexImage()
            st.getTransformMatrix(stMatrix)
            computeXform()

            previewEgl?.let { renderTo(core, it, previewW, previewH, presentNs = 0L) }
            encoderEgl?.let {
                // Two independent gates decide whether this camera frame is fed to
                // the encoder:
                //  1. fps throttle — cap production at the configured target fps so
                //     the encoder's frame-count GOP (iFrameInterval×fps) maps to the
                //     intended wall-clock I-interval and bandwidth matches the setting.
                //  2. link pacing — never encode faster than BLE drains (permit
                //     window), so we never drop an already-encoded P-frame.
                val ts = st.timestamp
                val fpsOk = minEncoderIntervalNs <= 0L ||
                    lastEncoderFeedNs == 0L ||
                    ts - lastEncoderFeedNs >= minEncoderIntervalNs
                val paceOk = !paceEncoder || encoderPermits.get() > 0
                if (fpsOk && paceOk) {
                    if (paceEncoder) encoderPermits.decrementAndGet()
                    lastEncoderFeedNs = ts
                    renderTo(core, it, encoderW, encoderH, presentNs = ts)
                }
            }
            if (softwareMode) {
                // fps throttle (same target as the encoder surface): the software
                // JPEG/MSV1 encoder is fed from this readback, so cap it at the
                // configured fps. Without this the readback ran on every camera
                // frame, so the streamed rate followed the camera's AE-floor fps
                // instead of the setting. Skipping a frame before readback is
                // harmless — MSV1 P-frames are relative to the previous *encoded*
                // frame (prevRgba updates only on encoded frames).
                val ts = st.timestamp
                val fpsOk = minEncoderIntervalNs <= 0L ||
                    lastReadbackFeedNs == 0L ||
                    ts - lastReadbackFeedNs >= minEncoderIntervalNs
                if (fpsOk) {
                    lastReadbackFeedNs = ts
                    renderReadback(core, ts)
                }
            }
            pendingSnapshot?.let { cb ->
                pendingSnapshot = null
                runSnapshot(core, cb, snapW, snapH)
            }
        } catch (e: Exception) {
            onError("渲染失败: ${e.message}")
        }
    }

    /** Render to the offscreen pbuffer and read back top-down RGBA. */
    private fun renderReadback(core: EglCore, presentNs: Long) {
        val target = readbackEgl ?: return
        val buf = rbBuffer ?: return
        val cb = onRgbaFrame ?: return
        // Draw the same cropped/scaled frame; do NOT swap (pbuffer back buffer
        // would become undefined and glReadPixels must read the drawn buffer).
        renderTo(core, target, rbW, rbH, presentNs = 0L, swap = false)
        buf.position(0)
        GLES20.glReadPixels(0, 0, rbW, rbH, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
        // glReadPixels is bottom-up; flip rows to top-down for the encoders.
        val stride = rbW * 4
        val bottomUp = ByteArray(rbW * rbH * 4)
        buf.position(0)
        buf.get(bottomUp)
        val topDown = ByteArray(rbW * rbH * 4)
        for (y in 0 until rbH) {
            System.arraycopy(bottomUp, (rbH - 1 - y) * stride, topDown, y * stride, stride)
        }
        cb(topDown, rbW, rbH, presentNs)
    }

    /**
     * One-shot snapshot render. Creates a temp pbuffer at [w]×[h], renders the
     * current OES texture through the same crop/scale/rotation transform, reads
     * back top-down RGBA, releases the pbuffer, and invokes [cb]. Errors are
     * swallowed silently (the caller's timeout handles the miss).
     */
    private fun runSnapshot(
        core: EglCore,
        cb: (ByteArray, Int, Int) -> Unit,
        w: Int,
        h: Int,
    ) {
        if (w <= 0 || h <= 0) return
        var target: EGLSurface? = null
        try {
            target = core.createOffscreenSurface(w, h)
            renderTo(core, target, w, h, presentNs = 0L, swap = false)
            val stride = w * 4
            val buf = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
            GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
            val bottomUp = ByteArray(w * h * 4)
            buf.position(0)
            buf.get(bottomUp)
            val topDown = ByteArray(w * h * 4)
            for (y in 0 until h) {
                System.arraycopy(bottomUp, (h - 1 - y) * stride, topDown, y * stride, stride)
            }
            cb(topDown, w, h)
        } catch (e: Exception) {
            onError("拍照失败: ${e.message}")
        } finally {
            target?.let { egl?.releaseSurface(it) }
        }
    }

    private fun renderTo(
        core: EglCore,
        target: EGLSurface,
        w: Int,
        h: Int,
        presentNs: Long,
        swap: Boolean = true,
    ) {
        core.makeCurrent(target)
        GLES20.glViewport(0, 0, w, h)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        GLES20.glUseProgram(program)

        vertexBuf.position(0)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, vertexBuf)
        GLES20.glEnableVertexAttribArray(aPositionLoc)

        texBuf.position(0)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texBuf)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)

        GLES20.glUniformMatrix4fv(uTexMatrixLoc, 1, false, stMatrix, 0)
        GLES20.glUniformMatrix4fv(uXformLoc, 1, false, xform, 0)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)

        if (presentNs > 0L) core.setPresentationTime(target, presentNs)
        if (swap) core.swapBuffers(target)
    }

    /**
     * Build the texture-coordinate transform: crop a centered region matching
     * the output aspect ratio (then apply zoom), and rotate to upright.
     */
    private fun computeXform() {
        // Detect whether the SurfaceTexture matrix swaps the axes (a 90°/270°
        // rotation): the input s-axis maps to output vector (m[0], m[1]); if it
        // lands mostly on the t' (vertical) axis, the axes are swapped. Reading
        // this from the actual matrix (rather than assuming from
        // sensorOrientation) keeps crop aspect correct regardless of whether the
        // device's camera bakes rotation into uTexMatrix.
        val swap = Math.abs(stMatrix[1]) > Math.abs(stMatrix[0])

        // Upright (displayed) effective camera dimensions.
        val ew = (if (swap) cameraH else cameraW).toDouble()
        val eh = (if (swap) cameraW else cameraH).toDouble()
        val outAspect = outAspectW.toDouble() / outAspectH

        var fx: Double
        var fy: Double
        if (ew / eh > outAspect) {
            fx = (eh * outAspect) / ew
            fy = 1.0
        } else {
            fx = 1.0
            fy = (ew / outAspect) / eh
        }
        fx /= cropZoom
        fy /= cropZoom

        // The quad pairs screen-horizontal with texcoord-s and screen-vertical
        // with texcoord-t (always), so the s-scale is the display-WIDTH fraction
        // and the t-scale is the display-HEIGHT fraction — regardless of `swap`.
        // `swap` only affected which camera dimension is the display width/height
        // (used above to compute fx/fy); it must NOT swap the scale assignment,
        // or the crop lands on the wrong axis and the frame is distorted.
        val sx = fx.toFloat()
        val sy = fy.toFloat()

        // NOTE: this device's camera SurfaceTexture transform matrix (uTexMatrix)
        // already orients the frame upright, so we must NOT apply another
        // `rotateM(sensorOrientation)` here — doing so double-rotates the preview
        // 90° clockwise. We only apply crop scaling (in the camera's native axes,
        // with parity from sensorOrientation) and optional front-camera mirror.
        Matrix.setIdentityM(xform, 0)
        Matrix.translateM(xform, 0, 0.5f, 0.5f, 0f)
        if (mirror) Matrix.scaleM(xform, 0, -1f, 1f, 1f)
        Matrix.scaleM(xform, 0, sx, sy, 1f)
        Matrix.translateM(xform, 0, -0.5f, -0.5f, 0f)

        if (diagPending) {
            diagPending = false
            onInfo(
                "诊断 swap=$swap cam=${cameraW}x$cameraH " +
                    "out=${outAspectW}:$outAspectH sx=${"%.3f".format(sx)} " +
                    "sy=${"%.3f".format(sy)} m0=${"%.2f".format(stMatrix[0])} " +
                    "m1=${"%.2f".format(stMatrix[1])} m4=${"%.2f".format(stMatrix[4])} " +
                    "m5=${"%.2f".format(stMatrix[5])}",
            )
        }
    }

    // -------------------------------------------------------------------------
    // GL helpers
    // -------------------------------------------------------------------------

    private fun createOesTexture(): Int {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        val id = ids[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, id)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )
        return id
    }

    private fun buildProgram(): Int {
        val vs = """
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            uniform mat4 uTexMatrix;
            uniform mat4 uXform;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uTexMatrix * uXform * aTexCoord).xy;
            }
        """.trimIndent()
        val fs = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTexCoord);
            }
        """.trimIndent()

        val vShader = compileShader(GLES20.GL_VERTEX_SHADER, vs)
        val fShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fs)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vShader)
        GLES20.glAttachShader(prog, fShader)
        GLES20.glLinkProgram(prog)
        val status = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetProgramInfoLog(prog)
            throw RuntimeException("着色器链接失败: $log")
        }
        GLES20.glDeleteShader(vShader)
        GLES20.glDeleteShader(fShader)
        return prog
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw RuntimeException("着色器编译失败: $log")
        }
        return shader
    }

    private fun floatBuffer(data: FloatArray): FloatBuffer {
        return ByteBuffer.allocateDirect(data.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(data)
                position(0)
            }
    }
}
