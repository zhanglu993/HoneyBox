package com.honeygui.honeybox

/** Kotlin ownership facade for the framework-independent Honey Media Core C ABI. */
internal object NativeMediaCodec {
    const val FRAME_FLAG_KEY = 0x0000_0001
    const val FRAME_FLAG_KEY_KNOWN = 0x0000_0002

    init {
        System.loadLibrary("honey_media_jni")
    }

    data class EncodedFrame(
        val bytes: ByteArray,
        val frameFlags: Int,
    )

    data class AviInfo(
        val width: Int,
        val height: Int,
        val usecPerFrame: Int,
        val frameRateNum: Int,
        val frameRateDen: Int,
        val handlerFourcc: Int,
        val compressionFourcc: Int,
        val bitCount: Int,
        val frameCount: Int,
    )

    data class AviFrameInfo(
        val chunkFourcc: Int,
        val aviIndexFlags: Int,
        val frameFlags: Int,
    )

    data class CinepakOptions(
        val quality: Int = 60,
        val v1Size: Int = 256,
        val v4Size: Int = 256,
        val refineIterations: Int = 3,
        val chromaWeight: Int = 4,
        val strips: Int = 2,
        val skipThreshold: Int = 720,
        val keyInterval: Int = 0,
    )

    fun abiVersion(): Int = nativeAbiVersion()

    fun fourcc(value: String): Int {
        require(value.length == 4) { "FOURCC must contain exactly four characters" }
        return (value[0].code and 0xff) or
            ((value[1].code and 0xff) shl 8) or
            ((value[2].code and 0xff) shl 16) or
            ((value[3].code and 0xff) shl 24)
    }

    fun encodeMsv1(
        rgba: ByteArray,
        width: Int,
        height: Int,
        previousRgba: ByteArray?,
        skipThreshold: Int,
        forceKey: Boolean,
    ): EncodedFrame {
        val frameFlags = IntArray(1)
        val bytes = nativeMsv1Encode(
            rgba,
            width,
            height,
            previousRgba,
            skipThreshold,
            forceKey,
            frameFlags,
        )
        return EncodedFrame(bytes, frameFlags[0])
    }

    fun decodeMsv1(
        encoded: ByteArray,
        width: Int,
        height: Int,
        persistentArgb: IntArray,
    ) {
        nativeMsv1Decode(encoded, width, height, persistentArgb)
    }

    class CinepakEncoder(
        width: Int,
        height: Int,
        options: CinepakOptions = CinepakOptions(),
    ) : AutoCloseable {
        private var handle = nativeCinepakEncoderCreate(
            width,
            height,
            options.quality,
            options.v1Size,
            options.v4Size,
            options.refineIterations,
            options.chromaWeight,
            options.strips,
            options.skipThreshold,
            options.keyInterval,
        )

        @Synchronized
        fun encode(rgba: ByteArray, forceKey: Boolean = false): EncodedFrame {
            val frameFlags = IntArray(1)
            val bytes = nativeCinepakEncoderEncode(openHandle(), rgba, forceKey, frameFlags)
            return EncodedFrame(bytes, frameFlags[0])
        }

        @Synchronized
        fun reset() {
            nativeCinepakEncoderReset(openHandle())
        }

        @Synchronized
        override fun close() {
            val current = handle
            if (current == 0L) return
            handle = 0L
            nativeCinepakEncoderDestroy(current)
        }

        private fun openHandle(): Long {
            check(handle != 0L) { "Cinepak encoder is closed" }
            return handle
        }
    }

    class CinepakDecoder(width: Int, height: Int) : AutoCloseable {
        private var handle = nativeCinepakDecoderCreate(width, height)

        @Synchronized
        fun decode(encoded: ByteArray, outputArgb: IntArray) {
            nativeCinepakDecoderDecode(openHandle(), encoded, outputArgb)
        }

        @Synchronized
        fun reset() {
            nativeCinepakDecoderReset(openHandle())
        }

        @Synchronized
        override fun close() {
            val current = handle
            if (current == 0L) return
            handle = 0L
            nativeCinepakDecoderDestroy(current)
        }

        private fun openHandle(): Long {
            check(handle != 0L) { "Cinepak decoder is closed" }
            return handle
        }
    }

    class AviMuxer(
        width: Int,
        height: Int,
        frameRateNum: Int,
        frameRateDen: Int,
        handlerFourcc: Int,
        compressionFourcc: Int,
        bitCount: Int,
    ) : AutoCloseable {
        private var handle = nativeAviMuxerCreate(
            width,
            height,
            frameRateNum,
            frameRateDen,
            handlerFourcc,
            compressionFourcc,
            bitCount,
        )

        @Synchronized
        fun addFrame(bytes: ByteArray, frameFlags: Int) {
            nativeAviMuxerAddFrame(openHandle(), bytes, frameFlags)
        }

        @Synchronized
        fun finish(): ByteArray = nativeAviMuxerFinish(openHandle())

        @Synchronized
        override fun close() {
            val current = handle
            if (current == 0L) return
            handle = 0L
            nativeAviMuxerDestroy(current)
        }

        private fun openHandle(): Long {
            check(handle != 0L) { "AVI muxer is closed" }
            return handle
        }

        companion object {
            fun cvid(width: Int, height: Int, fps: Int): AviMuxer = AviMuxer(
                width,
                height,
                fps,
                1,
                fourcc("cvid"),
                fourcc("cvid"),
                24,
            )

            fun msvc(width: Int, height: Int, fps: Int): AviMuxer = AviMuxer(
                width,
                height,
                fps,
                1,
                fourcc("MSVC"),
                fourcc("MSVC"),
                16,
            )

            fun mjpg(width: Int, height: Int, fps: Int): AviMuxer = AviMuxer(
                width,
                height,
                fps,
                1,
                fourcc("MJPG"),
                fourcc("MJPG"),
                24,
            )
        }
    }

    class AviReader(bytes: ByteArray) : AutoCloseable {
        private var handle = nativeAviReaderCreate(bytes)

        @Synchronized
        fun info(): AviInfo {
            val fields = nativeAviReaderInfo(openHandle())
            check(fields.size == 9) { "Invalid native AVI info field count" }
            return AviInfo(
                fields[0],
                fields[1],
                fields[2],
                fields[3],
                fields[4],
                fields[5],
                fields[6],
                fields[7],
                fields[8],
            )
        }

        @Synchronized
        fun frameInfo(index: Int): AviFrameInfo {
            val fields = nativeAviReaderFrameInfo(openHandle(), index)
            check(fields.size == 3) { "Invalid native AVI frame info field count" }
            return AviFrameInfo(fields[0], fields[1], fields[2])
        }

        @Synchronized
        fun copyFrame(index: Int): ByteArray = nativeAviReaderCopyFrame(openHandle(), index)

        @Synchronized
        override fun close() {
            val current = handle
            if (current == 0L) return
            handle = 0L
            nativeAviReaderDestroy(current)
        }

        private fun openHandle(): Long {
            check(handle != 0L) { "AVI reader is closed" }
            return handle
        }
    }

    private external fun nativeAbiVersion(): Int
    private external fun nativeMsv1Encode(
        rgba: ByteArray,
        width: Int,
        height: Int,
        previousRgba: ByteArray?,
        skipThreshold: Int,
        forceKey: Boolean,
        outputFrameFlags: IntArray,
    ): ByteArray
    private external fun nativeMsv1Decode(
        encoded: ByteArray,
        width: Int,
        height: Int,
        persistentArgb: IntArray,
    )
    private external fun nativeCinepakEncoderCreate(
        width: Int,
        height: Int,
        quality: Int,
        v1Size: Int,
        v4Size: Int,
        refineIterations: Int,
        chromaWeight: Int,
        strips: Int,
        skipThreshold: Int,
        keyInterval: Int,
    ): Long
    private external fun nativeCinepakEncoderEncode(
        handle: Long,
        rgba: ByteArray,
        forceKey: Boolean,
        outputFrameFlags: IntArray,
    ): ByteArray
    private external fun nativeCinepakEncoderReset(handle: Long)
    private external fun nativeCinepakEncoderDestroy(handle: Long)
    private external fun nativeCinepakDecoderCreate(width: Int, height: Int): Long
    private external fun nativeCinepakDecoderDecode(handle: Long, encoded: ByteArray, outputArgb: IntArray)
    private external fun nativeCinepakDecoderReset(handle: Long)
    private external fun nativeCinepakDecoderDestroy(handle: Long)
    private external fun nativeAviMuxerCreate(
        width: Int,
        height: Int,
        frameRateNum: Int,
        frameRateDen: Int,
        handlerFourcc: Int,
        compressionFourcc: Int,
        bitCount: Int,
    ): Long
    private external fun nativeAviMuxerAddFrame(handle: Long, bytes: ByteArray, frameFlags: Int)
    private external fun nativeAviMuxerFinish(handle: Long): ByteArray
    private external fun nativeAviMuxerDestroy(handle: Long)
    private external fun nativeAviReaderCreate(bytes: ByteArray): Long
    private external fun nativeAviReaderInfo(handle: Long): IntArray
    private external fun nativeAviReaderFrameInfo(handle: Long, index: Int): IntArray
    private external fun nativeAviReaderCopyFrame(handle: Long, index: Int): ByteArray
    private external fun nativeAviReaderDestroy(handle: Long)
}

/** Production MSV1/JPEG AVI orchestration shared by camera and parity tests. */
internal object CameraSoftwareMedia {
    fun encodeMsv1(
        rgba: ByteArray,
        width: Int,
        height: Int,
        previousRgba: ByteArray?,
        skipThreshold: Int,
        forceKey: Boolean,
    ): NativeMediaCodec.EncodedFrame = NativeMediaCodec.encodeMsv1(
        rgba,
        width,
        height,
        previousRgba,
        skipThreshold,
        forceKey,
    )

    fun decodeMsv1(
        encoded: ByteArray,
        width: Int,
        height: Int,
        persistentArgb: IntArray,
    ) {
        NativeMediaCodec.decodeMsv1(encoded, width, height, persistentArgb)
    }

    fun jpegFrame(bytes: ByteArray): NativeMediaCodec.EncodedFrame =
        NativeMediaCodec.EncodedFrame(
            bytes,
            NativeMediaCodec.FRAME_FLAG_KEY or NativeMediaCodec.FRAME_FLAG_KEY_KNOWN,
        )

    fun isKey(frame: NativeMediaCodec.EncodedFrame): Boolean =
        frame.frameFlags and NativeMediaCodec.FRAME_FLAG_KEY != 0

    fun finishAvi(
        frames: List<NativeMediaCodec.EncodedFrame>,
        width: Int,
        height: Int,
        fps: Int,
        mode: String,
    ): ByteArray {
        val muxer = when (mode) {
            "mvs1" -> NativeMediaCodec.AviMuxer.msvc(width, height, fps)
            "jpeg" -> NativeMediaCodec.AviMuxer.mjpg(width, height, fps)
            else -> throw IllegalArgumentException("Unsupported camera software mode: $mode")
        }
        return muxer.use {
            frames.forEach { frame -> it.addFrame(frame.bytes, frame.frameFlags) }
            it.finish()
        }
    }
}

/** Production Cinepak-to-CVID orchestration shared by every converter path. */
internal class CvidAviSession(
    width: Int,
    height: Int,
    fps: Int,
    options: NativeMediaCodec.CinepakOptions,
) : AutoCloseable {
    private var encoder: NativeMediaCodec.CinepakEncoder? = null
    private var muxer: NativeMediaCodec.AviMuxer? = null

    init {
        val createdEncoder = NativeMediaCodec.CinepakEncoder(width, height, options)
        try {
            val createdMuxer = NativeMediaCodec.AviMuxer.cvid(width, height, fps)
            encoder = createdEncoder
            muxer = createdMuxer
        } catch (failure: Throwable) {
            try {
                createdEncoder.close()
            } catch (closeFailure: Throwable) {
                failure.addSuppressed(closeFailure)
            }
            throw failure
        }
    }

    @Synchronized
    fun encodeAndAdd(rgba: ByteArray, forceKey: Boolean = false): NativeMediaCodec.EncodedFrame {
        try {
            val frame = openEncoder().encode(rgba, forceKey)
            openMuxer().addFrame(frame.bytes, frame.frameFlags)
            return frame
        } catch (failure: Throwable) {
            closeAfterFailure(failure)
        }
    }

    @Synchronized
    fun addFrame(frame: NativeMediaCodec.EncodedFrame) {
        try {
            openMuxer().addFrame(frame.bytes, frame.frameFlags)
        } catch (failure: Throwable) {
            closeAfterFailure(failure)
        }
    }

    @Synchronized
    fun finish(): ByteArray {
        try {
            return openMuxer().finish()
        } catch (failure: Throwable) {
            closeAfterFailure(failure)
        }
    }

    @Synchronized
    override fun close() {
        val currentMuxer = muxer
        val currentEncoder = encoder
        muxer = null
        encoder = null

        var failure: Throwable? = null
        try {
            currentMuxer?.close()
        } catch (closeFailure: Throwable) {
            failure = closeFailure
        }
        try {
            currentEncoder?.close()
        } catch (closeFailure: Throwable) {
            if (failure == null) failure = closeFailure else failure.addSuppressed(closeFailure)
        }
        if (failure != null) throw failure
    }

    private fun openEncoder(): NativeMediaCodec.CinepakEncoder =
        checkNotNull(encoder) { "CVID AVI session is closed" }

    private fun openMuxer(): NativeMediaCodec.AviMuxer =
        checkNotNull(muxer) { "CVID AVI session is closed" }

    private fun closeAfterFailure(failure: Throwable): Nothing {
        try {
            close()
        } catch (closeFailure: Throwable) {
            failure.addSuppressed(closeFailure)
        }
        throw failure
    }
}
