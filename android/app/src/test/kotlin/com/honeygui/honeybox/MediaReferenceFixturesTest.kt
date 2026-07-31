package com.honeygui.honeybox

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

class MediaReferenceFixturesTest {
    @Test
    fun videoConverterHasNoUnqualifiedLegacyCinepakOrCvidReferences() {
        val source = String(
            Files.readAllBytes(
                repositoryRoot().resolve(
                    "android/app/src/main/kotlin/com/honeygui/honeybox/VideoConverter.kt",
                ),
            ),
            Charsets.UTF_8,
        )
        val legacyReference = Regex(
            "(?<!NativeMediaCodec\\.)\\b(CinepakEncoder|CinepakDecoder|CvidAviMuxer)\\b",
        ).find(source)
        if (legacyReference != null) {
            fail("Legacy Cinepak/CVID reference remains: ${legacyReference.value}")
        }
    }

    @Test
    fun committedReferenceFixturesMatchKotlinBehavior() {
        val expected = expectedFixtures()
        val fixtureDirectory = fixtureDirectory()
        if (System.getProperty("ebadge.regenerateFixtures", "false").toBoolean()) {
            Files.createDirectories(fixtureDirectory)
            expected.forEach { (name, bytes) -> Files.write(fixtureDirectory.resolve(name), bytes) }
        }

        expected.forEach { (name, bytes) ->
            val fixture = fixtureDirectory.resolve(name)
            assertTrue("Missing committed fixture: $name", Files.isRegularFile(fixture))
            assertArrayEquals("Fixture differs from Kotlin reference: $name", bytes, Files.readAllBytes(fixture))
        }
    }

    @Test
    fun msv1SkipThresholdIncludesOneRgb555ChannelStep() {
        val previous = ByteArray(4 * 4 * 4).also { rgba ->
            for (pixel in 0 until 16) rgba[pixel * 4 + 3] = 0xff.toByte()
        }
        val oneRgb555Step = previous.clone().also { it[0] = 8 }
        val skipFrame = byteArrayOf(1, 0x84.toByte(), 0, 0)

        assertArrayEquals(skipFrame, SoftwareCodec.encodeMsv1(oneRgb555Step, 4, 4, previous, 1))
        assertFalse(SoftwareCodec.encodeMsv1(oneRgb555Step, 4, 4, previous, 0).contentEquals(skipFrame))
    }

    private fun fixtureDirectory(): Path {
        return repositoryRoot().resolve("media_core/tests/fixtures")
    }

    private fun repositoryRoot(): Path {
        val repositoryRoot = System.getProperty("ebadge.repositoryRoot")
        require(!repositoryRoot.isNullOrBlank()) { "ebadge.repositoryRoot must be set for fixture tests" }
        return Paths.get(repositoryRoot)
    }

    private fun expectedFixtures(): Map<String, ByteArray> {
        val a = rgbaA()
        val b = rgbaB()

        val msv1Key = SoftwareCodec.encodeMsv1(a, 8, 8, null, 0)
        val msv1AllSkip = SoftwareCodec.encodeMsv1(a, 8, 8, a, 0)
        val msv1Inter = SoftwareCodec.encodeMsv1(b, 8, 8, a, 0)
        val msv1Pixels = IntArray(64)
        SoftwareCodec.decodeMsv1(msv1Key, 8, 8, msv1Pixels)
        val msv1KeyArgb = msv1Pixels.toLittleEndianArgb()
        SoftwareCodec.decodeMsv1(msv1AllSkip, 8, 8, msv1Pixels)
        val msv1AllSkipArgb = msv1Pixels.toLittleEndianArgb()
        SoftwareCodec.decodeMsv1(msv1Inter, 8, 8, msv1Pixels)
        val msv1InterArgb = msv1Pixels.toLittleEndianArgb()

        val cinepakEncoder = CinepakEncoder.Encoder(8, 8, CinepakEncoder.Options())
        val cinepakKey = cinepakEncoder.encode(a)
        val cinepakAllSkip = cinepakEncoder.encode(a)
        val cinepakInter = cinepakEncoder.encode(b)
        val cinepakDecoder = CinepakDecoder.Decoder(8, 8)
        val cinepakKeyArgb = cinepakDecoder.decodeFrame(cinepakKey).toLittleEndianArgb()
        val cinepakAllSkipArgb = cinepakDecoder.decodeFrame(cinepakAllSkip).toLittleEndianArgb()
        val cinepakInterArgb = cinepakDecoder.decodeFrame(cinepakInter).toLittleEndianArgb()

        return linkedMapOf(
            "input_8x8_a.rgba" to a,
            "input_8x8_b.rgba" to b,
            "msv1_key.bin" to msv1Key,
            "msv1_all_skip.bin" to msv1AllSkip,
            "msv1_inter.bin" to msv1Inter,
            "msv1_key.argb" to msv1KeyArgb,
            "msv1_all_skip.argb" to msv1AllSkipArgb,
            "msv1_inter.argb" to msv1InterArgb,
            "msvc_sample.avi" to SoftwareCodec.buildAvi(
                listOf(msv1Key, msv1AllSkip, msv1Inter), 8, 8, 10, "MSVC", 16,
                booleanArrayOf(true, false, false),
            ),
            "cinepak_key.bin" to cinepakKey,
            "cinepak_all_skip.bin" to cinepakAllSkip,
            "cinepak_inter.bin" to cinepakInter,
            "cinepak_key.argb" to cinepakKeyArgb,
            "cinepak_all_skip.argb" to cinepakAllSkipArgb,
            "cinepak_inter.argb" to cinepakInterArgb,
            "cvid_sample.avi" to CvidAviMuxer.buildAvi(
                listOf(cinepakKey, cinepakAllSkip, cinepakInter), 8, 8, 10,
            ),
        )
    }

    private fun IntArray.toLittleEndianArgb(): ByteArray = ByteArray(size * 4).also { out ->
        forEachIndexed { index, argb ->
            val p = index * 4
            out[p] = argb.toByte()
            out[p + 1] = (argb ushr 8).toByte()
            out[p + 2] = (argb ushr 16).toByte()
            out[p + 3] = (argb ushr 24).toByte()
        }
    }

    private fun rgbaA(): ByteArray = ByteArray(8 * 8 * 4).also { out ->
        for (y in 0 until 8) for (x in 0 until 8) {
            val p = (y * 8 + x) * 4
            out[p] = (x * 31).toByte()
            out[p + 1] = (y * 29).toByte()
            out[p + 2] = ((x * 17 + y * 13) and 0xff).toByte()
            out[p + 3] = 0xff.toByte()
        }
    }

    private fun rgbaB(): ByteArray = rgbaA().also { out ->
        for (y in 0 until 4) for (x in 0 until 4) {
            val p = (y * 8 + x) * 4
            out[p] = 0xf0.toByte()
            out[p + 1] = 0x30
            out[p + 2] = 0x80.toByte()
        }
    }
}
