package com.wesbos.housecapture.capture

import android.media.Image
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteOrder
import java.util.zip.Deflater

/** A copy of ARCore's raw depth (uint16 mm) and confidence (0–255) images, safe to keep after close(). */
class DepthCopy(val width: Int, val height: Int, val millimeters: ShortArray, val confidence: ByteArray) {
    companion object {
        /** Copies both single-plane images row by row, dropping row padding. Call on the GL thread. */
        fun of(depth: Image, confidence: Image): DepthCopy {
            val w = depth.width
            val h = depth.height
            val dPlane = depth.planes[0]
            val dBuf = dPlane.buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            val mm = ShortArray(w * h)
            for (y in 0 until h) {
                val row = y * dPlane.rowStride
                for (x in 0 until w) mm[y * w + x] = dBuf.getShort(row + x * dPlane.pixelStride)
            }
            val cPlane = confidence.planes[0]
            val cBuf = cPlane.buffer.duplicate()
            val conf = ByteArray(w * h)
            val cw = minOf(w, confidence.width)
            for (y in 0 until minOf(h, confidence.height)) {
                val row = y * cPlane.rowStride
                for (x in 0 until cw) conf[y * w + x] = cBuf.get(row + x * cPlane.pixelStride)
            }
            return DepthCopy(w, h, mm, conf)
        }
    }
}

/** depth/NNNNN.f16z + .conf, in the iOS app's format. */
object DepthWriter {
    fun write(copy: DepthCopy, f16z: File, conf: File) {
        f16z.writeBytes(encodeF16z(copy.millimeters))
        conf.writeBytes(quantizeConfidence(copy.confidence))
    }

    /** uint16 millimeters → Float16 meters, little-endian, row-major, raw DEFLATE (zlib wbits −15). 0 stays 0 (no estimate). */
    fun encodeF16z(millimeters: ShortArray): ByteArray {
        val raw = ByteArray(millimeters.size * 2)
        for (i in millimeters.indices) {
            val mm = millimeters[i].toInt() and 0xFFFF
            val half = floatToHalf(mm / 1000f).toInt()
            raw[i * 2] = half.toByte()
            raw[i * 2 + 1] = (half shr 8).toByte()
        }
        val deflater = Deflater(Deflater.BEST_SPEED, true)
        try {
            deflater.setInput(raw)
            deflater.finish()
            val out = ByteArrayOutputStream(raw.size / 2)
            val buffer = ByteArray(64 * 1024)
            while (!deflater.finished()) out.write(buffer, 0, deflater.deflate(buffer))
            return out.toByteArray()
        } finally {
            deflater.end()
        }
    }

    /** ARCore confidence 0–255 → the iOS app's 0 (low), 1 (medium), 2 (high). */
    fun quantizeConfidence(value: Int): Byte = when {
        value < 64 -> 0
        value < 192 -> 1
        else -> 2
    }.toByte()

    fun quantizeConfidence(raw: ByteArray): ByteArray =
        ByteArray(raw.size) { quantizeConfidence(raw[it].toInt() and 0xFF) }

    /** IEEE 754 binary16 bits for [value], round to nearest (android.util.Half without the Android dependency). */
    fun floatToHalf(value: Float): Short {
        val bits = value.toRawBits()
        val sign = (bits ushr 16) and 0x8000
        val abs = bits and 0x7FFFFFFF
        if (abs >= 0x7F800000) return (sign or 0x7C00 or (if (abs > 0x7F800000) 0x200 else 0)).toShort() // inf, NaN
        val rounded = abs + 0x1000
        if (rounded >= 0x47800000) return (sign or 0x7C00).toShort() // overflow → inf
        if (rounded >= 0x38800000) return (sign or ((rounded - 0x38000000) ushr 13)).toShort() // normal
        if (abs < 0x33000000) return sign.toShort() // too small → ±0
        val exponent = abs ushr 23 // subnormal
        val mantissa = (abs and 0x7FFFFF) or 0x800000
        return (sign or ((mantissa + (0x800000 ushr (exponent - 102))) ushr (126 - exponent))).toShort()
    }

    fun halfToFloat(half: Short): Float {
        val h = half.toInt() and 0xFFFF
        val sign = if ((h and 0x8000) != 0) -1f else 1f
        val exponent = (h ushr 10) and 0x1F
        val mantissa = h and 0x3FF
        return sign * when (exponent) {
            0 -> mantissa / 1024f * Math.scalb(1f, -14)
            31 -> if (mantissa == 0) Float.POSITIVE_INFINITY else Float.NaN
            else -> (1f + mantissa / 1024f) * Math.scalb(1f, exponent - 15)
        }
    }
}
