package com.honeygui.honeybox

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraSoftwareSessionGateTest {
    @Test
    fun oldQueuedTokenIsRejectedAfterNewSessionBegins() {
        val gate = CameraSoftwareSessionGate()
        val old = gate.beginSession()
        gate.beginSession()

        assertFalse(gate.isCurrent(old))
        assertFalse(gate.tryAcquire(old) { true })
    }

    @Test
    fun inFlightResultCannotCommitAfterItsSessionBecomesStale() {
        val gate = CameraSoftwareSessionGate()
        val old = gate.beginSession()
        assertTrue(gate.tryAcquire(old) { true })
        gate.beginSession()

        var committed = false
        assertFalse(gate.commitIfCurrent(old) { committed = true })
        assertFalse(committed)
    }

    @Test
    fun staleReleaseDoesNotClearNewSessionBusyState() {
        val gate = CameraSoftwareSessionGate()
        val old = gate.beginSession()
        assertTrue(gate.tryAcquire(old) { true })
        val current = gate.beginSession()
        assertTrue(gate.tryAcquire(current) { true })

        gate.release(old)

        assertFalse(gate.tryAcquire(current) { true })
        gate.release(current)
        assertTrue(gate.tryAcquire(current) { true })
    }

    @Test
    fun sameSessionCanCommitReleaseAndAcquireAgain() {
        val gate = CameraSoftwareSessionGate()
        val token = gate.beginSession()
        assertTrue(gate.tryAcquire(token) { true })

        var committed = false
        assertTrue(gate.commitIfCurrent(token) { committed = true })
        assertTrue(committed)
        gate.release(token)

        assertTrue(gate.tryAcquire(token) { true })
    }

    @Test
    fun drainingRejectsNewFramesButKeepsAlreadyQueuedResultCommittable() {
        val gate = CameraSoftwareSessionGate()
        val token = gate.beginSession()
        assertTrue(gate.tryAcquire(token) { true })
        var barrierPosted = false

        assertTrue(gate.stopAccepting(token) {
            barrierPosted = true
            true
        })

        assertTrue(barrierPosted)
        assertFalse(gate.tryAcquire(token) { true })
        assertTrue(gate.commitIfCurrent(token) {})
    }

    @Test
    fun failedEnqueueReleasesBusyReservation() {
        val gate = CameraSoftwareSessionGate()
        val token = gate.beginSession()

        assertFalse(gate.tryAcquire(token) { false })
        assertTrue(gate.tryAcquire(token) { true })
    }

}
