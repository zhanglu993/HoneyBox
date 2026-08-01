package com.honeygui.honeybox

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.IOException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeMediaParityTest {
    @Test
    fun cameraSoftwareMediaPreservesMsv1StateFlagsAndScopedAviProfiles() {
        val a = asset("input_8x8_a.rgba")
        val b = asset("input_8x8_b.rgba")
        val key = CameraSoftwareMedia.encodeMsv1(a, 8, 8, null, 0, false)
        val allSkip = CameraSoftwareMedia.encodeMsv1(a, 8, 8, a, 0, false)
        val inter = CameraSoftwareMedia.encodeMsv1(b, 8, 8, a, 0, false)
        val frames = listOf(key, allSkip, inter)

        assertArrayEquals(asset("msv1_key.bin"), key.bytes)
        assertArrayEquals(asset("msv1_all_skip.bin"), allSkip.bytes)
        assertArrayEquals(asset("msv1_inter.bin"), inter.bytes)
        assertEquals(
            NativeMediaCodec.FRAME_FLAG_KEY or NativeMediaCodec.FRAME_FLAG_KEY_KNOWN,
            key.frameFlags,
        )
        assertEquals(NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, allSkip.frameFlags)
        assertEquals(NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, inter.frameFlags)

        val pixels = IntArray(64)
        CameraSoftwareMedia.decodeMsv1(key.bytes, 8, 8, pixels)
        assertArrayEquals(argbAsset("msv1_key.argb"), pixels)
        CameraSoftwareMedia.decodeMsv1(allSkip.bytes, 8, 8, pixels)
        assertArrayEquals(argbAsset("msv1_all_skip.argb"), pixels)
        CameraSoftwareMedia.decodeMsv1(inter.bytes, 8, 8, pixels)
        assertArrayEquals(argbAsset("msv1_inter.argb"), pixels)

        val msvcAvi = CameraSoftwareMedia.finishAvi(frames, 8, 8, 10, "mvs1")
        assertArrayEquals(asset("msvc_sample.avi"), msvcAvi)

        val jpegA = CameraSoftwareMedia.jpegFrame(byteArrayOf(0xff.toByte(), 0xd8.toByte(), 1, 0xff.toByte(), 0xd9.toByte()))
        val jpegB = CameraSoftwareMedia.jpegFrame(byteArrayOf(0xff.toByte(), 0xd8.toByte(), 2, 0xff.toByte(), 0xd9.toByte()))
        val mjpgAvi = CameraSoftwareMedia.finishAvi(listOf(jpegA, jpegB), 8, 8, 5, "jpeg")
        NativeMediaCodec.AviReader(mjpgAvi).use { reader ->
            val info = reader.info()
            assertEquals(NativeMediaCodec.fourcc("MJPG"), info.handlerFourcc)
            assertEquals(NativeMediaCodec.fourcc("MJPG"), info.compressionFourcc)
            assertEquals(24, info.bitCount)
            assertEquals(2, info.frameCount)
            assertEquals(jpegA.frameFlags, reader.frameInfo(0).frameFlags)
            assertEquals(jpegB.frameFlags, reader.frameInfo(1).frameFlags)
            assertArrayEquals(jpegA.bytes, reader.copyFrame(0))
            assertArrayEquals(jpegB.bytes, reader.copyFrame(1))
        }
    }

    @Test
    fun productionCvidSessionMatchesFixtureFlagsAndSequentialDecode() {
        val a = asset("input_8x8_a.rgba")
        val b = asset("input_8x8_b.rgba")
        val encoded = ArrayList<NativeMediaCodec.EncodedFrame>(3)
        val avi = CvidAviSession(8, 8, 10, NativeMediaCodec.CinepakOptions()).use { session ->
            encoded += session.encodeAndAdd(a)
            encoded += session.encodeAndAdd(a)
            encoded += session.encodeAndAdd(b)
            session.finish()
        }

        assertEquals(
            NativeMediaCodec.FRAME_FLAG_KEY or NativeMediaCodec.FRAME_FLAG_KEY_KNOWN,
            encoded[0].frameFlags,
        )
        assertEquals(NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, encoded[1].frameFlags)
        assertEquals(NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, encoded[2].frameFlags)
        assertArrayEquals(asset("cvid_sample.avi"), avi)

        NativeMediaCodec.AviReader(avi).use { reader ->
            val info = reader.info()
            assertEquals(3, info.frameCount)
            NativeMediaCodec.CinepakDecoder(info.width, info.height).use { decoder ->
                val pixels = IntArray(info.width * info.height)
                for (index in 0 until info.frameCount) {
                    assertEquals(encoded[index].frameFlags, reader.frameInfo(index).frameFlags)
                    decoder.decode(reader.copyFrame(index), pixels)
                    assertArrayEquals(argbAsset(arrayOf("cinepak_key.argb", "cinepak_all_skip.argb", "cinepak_inter.argb")[index]), pixels)
                }
            }
        }
    }

    @Test
    fun abiAndMsv1EncodingMatchCommittedKotlinReference() {
        assertEquals(0x0001_0000, NativeMediaCodec.abiVersion())

        val a = asset("input_8x8_a.rgba")
        val b = asset("input_8x8_b.rgba")
        val key = NativeMediaCodec.encodeMsv1(a, 8, 8, null, 0, false)
        val allSkip = NativeMediaCodec.encodeMsv1(a, 8, 8, a, 0, false)
        val inter = NativeMediaCodec.encodeMsv1(b, 8, 8, a, 0, false)
        val forcedKey = NativeMediaCodec.encodeMsv1(a, 8, 8, a, 0, true)

        assertEquals(NativeMediaCodec.FRAME_FLAG_KEY or NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, key.frameFlags)
        assertEquals(NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, allSkip.frameFlags)
        assertEquals(NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, inter.frameFlags)
        assertEquals(
            NativeMediaCodec.FRAME_FLAG_KEY or NativeMediaCodec.FRAME_FLAG_KEY_KNOWN,
            forcedKey.frameFlags,
        )
        assertArrayEquals(asset("msv1_key.bin"), key.bytes)
        assertArrayEquals(asset("msv1_all_skip.bin"), allSkip.bytes)
        assertArrayEquals(asset("msv1_inter.bin"), inter.bytes)
        assertArrayEquals(asset("msv1_key.bin"), forcedKey.bytes)
    }

    @Test
    fun msv1DecodePreservesPersistentPixelsAndIsAtomicOnMalformedInput() {
        val persistent = IntArray(64)
        NativeMediaCodec.decodeMsv1(asset("msv1_key.bin"), 8, 8, persistent)
        assertArrayEquals(argbAsset("msv1_key.argb"), persistent)
        NativeMediaCodec.decodeMsv1(asset("msv1_all_skip.bin"), 8, 8, persistent)
        assertArrayEquals(argbAsset("msv1_all_skip.argb"), persistent)
        NativeMediaCodec.decodeMsv1(asset("msv1_inter.bin"), 8, 8, persistent)
        assertArrayEquals(argbAsset("msv1_inter.argb"), persistent)

        val before = persistent.clone()
        assertThrows(IOException::class.java) {
            NativeMediaCodec.decodeMsv1(byteArrayOf(0), 8, 8, persistent)
        }
        assertArrayEquals(before, persistent)
        assertThrows(IOException::class.java) {
            NativeMediaCodec.decodeMsv1(byteArrayOf(), 8, 8, persistent)
        }
        assertArrayEquals(before, persistent)
    }

    @Test
    fun cinepakEncoderMatchesFixturesAndResetRestoresFreshState() {
        val a = asset("input_8x8_a.rgba")
        val b = asset("input_8x8_b.rgba")
        NativeMediaCodec.CinepakEncoder(8, 8).use { encoder ->
            val key = encoder.encode(a)
            val allSkip = encoder.encode(a)
            val inter = encoder.encode(b)
            val forcedKey = encoder.encode(a, forceKey = true)
            assertEquals(NativeMediaCodec.FRAME_FLAG_KEY or NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, key.frameFlags)
            assertEquals(NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, allSkip.frameFlags)
            assertEquals(NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, inter.frameFlags)
            assertEquals(
                NativeMediaCodec.FRAME_FLAG_KEY or NativeMediaCodec.FRAME_FLAG_KEY_KNOWN,
                forcedKey.frameFlags,
            )
            assertArrayEquals(asset("cinepak_key.bin"), key.bytes)
            assertArrayEquals(asset("cinepak_all_skip.bin"), allSkip.bytes)
            assertArrayEquals(asset("cinepak_inter.bin"), inter.bytes)
            assertArrayEquals(asset("cinepak_key.bin"), forcedKey.bytes)
            assertNotSame(key.bytes, allSkip.bytes)

            encoder.reset()
            assertArrayEquals(asset("cinepak_key.bin"), encoder.encode(a).bytes)
        }
    }

    @Test
    fun cinepakDecoderIsSequentialAndResetRejectsInterFirst() {
        NativeMediaCodec.CinepakDecoder(8, 8).use { decoder ->
            val pixels = IntArray(64)
            decoder.decode(asset("cinepak_key.bin"), pixels)
            assertArrayEquals(argbAsset("cinepak_key.argb"), pixels)
            decoder.decode(asset("cinepak_all_skip.bin"), pixels)
            assertArrayEquals(argbAsset("cinepak_all_skip.argb"), pixels)
            decoder.decode(asset("cinepak_inter.bin"), pixels)
            assertArrayEquals(argbAsset("cinepak_inter.argb"), pixels)

            decoder.reset()
            assertThrows(IllegalStateException::class.java) {
                decoder.decode(asset("cinepak_inter.bin"), pixels)
            }
            decoder.decode(asset("cinepak_key.bin"), pixels)
            val beforeMalformed = pixels.clone()
            assertThrows(IOException::class.java) { decoder.decode(byteArrayOf(), pixels) }
            assertArrayEquals(beforeMalformed, pixels)
            val truncated = asset("cinepak_inter.bin").let { it.copyOf(it.size - 1) }
            assertThrows(IOException::class.java) { decoder.decode(truncated, pixels) }
            assertArrayEquals(beforeMalformed, pixels)
            assertThrows(UnsupportedOperationException::class.java) {
                decoder.decode(unsupportedCinepakFrame(), pixels)
            }
            assertArrayEquals(beforeMalformed, pixels)
            decoder.decode(asset("cinepak_inter.bin"), pixels)
            assertArrayEquals(argbAsset("cinepak_inter.argb"), pixels)
        }
    }

    @Test
    fun incrementalMuxersMatchBothCommittedAviProfiles() {
        val a = asset("input_8x8_a.rgba")
        val b = asset("input_8x8_b.rgba")
        val cvidFrames = NativeMediaCodec.CinepakEncoder(8, 8).use { encoder ->
            listOf(encoder.encode(a), encoder.encode(a), encoder.encode(b))
        }
        NativeMediaCodec.AviMuxer.cvid(8, 8, 10).use { muxer ->
            cvidFrames.forEach { muxer.addFrame(it.bytes, it.frameFlags) }
            assertArrayEquals(asset("cvid_sample.avi"), muxer.finish())
            assertThrows(IllegalStateException::class.java) { muxer.finish() }
            assertThrows(IllegalStateException::class.java) {
                muxer.addFrame(cvidFrames[0].bytes, cvidFrames[0].frameFlags)
            }
        }

        val msv1Frames = listOf(
            NativeMediaCodec.encodeMsv1(a, 8, 8, null, 0, false),
            NativeMediaCodec.encodeMsv1(a, 8, 8, a, 0, false),
            NativeMediaCodec.encodeMsv1(b, 8, 8, a, 0, false),
        )
        NativeMediaCodec.AviMuxer.msvc(8, 8, 10).use { muxer ->
            msv1Frames.forEach { muxer.addFrame(it.bytes, it.frameFlags) }
            assertArrayEquals(asset("msvc_sample.avi"), muxer.finish())
        }
    }

    @Test
    fun aviReaderReturnsOwnedCopiesAndNormalizedMetadata() {
        val source = asset("cvid_sample.avi")
        NativeMediaCodec.AviReader(source).use { reader ->
            source.fill(0)
            val info = reader.info()
            assertEquals(8, info.width)
            assertEquals(8, info.height)
            assertEquals(100_000, info.usecPerFrame)
            assertEquals(10, info.frameRateNum)
            assertEquals(1, info.frameRateDen)
            assertEquals(NativeMediaCodec.fourcc("cvid"), info.handlerFourcc)
            assertEquals(NativeMediaCodec.fourcc("cvid"), info.compressionFourcc)
            assertEquals(24, info.bitCount)
            assertEquals(3, info.frameCount)

            val first = reader.frameInfo(0)
            assertEquals(0x10, first.aviIndexFlags)
            assertEquals(NativeMediaCodec.fourcc("00dc"), first.chunkFourcc)
            assertEquals(NativeMediaCodec.FRAME_FLAG_KEY or NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, first.frameFlags)
            assertEquals(NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, reader.frameInfo(1).frameFlags)
            assertEquals(NativeMediaCodec.FRAME_FLAG_KEY_KNOWN, reader.frameInfo(2).frameFlags)
            val firstCopy = reader.copyFrame(0)
            assertArrayEquals(asset("cinepak_key.bin"), firstCopy)
            firstCopy[0] = (firstCopy[0].toInt() xor 0xff).toByte()
            val secondCopy = reader.copyFrame(0)
            assertNotSame(firstCopy, secondCopy)
            assertArrayEquals(asset("cinepak_key.bin"), secondCopy)
            assertArrayEquals(asset("cinepak_all_skip.bin"), reader.copyFrame(1))
            assertArrayEquals(asset("cinepak_inter.bin"), reader.copyFrame(2))
            assertThrows(IllegalArgumentException::class.java) { reader.frameInfo(3) }
            assertThrows(IllegalArgumentException::class.java) { reader.copyFrame(3) }
        }

        NativeMediaCodec.AviReader(asset("msvc_sample.avi")).use { reader ->
            assertEquals(NativeMediaCodec.fourcc("MSVC"), reader.info().handlerFourcc)
            assertEquals(16, reader.info().bitCount)
            assertArrayEquals(asset("msv1_inter.bin"), reader.copyFrame(2))
        }
    }

    @Test
    fun validationAndStatusMappingUseStableJavaExceptions() {
        val a = asset("input_8x8_a.rgba")
        assertThrows(IllegalArgumentException::class.java) {
            NativeMediaCodec.encodeMsv1(a, 6, 8, null, 0, false)
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativeMediaCodec.encodeMsv1(a.copyOf(8), 8, 8, null, 0, false)
        }
        assertThrows(IllegalArgumentException::class.java) {
            NativeMediaCodec.decodeMsv1(asset("msv1_key.bin"), 8, 8, IntArray(1))
        }
        NativeMediaCodec.CinepakEncoder(8, 8).use { encoder ->
            assertThrows(IllegalArgumentException::class.java) { encoder.encode(a.copyOf(8)) }
        }
        NativeMediaCodec.CinepakDecoder(8, 8).use { decoder ->
            assertThrows(IllegalArgumentException::class.java) {
                decoder.decode(asset("cinepak_key.bin"), IntArray(1))
            }
        }
        assertThrows(IOException::class.java) {
            NativeMediaCodec.AviReader(byteArrayOf(1, 2, 3))
        }
        assertThrows(IOException::class.java) {
            NativeMediaCodec.AviReader(byteArrayOf())
        }
        assertThrows(UnsupportedOperationException::class.java) {
            NativeMediaCodec.AviMuxer(
                8,
                8,
                10,
                1,
                NativeMediaCodec.fourcc("NOPE"),
                NativeMediaCodec.fourcc("NOPE"),
                24,
            )
        }
        NativeMediaCodec.AviMuxer.cvid(8, 8, 10).use { muxer ->
            assertThrows(UnsupportedOperationException::class.java) {
                muxer.addFrame(asset("cinepak_key.bin"), 0x4000_0000)
            }
        }
    }

    @Test
    fun closeIsIdempotentAndEveryClosedHandleRejectsOperations() {
        val a = asset("input_8x8_a.rgba")
        val encoder = NativeMediaCodec.CinepakEncoder(8, 8)
        encoder.close()
        encoder.close()
        assertThrows(IllegalStateException::class.java) { encoder.encode(a) }
        assertThrows(IllegalStateException::class.java) { encoder.reset() }

        val decoder = NativeMediaCodec.CinepakDecoder(8, 8)
        decoder.close()
        decoder.close()
        assertThrows(IllegalStateException::class.java) {
            decoder.decode(asset("cinepak_key.bin"), IntArray(64))
        }
        assertThrows(IllegalStateException::class.java) { decoder.reset() }

        val muxer = NativeMediaCodec.AviMuxer.cvid(8, 8, 10)
        muxer.close()
        muxer.close()
        assertThrows(IllegalStateException::class.java) {
            muxer.addFrame(asset("cinepak_key.bin"), NativeMediaCodec.FRAME_FLAG_KEY or NativeMediaCodec.FRAME_FLAG_KEY_KNOWN)
        }
        assertThrows(IllegalStateException::class.java) { muxer.finish() }

        val reader = NativeMediaCodec.AviReader(asset("cvid_sample.avi"))
        reader.close()
        reader.close()
        assertThrows(IllegalStateException::class.java) { reader.info() }
        assertThrows(IllegalStateException::class.java) { reader.frameInfo(0) }
        assertThrows(IllegalStateException::class.java) { reader.copyFrame(0) }
    }

    private fun asset(name: String): ByteArray =
        InstrumentationRegistry.getInstrumentation().context.assets.open(name).use { it.readBytes() }

    private fun argbAsset(name: String): IntArray {
        val bytes = asset(name)
        require(bytes.size % 4 == 0)
        return IntArray(bytes.size / 4) { index ->
            val offset = index * 4
            (bytes[offset].toInt() and 0xff) or
                ((bytes[offset + 1].toInt() and 0xff) shl 8) or
                ((bytes[offset + 2].toInt() and 0xff) shl 16) or
                ((bytes[offset + 3].toInt() and 0xff) shl 24)
        }
    }

    private fun unsupportedCinepakFrame(): ByteArray = asset("cinepak_key.bin").also { bytes ->
        require(bytes.size > 22 && bytes[22] == 0x22.toByte())
        bytes[22] = 0x23
    }
}
