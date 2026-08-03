package com.honeygui.honeybox

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.round

internal object MediaFramePlanner {
    fun plannedFrameCount(
        durationMs: Long,
        fps: Double,
        maximum: Int,
        preservePartialInterval: Boolean,
    ): Int {
        if (durationMs <= 0) return 1
        val count = durationMs.toDouble() * fps / 1000.0
        val nearestInteger = round(count)
        val tolerance = 1.0e-9 * maxOf(1.0, abs(count))
        val normalized =
            if (abs(count - nearestInteger) <= tolerance) nearestInteger else count
        if (normalized >= maximum.toDouble()) return maximum
        val planned =
            if (preservePartialInterval) ceil(normalized) else floor(normalized)
        return maxOf(1, planned.toInt())
    }

    fun presentationTimestampMs(index: Int, fps: Double, durationMs: Long): Long {
        var timestamp = Math.round(index.toDouble() * 1000.0 / fps)
        if (durationMs > 0 && timestamp >= durationMs) {
            timestamp = durationMs - 1
        }
        return maxOf(0L, timestamp)
    }
}
