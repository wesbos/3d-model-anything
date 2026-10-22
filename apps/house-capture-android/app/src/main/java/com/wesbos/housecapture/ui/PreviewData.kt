package com.wesbos.housecapture.ui

import android.content.Context
import android.graphics.Color
import android.view.View
import com.wesbos.housecapture.capture.CaptureContract
import com.wesbos.housecapture.capture.CaptureState
import com.wesbos.housecapture.capture.CoverageSnapshot
import com.wesbos.housecapture.capture.Phase
import com.wesbos.housecapture.capture.RoomReport
import com.wesbos.housecapture.capture.RoomSummary
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Fixed sample data for the @Preview functions. Never used at runtime. */
internal object PreviewData {
    /** A 4 x 3 m room: walls seen all round, the far half photographed. */
    val snapshot: CoverageSnapshot by lazy {
        val seen = ArrayList<Float>()
        val photographed = ArrayList<Float>()
        var x = -2f
        while (x <= 2f) {
            for (z in listOf(-1.5f, 1.5f)) {
                seen += x; seen += z
                if (z < 0) { photographed += x; photographed += z }
            }
            x += 0.1f
        }
        var z = -1.5f
        while (z <= 1.5f) {
            for (wx in listOf(-2f, 2f)) {
                seen += wx; seen += z
                if (z < 0.3f) { photographed += wx; photographed += z }
            }
            z += 0.1f
        }
        val photos = FloatArray(16) { i ->
            val a = 2 * PI * (i / 2) / 8
            (if (i % 2 == 0) 0.8 * cos(a) else 0.8 * sin(a)).toFloat()
        }
        CoverageSnapshot(
            seen = seen.toFloatArray(),
            photographed = photographed.toFloatArray(),
            planes = listOf(
                floatArrayOf(-1.9f, -1.5f, 1.2f, -1.5f),
                floatArrayOf(2f, -1.4f, 2f, 0.9f),
                floatArrayOf(-1.2f, -0.8f, 0.6f, -0.8f, 0.6f, 0.9f, -1.2f, 0.9f),
            ),
            cameraX = 0.3f,
            cameraZ = 0.4f,
            headingRadians = -2.2f,
            photoPositions = photos,
        )
    }

    val rooms = listOf(
        RoomSummary("2026-10-22 17.01.02", 0, "Living room", "/data/user/0/com.wesbos.housecapture/files/Houses/Android/sessions/2026-10-22 17.01.02", 84, 212, 5, 0.72f, 186_000_000),
        RoomSummary("2026-10-22 17.20.45", 0, "Kitchen", "/data/user/0/com.wesbos.housecapture/files/Houses/Android/sessions/2026-10-22 17.20.45", 41, 96, 4, null, 74_000_000),
    )

    /** The 4 × 3 m room as a saved report: four walls, photos in a ring. */
    val report: RoomReport by lazy {
        RoomReport(
            summary = rooms[0],
            walls = listOf(
                floatArrayOf(-2f, -1.5f, 2f, -1.5f),
                floatArrayOf(2f, -1.5f, 2f, 1.5f),
                floatArrayOf(2f, 1.5f, -2f, 1.5f),
                floatArrayOf(-2f, 1.5f, -2f, -1.5f),
            ),
            wallConfidence = listOf("medium", "medium", "medium", "low"),
            photoPositions = snapshot.photoPositions,
            floor = floatArrayOf(-2f, -1.5f, 2f, -1.5f, 2f, 1.5f, -2f, 1.5f),
            seconds = 95.0,
            trackingLostSeconds = 3.2,
            depthMode = "RAW_DEPTH_ONLY",
            depthStats = mapOf("written" to 212, "stale" to 640, "pose:exact" to 205, "pose:nearest" to 7),
            synthesized = false,
            finished = true,
        )
    }

    /** What the first Pixel 10 Pro scan looked like: photos but no depth. */
    val poorReport: RoomReport by lazy {
        report.copy(
            summary = rooms[1].copy(depthFrames = 0),
            walls = report.walls.take(2),
            depthStats = mapOf("noPose" to 180, "acquire:NotYetAvailableException" to 12),
            trackingLostSeconds = 0.4,
            seconds = 61.2,
        )
    }

    val scanning = CaptureState(
        phase = Phase.SCANNING,
        tracking = "normal",
        depthAvailable = true,
        photos = 37,
        manualPhotos = 2,
        depthFrames = 118,
        planes = 6,
        coverage = 0.48f,
        elapsedSeconds = 95,
        snapshot = snapshot,
    )

    val depthStalled = scanning.copy(
        depthFrames = 0,
        depthStalled = true,
        depthProblem = "Depth timestamps don't match any camera frame",
        coverage = null,
    )

    val limited = scanning.copy(
        tracking = "limited:INSUFFICIENT_FEATURES",
        trackingWarning = "Point at something with texture (not a blank wall)",
    )
}

/** A CaptureContract that only holds a state; the preview surface is a plain dark view. */
internal class PreviewCapture(initial: CaptureState = PreviewData.scanning) : CaptureContract {
    private val mutable = MutableStateFlow(initial)
    override val state: StateFlow<CaptureState> = mutable
    override fun createPreviewView(context: Context): View = View(context).apply { setBackgroundColor(Color.DKGRAY) }
    override fun onResume() {}
    override fun onPause() {}
    override fun startRoom(name: String) {}
    override fun takePhoto() {
        mutable.value = mutable.value.let { it.copy(photos = it.photos + 1, manualPhotos = it.manualPhotos + 1) }
    }
    override fun finishRoom() {}
    override fun release() {}
}
