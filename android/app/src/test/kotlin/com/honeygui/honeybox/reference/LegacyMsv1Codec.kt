package com.honeygui.honeybox.reference

import java.io.ByteArrayOutputStream

/**
 * TEST-ONLY IMMUTABLE MIGRATION REFERENCE. Never ship or import from production.
 * Source: android/app/src/main/kotlin/com/honeygui/honeybox/SoftwareCodec.kt
 * Git blob: eb9aa919ffcbad6c708f9654a73fea41e7a1baa9 (JPEG portion intentionally omitted).
 * Behavioral edits require an intentional fixture review.
 *
 * Kotlin reference for MSV1 and its minimal AVI muxer, ported from
 * the w04_web_app reference (verified against libavcodec/msvideo1.c).
 */
object LegacyMsv1Codec {

    // libavcodec scan order for the 2-color mask bits.
    private val SCAN = intArrayOf(12, 13, 14, 15, 8, 9, 10, 11, 4, 5, 6, 7, 0, 1, 2, 3)

    private fun rgb555(r: Int, g: Int, b: Int): Int =
        (((r shr 3) and 31) shl 10) or (((g shr 3) and 31) shl 5) or ((b shr 3) and 31)

    /** Solid-color words with high byte 0x84..0x87 collide with skip codes. */
    private fun isSkipColor(w: Int): Boolean = ((w shr 8) and 0xfc) == 0x84

    private inline fun rb(a: ByteArray, i: Int): Int = a[i].toInt() and 0xff

    /**
     * Encode one MSV1 frame. [prev] (previous frame RGBA) enables inter-frame
     * skip (P-frame): a 4×4 block whose per-pixel RGB555 delta sum ≤ [thr] is
     * skipped. [prev] = null → full I-frame.
     */
    fun encodeMsv1(rgba: ByteArray, w: Int, h: Int, prev: ByteArray?, thr: Int): ByteArray {
        val bw = w shr 2
        val bh = h shr 2
        val words = ArrayList<Int>(bw * bh)
        var run = 0
        // Blocks bottom-up rows, left→right within a row.
        var by = bh - 1
        while (by >= 0) {
            var bx = 0
            while (bx < bw) {
                if (prev != null && blockSkippable(rgba, prev, w, bx * 4, by * 4, thr)) {
                    run++
                } else {
                    if (run > 0) {
                        flushSkip(words, run); run = 0
                    }
                    encBlock(rgba, w, bx * 4, by * 4, words)
                }
                bx++
            }
            by--
        }
        if (run > 0) flushSkip(words, run)
        words.add(0x0000)
        val out = ByteArray(words.size * 2)
        for (i in words.indices) {
            out[i * 2] = (words[i] and 0xff).toByte()
            out[i * 2 + 1] = ((words[i] shr 8) and 0xff).toByte()
        }
        return out
    }

    private fun blockSkippable(
        rgba: ByteArray, prev: ByteArray, w: Int, x0: Int, y0: Int, thr: Int,
    ): Boolean {
        for (py in 0 until 4) for (px in 0 until 4) {
            val i = ((y0 + py) * w + (x0 + px)) * 4
            val d = Math.abs((rb(rgba, i) shr 3) - (rb(prev, i) shr 3)) +
                Math.abs((rb(rgba, i + 1) shr 3) - (rb(prev, i + 1) shr 3)) +
                Math.abs((rb(rgba, i + 2) shr 3) - (rb(prev, i + 2) shr 3))
            if (d > thr) return false
        }
        return true
    }

    // Skip-run: high byte = 0x84 | top2bits of count; max 0x3ff per record.
    private fun flushSkip(words: ArrayList<Int>, count: Int) {
        var n = count
        while (n > 0) {
            val k = Math.min(n, 0x3ff)
            words.add(((0x84 or ((k shr 8) and 3)) shl 8) or (k and 0xff))
            n -= k
        }
    }

    private fun pushSolid(words: ArrayList<Int>, c555: Int) {
        val w = (c555 and 0x7fff) or 0x8000
        if (isSkipColor(w)) {
            words.add(0x0000); words.add(0x0000); words.add(c555 and 0x7fff)
        } else {
            words.add(w)
        }
    }

    private fun encBlock(rgba: ByteArray, W: Int, x0: Int, y0: Int, words: ArrayList<Int>) {
        val r = IntArray(16); val g = IntArray(16); val b = IntArray(16); val c = IntArray(16)
        for (py in 0 until 4) for (px in 0 until 4) {
            val idx = ((y0 + py) * W + (x0 + px)) * 4
            val k = py * 4 + px
            r[k] = rb(rgba, idx); g[k] = rb(rgba, idx + 1); b[k] = rb(rgba, idx + 2)
            c[k] = rgb555(r[k], g[k], b[k])
        }
        var solid = true
        for (k in 1 until 16) if (c[k] != c[0]) { solid = false; break }
        if (solid) { pushSolid(words, c[0]); return }

        // Split into two clusters by luminance extremes, then refine.
        var lo = Int.MAX_VALUE; var hi = Int.MIN_VALUE; var loi = 0; var hii = 0
        for (k in 0 until 16) {
            val L = r[k] * 299 + g[k] * 587 + b[k] * 114
            if (L < lo) { lo = L; loi = k }
            if (L > hi) { hi = L; hii = k }
        }
        val saR = r[hii]; val saG = g[hii]; val saB = b[hii]
        val sbR = r[loi]; val sbG = g[loi]; val sbB = b[loi]
        val grp = IntArray(16)
        var aR = 0; var aG = 0; var aB = 0; var na = 0
        var bR = 0; var bG = 0; var bB = 0; var nb = 0
        for (k in 0 until 16) {
            val da = (r[k] - saR) * (r[k] - saR) + (g[k] - saG) * (g[k] - saG) + (b[k] - saB) * (b[k] - saB)
            val db = (r[k] - sbR) * (r[k] - sbR) + (g[k] - sbG) * (g[k] - sbG) + (b[k] - sbB) * (b[k] - sbB)
            if (da <= db) { grp[k] = 1; aR += r[k]; aG += g[k]; aB += b[k]; na++ }
            else { grp[k] = 0; bR += r[k]; bG += g[k]; bB += b[k]; nb++ }
        }
        if (na == 0 || nb == 0) { pushSolid(words, c[0]); return }
        var cA = rgb555(aR / na, aG / na, aB / na)
        var cB = rgb555(bR / nb, bG / nb, bB / nb)
        var mask = 0
        for (i in 0 until 16) if (grp[SCAN[i]] == 1) mask = mask or (1 shl i)
        if (mask and 0x8000 != 0) { mask = mask xor 0xffff; val t = cA; cA = cB; cB = t }
        words.add(mask and 0xffff); words.add(cA and 0x7fff); words.add(cB and 0x7fff)
    }

    /**
     * Decode one MSV1 frame into [outArgb] (persistent ARGB8888, W*H ints).
     * Skip blocks keep the previous frame's pixels (pass the same [outArgb]
     * across frames for correct P-frame reconstruction). Ported from w04.
     */
    fun decodeMsv1(buf: ByteArray, W: Int, H: Int, outArgb: IntArray) {
        val bw = W shr 2
        val bh = H shr 2
        var sp = 0
        fun rd(): Int {
            val v = (buf[sp].toInt() and 0xff) or ((buf[sp + 1].toInt() and 0xff) shl 8)
            sp += 2; return v
        }
        fun put(x: Int, y: Int, c: Int) {
            val r = (c shr 10) and 31; val g = (c shr 5) and 31; val b = c and 31
            val R = (r shl 3) or (r shr 2)
            val G = (g shl 3) or (g shr 2)
            val B = (b shl 3) or (b shr 2)
            outArgb[y * W + x] = (0xFF shl 24) or (R shl 16) or (G shl 8) or B
        }
        var total = bw * bh
        var skip = 0
        var by = bh - 1
        while (by >= 0) {
            var bx = 0
            while (bx < bw) {
                val x0 = bx * 4; val y0 = by * 4
                if (skip > 0) { skip--; total--; bx++; continue }
                if (sp + 1 >= buf.size) return
                val a = buf[sp].toInt() and 0xff
                val bb = buf[sp + 1].toInt() and 0xff
                if (a == 0 && bb == 0 && total == 0) return
                if ((bb and 0xfc) == 0x84) {
                    sp += 2; skip = ((bb - 0x84) shl 8) + a - 1; total--; bx++; continue
                }
                if (bb < 0x80) {
                    val flags = rd(); val c0 = rd(); val c1 = rd()
                    if (c0 and 0x8000 != 0) {
                        val cols = intArrayOf(c0, c1, rd(), rd(), rd(), rd(), rd(), rd())
                        var f = flags
                        for (py in 0 until 4) for (px in 0 until 4) {
                            put(x0 + px, y0 + (3 - py), cols[((py and 2) shl 1) + (px and 2) + ((f and 1) xor 1)])
                            f = f shr 1
                        }
                    } else {
                        var f = flags
                        for (py in 0 until 4) for (px in 0 until 4) {
                            put(x0 + px, y0 + (3 - py), if (f and 1 != 0) c0 else c1)
                            f = f shr 1
                        }
                    }
                } else {
                    val c = ((bb shl 8) or a) and 0x7fff; sp += 2
                    for (py in 0 until 4) for (px in 0 until 4) put(x0 + px, y0 + py, c)
                }
                total--
                bx++
            }
            by--
        }
    }

    // ── Minimal AVI muxer (vids: MSVC 16bpp / MJPG 24bpp) ────────────────────

    private class Le {
        val b = ByteArrayOutputStream()
        fun str(s: String) = apply { for (ch in s) b.write(ch.code and 0xff) }
        fun u16(v: Int) = apply { b.write(v and 0xff); b.write((v shr 8) and 0xff) }
        fun u32(v: Int) = apply {
            b.write(v and 0xff); b.write((v shr 8) and 0xff)
            b.write((v shr 16) and 0xff); b.write((v ushr 24) and 0xff)
        }
        fun bytes(a: ByteArray) = apply { b.write(a) }
        fun raw(v: Int) = apply { b.write(v and 0xff) }
    }

    /**
     * Build an AVI from [frames]. [fourcc] = "MSVC"/"MJPG", [bitCount] = 16/24.
     * [keyFlags] marks keyframes (I-frames); null → all keyframes.
     */
    fun buildAvi(
        frames: List<ByteArray>, width: Int, height: Int, fps: Int,
        fourcc: String, bitCount: Int, keyFlags: BooleanArray?,
    ): ByteArray {
        val n = frames.size
        var maxF = 1
        val pads = IntArray(n)
        val totals = IntArray(n)
        for (i in 0 until n) {
            val len = frames[i].size
            pads[i] = len and 1
            totals[i] = 8 + len + pads[i]
            if (len > maxF) maxF = len
        }
        var cur = 4
        val offs = IntArray(n)
        for (i in 0 until n) { offs[i] = cur; cur += totals[i] }
        val moviData = cur
        val idx1Data = 16 * n
        val hdrlData = 4 + 64 + 124
        val riffData = 4 + (8 + hdrlData) + (8 + moviData) + (8 + idx1Data)
        val usPerFrame = Math.round(1e6 / fps).toInt()
        val w = Le()
        w.str("RIFF").u32(riffData).str("AVI ")
        w.str("LIST").u32(hdrlData).str("hdrl")
        w.str("avih").u32(56).u32(usPerFrame).u32(0).u32(0).u32(0x10).u32(n).u32(0)
            .u32(1).u32(maxF).u32(width).u32(height).u32(0).u32(0).u32(0).u32(0)
        w.str("LIST").u32(124).str("strl")
        w.str("strh").u32(56).str("vids").str(fourcc).u32(0).u16(0).u16(0).u32(0)
            .u32(1).u32(fps).u32(0).u32(n).u32(maxF).u32(-1).u32(0).u16(0).u16(0)
            .u16(width).u16(height)
        w.str("strf").u32(40).u32(40).u32(width).u32(height).u16(1).u16(bitCount)
            .str(fourcc).u32(width * height * 2).u32(0).u32(0).u32(0).u32(0)
        w.str("LIST").u32(moviData).str("movi")
        for (i in 0 until n) {
            w.str("00dc").u32(frames[i].size).bytes(frames[i])
            if (pads[i] != 0) w.raw(0)
        }
        w.str("idx1").u32(idx1Data)
        for (i in 0 until n) {
            val key = keyFlags == null || keyFlags[i]
            w.str("00dc").u32(if (key) 0x10 else 0).u32(offs[i]).u32(frames[i].size)
        }
        return w.b.toByteArray()
    }
}
