package com.wesbos.housecapture.capture

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import androidx.exifinterface.media.ExifInterface
import java.io.File

/**
 * The three planes of ARCore's CPU camera image (YUV_420_888, unrotated sensor orientation), bulk
 * copied on the GL thread so the Image can be closed right away. Conversion to NV21 and JPEG
 * encoding happen later on the writer thread.
 */
class YuvPlanes(
    val width: Int,
    val height: Int,
    val y: ByteArray, val yRowStride: Int, val yPixelStride: Int,
    val u: ByteArray, val uRowStride: Int, val uPixelStride: Int,
    val v: ByteArray, val vRowStride: Int, val vPixelStride: Int,
) {
    /**
     * NV21, nearest-neighbour downscaled to at most [maxWidth] pixels wide (sizes kept even).
     * Handles row padding and chroma pixel strides of 1 (planar) and 2 (semi-planar).
     */
    fun toNv21(maxWidth: Int = Int.MAX_VALUE): Nv21Image {
        val sw = width and 1.inv()
        val sh = height and 1.inv()
        val w = minOf(sw, maxWidth and 1.inv())
        val h = if (w == sw) sh else (Math.round(sh.toFloat() * w / sw) and 1.inv()).coerceAtLeast(2)
        val out = ByteArray(w * h * 3 / 2)
        if (w == sw && yPixelStride == 1) {
            for (row in 0 until h) System.arraycopy(y, row * yRowStride, out, row * w, w)
        } else {
            for (row in 0 until h) {
                val src = (row * sh / h) * yRowStride
                for (col in 0 until w) out[row * w + col] = y[src + (col * sw / w) * yPixelStride]
            }
        }
        var o = w * h
        for (row in 0 until h / 2) {
            val sy = row * sh / h
            val uRow = sy * uRowStride
            val vRow = sy * vRowStride
            for (col in 0 until w / 2) {
                val sx = col * sw / w
                out[o++] = v[vRow + sx * vPixelStride]
                out[o++] = u[uRow + sx * uPixelStride]
            }
        }
        return Nv21Image(w, h, out)
    }

    companion object {
        /** One bulk copy per plane (a few MB at 1080p): the GL thread never loops over pixels. */
        fun copy(image: Image): YuvPlanes {
            val (yPlane, uPlane, vPlane) = image.planes
            return YuvPlanes(
                image.width, image.height,
                bytes(yPlane), yPlane.rowStride, yPlane.pixelStride,
                bytes(uPlane), uPlane.rowStride, uPlane.pixelStride,
                bytes(vPlane), vPlane.rowStride, vPlane.pixelStride,
            )
        }

        private fun bytes(plane: Image.Plane): ByteArray {
            val buffer = plane.buffer.duplicate()
            buffer.rewind()
            return ByteArray(buffer.remaining()).also { buffer.get(it) }
        }
    }
}

/** An NV21 image (full-resolution Y, then interleaved V/U at half resolution). */
class Nv21Image(val width: Int, val height: Int, val data: ByteArray) {
    fun writeJpeg(file: File, quality: Int = 85) {
        file.outputStream().buffered().use {
            YuvImage(data, ImageFormat.NV21, width, height, null).compressToJpeg(Rect(0, 0, width, height), quality, it)
        }
    }
}

/** photos/NNNN.jpg: sensor-orientation pixels untouched, EXIF orientation 6 so viewers show them upright. */
object PhotoWriter {
    fun write(image: Nv21Image, file: File) {
        image.writeJpeg(file, quality = 85)
        val exif = ExifInterface(file.absolutePath)
        exif.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
        exif.saveAttributes()
    }
}
