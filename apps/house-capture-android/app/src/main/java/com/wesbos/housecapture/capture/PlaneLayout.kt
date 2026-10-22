package com.wesbos.housecapture.capture

import com.wesbos.housecapture.bundle.Matrices
import com.wesbos.housecapture.bundle.RoomPlanElement
import com.wesbos.housecapture.bundle.RoomPlanRoom
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

/**
 * A minimal, valid RoomPlan-shaped room from ARCore planes, so a fresh export already converts with
 * bundle_to_room.py / bundle_plan.py. Vertical planes become walls (confidence medium when ≥ 2 m long,
 * else low), the floor plane sets the floor height, and with fewer than two walls a box around the
 * camera path stands in (confidence low).
 * android_synthesize_room.py replaces this with a layout from the depth frames.
 */
object PlaneLayout {
    enum class Kind { FLOOR, CEILING, WALL }

    /**
     * Plain-data copy of an ARCore Plane: [pose] is its center pose (column-major; local +Y is the
     * normal), [polygon] the boundary as local x, z pairs.
     */
    class PlaneInput(
        val kind: Kind,
        val pose: FloatArray,
        val extentX: Float,
        val extentZ: Float,
        val polygon: FloatArray,
    )

    private const val MIN_WALL = 0.6f
    private const val FALLBACK_MARGIN = 0.8f
    private const val EYE_HEIGHT = 1.3f

    fun build(planes: List<PlaneInput>, cameraPath: List<FloatArray>, newId: () -> String = Matrices::newIdentifier): RoomPlanRoom {
        val pathX = cameraPath.map { it[0] }
        val pathZ = cameraPath.map { it[2] }
        val centroidX = pathX.average().toFloat().takeIf { it.isFinite() } ?: 0f
        val centroidZ = pathZ.average().toFloat().takeIf { it.isFinite() } ?: 0f

        val floorPlane = planes.filter { it.kind == Kind.FLOOR && polygonArea(it.polygon) >= 1f }.minByOrNull { it.pose[13] }
        val floorY = floorPlane?.pose?.get(13) ?: ((cameraPath.minOfOrNull { it[1] } ?: 0f) - EYE_HEIGHT)

        val spans = mergeSpans(planes.filter { it.kind == Kind.WALL }.mapNotNull { span(it, centroidX, centroidZ) })
        val tops = spans.map { it.top - floorY }.sorted()
        val p95 = tops.getOrNull(((tops.size - 1) * 0.95f).toInt()) ?: 0f
        val height = max(2.4f, p95).coerceIn(2.2f, 3.5f)

        val walls = ArrayList<RoomPlanElement>()
        val outline = ArrayList<FloatArray>()
        if (spans.size >= 2) {
            for (s in spans) {
                val ux = s.nz; val uz = -s.nx
                val mid = (s.lo + s.hi) / 2
                val cx = s.nx * s.offset + ux * mid
                val cz = s.nz * s.offset + uz * mid
                val length = s.hi - s.lo
                // never "high": one ARCore plane may be a cabinet face; the synthesizer earns "high" from depth
                walls.add(wall(newId(), cx, cz, s.nx, s.nz, length, floorY, height, if (length >= 2f) "medium" else "low"))
                outline.add(floatArrayOf(cx - ux * length / 2, cz - uz * length / 2))
                outline.add(floatArrayOf(cx + ux * length / 2, cz + uz * length / 2))
            }
        } else {
            val x0 = (pathX.minOrNull() ?: 0f) - FALLBACK_MARGIN
            val x1 = (pathX.maxOrNull() ?: 0f) + FALLBACK_MARGIN
            val z0 = (pathZ.minOrNull() ?: 0f) - FALLBACK_MARGIN
            val z1 = (pathZ.maxOrNull() ?: 0f) + FALLBACK_MARGIN
            val mx = (x0 + x1) / 2; val mz = (z0 + z1) / 2
            walls.add(wall(newId(), mx, z0, 0f, 1f, x1 - x0, floorY, height, "low"))
            walls.add(wall(newId(), x1, mz, -1f, 0f, z1 - z0, floorY, height, "low"))
            walls.add(wall(newId(), mx, z1, 0f, -1f, x1 - x0, floorY, height, "low"))
            walls.add(wall(newId(), x0, mz, 1f, 0f, z1 - z0, floorY, height, "low"))
            outline.addAll(listOf(floatArrayOf(x0, z0), floatArrayOf(x1, z0), floatArrayOf(x1, z1), floatArrayOf(x0, z1)))
        }

        // Floor outline: hull of the floor plane, the camera path and the wall ends, so every wall's
        // inside (bundle_to_room's point-in-polygon test) lies inside it.
        if (floorPlane != null) {
            val fp = footprint(floorPlane)
            for (i in fp.indices step 2) outline.add(floatArrayOf(fp[i], fp[i + 1]))
        }
        for (p in cameraPath) outline.add(floatArrayOf(p[0], p[2]))
        val hull = counterClockwiseSeenFromAbove(convexHull(outline))

        val floors = listOf(
            RoomPlanElement(
                category = RoomPlanElement.tag("floor"),
                confidence = RoomPlanElement.tag(if (floorPlane != null) "medium" else "low"),
                dimensions = listOf(
                    (hull.maxOfOrNull { it[0] } ?: 0f) - (hull.minOfOrNull { it[0] } ?: 0f),
                    (hull.maxOfOrNull { it[1] } ?: 0f) - (hull.minOfOrNull { it[1] } ?: 0f),
                    0f,
                ),
                identifier = newId(),
                polygonCorners = if (hull.size >= 3) hull.map { listOf(it[0], 0f, it[1]) } else emptyList(),
                transform = Matrices.IDENTITY.toMutableList().also { it[13] = floorY },
            ),
        )
        return RoomPlanRoom(walls = walls, floors = floors)
    }

    /** World x, z outline for the plan view: a 2-point segment for walls, the polygon otherwise. */
    fun footprint(plane: PlaneInput): FloatArray {
        val m = plane.pose
        if (plane.kind == Kind.WALL) {
            val axis = alongAxis(plane)
            val h = axis.along / 2
            return floatArrayOf(m[12] - axis.x * h, m[14] - axis.z * h, m[12] + axis.x * h, m[14] + axis.z * h)
        }
        val out = FloatArray(plane.polygon.size)
        for (i in 0 until plane.polygon.size / 2) {
            val p = Matrices.transformPoint(m, plane.polygon[i * 2], 0f, plane.polygon[i * 2 + 1])
            out[i * 2] = p[0]
            out[i * 2 + 1] = p[2]
        }
        return out
    }

    // --- walls ------------------------------------------------------------------------------

    /** One vertical plane as a line (inward normal n, offset n·p) and an interval along u = (n_z, −n_x). */
    private class Span(val nx: Float, val nz: Float, var offset: Float, var lo: Float, var hi: Float, var top: Float)

    private fun span(plane: PlaneInput, towardX: Float, towardZ: Float): Span? {
        val m = plane.pose
        val axis = alongAxis(plane)
        val along = axis.along
        if (along < MIN_WALL) return null
        var nx = m[4]; var nz = m[6] // local +Y = plane normal
        val len = hypot(nx, nz)
        if (len < 1e-3f) {
            nx = axis.z; nz = -axis.x
        } else {
            nx /= len; nz /= len
        }
        if (nx * (towardX - m[12]) + nz * (towardZ - m[14]) < 0) {
            nx = -nx; nz = -nz
        }
        val ux = nz; val uz = -nx
        val mid = ux * m[12] + uz * m[14]
        // the plane's along-axis may differ in sign from u; the span is symmetric either way
        return Span(nx, nz, nx * m[12] + nz * m[14], mid - along / 2, mid + along / 2, m[13] + axis.across / 2)
    }

    /** A plane's horizontal in-plane direction (x, z), its extent, and the extent across it. */
    private class Axis(val x: Float, val z: Float, val along: Float, val across: Float)

    /** Local X or Z, whichever is more horizontal, is "along" for a vertical plane. */
    private fun alongAxis(plane: PlaneInput): Axis {
        val m = plane.pose
        val useX = abs(m[1]) <= abs(m[9])
        val ax = if (useX) m[0] else m[8]
        val az = if (useX) m[2] else m[10]
        val len = hypot(ax, az).takeIf { it > 1e-6f } ?: 1f
        return if (useX) Axis(ax / len, az / len, plane.extentX, plane.extentZ)
        else Axis(ax / len, az / len, plane.extentZ, plane.extentX)
    }

    /** Merges coplanar spans (normals within ~11°, offsets within 10 cm, overlapping along the wall). */
    private fun mergeSpans(spans: List<Span>): List<Span> {
        val merged = ArrayList<Span>()
        for (s in spans.sortedByDescending { it.hi - it.lo }) {
            val target = merged.firstOrNull { m ->
                m.nx * s.nx + m.nz * s.nz > 0.98f &&
                    abs(m.offset - offsetAlong(m, s)) < 0.1f &&
                    projected(m, s).let { (lo, hi) -> lo <= m.hi && hi >= m.lo }
            }
            if (target == null) {
                merged.add(s)
                continue
            }
            val (lo, hi) = projected(target, s)
            val wt = target.hi - target.lo
            val ws = hi - lo
            target.offset = (target.offset * wt + offsetAlong(target, s) * ws) / (wt + ws)
            target.lo = minOf(target.lo, lo)
            target.hi = maxOf(target.hi, hi)
            target.top = maxOf(target.top, s.top)
        }
        return merged
    }

    /** Center (x, z) of a span: n·offset + u·mid. */
    private fun center(s: Span): Pair<Float, Float> {
        val mid = (s.lo + s.hi) / 2
        return Pair(s.nx * s.offset + s.nz * mid, s.nz * s.offset - s.nx * mid)
    }

    /** [s]'s center measured along [onto]'s normal. */
    private fun offsetAlong(onto: Span, s: Span): Float {
        val (cx, cz) = center(s)
        return onto.nx * cx + onto.nz * cz
    }

    /** [s]'s interval expressed along [onto]'s u axis. */
    private fun projected(onto: Span, s: Span): Pair<Float, Float> {
        val (cx, cz) = center(s)
        val c = onto.nz * cx - onto.nx * cz
        val h = (s.hi - s.lo) / 2
        return Pair(c - h, c + h)
    }

    private fun wall(
        id: String, cx: Float, cz: Float, nx: Float, nz: Float,
        length: Float, floorY: Float, height: Float, confidence: String,
    ): RoomPlanElement {
        // local x̂ = u along the wall, ŷ = up, ẑ = n into the room, with u × up = n
        val ux = nz; val uz = -nx
        return RoomPlanElement(
            category = RoomPlanElement.tag("wall"),
            confidence = RoomPlanElement.tag(confidence),
            dimensions = listOf(length, height, 0f),
            identifier = id,
            transform = listOf(ux, 0f, uz, 0f, 0f, 1f, 0f, 0f, nx, 0f, nz, 0f, cx, floorY + height / 2, cz, 1f),
        )
    }

    // --- polygons -------------------------------------------------------------------------------

    /** Shoelace area of x, z pairs. */
    fun polygonArea(xz: FloatArray): Float {
        var a = 0f
        val n = xz.size / 2
        for (i in 0 until n) {
            val j = (i + 1) % n
            a += xz[i * 2] * xz[j * 2 + 1] - xz[j * 2] * xz[i * 2 + 1]
        }
        return abs(a) / 2
    }

    /** Andrew's monotone chain over (x, z) points. */
    fun convexHull(points: List<FloatArray>): List<FloatArray> {
        val pts = points.distinctBy { Pair(it[0], it[1]) }.sortedWith(compareBy({ it[0] }, { it[1] }))
        if (pts.size < 3) return pts
        fun cross(o: FloatArray, a: FloatArray, b: FloatArray) = (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
        val lower = ArrayList<FloatArray>()
        for (p in pts) {
            while (lower.size >= 2 && cross(lower[lower.size - 2], lower[lower.size - 1], p) <= 0) lower.removeAt(lower.size - 1)
            lower.add(p)
        }
        val upper = ArrayList<FloatArray>()
        for (p in pts.asReversed()) {
            while (upper.size >= 2 && cross(upper[upper.size - 2], upper[upper.size - 1], p) <= 0) upper.removeAt(upper.size - 1)
            upper.add(p)
        }
        lower.removeAt(lower.size - 1)
        upper.removeAt(upper.size - 1)
        return lower + upper
    }

    /** Signed area in (x, −z), positive when counter-clockwise seen from above (bundle_to_room's test). */
    fun signedAreaSeenFromAbove(xz: List<FloatArray>): Float {
        var a = 0f
        for (i in xz.indices) {
            val p = xz[i]; val q = xz[(i + 1) % xz.size]
            a += p[0] * -q[1] - q[0] * -p[1]
        }
        return a / 2
    }

    private fun counterClockwiseSeenFromAbove(xz: List<FloatArray>): List<FloatArray> =
        if (signedAreaSeenFromAbove(xz) < 0) xz.asReversed() else xz
}
