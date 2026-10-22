package com.wesbos.housecapture

import com.wesbos.housecapture.bundle.CameraConfigInfo
import com.wesbos.housecapture.bundle.CaptureInfo
import com.wesbos.housecapture.bundle.DepthStatsInfo
import com.wesbos.housecapture.bundle.Manifest
import com.wesbos.housecapture.bundle.Matrices
import com.wesbos.housecapture.bundle.PhotoRecord
import com.wesbos.housecapture.bundle.RoomPlanElement
import com.wesbos.housecapture.bundle.RoomPlanRoom
import com.wesbos.housecapture.bundle.RoomRecord
import com.wesbos.housecapture.bundle.RoomReports
import com.wesbos.housecapture.capture.CaptureState
import com.wesbos.housecapture.capture.CoverageSnapshot
import com.wesbos.housecapture.capture.Phase
import com.wesbos.housecapture.capture.RoomReport
import com.wesbos.housecapture.capture.RoomSummary
import com.wesbos.housecapture.ui.ScanGuide
import com.wesbos.housecapture.ui.ScanQuality
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs

class ScanSummaryTest {
    private val summary = RoomSummary("2026-10-22 18.13.39", 0, "Office", "/tmp/x", photos = 38, depthFrames = 120, walls = 4, coverage = 0.7f, bytes = 1L)

    private fun report(
        summary: RoomSummary = this.summary,
        walls: List<FloatArray> = box(4f, 3f),
        confidence: List<String> = List(walls.size) { "medium" },
        depthMode: String? = "RAW_DEPTH_ONLY",
        stats: Map<String, Int> = mapOf("written" to summary.depthFrames),
        seconds: Double? = 60.0,
        lost: Double? = 1.0,
    ) = RoomReport(summary, walls, confidence, FloatArray(0), FloatArray(0), seconds, lost, depthMode, stats, synthesized = false, finished = true)

    private fun box(w: Float, d: Float) = listOf(
        floatArrayOf(0f, 0f, w, 0f), floatArrayOf(w, 0f, w, d), floatArrayOf(w, d, 0f, d), floatArrayOf(0f, d, 0f, 0f),
    )

    // --- verdict ------------------------------------------------------------------------------

    @Test
    fun goodScanHasNoWarnings() {
        val v = ScanQuality.assess(report())
        assertEquals(ScanQuality.Level.GOOD, v.level)
        assertTrue(v.warnings.isEmpty())
    }

    @Test
    fun zeroDepthIsPoorAndSaysWhy() {
        val v = ScanQuality.assess(report(summary.copy(depthFrames = 0), stats = mapOf("noPose" to 90, "stale" to 300)))
        assertEquals(ScanQuality.Level.POOR, v.level)
        val w = v.warnings.first()
        assertTrue(w, w.startsWith("No depth: walls are only an estimate"))
        assertTrue(w, w.contains("noPose"))
    }

    @Test
    fun noDepthModeIsPoor() {
        val v = ScanQuality.assess(report(summary.copy(depthFrames = 0), depthMode = "DISABLED", stats = emptyMap()))
        assertEquals(ScanQuality.Level.POOR, v.level)
        assertTrue(v.warnings.first().contains("No depth on this phone"))
    }

    @Test
    fun gapsMakeAUsableScan() {
        val v = ScanQuality.assess(
            report(summary.copy(photos = 10, coverage = 0.3f), walls = box(4f, 3f).take(2), seconds = 60.0, lost = 12.0),
        )
        assertEquals(ScanQuality.Level.USABLE, v.level)
        val all = v.warnings.joinToString("\n")
        assertTrue(all, all.contains("Only 10 photos"))
        assertTrue(all, all.contains("Photo detail 30%"))
        assertTrue(all, all.contains("Tracking was lost for 12 s"))
        assertTrue(all, all.contains("Only 2 walls"))
    }

    @Test
    fun roomSizeFollowsTheLongestWallEvenWhenRotated() {
        val (w, d) = ScanQuality.roomSize(box(4f, 3f))!!
        assertEquals(4f, w, 1e-4f)
        assertEquals(3f, d, 1e-4f)
        // the same room turned 30° in ARCore's world
        val a = (PI / 6).toFloat()
        val c = kotlin.math.cos(a); val s = kotlin.math.sin(a)
        val rotated = box(4f, 3f).map { floatArrayOf(it[0] * c - it[1] * s, it[0] * s + it[1] * c, it[2] * c - it[3] * s, it[2] * s + it[3] * c) }
        val (rw, rd) = ScanQuality.roomSize(rotated)!!
        assertEquals(4f, rw, 1e-3f)
        assertEquals(3f, rd, 1e-3f)
        assertNull(ScanQuality.roomSize(emptyList()))
    }

    // --- room report from bundle files -------------------------------------------------------

    @Test
    fun reportReadsWallsPhotosAndCaptureDetails() {
        // a 2 m wall centered at (1, 1.2, -2) running along +x (local x = column 0)
        val wall = RoomPlanElement(
            category = RoomPlanElement.tag("wall"),
            confidence = RoomPlanElement.tag("low"),
            dimensions = listOf(2f, 2.4f, 0f),
            identifier = "W",
            transform = listOf(1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f, 1f, 1.2f, -2f, 1f),
        )
        val floor = RoomPlanElement(
            category = RoomPlanElement.tag("floor"),
            confidence = RoomPlanElement.tag("medium"),
            dimensions = listOf(0f, 0f, 0f),
            identifier = "F",
            polygonCorners = listOf(listOf(0f, 0f, 0f), listOf(2f, 0f, 0f), listOf(2f, 0f, -2f)),
            transform = Matrices.IDENTITY.toMutableList().also { it[13] = -1.3f },
        )
        val photo = PhotoRecord(
            file = "photos/0000.jpg", height = 1080, intrinsics = Matrices.intrinsics(1f, 1f, 0f, 0f), manual = false,
            room = 0, timestamp = 1.0, transform = Matrices.pose(0.5f, 1.4f, -0.7f, 0f, 0f, 0f, 1f).toList(), width = 1920,
        )
        val manifest = Manifest(
            capture = CaptureInfo(
                arcoreSdk = "1.57.0", cameraConfig = CameraConfigInfo(30, 30, 1080, 1920, 1080, 1920), depthMode = "RAW_DEPTH_ONLY",
                depthStats = DepthStatsInfo(outcomes = mapOf("written" to 3)), trackingLostSeconds = 2.0,
            ),
            createdAt = Matrices.iso(), device = "Pixel 10 Pro", house = "android", session = "s", systemVersion = "Android 16",
            rooms = listOf(RoomRecord(capturedAt = Matrices.iso(), detailSeconds = 61.2, file = "rooms/room-0.json", index = 0, name = "Office")),
        )
        val r = RoomReports.build(summary, manifest, RoomPlanRoom(floors = listOf(floor), walls = listOf(wall)), listOf(photo))
        assertEquals(1, r.walls.size)
        assertClose(floatArrayOf(0f, -2f, 2f, -2f), r.walls[0])
        assertEquals(listOf("low"), r.wallConfidence)
        assertClose(floatArrayOf(0.5f, -0.7f), r.photoPositions)
        assertClose(floatArrayOf(0f, 0f, 2f, 0f, 2f, -2f), r.floor)
        assertEquals(61.2, r.seconds!!, 1e-9)
        assertEquals(2.0, r.trackingLostSeconds!!, 1e-9)
        assertEquals(mapOf("written" to 3), r.depthStats)
        assertTrue(r.finished)
        assertEquals(2f, ScanQuality.length(r.walls[0]), 1e-5f)
    }

    @Test
    fun reportWithoutFilesIsEmptyNotACrash() {
        val r = RoomReports.build(summary, null, null, emptyList())
        assertTrue(r.walls.isEmpty())
        assertEquals(0, r.floor.size)
        assertNull(r.depthMode)
        assertTrue(!r.finished)
    }

    // --- next-step hint ------------------------------------------------------------------------

    /** Seen cells on a ring of radius 2 m around the origin, except within ±60° of [gapDegrees]. */
    private fun snapshot(gapDegrees: Double?, heading: Float = 0f): CoverageSnapshot {
        val seen = ArrayList<Float>()
        for (deg in 0 until 360 step 2) {
            if (gapDegrees != null) {
                var diff = abs(deg - gapDegrees) % 360
                if (diff > 180) diff = 360 - diff
                if (diff < 60) continue
            }
            val a = Math.toRadians(deg.toDouble())
            seen += (2 * kotlin.math.cos(a)).toFloat()
            seen += (2 * kotlin.math.sin(a)).toFloat()
        }
        return CoverageSnapshot(seen.toFloatArray(), FloatArray(0), emptyList(), 0f, 0f, heading, FloatArray(0))
    }

    @Test
    fun sideOfFollowsThePlanAxes() {
        assertEquals(ScanGuide.Side.AHEAD, ScanGuide.sideOf(0f))
        // +90° from the heading in the x-right, z-down plan is the user's right
        assertEquals(ScanGuide.Side.RIGHT, ScanGuide.sideOf((PI / 2).toFloat()))
        assertEquals(ScanGuide.Side.LEFT, ScanGuide.sideOf((-PI / 2).toFloat()))
        assertEquals(ScanGuide.Side.BEHIND, ScanGuide.sideOf(PI.toFloat()))
        assertEquals(ScanGuide.Side.BEHIND, ScanGuide.sideOf((-3.0).toFloat()))
        assertEquals(ScanGuide.Side.LEFT, ScanGuide.sideOf((3 * PI / 2).toFloat()))
    }

    @Test
    fun unseenSideIsRelativeToTheHeading() {
        // heading along +x (0 rad); the gap at +z (90°) is to the right
        assertEquals(ScanGuide.Side.RIGHT, ScanGuide.unseenSide(snapshot(90.0)))
        assertEquals(ScanGuide.Side.BEHIND, ScanGuide.unseenSide(snapshot(180.0)))
        // facing +z, the same +z gap is ahead
        assertEquals(ScanGuide.Side.AHEAD, ScanGuide.unseenSide(snapshot(90.0, heading = (PI / 2).toFloat())))
        assertNull(ScanGuide.unseenSide(snapshot(null)))
    }

    @Test
    fun hintPrioritisesTrackingThenDepthThenCoverage() {
        val base = CaptureState(phase = Phase.SCANNING, tracking = "normal", depthAvailable = true, snapshot = snapshot(null), coverage = 0.9f)
        assertTrue(ScanGuide.hint(base).text.startsWith("Looks complete"))
        assertTrue(ScanGuide.hint(base.copy(coverage = 0.2f)).text.contains("grey areas"))
        assertTrue(ScanGuide.hint(base.copy(snapshot = snapshot(180.0))).text.startsWith("Turn around"))
        val stalled = ScanGuide.hint(base.copy(depthStalled = true))
        assertTrue(stalled.urgent)
        assertTrue(stalled.text.startsWith("No depth yet"))
        val limited = ScanGuide.hint(base.copy(depthStalled = true, tracking = "limited:EXCESSIVE_MOTION", trackingWarning = "Move slower"))
        assertEquals("Move slower", limited.text)
        assertTrue(ScanGuide.hint(base.copy(phase = Phase.STARTING)).text.contains("side to side"))
        assertTrue(ScanGuide.hint(base.copy(snapshot = null)).text.contains("along a wall"))
    }

    private fun assertClose(expected: FloatArray, actual: FloatArray) {
        assertEquals(expected.size, actual.size)
        for (i in expected.indices) assertEquals("[$i]", expected[i], actual[i], 1e-4f)
    }
}
