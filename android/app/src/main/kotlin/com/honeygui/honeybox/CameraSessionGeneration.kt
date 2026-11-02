package com.honeygui.honeybox

/** Rejects callbacks produced by a camera session that has since been replaced. */
internal class CameraSessionGeneration {
    internal class Token internal constructor(internal val value: Long)

    private var value = 0L
    private var current: Token? = null

    @Synchronized
    fun beginSession(): Token {
        val token = Token(++value)
        current = token
        return token
    }

    @Synchronized
    fun invalidate() {
        value++
        current = null
    }

    @Synchronized
    fun currentToken(): Token? = current

    @Synchronized
    fun isCurrent(token: Token): Boolean = current === token

    @Synchronized
    fun commitIfCurrent(token: Token, block: () -> Unit): Boolean {
        if (current !== token) return false
        block()
        return true
    }
}
