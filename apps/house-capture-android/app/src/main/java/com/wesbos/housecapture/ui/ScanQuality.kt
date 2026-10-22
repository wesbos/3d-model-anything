package com.wesbos.housecapture.ui

import com.wesbos.housecapture.capture.RoomReport
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** The room page's verdict on a scan. Pure, so it is unit-tested. English only. */
object ScanQuality {
    enum class Level(val label: String) { GOOD("Good scan"), USABLE("Usable, with gaps"), POOR("Poor scan") }

    class Verdict(val level: Level, val warnings: List<String>)

    fun assess(report: RoomReport): Verdict {
        val warnings = ArrayList<String>()
        var poor = false
        val s = report.summary
        val written = report.depthStats["written"] ?: s.depthFrames
        when {
            report.depthMode == "DISABLED" -> {
                poor = true
                warnings += "No depth on this phone: walls are only an estimate from ARCore planes"
            }
            s.depthFrames == 0 -> {
                poor = true
                val why = report.depthStats.filterKeys { it != "written" && it != "stale" && !it.startsWith("pose:") }
                    .maxByOrNull { it.value }?.key
                warnings += "No depth: walls are only an estimate" + (why?.let { " (most depth attempts: $it)" } ?: "")
            }
            s.depthFrames < 30 -> warnings += "Only ${s.depthFrames} depth frames: the offline walls may be incomplete"
        }
        if (written > 0 && (report.depthStats["pose:nearest"] ?: 0) > written / 2) {
            warnings += "Most depth poses are approximate (nearest frame, ≤ 50 ms)"
        }
        when {
            s.photos < 5 -> { poor = true; warnings += "Only ${s.photos} photos" }
            s.photos < 15 -> warnings += "Only ${s.photos} photos: textures will have gaps"
        }
        s.coverage?.let { if (it < 0.5f) warnings += "Photo detail ${(it * 100).toInt()}%: parts of the room were never photographed up close" }
        val seconds = report.seconds
        val lost = report.trackingLostSeconds
        if (lost != null && seconds != null && seconds > 0 && lost / seconds > 0.1) {
            warnings += "Tracking was lost for ${lost.toInt()} s of ${seconds.toInt()} s: walls may be doubled"
        }
        if (report.walls.size < 3) warnings += "Only ${report.walls.size} walls found"
        if (report.walls.isNotEmpty() && report.wallConfidence.all { it == "low" }) {
            warnings += "All walls are low confidence (short planes or a box around your path)"
        }
        if (!report.finished) warnings += "Unfinished scan: sharing adds the room entry first"
        val level = when {
            poor -> Level.POOR
            warnings.isNotEmpty() -> Level.USABLE
            else -> Level.GOOD
        }
        return Verdict(level, warnings)
    }

    /**
     * Width × depth (m) of the walls' extent, measured along the longest wall and across it, so a
     * room that is rotated in ARCore's world still measures its own size. Null without walls.
     */
    fun roomSize(walls: List<FloatArray>): Pair<Float, Float>? {
        val longest = walls.maxByOrNull { hypot(it[2] - it[0], it[3] - it[1]) } ?: return null
        val len = hypot(longest[2] - longest[0], longest[3] - longest[1])
        if (len <= 0f) return null
        val ux = (longest[2] - longest[0]) / len
        val uz = (longest[3] - longest[1]) / len
        var minU = Float.MAX_VALUE; var maxU = -Float.MAX_VALUE
        var minV = Float.MAX_VALUE; var maxV = -Float.MAX_VALUE
        for (w in walls) {
            for (k in 0..1) {
                val x = w[k * 2]; val z = w[k * 2 + 1]
                val u = x * ux + z * uz
                val v = -x * uz + z * ux
                minU = min(minU, u); maxU = max(maxU, u)
                minV = min(minV, v); maxV = max(maxV, v)
            }
        }
        return Pair(maxU - minU, maxV - minV)
    }

    fun length(wall: FloatArray): Float = hypot(wall[2] - wall[0], wall[3] - wall[1])
}
