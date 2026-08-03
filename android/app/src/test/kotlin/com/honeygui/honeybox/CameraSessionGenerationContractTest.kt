package com.honeygui.honeybox

import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

class CameraSessionGenerationContractTest {
    @Test
    fun cameraCallbacksAreBoundToTheSessionThatCreatedThem() {
        val root = System.getProperty("ebadge.repositoryRoot")
        require(!root.isNullOrBlank()) { "ebadge.repositoryRoot must be set" }
        val path = Paths.get(root).resolve(
            "android/app/src/main/kotlin/com/honeygui/honeybox/CameraEncoder.kt",
        )
        val source = String(Files.readAllBytes(path), Charsets.UTF_8)

        assertTrue(
            "openCamera must begin a new camera generation",
            source.contains("cameraSessionGeneration.beginSession()"),
        )
        assertTrue(
            "closeCamera must invalidate callbacks before releasing resources",
            Regex(
                "fun closeCamera\\(\\) \\{\\s*cameraSessionGeneration\\.invalidate\\(\\)",
            ).containsMatchIn(source),
        )
        assertTrue(
            "CameraDevice callbacks must carry the opening token",
            Regex(
                "private fun openDevice\\([^)]*CameraSessionGeneration\\.Token",
                RegexOption.DOT_MATCHES_ALL,
            ).containsMatchIn(source),
        )
        assertTrue(
            "onOpened must gate global cameraDevice writes",
            Regex(
                "override fun onOpened\\([^)]*\\) \\{.*?" +
                    "cameraSessionGeneration\\.commitIfCurrent\\(token\\)",
                RegexOption.DOT_MATCHES_ALL,
            ).containsMatchIn(source),
        )
        assertTrue(
            "CameraCaptureSession callbacks must carry the opening token",
            Regex(
                "private fun buildSession\\([^)]*CameraSessionGeneration\\.Token",
                RegexOption.DOT_MATCHES_ALL,
            ).containsMatchIn(source),
        )
        assertTrue(
            "onConfigured must gate captureSession writes and ready emission",
            Regex(
                "override fun onConfigured\\([^)]*\\) \\{.*?" +
                    "cameraSessionGeneration\\.commitIfCurrent\\(token\\).*?" +
                    "emitCameraReady\\(token\\)",
                RegexOption.DOT_MATCHES_ALL,
            ).containsMatchIn(source),
        )
        assertTrue(
            "GL startup callback must reject stale surfaces",
            Regex(
                "gl\\.start\\([^}]*cameraSessionGeneration\\.isCurrent\\(token\\)",
                RegexOption.DOT_MATCHES_ALL,
            ).containsMatchIn(source),
        )
        assertTrue(
            "camera ready posts must recheck the captured token",
            Regex(
                "private fun emitCameraReady\\(token: CameraSessionGeneration\\.Token\\).*?" +
                    "mainHandler\\.post.*?cameraSessionGeneration\\.isCurrent\\(token\\)",
                RegexOption.DOT_MATCHES_ALL,
            ).containsMatchIn(source),
        )
        assertTrue(
            "camera errors must use a token-gated emitter",
            source.contains("private fun emitCameraError(") &&
                source.contains("cameraSessionGeneration.isCurrent(token)"),
        )
    }
}
