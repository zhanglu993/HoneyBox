package com.honeygui.honeybox

import java.util.concurrent.atomic.AtomicBoolean

/** Result boundary used by [CameraMsv1State] without depending on JNI types. */
internal data class CameraMsv1EncodeResult<T>(
    val value: T,
    val isKey: Boolean,
)

/**
 * Stateful MSV1 camera scheduling independent of Android and JNI.
 *
 * Explicit key-frame requests are consumed atomically before encoding. A failed
 * explicit-key attempt restores the request, while a request arriving during an
 * in-flight encode remains pending for the next frame.
 */
internal class CameraMsv1State {
    private val keyframeRequested = AtomicBoolean(false)
    private var keyIntervalFrames = 0
    private var framesSinceKey = 0
    private var previousRgba: ByteArray? = null

    fun requestKeyframe() {
        keyframeRequested.set(true)
    }

    @Synchronized
    fun reset(keyIntervalFrames: Int = 0) {
        this.keyIntervalFrames = keyIntervalFrames
        framesSinceKey = 0
        previousRgba = null
        keyframeRequested.set(false)
    }

    @Synchronized
    fun resetPreviousFrame() {
        previousRgba = null
    }

    @Synchronized
    fun <T> encode(
        rgba: ByteArray,
        skipEnabled: Boolean,
        encoder: (previousRgba: ByteArray?, forceKey: Boolean) -> CameraMsv1EncodeResult<T>,
    ): T {
        val explicitRequest = keyframeRequested.getAndSet(false)
        val periodic = keyIntervalFrames > 0 && framesSinceKey >= keyIntervalFrames
        val forceKey = explicitRequest || periodic
        val previous = if (skipEnabled && !forceKey) previousRgba else null

        val encoded = try {
            encoder(previous, forceKey)
        } catch (failure: Throwable) {
            if (explicitRequest) keyframeRequested.set(true)
            throw failure
        }

        framesSinceKey = if (encoded.isKey) 0 else framesSinceKey + 1
        previousRgba = rgba
        return encoded.value
    }
}
