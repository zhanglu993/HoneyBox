package com.honeygui.honeybox.reference

/*
 * TEST-ONLY IMMUTABLE MIGRATION REFERENCE. Never ship or import from production.
 * Source: android/app/src/main/kotlin/com/honeygui/honeybox/CinepakEncoder.kt
 * Git blob: d72ad9a80d8baaaf64f0a55417896bb0c59a114a
 * Behavioral edits require an intentional fixture review.
 */

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Pure-Kotlin Cinepak (CVID) frame encoder — a faithful port of the
 * miniprogram's `utils/cinepak-encoder.js` (itself derived from FFmpeg
 * libavcodec/cinepakenc.c write format + RGB→YUV coefficients):
 *
 *   · key frames (intra): each frame carries a full codebook, self-decodable;
 *   · inter frames: per-MB skip bit — unchanged blocks reuse the previous
 *     frame's pixels; only changed blocks are coded → smaller frames;
 *   · multi-strip (default 2): each strip carries its own V1+V4 codebooks;
 *   · VQ = median-cut init + Lloyd (k-means) refine (approximates FFmpeg ELBG);
 *   · V1/V4 decision folds in both luma and chroma error;
 *   · quality knob controls V1-only vs V1+V4 and the V4 adoption threshold.
 *
 * Bitstream (big-endian), verified against the device parser gui_lite_video.c:
 *   frame header 10B: flags(1)=0 key/1 inter | size(3) | w(2) | h(2) | strips(2)
 *   strip 12B: id(1)=0x10 key/0x11 inter | size(3) | top(2)=0 | left(2)=0
 *              | bot(2)=band height | right(2)=w
 *   chunk 4B: id(1) | size(3) (size includes the header)
 *   codebooks: 0x22=V1, 0x20=V4; each entry 6B = [Y0 Y1 Y2 Y3 U V] (U/V signed)
 *   vectors: 0x32=all-V1, 0x30=key mixed (1 type bit/MB), 0x31=inter
 *            (1 skip bit/MB, then 1 type bit for coded blocks)
 */
object LegacyCinepakEncoder {

    // ── Tunables resolved from options ──────────────────────────────────────
    class Params(
        val mixed: Boolean,
        val v1Size: Int,
        val v4Size: Int,
        val v4Threshold: Double,
        val refine: Int,
        val chromaW: Int,
        val skipThresh: Int,
    )

    class Options(
        val quality: Int = 60,
        val v1Size: Int = 256,
        val v4Size: Int = 256,
        val refine: Int = 3,
        val chromaW: Int = 4,
        val strips: Int = 2,
        val skipThresh: Int = 720,
        val keyint: Int = 0,
    )

    private class Parsed(val p: Params, val numStrips: Int, val keyint: Int)

    private fun parseOpts(height: Int, o: Options): Parsed {
        val quality = o.quality
        val v1Size = minOf(o.v1Size, 256)
        val v4Size = minOf(o.v4Size, 256)
        val refine = o.refine
        val chromaW = o.chromaW
        val mbY = height shr 2
        val numStrips = maxOf(1, minOf(o.strips, mbY))
        val mixed = quality > 20
        val v4Threshold =
            if (mixed) maxOf(0.0, 2000.0 * (100 - quality) / 80.0) else Double.POSITIVE_INFINITY
        return Parsed(
            Params(mixed, v1Size, v4Size, v4Threshold, refine, chromaW, o.skipThresh),
            numStrips,
            o.keyint,
        )
    }

    // ── RGBA → YUV (FFmpeg cinepakenc fixed-point coeffs, >> 23) ─────────────
    private class Yuv(val y: IntArray, val u: IntArray, val v: IntArray, val uvW: Int, val uvH: Int)

    private fun rgbToYuv(rgba: ByteArray, w: Int, h: Int): Yuv {
        val Y = IntArray(w * h)
        val uvW = w shr 1
        val uvH = h shr 1
        val U = IntArray(uvW * uvH)
        val V = IntArray(uvW * uvH)

        for (py in 0 until h) {
            for (px in 0 until w) {
                val i = (py * w + px) * 4
                val r = rgba[i].toInt() and 0xFF
                val g = rgba[i + 1].toInt() and 0xFF
                val b = rgba[i + 2].toInt() and 0xFF
                var y = (2396625 * r + 4793251 * g + 1198732 * b) shr 23
                if (y < 0) y = 0 else if (y > 255) y = 255
                Y[py * w + px] = y
            }
        }

        for (by in 0 until uvH) {
            for (bx in 0 until uvW) {
                val x = bx shl 1
                val yy = by shl 1
                var sr = 0
                var sg = 0
                var sb = 0
                for (dy in 0 until 2) {
                    var i = ((yy + dy) * w + x) * 4
                    for (dx in 0 until 2) {
                        sr += rgba[i].toInt() and 0xFF
                        sg += rgba[i + 1].toInt() and 0xFF
                        sb += rgba[i + 2].toInt() and 0xFF
                        i += 4
                    }
                }
                var u = (-299683 * sr - 599156 * sg + 898839 * sb) shr 23
                var v = (748893 * sr - 599156 * sg - 149737 * sb) shr 23
                if (u < -128) u = -128 else if (u > 127) u = 127
                if (v < -128) v = -128 else if (v > 127) v = 127
                U[by * uvW + bx] = u
                V[by * uvW + bx] = v
            }
        }
        return Yuv(Y, U, V, uvW, uvH)
    }

    // ── median-cut vector quantization ───────────────────────────────────────
    private class VQ(val codebook: Array<IntArray>, val labels: IntArray)

    private class Box(var members: IntArray, var range: Int, var splitDim: Int)

    private fun rangeOf(data: IntArray, dim: Int, members: IntArray): IntArray {
        // returns [range, splitDim]
        var bestRange = -1
        var bestDim = 0
        for (d in 0 until dim) {
            var mn = Int.MAX_VALUE
            var mx = Int.MIN_VALUE
            for (k in members.indices) {
                val value = data[members[k] * dim + d]
                if (value < mn) mn = value
                if (value > mx) mx = value
            }
            val r = mx - mn
            if (r > bestRange) {
                bestRange = r
                bestDim = d
            }
        }
        return intArrayOf(bestRange, bestDim)
    }

    private fun medianCut(data: IntArray, count: Int, dim: Int, maxK: Int): VQ {
        if (count == 0) return VQ(emptyArray(), IntArray(0))

        val all = IntArray(count) { it }
        val r0 = rangeOf(data, dim, all)
        val boxes = ArrayList<Box>()
        boxes.add(Box(all, r0[0], r0[1]))

        while (boxes.size < maxK) {
            var bi = -1
            var br = 0
            for (i in boxes.indices) {
                if (boxes[i].members.size > 1 && boxes[i].range > br) {
                    br = boxes[i].range
                    bi = i
                }
            }
            if (bi < 0 || br <= 0) break

            val box = boxes[bi]
            val d = box.splitDim
            val mem = box.members.toTypedArray()
            mem.sortBy { data[it * dim + d] }
            val mid = mem.size shr 1
            val left = IntArray(mid) { mem[it] }
            val right = IntArray(mem.size - mid) { mem[mid + it] }
            val lr = rangeOf(data, dim, left)
            val rr = rangeOf(data, dim, right)
            boxes[bi] = Box(left, lr[0], lr[1])
            boxes.add(Box(right, rr[0], rr[1]))
        }

        val codebook = Array(boxes.size) { IntArray(dim) }
        val labels = IntArray(count)
        for (i in boxes.indices) {
            val mem = boxes[i].members
            val entry = IntArray(dim)
            for (k in mem.indices) {
                val base = mem[k] * dim
                for (d in 0 until dim) entry[d] += data[base + d]
                labels[mem[k]] = i
            }
            val n = mem.size
            for (d in 0 until dim) entry[d] = (entry[d].toDouble() / n).roundToInt()
            codebook[i] = entry
        }
        return VQ(codebook, labels)
    }

    // ── Lloyd (k-means) refine — dim assumed 6, layout [Y0 Y1 Y2 Y3 U V] ──────
    private fun lloydRefine(
        data: IntArray,
        count: Int,
        dim: Int,
        init: VQ,
        iters: Int,
        chromaW: Int,
    ): VQ {
        val K = init.codebook.size
        if (K == 0 || count == 0 || iters <= 0) return init
        val C = DoubleArray(K * dim)
        for (i in 0 until K) for (d in 0 until dim) C[i * dim + d] = init.codebook[i][d].toDouble()
        val labels = init.labels
        val sum = DoubleArray(K * dim)
        val cnt = IntArray(K)
        for (it in 0 until iters) {
            sum.fill(0.0)
            cnt.fill(0)
            for (i in 0 until count) {
                val b = i * dim
                var best = 0
                var bd = Double.POSITIVE_INFINITY
                for (c in 0 until K) {
                    val cb = c * dim
                    var e = 0.0
                    for (d in 0 until 4) {
                        val x = data[b + d] - C[cb + d]
                        e += x * x
                    }
                    var dc = data[b + 4] - C[cb + 4]
                    e += chromaW * dc * dc
                    dc = data[b + 5] - C[cb + 5]
                    e += chromaW * dc * dc
                    if (e < bd) {
                        bd = e
                        best = c
                    }
                }
                labels[i] = best
                cnt[best]++
                val sb = best * dim
                for (d in 0 until dim) sum[sb + d] += data[b + d]
            }
            for (c in 0 until K) {
                if (cnt[c] > 0) {
                    val cb = c * dim
                    for (d in 0 until dim) C[cb + d] = sum[cb + d] / cnt[c]
                }
            }
        }
        val codebook = Array(K) { IntArray(dim) }
        for (c in 0 until K) {
            val cb = c * dim
            val e = IntArray(dim)
            for (d in 0 until dim) e[d] = C[cb + d].roundToInt()
            codebook[c] = e
        }
        return VQ(codebook, labels)
    }

    // 4x4 MB → four 2x2 quadrants: TL, TR, BL, BR; matches decoder geometry.
    private val QUAD_X = intArrayOf(0, 2, 0, 2)
    private val QUAD_Y = intArrayOf(0, 0, 2, 2)

    // Persistent reconstruction of what the device currently shows.
    class Recon(val y: IntArray, val u: IntArray, val v: IntArray)

    private fun paintV1Into(recon: Recon, w: Int, uvW: Int, x0: Int, y0: Int, e: IntArray) {
        val Y = recon.y
        for (q in 0 until 4) {
            val qx = x0 + QUAD_X[q]
            val qy = y0 + QUAD_Y[q]
            val a = e[q]
            Y[qy * w + qx] = a
            Y[qy * w + qx + 1] = a
            Y[(qy + 1) * w + qx] = a
            Y[(qy + 1) * w + qx + 1] = a
        }
        val ux = x0 shr 1
        val uy = y0 shr 1
        recon.u[uy * uvW + ux] = e[4]; recon.u[uy * uvW + ux + 1] = e[4]
        recon.u[(uy + 1) * uvW + ux] = e[4]; recon.u[(uy + 1) * uvW + ux + 1] = e[4]
        recon.v[uy * uvW + ux] = e[5]; recon.v[uy * uvW + ux + 1] = e[5]
        recon.v[(uy + 1) * uvW + ux] = e[5]; recon.v[(uy + 1) * uvW + ux + 1] = e[5]
    }

    private fun paintV4Into(
        recon: Recon,
        w: Int,
        uvW: Int,
        x0: Int,
        y0: Int,
        A: IntArray,
        B: IntArray,
        C: IntArray,
        D: IntArray,
    ) {
        val Y = recon.y
        val quad = arrayOf(A, B, C, D)
        for (q in 0 until 4) {
            val qx = x0 + QUAD_X[q]
            val qy = y0 + QUAD_Y[q]
            val e = quad[q]
            Y[qy * w + qx] = e[0]; Y[qy * w + qx + 1] = e[1]
            Y[(qy + 1) * w + qx] = e[2]; Y[(qy + 1) * w + qx + 1] = e[3]
        }
        val ux = x0 shr 1
        val uy = y0 shr 1
        recon.u[uy * uvW + ux] = A[4]; recon.u[uy * uvW + ux + 1] = B[4]
        recon.u[(uy + 1) * uvW + ux] = C[4]; recon.u[(uy + 1) * uvW + ux + 1] = D[4]
        recon.v[uy * uvW + ux] = A[5]; recon.v[uy * uvW + ux + 1] = B[5]
        recon.v[(uy + 1) * uvW + ux] = C[5]; recon.v[(uy + 1) * uvW + ux + 1] = D[5]
    }

    // ── Encode one horizontal strip ──────────────────────────────────────────
    private fun encodeStrip(
        Y: IntArray,
        U: IntArray,
        V: IntArray,
        uvW: Int,
        width: Int,
        topRow: Int,
        bandH: Int,
        mbX: Int,
        mbRows: Int,
        P: Params,
        recon: Recon?,
        isInter: Boolean,
    ): ByteArray {
        val numMB = mbX * mbRows

        val v1vec = IntArray(numMB * 6)
        val v4vec = IntArray(numMB * 4 * 6)

        for (lmy in 0 until mbRows) {
            for (mx in 0 until mbX) {
                val mb = lmy * mbX + mx
                val x0 = mx shl 2
                val y0 = topRow + (lmy shl 2)
                var uSum = 0
                var vSum = 0
                val v1base = mb * 6
                for (q in 0 until 4) {
                    val qx = x0 + QUAD_X[q]
                    val qy = y0 + QUAD_Y[q]
                    val y00 = Y[qy * width + qx]
                    val y10 = Y[qy * width + qx + 1]
                    val y01 = Y[(qy + 1) * width + qx]
                    val y11 = Y[(qy + 1) * width + qx + 1]
                    val uvIdx = (qy shr 1) * uvW + (qx shr 1)
                    val uu = U[uvIdx]
                    val vv = V[uvIdx]
                    val vb = (mb * 4 + q) * 6
                    v4vec[vb] = y00; v4vec[vb + 1] = y10; v4vec[vb + 2] = y01; v4vec[vb + 3] = y11
                    v4vec[vb + 4] = uu; v4vec[vb + 5] = vv
                    v1vec[v1base + q] = (y00 + y10 + y01 + y11 + 2) shr 2
                    uSum += uu
                    vSum += vv
                }
                v1vec[v1base + 4] = (uSum / 4.0).roundToInt()
                v1vec[v1base + 5] = (vSum / 4.0).roundToInt()
            }
        }

        var v1cb = medianCut(v1vec, numMB, 6, P.v1Size)
        v1cb = lloydRefine(v1vec, numMB, 6, v1cb, P.refine, P.chromaW)
        var v4cb: VQ? = null
        if (P.mixed) {
            v4cb = medianCut(v4vec, numMB * 4, 6, P.v4Size)
            v4cb = lloydRefine(v4vec, numMB * 4, 6, v4cb, P.refine, P.chromaW)
        }
        val v1lab = v1cb.labels
        val v4lab = v4cb?.labels

        val isV4 = ByteArray(numMB)
        if (P.mixed && v4cb != null) {
            for (lmy in 0 until mbRows) {
                for (mx in 0 until mbX) {
                    val mb = lmy * mbX + mx
                    val x0 = mx shl 2
                    val y0 = topRow + (lmy shl 2)
                    val v1e = v1cb.codebook[v1lab[mb]]
                    var errV1 = 0L
                    var errV4 = 0L
                    for (q in 0 until 4) {
                        val qx = x0 + QUAD_X[q]
                        val qy = y0 + QUAD_Y[q]
                        val y00 = Y[qy * width + qx]
                        val y10 = Y[qy * width + qx + 1]
                        val y01 = Y[(qy + 1) * width + qx]
                        val y11 = Y[(qy + 1) * width + qx + 1]
                        val a = v1e[q]
                        errV1 += ((y00 - a) * (y00 - a) + (y10 - a) * (y10 - a) +
                            (y01 - a) * (y01 - a) + (y11 - a) * (y11 - a)).toLong()
                        val e = v4cb.codebook[v4lab!![mb * 4 + q]]
                        errV4 += ((y00 - e[0]) * (y00 - e[0]) + (y10 - e[1]) * (y10 - e[1]) +
                            (y01 - e[2]) * (y01 - e[2]) + (y11 - e[3]) * (y11 - e[3])).toLong()
                        val uvIdx = (qy shr 1) * uvW + (qx shr 1)
                        val uu = U[uvIdx]
                        val vv = V[uvIdx]
                        val du1 = uu - v1e[4]
                        val dv1 = vv - v1e[5]
                        errV1 += P.chromaW.toLong() * (du1 * du1 + dv1 * dv1)
                        val du4 = uu - e[4]
                        val dv4 = vv - e[5]
                        errV4 += P.chromaW.toLong() * (du4 * du4 + dv4 * dv4)
                    }
                    if ((errV1 - errV4).toDouble() > P.v4Threshold) isV4[mb] = 1
                }
            }
        }

        // skip decision (inter) + write reconstruction back into recon
        val skip = ByteArray(numMB)
        var codedV4 = 0
        for (lmy in 0 until mbRows) {
            for (mx in 0 until mbX) {
                val mb = lmy * mbX + mx
                val x0 = mx shl 2
                val y0 = topRow + (lmy shl 2)
                if (isInter && recon != null) {
                    var e = 0L
                    for (q in 0 until 4) {
                        val qx = x0 + QUAD_X[q]
                        val qy = y0 + QUAD_Y[q]
                        val i00 = qy * width + qx
                        val i01 = (qy + 1) * width + qx
                        var d = Y[i00] - recon.y[i00]; e += (d * d).toLong()
                        d = Y[i00 + 1] - recon.y[i00 + 1]; e += (d * d).toLong()
                        d = Y[i01] - recon.y[i01]; e += (d * d).toLong()
                        d = Y[i01 + 1] - recon.y[i01 + 1]; e += (d * d).toLong()
                        val uvIdx = (qy shr 1) * uvW + (qx shr 1)
                        val du = U[uvIdx] - recon.u[uvIdx]
                        val dv = V[uvIdx] - recon.v[uvIdx]
                        e += P.chromaW.toLong() * (du * du + dv * dv)
                    }
                    if (e <= P.skipThresh) {
                        skip[mb] = 1
                        continue
                    }
                }
                val useV4Here = P.mixed && isV4[mb].toInt() == 1
                if (useV4Here) codedV4++
                if (recon != null) {
                    if (useV4Here) {
                        val b = mb * 4
                        paintV4Into(
                            recon, width, uvW, x0, y0,
                            v4cb!!.codebook[v4lab!![b]], v4cb.codebook[v4lab[b + 1]],
                            v4cb.codebook[v4lab[b + 2]], v4cb.codebook[v4lab[b + 3]],
                        )
                    } else {
                        paintV1Into(recon, width, uvW, x0, y0, v1cb.codebook[v1lab[mb]])
                    }
                }
            }
        }
        val useV4Chunk = P.mixed && codedV4 > 0

        // ── build the vector chunk body ──────────────────────────────────────
        val vecId: Int
        val vecBody = ArrayList<Int>()
        if (!isInter && !useV4Chunk) {
            vecId = 0x32
            for (mb in 0 until numMB) vecBody.add(v1lab[mb])
        } else {
            vecId = if (isInter) 0x31 else 0x30
            val wordIdx = ArrayList<Int>()
            val wordVal = ArrayList<Int>()
            var mask = 0
            var curIdx = -1
            // emitBit inlined below via closure-like helper
            fun emitBit(bit: Boolean) {
                mask = mask ushr 1
                if (mask == 0) {
                    curIdx = wordVal.size
                    wordIdx.add(vecBody.size)
                    wordVal.add(0)
                    vecBody.add(0); vecBody.add(0); vecBody.add(0); vecBody.add(0)
                    mask = 0x80000000.toInt()
                }
                if (bit) wordVal[curIdx] = wordVal[curIdx] or mask
            }
            for (mb in 0 until numMB) {
                if (isInter) {
                    if (skip[mb].toInt() == 1) {
                        emitBit(false)
                        continue
                    }
                    emitBit(true)
                }
                if (useV4Chunk && isV4[mb].toInt() == 1) {
                    emitBit(true)
                    val b = mb * 4
                    vecBody.add(v4lab!![b]); vecBody.add(v4lab[b + 1])
                    vecBody.add(v4lab[b + 2]); vecBody.add(v4lab[b + 3])
                } else {
                    emitBit(false)
                    vecBody.add(v1lab[mb])
                }
            }
            for (i in wordIdx.indices) {
                val idx = wordIdx[i]
                val v = wordVal[i]
                vecBody[idx] = (v ushr 24) and 0xFF
                vecBody[idx + 1] = (v ushr 16) and 0xFF
                vecBody[idx + 2] = (v ushr 8) and 0xFF
                vecBody[idx + 3] = v and 0xFF
            }
        }

        // ── size and emit ─────────────────────────────────────────────────────
        val v1ChunkSize = 4 + v1cb.codebook.size * 6
        val v4ChunkSize = if (useV4Chunk) 4 + v4cb!!.codebook.size * 6 else 0
        val vecChunkSize = 4 + vecBody.size
        val stripSize = 12 + v1ChunkSize + v4ChunkSize + vecChunkSize

        val out = ByteArray(stripSize)
        var p = 0
        fun u8(v: Int) { out[p++] = (v and 0xFF).toByte() }
        fun be16(v: Int) { out[p++] = ((v shr 8) and 0xFF).toByte(); out[p++] = (v and 0xFF).toByte() }
        fun be24(v: Int) {
            out[p++] = ((v shr 16) and 0xFF).toByte()
            out[p++] = ((v shr 8) and 0xFF).toByte()
            out[p++] = (v and 0xFF).toByte()
        }

        u8(if (isInter) 0x11 else 0x10)
        be24(stripSize)
        be16(0)        // top
        be16(0)        // left
        be16(bandH)    // bot = band height
        be16(width)    // right

        fun writeCodebook(id: Int, cb: Array<IntArray>) {
            u8(id)
            be24(4 + cb.size * 6)
            for (i in cb.indices) {
                val e = cb[i]
                u8(e[0]); u8(e[1]); u8(e[2]); u8(e[3])
                u8(e[4] and 0xFF); u8(e[5] and 0xFF)
            }
        }

        writeCodebook(0x22, v1cb.codebook)
        if (useV4Chunk) writeCodebook(0x20, v4cb!!.codebook)
        u8(vecId)
        be24(vecChunkSize)
        for (i in vecBody.indices) out[p++] = (vecBody[i] and 0xFF).toByte()

        return out
    }

    private fun assembleFrame(
        stripBufs: List<ByteArray>,
        width: Int,
        height: Int,
        numStrips: Int,
        isKey: Boolean,
    ): ByteArray {
        var body = 0
        for (s in stripBufs) body += s.size
        val frameSize = 10 + body
        val out = ByteArray(frameSize)
        out[0] = if (isKey) 0x00 else 0x01
        out[1] = ((frameSize shr 16) and 0xFF).toByte()
        out[2] = ((frameSize shr 8) and 0xFF).toByte()
        out[3] = (frameSize and 0xFF).toByte()
        out[4] = ((width shr 8) and 0xFF).toByte()
        out[5] = (width and 0xFF).toByte()
        out[6] = ((height shr 8) and 0xFF).toByte()
        out[7] = (height and 0xFF).toByte()
        out[8] = ((numStrips shr 8) and 0xFF).toByte()
        out[9] = (numStrips and 0xFF).toByte()
        var off = 10
        for (s in stripBufs) {
            System.arraycopy(s, 0, out, off, s.size)
            off += s.size
        }
        return out
    }

    private fun encodeStrips(
        Y: IntArray,
        U: IntArray,
        V: IntArray,
        uvW: Int,
        width: Int,
        mbX: Int,
        mbY: Int,
        P: Params,
        numStrips: Int,
        recon: Recon?,
        isInter: Boolean,
    ): List<ByteArray> {
        val stripBufs = ArrayList<ByteArray>()
        var rowStart = 0
        for (s in 0 until numStrips) {
            val rows = (mbY - rowStart) / (numStrips - s)
            stripBufs.add(
                encodeStrip(
                    Y, U, V, uvW, width, rowStart shl 2, rows shl 2, mbX, rows, P, recon, isInter,
                ),
            )
            rowStart += rows
        }
        return stripBufs
    }

    /** Stateless key-frame encode (backward compatible). w/h must be × of 4. */
    fun encodeFrame(rgba: ByteArray, width: Int, height: Int, options: Options): ByteArray {
        require(width and 3 == 0 && height and 3 == 0) { "Cinepak requires width/height multiple of 4" }
        val parsed = parseOpts(height, options)
        val yuv = rgbToYuv(rgba, width, height)
        val mbX = width shr 2
        val mbY = height shr 2
        val stripBufs = encodeStrips(
            yuv.y, yuv.u, yuv.v, yuv.uvW, width, mbX, mbY, parsed.p, parsed.numStrips, null, false,
        )
        return assembleFrame(stripBufs, width, height, parsed.numStrips, true)
    }

    /** Stateful sequence encoder: first frame key, rest inter (skip unchanged). */
    class Encoder(private val width: Int, private val height: Int, options: Options) {
        private val parsed = parseOpts(height, options)
        private val mbX = width shr 2
        private val mbY = height shr 2
        private val uvW = width shr 1
        private val uvH = height shr 1
        private val recon = Recon(IntArray(width * height), IntArray(uvW * uvH), IntArray(uvW * uvH))
        private var frameIdx = 0
        private var lastKey = -1

        init {
            require(width and 3 == 0 && height and 3 == 0) {
                "Cinepak requires width/height multiple of 4"
            }
        }

        fun encode(rgba: ByteArray, forceKey: Boolean = false): ByteArray {
            val isKey = forceKey || frameIdx == 0 ||
                (parsed.keyint > 0 && (frameIdx - lastKey) >= parsed.keyint)
            val yuv = rgbToYuv(rgba, width, height)
            val stripBufs = encodeStrips(
                yuv.y, yuv.u, yuv.v, uvW, width, mbX, mbY, parsed.p, parsed.numStrips, recon, !isKey,
            )
            val out = assembleFrame(stripBufs, width, height, parsed.numStrips, isKey)
            if (isKey) lastKey = frameIdx
            frameIdx++
            return out
        }

        fun reset() {
            frameIdx = 0
            lastKey = -1
            recon.y.fill(0)
            recon.u.fill(0)
            recon.v.fill(0)
        }
    }
}
