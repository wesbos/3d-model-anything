package com.wesbos.housecapture

import com.wesbos.housecapture.bundle.ArcoreDepthInfo
import com.wesbos.housecapture.bundle.BundleJson
import com.wesbos.housecapture.bundle.CameraConfigInfo
import com.wesbos.housecapture.bundle.CaptureInfo
import com.wesbos.housecapture.bundle.DepthFrameRecord
import com.wesbos.housecapture.bundle.DepthStatsInfo
import com.wesbos.housecapture.bundle.Matrices
import com.wesbos.housecapture.capture.DepthDecision
import com.wesbos.housecapture.capture.DepthPairing
import com.wesbos.housecapture.capture.DepthStats
import com.wesbos.housecapture.capture.PoseMatch
import com.wesbos.housecapture.capture.PoseRing
import com.wesbos.housecapture.capture.PoseSource
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class DepthPairingTest {
    private val ms = 1_000_000L

    /** Frames at 30 fps from t0, each with a pose whose x translation is the frame index. */
    private fun ring(frames: Int, t0: Long = 1_000_000_000L): Pair<PoseRing, List<Long>> {
        val ring = PoseRing(capacity = 90)
        val times = List(frames) { t0 + it * 33 * ms }
        times.forEachIndexed { i, t -> ring.add(t, Matrices.pose(i.toFloat(), 0f, 0f, 0f, 0f, 0f, 1f)) }
        return ring to times
    }

    @Test
    fun depthFromAnEarlierFrameGetsThatFramesPose() {
        val (ring, times) = ring(30)
        // depth computed for frame 26 arrives while frame 29 is current: the old equality gate rejected this
        val d = DepthPairing.decide(times[26], lastDepthNanos = times[23], frameNanos = times[29], ring = ring)
        assertTrue(d is DepthDecision.Take)
        d as DepthDecision.Take
        assertEquals(PoseSource.EXACT, d.match.source)
        assertEquals(26f, d.match.pose[12])
        assertEquals(times[26], d.match.frameNanos)
        assertEquals(0L, d.match.offsetNanos)
        assertFalse("not the current frame: no color image", d.sameFrame)
    }

    @Test
    fun depthOfTheCurrentFrameIsSameFrame() {
        val (ring, times) = ring(10)
        val d = DepthPairing.decide(times[9], lastDepthNanos = null, frameNanos = times[9], ring = ring) as DepthDecision.Take
        assertTrue(d.sameFrame)
        assertEquals(9f, d.match.pose[12])
    }

    @Test
    fun repeatedTimestampIsStale() {
        val (ring, times) = ring(10)
        assertSame(DepthDecision.Stale, DepthPairing.decide(times[5], lastDepthNanos = times[5], frameNanos = times[9], ring = ring))
    }

    @Test
    fun nearestPoseWithinFiftyMillisecondsIsFlagged() {
        val (ring, times) = ring(10)
        val d = DepthPairing.decide(times[4] + 12 * ms, lastDepthNanos = null, frameNanos = times[9], ring = ring) as DepthDecision.Take
        assertEquals(PoseSource.NEAREST, d.match.source)
        assertEquals(4f, d.match.pose[12])
        assertEquals(12 * ms, d.match.offsetNanos)
        assertFalse(d.sameFrame)
    }

    @Test
    fun noPoseBeyondTheTolerance() {
        val (ring, times) = ring(10)
        // after the newest frame by 80 ms
        val d = DepthPairing.decide(times[9] + 80 * ms, lastDepthNanos = null, frameNanos = times[9], ring = ring)
        assertTrue(d is DepthDecision.NoPose)
        assertEquals(80 * ms, (d as DepthDecision.NoPose).offsetNanos)
        // a different clock entirely: reported, not silently dropped
        val far = DepthPairing.decide(5_000_000_000_000L, lastDepthNanos = null, frameNanos = times[9], ring = ring) as DepthDecision.NoPose
        assertTrue(far.offsetNanos!! > 0)
    }

    @Test
    fun emptyRingHasNoPoseAndNoOffset() {
        val m = PoseRing().match(123L)
        assertTrue(m is PoseMatch.None)
        assertNull((m as PoseMatch.None).offsetNanos)
    }

    @Test
    fun ringDropsTheOldestFrames() {
        val ring = PoseRing(capacity = 4)
        for (i in 0 until 10) ring.add(i * 33 * ms, Matrices.pose(i.toFloat(), 0f, 0f, 0f, 0f, 0f, 1f))
        assertEquals(4, ring.count)
        assertTrue(ring.match(2 * 33 * ms) is PoseMatch.None) // evicted
        assertEquals(6f, (ring.match(6 * 33 * ms) as PoseMatch.Found).pose[12])
        ring.clear()
        assertEquals(0, ring.count)
        assertTrue(ring.match(9 * 33 * ms) is PoseMatch.None)
    }

    @Test
    fun exactMatchWinsOverACloserLookingNeighbour() {
        val ring = PoseRing()
        ring.add(100 * ms, Matrices.pose(1f, 0f, 0f, 0f, 0f, 0f, 1f))
        ring.add(100 * ms + 1, Matrices.pose(2f, 0f, 0f, 0f, 0f, 0f, 1f))
        val m = ring.match(100 * ms) as PoseMatch.Found
        assertEquals(PoseSource.EXACT, m.source)
        assertEquals(1f, m.pose[12])
    }

    @Test
    fun statsCountEveryOutcomeAndNameTheTopProblem() {
        val stats = DepthStats()
        assertEquals("no attempts", stats.summary())
        repeat(3) { stats.count(DepthStats.exceptionKey("acquire", IllegalStateException())) }
        repeat(5) { stats.count(DepthStats.NO_POSE) }
        repeat(40) { stats.count(DepthStats.STALE) }
        stats.count(DepthStats.WRITTEN)
        stats.count("pose:exact")
        assertEquals(5, stats[DepthStats.NO_POSE])
        assertEquals(3, stats["acquire:IllegalStateException"])
        // stale is normal (depth updates slower than the camera), so it is never "the problem"
        assertEquals(DepthStats.NO_POSE, stats.topProblem())
        assertTrue(stats.summary().contains("noPose 5"))
        assertTrue(DepthStats.describe("acquire:NotYetAvailableException")!!.contains("sideways"))
        assertNull(DepthStats.describe(null))
    }

    @Test
    fun depthStatsAndPoseSourceAreSerialized() {
        val capture = CaptureInfo(
            arcoreSdk = "1.57.0",
            cameraConfig = CameraConfigInfo(30, 30, 1080, 1920, 1080, 1920),
            depthMode = "RAW_DEPTH_ONLY",
            depthStats = DepthStatsInfo(firstWrittenSeconds = 2.5, outcomes = mapOf("written" to 7, "stale" to 30)),
            trackingLostSeconds = 1.5,
        )
        val json = BundleJson.parseToJsonElement(BundleJson.encodeToString(capture)).jsonObject
        val stats = json["depthStats"]!!.jsonObject
        assertEquals(7, stats["outcomes"]!!.jsonObject["written"]!!.jsonPrimitive.int)
        assertEquals("2.5", stats["firstWrittenSeconds"]!!.jsonPrimitive.content)
        assertFalse("null keys are omitted", "lastUnmatchedOffsetMs" in stats)
        assertEquals("1.5", json["trackingLostSeconds"]!!.jsonPrimitive.content)

        val frame = DepthFrameRecord(
            arcore = ArcoreDepthInfo(depthTimestamp = 1.0, frameTimestamp = 1.1, poseSource = "exact", textureHeight = 1080, textureIntrinsics = Matrices.intrinsics(1f, 1f, 0f, 0f), textureWidth = 1920),
            confidence = "depth/00000.conf", file = "depth/00000.f16z", height = 90, intrinsics = Matrices.intrinsics(1f, 1f, 0f, 0f),
            room = 0, timestamp = 1.0, transform = Matrices.IDENTITY, width = 160,
        )
        val arcore = BundleJson.parseToJsonElement(BundleJson.encodeToString(frame)).jsonObject["arcore"]!!.jsonObject
        assertEquals("exact", arcore["poseSource"]!!.jsonPrimitive.content)
        assertFalse("poseOffsetMs only for nearest", "poseOffsetMs" in arcore)
    }
}
