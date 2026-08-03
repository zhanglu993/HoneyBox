package com.honeygui.honeybox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaFramePlannerTest {
    @Test
    fun animatedGifKeepsTheSecondFrameWhenTenFpsSamplesAtOneHundredMs() {
        val count = MediaFramePlanner.plannedFrameCount(
            durationMs = 140,
            fps = 10.0,
            maximum = 10,
            preservePartialInterval = true,
        )
        val timestamps = (0 until count).map {
            MediaFramePlanner.presentationTimestampMs(it, 10.0, 140)
        }

        assertEquals(2, count)
        assertEquals(listOf(0L, 100L), timestamps)
        assertTrue(timestamps[1] >= 70L)
    }

    @Test
    fun gifNativeFpsDoesNotCreateAnExtraFrameFromFloatingPointNoise() {
        val nativeFps = 2.0 / 0.14
        assertEquals(
            2,
            MediaFramePlanner.plannedFrameCount(
                durationMs = 140,
                fps = nativeFps,
                maximum = 10,
                preservePartialInterval = true,
            ),
        )
    }

    @Test
    fun gifNativeFpsSnapsNearIntegerCountBeforeCeiling() {
        val nativeFps = 3.0 / 0.18
        assertEquals(
            3,
            MediaFramePlanner.plannedFrameCount(
                durationMs = 180,
                fps = nativeFps,
                maximum = 10,
                preservePartialInterval = true,
            ),
        )
        val twoFrameNativeFps = 2.0 / 0.69
        assertEquals(
            2,
            MediaFramePlanner.plannedFrameCount(
                durationMs = 690,
                fps = twoFrameNativeFps,
                maximum = 10,
                preservePartialInterval = true,
            ),
        )
        assertEquals(
            1,
            MediaFramePlanner.plannedFrameCount(
                durationMs = 180,
                fps = nativeFps,
                maximum = 1,
                preservePartialInterval = true,
            ),
        )
    }

    @Test
    fun videoKeepsTheExistingFloorSemanticsForAPartialInterval() {
        assertEquals(
            1,
            MediaFramePlanner.plannedFrameCount(
                durationMs = 140,
                fps = 10.0,
                maximum = 10,
                preservePartialInterval = false,
            ),
        )
    }
}
