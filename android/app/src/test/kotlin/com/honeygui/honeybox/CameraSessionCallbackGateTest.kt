package com.honeygui.honeybox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraSessionCallbackGateTest {
    private val generation = CameraSessionGeneration()
    private val callbacks = CameraSessionCallbackGate(generation)

    @Test
    fun glSurfaceRunsOnlyForTheCurrentSession() {
        val token = generation.beginSession()
        val effects = mutableListOf<String>()

        assertTrue(callbacks.onGlSurface(token) { effects += "use-surface" })
        generation.invalidate()
        assertFalse(callbacks.onGlSurface(token) { effects += "stale-surface" })

        assertEquals(listOf("use-surface"), effects)
    }

    @Test
    fun cameraOpenedClosesStaleDeviceInsteadOfWritingOrBuilding() {
        val token = generation.beginSession()
        generation.invalidate()
        val effects = mutableListOf<String>()

        val accepted = callbacks.onCameraOpened(
            token,
            closeStale = { effects += "close-device" },
        ) {
            effects += "write-device"
            effects += "build-session"
        }

        assertFalse(accepted)
        assertEquals(listOf("close-device"), effects)
    }

    @Test
    fun captureConfiguredClosesStaleSessionInsteadOfWritingOrReady() {
        val token = generation.beginSession()
        generation.invalidate()
        val effects = mutableListOf<String>()

        val accepted = callbacks.onCaptureConfigured(
            token,
            closeStale = { effects += "close-session" },
        ) {
            effects += "write-session"
            effects += "repeat"
            effects += "ready"
        }

        assertFalse(accepted)
        assertEquals(listOf("close-session"), effects)
    }

    @Test
    fun currentCameraAndCaptureCallbacksPreserveSideEffectOrder() {
        val token = generation.beginSession()
        val effects = mutableListOf<String>()

        assertTrue(callbacks.onCameraOpened(token, { effects += "stale-device" }) {
            effects += "write-device"
            effects += "build-session"
        })
        assertTrue(callbacks.onCaptureConfigured(token, { effects += "stale-session" }) {
            effects += "write-session"
            effects += "repeat"
            effects += "ready"
        })

        assertEquals(
            listOf("write-device", "build-session", "write-session", "repeat", "ready"),
            effects,
        )
    }

    @Test
    fun readyAndErrorEmissionAreSuppressedAfterInvalidation() {
        val token = generation.beginSession()
        generation.invalidate()
        val effects = mutableListOf<String>()

        assertFalse(callbacks.emitReady(token) { effects += "ready" })
        assertFalse(callbacks.emitError(token) { effects += "error" })

        assertEquals(emptyList<String>(), effects)
    }
}
