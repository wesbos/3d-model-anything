package com.wesbos.housecapture.bundle

import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import java.util.UUID
import kotlin.math.sqrt

/** Small helpers shared by the writers. Matrices are column-major float[16], like ARKit's and the bundle's. */
object Matrices {
    val IDENTITY: List<Float> = listOf(1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f)

    /** Rigid transform from a translation + unit quaternion (ARCore Pose tx..qw), column-major. */
    fun pose(tx: Float, ty: Float, tz: Float, qx: Float, qy: Float, qz: Float, qw: Float): FloatArray {
        val n = sqrt(qx * qx + qy * qy + qz * qz + qw * qw).takeIf { it > 0f } ?: 1f
        val x = qx / n; val y = qy / n; val z = qz / n; val w = qw / n
        return floatArrayOf(
            1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0f,
            2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0f,
            2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0f,
            tx, ty, tz, 1f,
        )
    }

    /** Column-major 3×3 camera matrix: fx, 0, 0, 0, fy, 0, cx, cy, 1. */
    fun intrinsics(fx: Float, fy: Float, cx: Float, cy: Float): List<Float> =
        listOf(fx, 0f, 0f, 0f, fy, 0f, cx, cy, 1f)

    /** Column [c] (0–3) of a column-major 4×4, as x, y, z. */
    fun column(m: FloatArray, c: Int): FloatArray = floatArrayOf(m[c * 4], m[c * 4 + 1], m[c * 4 + 2])

    /** m · (x, y, z, 1). */
    fun transformPoint(m: FloatArray, x: Float, y: Float, z: Float): FloatArray = floatArrayOf(
        m[0] * x + m[4] * y + m[8] * z + m[12],
        m[1] * x + m[5] * y + m[9] * z + m[13],
        m[2] * x + m[6] * y + m[10] * z + m[14],
    )

    /** inverse(m) · (x, y, z, 1) for a rigid m (rotation + translation). */
    fun inverseTransformPoint(m: FloatArray, x: Float, y: Float, z: Float): FloatArray {
        val dx = x - m[12]; val dy = y - m[13]; val dz = z - m[14]
        return floatArrayOf(
            m[0] * dx + m[1] * dy + m[2] * dz,
            m[4] * dx + m[5] * dy + m[6] * dz,
            m[8] * dx + m[9] * dy + m[10] * dz,
        )
    }

    /** RoomPlan-style identifier (Swift's UUID().uuidString is upper case). */
    fun newIdentifier(): String = UUID.randomUUID().toString().uppercase(Locale.ROOT)

    /** ISO-8601 without fractional seconds: Swift's `.iso8601` date decoder rejects fractions. */
    fun iso(instant: Instant = Instant.now()): String =
        DateTimeFormatter.ISO_INSTANT.format(instant.truncatedTo(ChronoUnit.SECONDS))
}
