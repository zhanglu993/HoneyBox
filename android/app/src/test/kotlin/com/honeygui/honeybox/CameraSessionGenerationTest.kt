package com.honeygui.honeybox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraSessionGenerationTest {
    @Test
    fun newSessionInvalidatesOldToken() {
        val generation = CameraSessionGeneration()
        val oldToken = generation.beginSession()
        val newToken = generation.beginSession()

        assertFalse(generation.isCurrent(oldToken))
        assertTrue(generation.isCurrent(newToken))
    }

    @Test
    fun closeInvalidationRejectsCurrentToken() {
        val generation = CameraSessionGeneration()
        val token = generation.beginSession()

        generation.invalidate()

        assertFalse(generation.isCurrent(token))
        assertFalse(generation.commitIfCurrent(token) {})
    }

    @Test
    fun staleCommitCannotWriteState() {
        val generation = CameraSessionGeneration()
        val staleToken = generation.beginSession()
        generation.beginSession()
        var value = "unchanged"

        val committed = generation.commitIfCurrent(staleToken) {
            value = "stale"
        }

        assertFalse(committed)
        assertEquals("unchanged", value)
    }
}
