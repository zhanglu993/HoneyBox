package com.honeygui.honeybox

/** Serializes ownership of asynchronous software-camera frame work. */
internal class CameraSoftwareSessionGate {
    internal class Token internal constructor(val generation: Long)

    private var generation = 0L
    private var current: Token? = null
    private var busyGeneration: Long? = null
    private var accepting = false

    @Synchronized
    fun beginSession(): Token {
        val token = Token(++generation)
        current = token
        busyGeneration = null
        accepting = true
        return token
    }

    @Synchronized
    fun invalidate() {
        generation++
        current = null
        busyGeneration = null
        accepting = false
    }

    @Synchronized
    fun currentToken(): Token? = current

    @Synchronized
    fun isCurrent(token: Token): Boolean = current === token

    @Synchronized
    fun tryAcquire(token: Token, enqueue: () -> Boolean): Boolean {
        if (!accepting || current != token || busyGeneration != null) return false
        busyGeneration = token.generation
        val enqueued = try {
            enqueue()
        } catch (error: Throwable) {
            if (current == token && busyGeneration == token.generation) {
                busyGeneration = null
            }
            throw error
        }
        if (!enqueued && current == token && busyGeneration == token.generation) {
            busyGeneration = null
        }
        return enqueued
    }

    @Synchronized
    fun release(token: Token) {
        if (current == token && busyGeneration == token.generation) {
            busyGeneration = null
        }
    }

    @Synchronized
    fun commitIfCurrent(token: Token, block: () -> Unit): Boolean {
        if (current != token) return false
        block()
        return true
    }

    @Synchronized
    fun stopAccepting(token: Token, enqueueBarrier: () -> Boolean): Boolean {
        if (current != token) return false
        accepting = false
        return enqueueBarrier()
    }
}
