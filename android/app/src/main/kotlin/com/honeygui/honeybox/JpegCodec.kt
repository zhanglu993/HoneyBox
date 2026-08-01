package com.honeygui.honeybox

import android.graphics.Bitmap
import java.io.ByteArrayOutputStream

/** Android JPEG adapter. MSV1 and AVI are implemented by Honey Media Core. */
internal object JpegCodec {
    fun encode(rgba: ByteArray, width: Int, height: Int, quality: Int): ByteArray {
        val pixels = IntArray(width * height)
        for (index in pixels.indices) {
            val offset = index * 4
            val red = rgba[offset].toInt() and 0xff
            val green = rgba[offset + 1].toInt() and 0xff
            val blue = rgba[offset + 2].toInt() and 0xff
            pixels[index] =
                (0xff shl 24) or (red shl 16) or (green shl 8) or blue
        }

        val bitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
        return try {
            ByteArrayOutputStream().use { output ->
                bitmap.compress(
                    Bitmap.CompressFormat.JPEG,
                    quality.coerceIn(1, 100),
                    output,
                )
                output.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }
    }
}
