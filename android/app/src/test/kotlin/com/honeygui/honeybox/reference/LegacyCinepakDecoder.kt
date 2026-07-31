package com.honeygui.honeybox.reference

/*
 * TEST-ONLY IMMUTABLE MIGRATION REFERENCE. Never ship or import from production.
 * Source: android/app/src/main/kotlin/com/honeygui/honeybox/CinepakDecoder.kt
 * Git blob: 4961ac214fd3e3b3793523b59c8c2cd28a9c195e
 * Behavioral edits require an intentional fixture review.
 */

/**
 * Pure-Kotlin Cinepak (CVID) decoder — the exact inverse of [LegacyCinepakEncoder] and
 * the AVI written by [LegacyCvidAviMuxer]. It exists purely as a frozen test reference
 * for cached clips: the cached `.avi` is Cinepak, which no Android platform decoder
 * (MediaCodec / MediaMetadataRetriever / ExoPlayer) can read — only the device
 * firmware and this app's own encoder handle it.
 *
 * Bitstream (big-endian), mirrored 1:1 from the encoder:
 *   frame header 10B: flags(1) | size(3) | w(2) | h(2) | strips(2)
 *   strip 12B: id(1)=0x10 key/0x11 inter | size(3) | top(2)=0 | left(2)=0
 *              | bot(2)=band height | right(2)=w
 *   chunk 4B: id(1) | size(3) (size includes the header)
 *   codebooks: 0x22=V1, 0x20=V4; each entry 6B = [Y0 Y1 Y2 Y3 U V] (U/V signed)
 *   vectors: 0x32=all-V1 (one index byte/MB, no bits), 0x30=key mixed
 *            (1 type bit/MB), 0x31=inter (1 skip bit/MB, then 1 type bit for coded)
 *
 * YUV→RGB is the algebraic inverse of the encoder's RGB→YUV coefficients, which
 * reduces to the classic Cinepak formula: R=Y+2V, G=Y-U/2-V, B=Y+2U — so a decode
 * of our own encode is loss-free bar VQ, and matches what the device shows.
 *
 * The strips carry no absolute Y (`top` is always 0), so — like the encoder's
 * `encodeStrips` row accumulator — we track the running top row across strips.
 * Inter frames keep a persistent YUV reconstruction ([Decoder] fields) so skipped
 * macroblocks reuse the previous frame's pixels.
 */
object LegacyCinepakDecoder {

    // 4x4 MB → four 2x2 quadrants: TL, TR, BL, BR (identical to the encoder).
    private val QUAD_X = intArrayOf(0, 2, 0, 2)
    private val QUAD_Y = intArrayOf(0, 0, 2, 2)

    /** Per-frame Cinepak bitstreams pulled out of an AVI, plus its dims / rate. */
    class Avi(
        val frames: List<ByteArray>,
        val width: Int,
        val height: Int,
        val usecPerFrame: Int,
    )

    private fun u32le(b: ByteArray, o: Int): Int =
        (b[o].toInt() and 0xFF) or
            ((b[o + 1].toInt() and 0xFF) shl 8) or
            ((b[o + 2].toInt() and 0xFF) shl 16) or
            ((b[o + 3].toInt() and 0xFF) shl 24)

    private fun fourccEq(b: ByteArray, o: Int, s: String): Boolean {
        if (o + 4 > b.size) return false
        return b[o] == s[0].code.toByte() && b[o + 1] == s[1].code.toByte() &&
            b[o + 2] == s[2].code.toByte() && b[o + 3] == s[3].code.toByte()
    }

    /**
     * Parse a standard AVI(CVID) — the layout produced by [LegacyCvidAviMuxer] — into
     * its per-frame Cinepak bitstreams. Walks the RIFF chunk tree so it tolerates
     * ordering; reads dims from `strf`/`avih` (falling back to the first frame
     * header) and `usecPerFrame` from `avih`.
     */
    fun parseAvi(b: ByteArray): Avi {
        require(b.size >= 12 && fourccEq(b, 0, "RIFF") && fourccEq(b, 8, "AVI ")) {
            "不是有效的 AVI 文件"
        }
        var width = 0
        var height = 0
        var usecPerFrame = 100_000
        val frames = ArrayList<ByteArray>()

        var p = 12
        while (p + 8 <= b.size) {
            val size = u32le(b, p + 4)
            val body = p + 8
            if (fourccEq(b, p, "LIST")) {
                if (fourccEq(b, body, "movi")) {
                    var q = body + 4
                    val end = minOf(body + size, b.size)
                    while (q + 8 <= end) {
                        val clen = u32le(b, q + 4)
                        val cbody = q + 8
                        if (fourccEq(b, q, "00dc") && cbody + clen <= b.size) {
                            frames.add(b.copyOfRange(cbody, cbody + clen))
                        }
                        q = cbody + clen + (clen and 1)
                    }
                } else if (fourccEq(b, body, "hdrl")) {
                    var q = body + 4
                    val end = minOf(body + size, b.size)
                    while (q + 8 <= end) {
                        val clen = u32le(b, q + 4)
                        val cbody = q + 8
                        if (fourccEq(b, q, "avih") && cbody + 40 <= b.size) {
                            usecPerFrame = u32le(b, cbody)
                            width = u32le(b, cbody + 32)
                            height = u32le(b, cbody + 36)
                        } else if (fourccEq(b, q, "LIST") && fourccEq(b, cbody, "strl")) {
                            var r = cbody + 4
                            val e2 = minOf(cbody + clen, b.size)
                            while (r + 8 <= e2) {
                                val slen = u32le(b, r + 4)
                                val sbody = r + 8
                                if (fourccEq(b, r, "strf") && sbody + 12 <= b.size) {
                                    width = u32le(b, sbody + 4)
                                    height = u32le(b, sbody + 8)
                                }
                                r = sbody + slen + (slen and 1)
                            }
                        }
                        q = cbody + clen + (clen and 1)
                    }
                }
            }
            p = body + size + (size and 1)
        }

        require(frames.isNotEmpty()) { "AVI 中没有视频帧" }
        if (width <= 0 || height <= 0) {
            val f0 = frames[0]
            require(f0.size >= 8) { "帧头不完整" }
            width = ((f0[4].toInt() and 0xFF) shl 8) or (f0[5].toInt() and 0xFF)
            height = ((f0[6].toInt() and 0xFF) shl 8) or (f0[7].toInt() and 0xFF)
        }
        require(width > 0 && height > 0 && (width and 1) == 0 && (height and 1) == 0) {
            "视频尺寸无效"
        }
        return Avi(frames, width, height, usecPerFrame)
    }

    /**
     * Stateful decoder: feed frames in order (inter frames depend on the running
     * reconstruction). [decodeFrame] returns ARGB_8888 pixels (opaque) for one
     * frame, reusing the previous frame's pixels for skipped macroblocks.
     */
    class Decoder(val width: Int, val height: Int) {
        private val uvW = width shr 1
        private val uvH = height shr 1
        private val yPlane = IntArray(width * height)
        private val uPlane = IntArray(uvW * uvH)
        private val vPlane = IntArray(uvW * uvH)
        private val mbX = width shr 2

        // ── bit reader state (reset per mixed-vector chunk) ──────────────────
        private var f: ByteArray = ByteArray(0)
        private var pos = 0
        private var bitMask = 0
        private var bitWord = 0

        private fun be16(o: Int) = ((f[o].toInt() and 0xFF) shl 8) or (f[o + 1].toInt() and 0xFF)
        private fun be24(o: Int) =
            ((f[o].toInt() and 0xFF) shl 16) or ((f[o + 1].toInt() and 0xFF) shl 8) or
                (f[o + 2].toInt() and 0xFF)

        // Mirrors the encoder's emitBit: shift first, and when the 32-bit word is
        // exhausted pull the next big-endian word from the stream (MSB first).
        private fun readBit(): Boolean {
            bitMask = bitMask ushr 1
            if (bitMask == 0) {
                bitWord = ((f[pos].toInt() and 0xFF) shl 24) or
                    ((f[pos + 1].toInt() and 0xFF) shl 16) or
                    ((f[pos + 2].toInt() and 0xFF) shl 8) or
                    (f[pos + 3].toInt() and 0xFF)
                pos += 4
                bitMask = 0x80000000.toInt()
            }
            return (bitWord and bitMask) != 0
        }

        fun decodeFrame(frame: ByteArray): IntArray {
            f = frame
            require(frame.size >= 10) { "帧头不完整" }
            val strips = be16(8)
            var p = 10
            var topRow = 0
            for (s in 0 until strips) {
                if (p + 12 > frame.size) break
                val stripSize = be24(p + 1)
                val bandH = be16(p + 8)
                decodeStrip(p, stripSize, topRow, bandH shr 2)
                topRow += bandH
                p += stripSize
            }
            return yuvToArgb()
        }

        private fun decodeStrip(stripStart: Int, stripSize: Int, topRow: Int, mbRows: Int) {
            var v1cb: Array<IntArray>? = null
            var v4cb: Array<IntArray>? = null
            var p = stripStart + 12
            val end = minOf(stripStart + stripSize, f.size)
            while (p + 4 <= end) {
                val id = f[p].toInt() and 0xFF
                val size = be24(p + 1)
                val cbody = p + 4
                val bodyLen = size - 4
                when (id) {
                    0x22 -> v1cb = readCodebook(cbody, bodyLen)
                    0x20 -> v4cb = readCodebook(cbody, bodyLen)
                    0x32 -> decodeAllV1(cbody, topRow, mbRows, v1cb)
                    0x30 -> decodeMixed(cbody, topRow, mbRows, v1cb, v4cb, inter = false)
                    0x31 -> decodeMixed(cbody, topRow, mbRows, v1cb, v4cb, inter = true)
                }
                p += size
            }
        }

        // Each entry 6B: Y0..Y3 (unsigned) then U, V (signed — Byte.toInt sign-extends,
        // the exact inverse of the encoder's `u8(e[4] and 0xFF)`).
        private fun readCodebook(body: Int, len: Int): Array<IntArray> {
            val n = if (len > 0) len / 6 else 0
            return Array(n) { i ->
                val o = body + i * 6
                intArrayOf(
                    f[o].toInt() and 0xFF,
                    f[o + 1].toInt() and 0xFF,
                    f[o + 2].toInt() and 0xFF,
                    f[o + 3].toInt() and 0xFF,
                    f[o + 4].toInt(),
                    f[o + 5].toInt(),
                )
            }
        }

        private fun decodeAllV1(body: Int, topRow: Int, mbRows: Int, v1cb: Array<IntArray>?) {
            if (v1cb == null) return
            var o = body
            for (lmy in 0 until mbRows) {
                for (mx in 0 until mbX) {
                    val idx = f[o].toInt() and 0xFF
                    o++
                    if (idx < v1cb.size) paintV1(mx shl 2, topRow + (lmy shl 2), v1cb[idx])
                }
            }
        }

        private fun decodeMixed(
            body: Int,
            topRow: Int,
            mbRows: Int,
            v1cb: Array<IntArray>?,
            v4cb: Array<IntArray>?,
            inter: Boolean,
        ) {
            pos = body
            bitMask = 0
            bitWord = 0
            for (lmy in 0 until mbRows) {
                for (mx in 0 until mbX) {
                    val x0 = mx shl 2
                    val y0 = topRow + (lmy shl 2)
                    if (inter && !readBit()) continue // skip → reuse previous recon
                    if (readBit()) {
                        val a = f[pos].toInt() and 0xFF
                        val b = f[pos + 1].toInt() and 0xFF
                        val c = f[pos + 2].toInt() and 0xFF
                        val d = f[pos + 3].toInt() and 0xFF
                        pos += 4
                        if (v4cb != null && a < v4cb.size && b < v4cb.size &&
                            c < v4cb.size && d < v4cb.size
                        ) {
                            paintV4(x0, y0, v4cb[a], v4cb[b], v4cb[c], v4cb[d])
                        }
                    } else {
                        val idx = f[pos].toInt() and 0xFF
                        pos++
                        if (v1cb != null && idx < v1cb.size) paintV1(x0, y0, v1cb[idx])
                    }
                }
            }
        }

        // One YUV per quadrant, luma expanded 2×2; chroma shared by the whole MB.
        private fun paintV1(x0: Int, y0: Int, e: IntArray) {
            for (q in 0 until 4) {
                val qx = x0 + QUAD_X[q]
                val qy = y0 + QUAD_Y[q]
                val a = e[q]
                yPlane[qy * width + qx] = a
                yPlane[qy * width + qx + 1] = a
                yPlane[(qy + 1) * width + qx] = a
                yPlane[(qy + 1) * width + qx + 1] = a
            }
            val ux = x0 shr 1
            val uy = y0 shr 1
            uPlane[uy * uvW + ux] = e[4]; uPlane[uy * uvW + ux + 1] = e[4]
            uPlane[(uy + 1) * uvW + ux] = e[4]; uPlane[(uy + 1) * uvW + ux + 1] = e[4]
            vPlane[uy * uvW + ux] = e[5]; vPlane[uy * uvW + ux + 1] = e[5]
            vPlane[(uy + 1) * uvW + ux] = e[5]; vPlane[(uy + 1) * uvW + ux + 1] = e[5]
        }

        // Four Y per quadrant (its 2×2), one chroma pair per quadrant.
        private fun paintV4(x0: Int, y0: Int, a: IntArray, b: IntArray, c: IntArray, d: IntArray) {
            val quad = arrayOf(a, b, c, d)
            for (q in 0 until 4) {
                val qx = x0 + QUAD_X[q]
                val qy = y0 + QUAD_Y[q]
                val e = quad[q]
                yPlane[qy * width + qx] = e[0]; yPlane[qy * width + qx + 1] = e[1]
                yPlane[(qy + 1) * width + qx] = e[2]; yPlane[(qy + 1) * width + qx + 1] = e[3]
            }
            val ux = x0 shr 1
            val uy = y0 shr 1
            uPlane[uy * uvW + ux] = a[4]; uPlane[uy * uvW + ux + 1] = b[4]
            uPlane[(uy + 1) * uvW + ux] = c[4]; uPlane[(uy + 1) * uvW + ux + 1] = d[4]
            vPlane[uy * uvW + ux] = a[5]; vPlane[uy * uvW + ux + 1] = b[5]
            vPlane[(uy + 1) * uvW + ux] = c[5]; vPlane[(uy + 1) * uvW + ux + 1] = d[5]
        }

        private fun yuvToArgb(): IntArray {
            val out = IntArray(width * height)
            for (py in 0 until height) {
                val uvRow = (py shr 1) * uvW
                val row = py * width
                for (px in 0 until width) {
                    val y = yPlane[row + px]
                    val uvi = uvRow + (px shr 1)
                    val u = uPlane[uvi]
                    val v = vPlane[uvi]
                    var r = y + 2 * v
                    var g = y - (u shr 1) - v
                    var bl = y + 2 * u
                    r = if (r < 0) 0 else if (r > 255) 255 else r
                    g = if (g < 0) 0 else if (g > 255) 255 else g
                    bl = if (bl < 0) 0 else if (bl > 255) 255 else bl
                    out[row + px] = (0xFF shl 24) or (r shl 16) or (g shl 8) or bl
                }
            }
            return out
        }
    }
}
