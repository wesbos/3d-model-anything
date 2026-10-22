package com.wesbos.housecapture.capture

import kotlin.math.abs

/**
 * Pairs an ARCore raw depth image with the camera pose it was computed for.
 *
 * Raw depth updates about 10 times a second and usually lags the camera: `Image.getTimestamp()` of
 * the depth is the timestamp of an earlier camera frame, so requiring it to equal the current
 * frame's timestamp can reject every depth image on a device (it did on the Pixel 10 Pro). ARCore's
 * docs say a depth image is new when its timestamp differs from the previous depth image's.
 * So: a depth image is taken when its timestamp is new, and its pose is the one recorded for the
 * frame with exactly that timestamp, kept in a short ring of recent frame poses. If no frame matches
 * exactly, the nearest pose within [toleranceNanos] is used and flagged.
 *
 * Pure Kotlin, GL thread only (not thread-safe).
 */
class PoseRing(private val capacity: Int = 90, private val toleranceNanos: Long = 50_000_000L) {
    private val timestamps = LongArray(capacity)
    private val poses = arrayOfNulls<FloatArray>(capacity)
    private var next = 0
    private var size = 0

    /** Remembers the pose of the frame at [timestampNanos] (oldest entries are dropped). */
    fun add(timestampNanos: Long, pose: FloatArray) {
        timestamps[next] = timestampNanos
        poses[next] = pose
        next = (next + 1) % capacity
        if (size < capacity) size++
    }

    fun clear() {
        size = 0
        next = 0
        poses.fill(null)
    }

    val count: Int get() = size

    /** The pose for a depth image taken at [depthNanos], or why there is none. */
    fun match(depthNanos: Long): PoseMatch {
        var bestIndex = -1
        var bestDelta = Long.MAX_VALUE
        for (n in 0 until size) {
            val i = (next - 1 - n + capacity) % capacity
            val delta = abs(timestamps[i] - depthNanos)
            if (delta < bestDelta) {
                bestDelta = delta
                bestIndex = i
                if (delta == 0L) break
            }
        }
        if (bestIndex < 0) return PoseMatch.None(null)
        val signed = depthNanos - timestamps[bestIndex]
        return when {
            bestDelta == 0L -> PoseMatch.Found(poses[bestIndex]!!, timestamps[bestIndex], PoseSource.EXACT, 0L)
            bestDelta <= toleranceNanos -> PoseMatch.Found(poses[bestIndex]!!, timestamps[bestIndex], PoseSource.NEAREST, signed)
            else -> PoseMatch.None(signed)
        }
    }
}

enum class PoseSource(val key: String) {
    /** a recorded frame has exactly the depth image's timestamp */
    EXACT("exact"),
    /** no exact frame; the nearest recorded frame within the tolerance */
    NEAREST("nearest"),
}

sealed interface PoseMatch {
    /** [offsetNanos] = depth timestamp − frame timestamp (0 for [PoseSource.EXACT]) */
    class Found(val pose: FloatArray, val frameNanos: Long, val source: PoseSource, val offsetNanos: Long) : PoseMatch
    /** no frame close enough; [offsetNanos] = depth timestamp − nearest frame's, null when the ring is empty */
    class None(val offsetNanos: Long?) : PoseMatch
}

/** What to do with a raw depth image, before its pixels are copied. */
sealed interface DepthDecision {
    /** same timestamp as the last depth image looked at: ARCore reprojected old depth */
    data object Stale : DepthDecision
    class NoPose(val offsetNanos: Long?) : DepthDecision
    /** [sameFrame]: the depth belongs to the current camera frame, so its CPU image is the depth's color */
    class Take(val match: PoseMatch.Found, val sameFrame: Boolean) : DepthDecision
}

object DepthPairing {
    /**
     * [depthNanos] the depth image's timestamp, [lastDepthNanos] the timestamp of the previous depth
     * image looked at (or null), [frameNanos] the current frame's.
     */
    fun decide(depthNanos: Long, lastDepthNanos: Long?, frameNanos: Long, ring: PoseRing): DepthDecision {
        if (lastDepthNanos != null && depthNanos == lastDepthNanos) return DepthDecision.Stale
        return when (val m = ring.match(depthNanos)) {
            is PoseMatch.Found -> DepthDecision.Take(m, sameFrame = m.frameNanos == frameNanos && m.source == PoseSource.EXACT)
            is PoseMatch.None -> DepthDecision.NoPose(m.offsetNanos)
        }
    }
}

/**
 * Counts every outcome of trying to record a depth frame, so a scan can never again record zero
 * depth without saying why. Keys: "written", "stale", "noPose", "acquire:<Exception>",
 * "confidence:<Exception>", "copy:<Exception>", "writeFailed:<Exception>", "busy", plus
 * "pose:exact" / "pose:nearest" for written frames. Thread-safe.
 */
class DepthStats {
    private val counts = LinkedHashMap<String, Int>()
    /** depth timestamp − nearest frame timestamp of the last image without a pose, ms */
    @Volatile var lastUnmatchedOffsetMs: Double? = null
    @Volatile var firstWrittenSeconds: Double? = null

    @Synchronized
    fun count(key: String) {
        counts[key] = (counts[key] ?: 0) + 1
    }

    @Synchronized
    fun snapshot(): Map<String, Int> = counts.toSortedMap()

    operator fun get(key: String): Int = synchronized(this) { counts[key] ?: 0 }

    /** "written 12, stale 40, acquire:NotYetAvailableException 7" */
    fun summary(): String = snapshot().entries.joinToString(", ") { "${it.key} ${it.value}" }.ifEmpty { "no attempts" }

    /** The most frequent reason depth was not written, for the scan screen. */
    fun topProblem(): String? = snapshot()
        .filterKeys { it != WRITTEN && it != STALE && it != BUSY && !it.startsWith("pose:") }
        .maxByOrNull { it.value }?.key

    companion object {
        const val WRITTEN = "written"
        const val STALE = "stale"
        const val NO_POSE = "noPose"
        const val BUSY = "busy"

        fun exceptionKey(stage: String, e: Throwable) = "$stage:${e.javaClass.simpleName}"

        /** Plain words for a depth problem key, for the scan screen. */
        fun describe(key: String?): String? = when {
            key == null -> null
            key.contains("NotYetAvailable") -> "ARCore has no depth yet: move the phone sideways slowly"
            key.contains("NotTracking") -> "Depth needs tracking: move slowly and aim at detail"
            key.contains("ResourceExhausted") -> "Depth images exhausted (app bug): finish and report"
            key.contains("DeadlineExceeded") -> "Depth arrived too late (phone busy)"
            key == NO_POSE -> "Depth timestamps don't match any camera frame"
            key.startsWith("writeFailed") -> "Depth could not be saved (storage?)"
            else -> "Depth error: $key"
        }
    }
}
