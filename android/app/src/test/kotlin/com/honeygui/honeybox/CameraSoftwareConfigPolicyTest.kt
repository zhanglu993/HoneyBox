package com.honeygui.honeybox

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraSoftwareConfigPolicyTest {
    private val current = EncoderConfig(
        format = "mvs1",
        width = 320,
        height = 240,
        fps = 15,
        bitrate = 500_000,
        iFrameIntervalSec = 2,
        cropZoom = 1.0,
        msv1Skip = true,
        msv1SkipThr = 4,
        jpegQuality = 80,
        recordToFile = true,
        stream = true,
    )

    @Test
    fun cropZoomIsTheOnlySafeSoftwareFinishingChange() {
        assertTrue(isSoftwareCropOnlyChange(current, current.copy(cropZoom = 2.0)))
    }

    @Test
    fun codecGeometryTimingAndOutputsAreNotSafeFinishingChanges() {
        assertFalse(isSoftwareCropOnlyChange(current, current.copy(format = "jpeg")))
        assertFalse(isSoftwareCropOnlyChange(current, current.copy(width = 640)))
        assertFalse(isSoftwareCropOnlyChange(current, current.copy(fps = 10)))
        assertFalse(isSoftwareCropOnlyChange(current, current.copy(msv1SkipThr = 8)))
        assertFalse(isSoftwareCropOnlyChange(current, current.copy(recordToFile = false)))
        assertFalse(isSoftwareCropOnlyChange(current, current.copy(stream = false)))
    }

    @Test
    fun previewStateCanContinueOnlyWithTheSameCompatibleTarget() {
        val argb = IntArray(320 * 240)
        val surface = Any()

        assertTrue(
            canReuseSoftwarePreviewState(
                argb, argb, surface, surface,
                "mvs1", "mvs1", 320, 240, 320, 240,
            ),
        )
    }

    @Test
    fun changedPreviewStorageSurfaceCodecOrGeometryRequiresReset() {
        val argb = IntArray(4)
        val surface = Any()
        assertFalse(
            canReuseSoftwarePreviewState(
                argb, IntArray(4), surface, surface,
                "mvs1", "mvs1", 2, 2, 2, 2,
            ),
        )
        assertFalse(
            canReuseSoftwarePreviewState(
                argb, argb, surface, Any(),
                "mvs1", "mvs1", 2, 2, 2, 2,
            ),
        )
        assertFalse(
            canReuseSoftwarePreviewState(
                argb, argb, surface, surface,
                "mvs1", "jpeg", 2, 2, 2, 2,
            ),
        )
        assertFalse(
            canReuseSoftwarePreviewState(
                argb, argb, surface, surface,
                "mvs1", "mvs1", 2, 2, 4, 2,
            ),
        )
    }
}
