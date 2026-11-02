package com.honeygui.honeybox

/** Applies camera-generation checks before asynchronous callback side effects. */
internal class CameraSessionCallbackGate(
    private val generation: CameraSessionGeneration,
) {
    fun onGlSurface(
        token: CameraSessionGeneration.Token,
        useSurface: () -> Unit,
    ): Boolean = generation.commitIfCurrent(token, useSurface)

    fun onCameraOpened(
        token: CameraSessionGeneration.Token,
        closeStale: () -> Unit,
        accept: () -> Unit,
    ): Boolean = acceptOrClose(token, closeStale, accept)

    fun onCaptureConfigured(
        token: CameraSessionGeneration.Token,
        closeStale: () -> Unit,
        accept: () -> Unit,
    ): Boolean = acceptOrClose(token, closeStale, accept)

    fun emitReady(
        token: CameraSessionGeneration.Token,
        emit: () -> Unit,
    ): Boolean = generation.commitIfCurrent(token, emit)

    fun emitError(
        token: CameraSessionGeneration.Token,
        emit: () -> Unit,
    ): Boolean = generation.commitIfCurrent(token, emit)

    private fun acceptOrClose(
        token: CameraSessionGeneration.Token,
        closeStale: () -> Unit,
        accept: () -> Unit,
    ): Boolean {
        if (generation.commitIfCurrent(token, accept)) return true
        closeStale()
        return false
    }
}
