package com.honeygui.honeybox.reference

/*
 * TEST-ONLY IMMUTABLE MIGRATION REFERENCE. Never ship or import from production.
 * Source: android/app/src/main/kotlin/com/honeygui/honeybox/CvidAviMuxer.kt
 * Git blob: bf6a85417a931d51a91d4fef4ef6ee9089cbc6be
 * Behavioral edits require an intentional fixture review.
 */

/**
 * Muxes Cinepak (CVID) frames into a standard AVI(CVID) container — a faithful
 * port of the miniprogram's `utils/avi-muxer.js`. Field layout is matched to
 * the device parser gui_lite_video.c (ltv_src_init_mem):
 *   · all container ints little-endian (device memcpy's into uint32/uint16, ARM LE);
 *   · RIFF/AVI → LIST hdrl{ avih(56B) + LIST strl{ strh(56B) + strf(40B) } }
 *     → LIST movi{ 00dc chunks… } → idx1 (required — absence = parse failure);
 *   · strf = BITMAPINFOHEADER(40B), compression = "cvid";
 *   · idx1 entry 16B = { chunk_ID, flags, offset, size }, offset relative to the
 *     "movi" fourcc, pointing at the "00dc" chunk header (first frame = 4).
 * The parser reads strh (56B) then the next 8B as the strf header, so strh's
 * body must be exactly 56B with strf immediately after — no padding.
 */
object LegacyCvidAviMuxer {

    private const val AVIH_BODY = 56
    private const val STRH_BODY = 56
    private const val STRF_BODY = 40

    private const val AVIH_CHUNK = 8 + AVIH_BODY            // 64
    private const val STRH_CHUNK = 8 + STRH_BODY            // 64
    private const val STRF_CHUNK = 8 + STRF_BODY            // 48
    private const val STRL_PAYLOAD = 4 + STRH_CHUNK + STRF_CHUNK   // 116
    private const val STRL_CHUNK = 8 + STRL_PAYLOAD         // 124
    private const val HDRL_PAYLOAD = 4 + AVIH_CHUNK + STRL_CHUNK   // 192
    private const val HDRL_CHUNK = 8 + HDRL_PAYLOAD         // 200

    /** @param frames one Cinepak bitstream per frame. @return complete AVI bytes. */
    fun buildAvi(frames: List<ByteArray>, width: Int, height: Int, fps: Int): ByteArray {
        val n = frames.size
        val safeFps = if (fps > 0) fps else 10
        val usecPerFrame = Math.round(1_000_000.0 / safeFps).toInt()

        var moviPayload = 4 // "movi"
        var maxFrameLen = 0
        val pads = IntArray(n)
        for (i in 0 until n) {
            val len = frames[i].size
            if (len > maxFrameLen) maxFrameLen = len
            val pad = len and 1
            pads[i] = pad
            moviPayload += 8 + len + pad
        }
        val idx1Payload = n * 16

        val total = 12 + HDRL_CHUNK + (8 + moviPayload) + (8 + idx1Payload)

        val out = ByteArray(total)
        var p = 0
        fun u8(v: Int) { out[p++] = (v and 0xFF).toByte() }
        fun u16(v: Int) {
            out[p++] = (v and 0xFF).toByte()
            out[p++] = ((v shr 8) and 0xFF).toByte()
        }
        fun u32(v: Int) {
            out[p++] = (v and 0xFF).toByte()
            out[p++] = ((v shr 8) and 0xFF).toByte()
            out[p++] = ((v shr 16) and 0xFF).toByte()
            out[p++] = ((v shr 24) and 0xFF).toByte()
        }
        fun fourcc(s: String) {
            out[p++] = s[0].code.toByte()
            out[p++] = s[1].code.toByte()
            out[p++] = s[2].code.toByte()
            out[p++] = s[3].code.toByte()
        }

        // ── RIFF ──
        fourcc("RIFF")
        u32(total - 8)
        fourcc("AVI ")

        // ── LIST hdrl ──
        fourcc("LIST")
        u32(HDRL_PAYLOAD)
        fourcc("hdrl")

        // avih (AVIMAINHEADER, 56B)
        fourcc("avih")
        u32(AVIH_BODY)
        u32(usecPerFrame)
        u32(0)                          // max_byte_rate
        u32(0)                          // reserved_0 / padding_granularity
        u32(0x10)                       // flags = AVIF_HASINDEX
        u32(n)                          // total_frame
        u32(0)                          // initial_frame
        u32(1)                          // streams
        u32(maxFrameLen)                // buffer_size
        u32(width)
        u32(height)
        u32(0); u32(0); u32(0); u32(0)  // reserved[4]

        // LIST strl
        fourcc("LIST")
        u32(STRL_PAYLOAD)
        fourcc("strl")

        // strh (AVISTREAMHEADER, 56B)
        fourcc("strh")
        u32(STRH_BODY)
        fourcc("vids")
        fourcc("cvid")
        u32(0)                          // flags
        u32(0)                          // priority + language
        u32(0)                          // initial_frames
        u32(1)                          // scale
        u32(safeFps)                    // rate (rate/scale = fps)
        u32(0)                          // start
        u32(n)                          // length
        u32(maxFrameLen)                // buffer_size
        u32(0)                          // quality
        u32(0)                          // sample_size
        u16(0); u16(0); u16(width); u16(height)   // rcFrame

        // strf (BITMAPINFOHEADER, 40B)
        fourcc("strf")
        u32(STRF_BODY)
        u32(STRF_BODY)                  // biSize
        u32(width)                      // biWidth
        u32(height)                     // biHeight
        u16(1)                          // biPlanes
        u16(24)                         // biBitCount
        fourcc("cvid")                  // biCompression
        u32(width * height * 3)         // biSizeImage
        u32(0)                          // biXPelsPerMeter
        u32(0)                          // biYPelsPerMeter
        u32(0)                          // biClrUsed
        u32(0)                          // biClrImportant

        // ── LIST movi ──
        fourcc("LIST")
        u32(moviPayload)
        val moviBeacon = p
        fourcc("movi")

        val frameOffsets = IntArray(n)
        for (i in 0 until n) {
            frameOffsets[i] = p - moviBeacon
            fourcc("00dc")
            u32(frames[i].size)
            System.arraycopy(frames[i], 0, out, p, frames[i].size)
            p += frames[i].size
            if (pads[i] != 0) out[p++] = 0
        }

        // ── idx1 ──
        fourcc("idx1")
        u32(idx1Payload)
        for (i in 0 until n) {
            val isKey = (frames[i][0].toInt() and 0x01) == 0
            fourcc("00dc")
            u32(if (isKey) 0x10 else 0)
            u32(frameOffsets[i])
            u32(frames[i].size)
        }

        return out
    }
}
