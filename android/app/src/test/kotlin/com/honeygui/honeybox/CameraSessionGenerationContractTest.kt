package com.honeygui.honeybox

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

class CameraSessionGenerationContractTest {
    @Test
    fun cameraEncoderGatesEveryAsynchronousCameraSideEffectAtItsCallSite() {
        verifyIntegration(loadCameraEncoder())
    }

    @Test
    fun contractRejectsDeletedGatesAndSideEffectsMovedBeforeTheirGate() {
        val source = loadCameraEncoder()
        val mutations = linkedMapOf(
            "deleted GL gate" to replaceInsideBlock(
                source,
                "fun openCamera(",
                "cameraCallbacks.onGlSurface(token)",
                "cameraCallbacks.removedGlSurface(token)",
            ),
            "GL write before gate" to moveLineBeforeGateInsideBlock(
                source,
                "fun openCamera(",
                "cameraCallbacks.onGlSurface(token)",
                "gl.setPreviewSurface(",
            ),
            "deleted CameraDevice opened gate" to replaceInsideBlock(
                source,
                "override fun onOpened(",
                "cameraCallbacks.onCameraOpened(",
                "cameraCallbacks.removedCameraOpened(",
            ),
            "CameraDevice write before gate" to moveLineBeforeGateInsideBlock(
                source,
                "override fun onOpened(",
                "cameraCallbacks.onCameraOpened(",
                "cameraDevice = device",
            ),
            "deleted CameraDevice disconnect gate" to replaceInsideBlock(
                source,
                "override fun onDisconnected(",
                "cameraSessionGeneration.commitIfCurrent(token)",
                "cameraSessionGeneration.removedCommit(token)",
            ),
            "disconnect clear before gate" to moveLineBeforeGateInsideBlock(
                source,
                "override fun onDisconnected(",
                "cameraSessionGeneration.commitIfCurrent(token)",
                "if (cameraDevice === device) cameraDevice = null",
            ),
            "deleted CameraDevice error gate" to replaceInsideBlock(
                source,
                "override fun onError(device: CameraDevice",
                "cameraSessionGeneration.commitIfCurrent(token)",
                "cameraSessionGeneration.removedCommit(token)",
            ),
            "error clear before gate" to moveLineBeforeGateInsideBlock(
                source,
                "override fun onError(device: CameraDevice",
                "cameraSessionGeneration.commitIfCurrent(token)",
                "if (cameraDevice === device) cameraDevice = null",
            ),
            "deleted CaptureSession gate" to replaceInsideBlock(
                source,
                "override fun onConfigured(",
                "cameraCallbacks.onCaptureConfigured(",
                "cameraCallbacks.removedCaptureConfigured(",
            ),
            "CaptureSession write before gate" to moveLineBeforeGateInsideBlock(
                source,
                "override fun onConfigured(",
                "cameraCallbacks.onCaptureConfigured(",
                "captureSession = session",
            ),
            "deleted ready gate" to replaceInsideBlock(
                source,
                "private fun emitCameraReady(",
                "cameraCallbacks.emitReady(token)",
                "cameraCallbacks.removedReady(token)",
            ),
            "ready emit before gate" to insertLineBeforeGateInsideBlock(
                source,
                "private fun emitCameraReady(",
                "cameraCallbacks.emitReady(token)",
                "events.onEvent(mapOf(\"event\" to \"mutation\"))",
            ),
            "deleted error gate" to replaceInsideBlock(
                source,
                "private fun emitCameraError(",
                "cameraCallbacks.emitError(token)",
                "cameraCallbacks.removedError(token)",
            ),
            "error emit before gate" to insertLineBeforeGateInsideBlock(
                source,
                "private fun emitCameraError(",
                "cameraCallbacks.emitError(token)",
                "events.onEvent(mapOf(\"event\" to \"mutation\"))",
            ),
        )

        for ((name, mutation) in mutations) {
            var rejected = false
            try {
                verifyIntegration(mutation)
            } catch (_: AssertionError) {
                rejected = true
            } catch (_: IllegalStateException) {
                rejected = true
            }
            assertTrue("mutation survived contract: $name", rejected)
        }
    }

    private fun verifyIntegration(source: String) {
        assertTrue(
            "CameraEncoder must use the behavior-tested callback gate",
            source.contains(
                "private val cameraCallbacks = " +
                    "CameraSessionCallbackGate(cameraSessionGeneration)",
            ),
        )

        val openCamera = blockStartingAt(source, "fun openCamera(")
        assertOrdered(openCamera, "cameraSessionGeneration.beginSession()", "gl.start(")
        val glAccepted = lambdaStartingAt(openCamera, "cameraCallbacks.onGlSurface(token)")
        assertOrdered(
            glAccepted,
            "gl.setPreviewSurface(",
            "openDevice(id, camSurface, token)",
        )

        val openDevice = blockStartingAt(source, "private fun openDevice(")
        val onOpened = blockStartingAt(openDevice, "override fun onOpened(")
        val cameraAccepted = lambdaStartingAt(onOpened, "cameraCallbacks.onCameraOpened(")
        assertTrue(onOpened.contains("closeStale = device::close"))
        assertFalse(prefixBefore(onOpened, cameraAccepted).contains("cameraDevice = device"))
        assertOrdered(cameraAccepted, "cameraDevice = device", "buildSession(")

        val onDisconnected = blockStartingAt(openDevice, "override fun onDisconnected(")
        val disconnectAccepted = lambdaStartingAt(
            onDisconnected,
            "cameraSessionGeneration.commitIfCurrent(token)",
        )
        assertFalse(
            prefixBefore(onDisconnected, disconnectAccepted)
                .contains("cameraDevice = null"),
        )
        assertTrue(disconnectAccepted.contains("cameraDevice = null"))

        val onError = blockStartingAt(openDevice, "override fun onError(device: CameraDevice")
        val errorCleanupAccepted = lambdaStartingAt(
            onError,
            "cameraSessionGeneration.commitIfCurrent(token)",
        )
        assertFalse(prefixBefore(onError, errorCleanupAccepted).contains("cameraDevice = null"))
        assertTrue(errorCleanupAccepted.contains("cameraDevice = null"))
        assertOrdered(onError, "cameraSessionGeneration.commitIfCurrent(token)", "emitCameraError(")

        val buildSession = blockStartingAt(source, "private fun buildSession(")
        val onConfigured = blockStartingAt(buildSession, "override fun onConfigured(")
        val captureAccepted = lambdaStartingAt(
            onConfigured,
            "cameraCallbacks.onCaptureConfigured(",
        )
        assertTrue(onConfigured.contains("closeStale = session::close"))
        assertFalse(prefixBefore(onConfigured, captureAccepted).contains("captureSession = session"))
        assertOrdered(
            captureAccepted,
            "captureSession = session",
            "issueRepeating(token)",
            "emitCameraReady(token)",
        )

        val ready = blockStartingAt(
            source,
            "private fun emitCameraReady(token: CameraSessionGeneration.Token)",
        )
        assertOrdered(ready, "mainHandler.post", "cameraCallbacks.emitReady(token)")
        val readyAccepted = lambdaStartingAt(ready, "cameraCallbacks.emitReady(token)")
        assertFalse(prefixBefore(ready, readyAccepted).contains("events.onEvent("))
        assertTrue(readyAccepted.contains("events.onEvent("))

        val error = blockStartingAt(source, "private fun emitCameraError(")
        assertOrdered(error, "mainHandler.post", "cameraCallbacks.emitError(token)")
        val errorAccepted = lambdaStartingAt(error, "cameraCallbacks.emitError(token)")
        assertFalse(prefixBefore(error, errorAccepted).contains("events.onEvent("))
        assertTrue(errorAccepted.contains("events.onEvent("))

        val close = blockStartingAt(source, "fun closeCamera()")
        assertTrue(
            "closeCamera must invalidate before any native release side effect",
            close.substringAfter('{').trimStart()
                .startsWith("cameraSessionGeneration.invalidate()"),
        )
    }

    private fun loadCameraEncoder(): String {
        val root = System.getProperty("ebadge.repositoryRoot")
        require(!root.isNullOrBlank()) { "ebadge.repositoryRoot must be set" }
        val path = Paths.get(root).resolve(
            "android/app/src/main/kotlin/com/honeygui/honeybox/CameraEncoder.kt",
        )
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    private fun replaceInsideBlock(
        source: String,
        signature: String,
        target: String,
        replacement: String,
    ): String {
        val block = blockStartingAt(source, signature)
        check(block.contains(target)) { "target not found in $signature: $target" }
        return source.replaceFirst(block, block.replaceFirst(target, replacement))
    }

    private fun moveLineBeforeGateInsideBlock(
        source: String,
        signature: String,
        gate: String,
        sideEffect: String,
    ): String {
        val block = blockStartingAt(source, signature)
        val moved = moveLineBeforeGate(block, gate, sideEffect)
        return source.replaceFirst(block, moved)
    }

    private fun insertLineBeforeGateInsideBlock(
        source: String,
        signature: String,
        gate: String,
        sideEffect: String,
    ): String {
        val block = blockStartingAt(source, signature)
        val gateIndex = block.indexOf(gate)
        check(gateIndex >= 0) { "gate not found in $signature: $gate" }
        val gateLine = block.lastIndexOf('\n', gateIndex) + 1
        val indent = block.substring(gateLine, gateIndex)
        val mutated = block.substring(0, gateLine) + indent + sideEffect + "\n" +
            block.substring(gateLine)
        return source.replaceFirst(block, mutated)
    }

    private fun moveLineBeforeGate(source: String, gate: String, sideEffect: String): String {
        val gateIndex = source.indexOf(gate)
        val effectIndex = source.indexOf(sideEffect, gateIndex + gate.length)
        check(gateIndex >= 0 && effectIndex > gateIndex) {
            "side effect must follow gate: $gate -> $sideEffect"
        }
        val effectLineStart = source.lastIndexOf('\n', effectIndex) + 1
        val effectLineEnd = source.indexOf('\n', effectIndex).let {
            if (it < 0) source.length else it + 1
        }
        val effectLine = source.substring(effectLineStart, effectLineEnd).trimStart()
        val withoutEffect = source.removeRange(effectLineStart, effectLineEnd)
        val relocatedGate = withoutEffect.indexOf(gate)
        val gateLineStart = withoutEffect.lastIndexOf('\n', relocatedGate) + 1
        val indent = withoutEffect.substring(gateLineStart, relocatedGate)
        return withoutEffect.substring(0, gateLineStart) + indent + effectLine +
            withoutEffect.substring(gateLineStart)
    }

    private fun prefixBefore(owner: String, nested: String): String {
        val index = owner.indexOf(nested)
        check(index >= 0) { "nested block not found in owner" }
        return owner.substring(0, index)
    }

    private fun assertOrdered(source: String, vararg markers: String) {
        var cursor = -1
        for (marker in markers) {
            val next = source.indexOf(marker, cursor + 1)
            assertTrue("missing or out-of-order marker: $marker", next > cursor)
            cursor = next
        }
    }

    private fun lambdaStartingAt(source: String, call: String): String {
        val callIndex = source.indexOf(call)
        check(callIndex >= 0) { "call not found: $call" }
        val brace = source.indexOf('{', callIndex + call.length)
        check(brace >= 0) { "lambda body not found for: $call" }
        return balancedBlock(source, brace)
    }

    private fun blockStartingAt(source: String, signature: String): String {
        val signatureIndex = source.indexOf(signature)
        check(signatureIndex >= 0) { "signature not found: $signature" }
        val brace = source.indexOf('{', signatureIndex + signature.length)
        check(brace >= 0) { "body not found for: $signature" }
        return balancedBlock(source, brace)
    }

    private fun balancedBlock(source: String, openingBrace: Int): String {
        var depth = 0
        var quote: Char? = null
        var escaped = false
        for (index in openingBrace until source.length) {
            val char = source[index]
            if (quote != null) {
                if (escaped) {
                    escaped = false
                } else if (char == '\\') {
                    escaped = true
                } else if (char == quote) {
                    quote = null
                }
                continue
            }
            if (char == '"' || char == '\'') {
                quote = char
                continue
            }
            if (char == '{') depth++
            if (char == '}') {
                depth--
                if (depth == 0) return source.substring(openingBrace, index + 1)
            }
        }
        error("unbalanced block starting at $openingBrace")
    }
}
