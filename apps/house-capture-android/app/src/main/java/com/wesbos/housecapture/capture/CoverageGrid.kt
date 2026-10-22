package com.wesbos.housecapture.capture

import com.wesbos.housecapture.bundle.Matrices
import kotlin.math.floor
import kotlin.math.sqrt

/**
 * 10 cm voxels the depth has seen, and the subset a photo covers well: in frame, 0.3–4.5 m away
 * and within the central 60° of the view (the app's and bundle_plan.py's rule, without occlusion).
 * Thread-safe. The capture controller mutates and queries it on the writer thread; the counts are
 * plain volatile reads, so the GL thread never waits for a scan of the grid.
 */
class CoverageGrid(private val cell: Float = 0.1f) {
    private val seen = HashSet<Long>()
    private val photographed = HashSet<Long>()
    @Volatile private var seenSize = 0
    @Volatile private var photographedSize = 0

    /** Pinhole view of one photo (pixels of the image the intrinsics belong to). */
    class View(
        val transform: FloatArray,
        val fx: Float, val fy: Float, val cx: Float, val cy: Float,
        val width: Int, val height: Int,
    )

    @Synchronized
    fun addSeen(x: Float, y: Float, z: Float) {
        seen.add(key(x, y, z))
        seenSize = seen.size
    }

    /**
     * Back-projects every [step]-th pixel of a raw depth frame with confidence ≥ medium and depth
     * ≤ [maxMeters]. Depth pixels follow the camera's image axes; the pose is OpenGL-style (−Z forward).
     */
    fun addDepth(copy: DepthCopy, view: View, step: Int = 4, maxMeters: Float = 4f) {
        val points = ArrayList<Long>()
        for (v in 0 until copy.height step step) {
            for (u in 0 until copy.width step step) {
                val i = v * copy.width + u
                if ((copy.confidence[i].toInt() and 0xFF) < 64) continue
                val d = (copy.millimeters[i].toInt() and 0xFFFF) / 1000f
                if (d <= 0f || d > maxMeters) continue
                val x = (u - view.cx) / view.fx * d
                val y = (v - view.cy) / view.fy * d
                val p = Matrices.transformPoint(view.transform, x, -y, -d)
                points.add(key(p[0], p[1], p[2]))
            }
        }
        synchronized(this) {
            seen.addAll(points)
            seenSize = seen.size
        }
    }

    val seenCount: Int get() = seenSize

    /** photographed fraction of seen cells, or null before anything was seen */
    val coverage: Float?
        get() {
            val total = seenSize
            return if (total == 0) null else photographedSize.toFloat() / total
        }

    /** Seen cells this photo would newly cover. */
    @Synchronized
    fun gain(view: View): Int = seen.count { it !in photographed && covers(view, it) }

    val unphotographed: Int get() = seenSize - photographedSize

    @Synchronized
    fun markPhotographed(view: View) {
        seen.filterTo(photographed) { it !in photographed && covers(view, it) }
        photographedSize = photographed.size
    }

    /**
     * Top-down picture: x0, z0, x1, z1, … centers of columns with seen / photographed cells,
     * thinned by stride to at most [cap] points each.
     */
    @Synchronized
    fun topDown(cap: Int = 20_000): Pair<FloatArray, FloatArray> = Pair(columns(seen, cap), columns(photographed, cap))

    private fun columns(cells: Set<Long>, cap: Int): FloatArray {
        val xz = LinkedHashSet<Long>()
        for (k in cells) xz.add((ix(k).toLong() shl 32) or (iz(k).toLong() and 0xFFFFFFFFL))
        val stride = maxOf(1, (xz.size + cap - 1) / cap)
        val out = FloatArray((xz.size + stride - 1) / stride * 2)
        var i = 0
        for ((n, c) in xz.withIndex()) {
            if (n % stride != 0) continue
            out[i++] = ((c shr 32).toInt() + 0.5f) * cell
            out[i++] = (c.toInt() + 0.5f) * cell
        }
        return out
    }

    private fun covers(view: View, k: Long): Boolean {
        val p = Matrices.inverseTransformPoint(view.transform, (ix(k) + 0.5f) * cell, (iy(k) + 0.5f) * cell, (iz(k) + 0.5f) * cell)
        val d = -p[2]
        if (d < 0.3f || d > 4.5f) return false
        // central 60°: at most 30° off the optical axis
        if (d < COS_30 * sqrt(p[0] * p[0] + p[1] * p[1] + d * d)) return false
        val x = view.fx * (p[0] / d) + view.cx
        val y = view.fy * (-p[1] / d) + view.cy
        return x >= 0 && y >= 0 && x < view.width && y < view.height
    }

    private fun key(x: Float, y: Float, z: Float): Long {
        val i = floor(x / cell).toLong() + OFFSET
        val j = floor(y / cell).toLong() + OFFSET
        val k = floor(z / cell).toLong() + OFFSET
        return (i and MASK) or ((j and MASK) shl 21) or ((k and MASK) shl 42)
    }

    private fun ix(k: Long) = ((k and MASK) - OFFSET).toInt()
    private fun iy(k: Long) = (((k shr 21) and MASK) - OFFSET).toInt()
    private fun iz(k: Long) = (((k shr 42) and MASK) - OFFSET).toInt()

    private companion object {
        const val OFFSET = 1L shl 20
        const val MASK = (1L shl 21) - 1
        const val COS_30 = 0.8660254f
    }
}
