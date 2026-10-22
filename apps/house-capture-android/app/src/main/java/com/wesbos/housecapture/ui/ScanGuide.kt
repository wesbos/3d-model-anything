package com.wesbos.housecapture.ui

import com.wesbos.housecapture.capture.CaptureState
import com.wesbos.housecapture.capture.CoverageSnapshot
import com.wesbos.housecapture.capture.Phase
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * The scan screen's one-line "what to do next". Pure, so it is unit-tested. English only, like the
 * controller's tracking warnings.
 */
object ScanGuide {
    class Hint(val text: String, val urgent: Boolean)

    enum class Side(val turn: String) {
        AHEAD("Walk forward: the area ahead hasn't been seen"),
        RIGHT("Turn right: the area to your right hasn't been seen"),
        BEHIND("Turn around: the area behind you hasn't been seen"),
        LEFT("Turn left: the area to your left hasn't been seen"),
    }

    fun hint(state: CaptureState): Hint {
        if (state.phase == Phase.IDLE || state.phase == Phase.STARTING) {
            return Hint("Move the phone slowly from side to side", urgent = false)
        }
        state.trackingWarning?.let { return Hint(it, urgent = true) }
        if (state.depthStalled) return Hint("No depth yet: walk sideways slowly, 1–3 m from a wall", urgent = true)
        val snapshot = state.snapshot
        if (snapshot == null || snapshot.seen.size < MIN_SEEN * 2) {
            return Hint("Walk slowly sideways along a wall, 1–3 m away", urgent = false)
        }
        unseenSide(snapshot)?.let { return Hint(it.turn, urgent = false) }
        val coverage = state.coverage ?: 0f
        if (coverage < 0.6f) return Hint("Hold steady facing the grey areas so photos are taken", urgent = false)
        return Hint("Looks complete: walk back to where you started, then Finish room", urgent = false)
    }

    /**
     * The side (relative to where the phone points) with by far the fewest seen cells within 4 m,
     * or null when every side has been seen. Heading and angles are in the plan's x/z frame, where a
     * positive angle from the heading is to the user's right (see PlanCanvas).
     */
    fun unseenSide(snapshot: CoverageSnapshot, radius: Float = 4f): Side? {
        val counts = IntArray(4)
        val xz = snapshot.seen
        var i = 0
        while (i + 1 < xz.size) {
            val dx = xz[i] - snapshot.cameraX
            val dz = xz[i + 1] - snapshot.cameraZ
            i += 2
            val d = hypot(dx, dz)
            if (d < 0.3f || d > radius) continue
            counts[sideOf(atan2(dz, dx) - snapshot.headingRadians).ordinal]++
        }
        val most = counts.max()
        if (most < MIN_SEEN) return null
        // the emptiest side, preferring the cheaper move (ahead, then left/right, then behind) on ties
        val order = listOf(Side.AHEAD, Side.LEFT, Side.RIGHT, Side.BEHIND)
        val least = order.minBy { counts[it.ordinal] }
        return if (counts[least.ordinal] < 0.15f * most) least else null
    }

    /** Side for an angle relative to the heading (radians, positive = right). */
    fun sideOf(relative: Float): Side {
        var a = relative.toDouble()
        while (a > PI) a -= 2 * PI
        while (a <= -PI) a += 2 * PI
        return when {
            a >= -PI / 4 && a < PI / 4 -> Side.AHEAD
            a >= PI / 4 && a < 3 * PI / 4 -> Side.RIGHT
            a >= -3 * PI / 4 && a < -PI / 4 -> Side.LEFT
            else -> Side.BEHIND
        }
    }

    private const val MIN_SEEN = 30
}
