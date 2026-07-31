package com.honeygui.honeybox

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CameraMsv1StateTest {
    @Test
    fun keyframeRequestArrivingDuringEncodeIsConsumedByNextFrame() {
        val state = CameraMsv1State()
        val first = rgba(1)
        state.encode(first, skipEnabled = true) { previous, forceKey ->
            assertNull(previous)
            assertFalse(forceKey)
            CameraMsv1EncodeResult(Unit, isKey = true)
        }

        val enteredEncode = CountDownLatch(1)
        val releaseEncode = CountDownLatch(1)
        val workerFailure = AtomicReference<Throwable?>()
        val current = rgba(2)
        val worker = thread(name = "camera-msv1-test") {
            try {
                state.encode(current, skipEnabled = true) { previous, forceKey ->
                    assertSame(first, previous)
                    assertFalse(forceKey)
                    enteredEncode.countDown()
                    assertTrue(releaseEncode.await(5, TimeUnit.SECONDS))
                    CameraMsv1EncodeResult(Unit, isKey = false)
                }
            } catch (failure: Throwable) {
                workerFailure.set(failure)
            }
        }

        assertTrue(enteredEncode.await(5, TimeUnit.SECONDS))
        state.requestKeyframe()
        releaseEncode.countDown()
        worker.join(5_000)
        assertFalse("encode worker did not finish", worker.isAlive)
        workerFailure.get()?.let { throw it }

        state.encode(rgba(3), skipEnabled = true) { previous, forceKey ->
            assertNull(previous)
            assertTrue(forceKey)
            CameraMsv1EncodeResult(Unit, isKey = true)
        }
    }

    @Test
    fun failedExplicitKeyEncodeRestoresOnlyTheExplicitRequest() {
        val state = CameraMsv1State()
        state.reset(keyIntervalFrames = 1)
        state.requestKeyframe()

        try {
            state.encode<Unit>(rgba(1), skipEnabled = true) { _, forceKey ->
                assertTrue(forceKey)
                throw ExpectedFailure()
            }
            fail("encode should fail")
        } catch (_: ExpectedFailure) {
        }

        state.encode(rgba(2), skipEnabled = true) { previous, forceKey ->
            assertNull(previous)
            assertTrue(forceKey)
            CameraMsv1EncodeResult(Unit, isKey = true)
        }

        state.encode(rgba(3), skipEnabled = true) { previous, forceKey ->
            assertFalse(forceKey)
            assertTrue(previous != null)
            CameraMsv1EncodeResult(Unit, isKey = false)
        }
    }

    @Test
    fun periodicKeyAndPreviousFrameAdvanceOnlyAfterSuccessfulEncode() {
        val state = CameraMsv1State()
        state.reset(keyIntervalFrames = 2)
        val first = rgba(1)
        val second = rgba(2)
        val third = rgba(3)

        state.encode(first, skipEnabled = true) { previous, forceKey ->
            assertNull(previous)
            assertFalse(forceKey)
            CameraMsv1EncodeResult(Unit, isKey = true)
        }
        state.encode(second, skipEnabled = true) { previous, forceKey ->
            assertSame(first, previous)
            assertFalse(forceKey)
            CameraMsv1EncodeResult(Unit, isKey = false)
        }

        try {
            state.encode<Unit>(third, skipEnabled = true) { previous, forceKey ->
                assertSame(second, previous)
                assertFalse(forceKey)
                throw ExpectedFailure()
            }
            fail("encode should fail")
        } catch (_: ExpectedFailure) {
        }

        state.encode(third, skipEnabled = true) { previous, forceKey ->
            assertSame(second, previous)
            assertFalse(forceKey)
            CameraMsv1EncodeResult(Unit, isKey = false)
        }
        state.encode(rgba(4), skipEnabled = true) { previous, forceKey ->
            assertNull(previous)
            assertTrue(forceKey)
            CameraMsv1EncodeResult(Unit, isKey = true)
        }
    }

    @Test
    fun resetPreviousFrameForcesKeyWithoutCreatingAnExplicitRequest() {
        val state = CameraMsv1State()
        state.reset(keyIntervalFrames = 0)
        state.encode(rgba(1), skipEnabled = true) { _, _ ->
            CameraMsv1EncodeResult(Unit, isKey = true)
        }

        state.resetPreviousFrame()
        state.encode(rgba(2), skipEnabled = true) { previous, forceKey ->
            assertNull(previous)
            assertFalse(forceKey)
            CameraMsv1EncodeResult(Unit, isKey = true)
        }
    }

    private fun rgba(value: Int): ByteArray = ByteArray(4) { value.toByte() }

    private class ExpectedFailure : RuntimeException()
}
