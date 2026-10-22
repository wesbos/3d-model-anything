package com.wesbos.housecapture

import com.wesbos.housecapture.bundle.BundleJson
import com.wesbos.housecapture.bundle.CameraConfigInfo
import com.wesbos.housecapture.bundle.CaptureEvent
import com.wesbos.housecapture.bundle.CaptureInfo
import com.wesbos.housecapture.bundle.Manifest
import com.wesbos.housecapture.bundle.Matrices
import com.wesbos.housecapture.bundle.PhotoRecord
import com.wesbos.housecapture.bundle.RoomPlanElement
import com.wesbos.housecapture.bundle.RoomPlanRoom
import com.wesbos.housecapture.bundle.RoomRecord
import com.wesbos.housecapture.bundle.ScanBundle
import com.wesbos.housecapture.capture.CoverageGrid
import com.wesbos.housecapture.capture.DepthWriter
import com.wesbos.housecapture.capture.PlaneLayout
import com.wesbos.housecapture.capture.YuvPlanes
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.time.Instant
import java.time.LocalDateTime
import java.util.zip.Inflater
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

class BundleFormatTest {
    private val isoSeconds = Regex("""^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$""")

    @Test
    fun poseIsColumnMajorWithTranslationLast() {
        val m = Matrices.pose(1f, 2f, 3f, 0f, 0f, 0f, 1f)
        assertEquals(listOf(1f, 2f, 3f, 1f), m.slice(12..15))
        assertEquals(Matrices.IDENTITY.subList(0, 12), m.slice(0..11))

        // 90° about +Y: local +X maps to world −Z (column 0), local +Z to world +X (column 2)
        val half = Math.toRadians(45.0)
        val r = Matrices.pose(0f, 0f, 0f, 0f, sin(half).toFloat(), 0f, cos(half).toFloat())
        assertClose(floatArrayOf(0f, 0f, -1f), Matrices.column(r, 0))
        assertClose(floatArrayOf(1f, 0f, 0f), Matrices.column(r, 2))
        assertClose(floatArrayOf(5f, 0f, 0f), Matrices.transformPoint(r, 0f, 0f, 5f))
        assertClose(floatArrayOf(0f, 0f, 5f), Matrices.inverseTransformPoint(r, 5f, 0f, 0f))
    }

    @Test
    fun manifestHasSwiftRequiredKeysAndWholeSecondDates() {
        val manifest = Manifest(
            createdAt = Matrices.iso(Instant.parse("2026-10-22T17:01:02.345Z")),
            device = "Pixel 10 Pro",
            house = "android",
            session = "2026-10-22 17.01.02",
            systemVersion = "Android 16 (API 36)",
            photoCount = 3,
            rooms = listOf(RoomRecord(capturedAt = Matrices.iso(), file = "rooms/room-0.json", index = 0, name = "Kitchen", walls = 4)),
            endedAt = Matrices.iso(),
        )
        val json = BundleJson.parseToJsonElement(BundleJson.encodeToString(manifest)).jsonObject
        assertEquals("house-capture/5", json.string("format"))
        assertEquals("2026-10-22T17:01:02Z", json.string("createdAt"))
        for (key in listOf("format", "createdAt", "device", "systemVersion", "coordinateSystem", "house", "session", "zone", "rooms", "photos", "photoCount")) {
            assertTrue("manifest.$key", key in json)
        }
        assertEquals("android", json.string("platform"))
        assertEquals("first", json["alignment"]!!.jsonObject.string("method"))
        assertEquals(16, json["alignment"]!!.jsonObject["toZone"]!!.jsonArray.size)
        assertTrue(isoSeconds.matches(json.string("endedAt")))

        val room = json["rooms"]!!.jsonArray.single().jsonObject
        for (key in listOf("index", "name", "file", "usdz", "capturedAt", "walls", "doors", "windows", "openings", "objects")) {
            assertTrue("room.$key", key in room)
        }
        assertEquals("", room.string("usdz"))
        assertTrue(isoSeconds.matches(room.string("capturedAt")))
    }

    @Test
    fun f16zRoundTripsWithinAMillimeter() {
        val mm = shortArrayOf(0, 300, 512, 999, 1000, 1234, 1500, 1999, 2000, 2047, 1, 1800)
        val compressed = DepthWriter.encodeF16z(mm)
        val inflater = Inflater(true)
        // raw DEFLATE: a trailing dummy byte keeps Inflater(nowrap) happy on every JDK
        inflater.setInput(compressed + byteArrayOf(0))
        val raw = ByteArray(mm.size * 2)
        assertEquals(raw.size, inflater.inflate(raw))
        inflater.end()
        for (i in mm.indices) {
            val half = ((raw[i * 2].toInt() and 0xFF) or ((raw[i * 2 + 1].toInt() and 0xFF) shl 8)).toShort()
            val meters = DepthWriter.halfToFloat(half)
            assertTrue("pixel $i: ${mm[i]} mm → $meters m", abs(meters * 1000 - mm[i]) <= 1f)
        }
        assertEquals(0, DepthWriter.floatToHalf(0f).toInt())
        assertEquals(0x3C00, DepthWriter.floatToHalf(1f).toInt())
    }

    @Test
    fun confidenceQuantization() {
        val expected = mapOf(0 to 0, 63 to 0, 64 to 1, 191 to 1, 192 to 2, 255 to 2)
        for ((value, level) in expected) assertEquals("confidence $value", level, DepthWriter.quantizeConfidence(value).toInt())
        val bytes = DepthWriter.quantizeConfidence(byteArrayOf(0, 63, 64, 191.toByte(), 192.toByte(), 255.toByte()))
        assertEquals(listOf<Byte>(0, 0, 1, 1, 2, 2), bytes.toList())
    }

    @Test
    fun fallbackLayoutIsAValidRoom() {
        val path = listOf(floatArrayOf(0f, 1.4f, 0f), floatArrayOf(1.5f, 1.5f, 0.5f), floatArrayOf(0.5f, 1.6f, 2f))
        val room = PlaneLayout.build(emptyList(), path)
        assertEquals(4, room.walls.size)
        assertTrue(room.walls.all { it.confidence.keys == setOf("low") })
        checkBundleToRoomInvariants(room)

        val floorY = room.floors.single().transform[13]
        assertEquals(1.4f - 1.3f, floorY, 1e-4f)
        // the box is the camera path's bounds inflated by 0.8 m
        val corners = room.floors.single().polygonCorners
        assertEquals(-0.8f, corners.minOf { it[0] }, 1e-4f)
        assertEquals(2.3f, corners.maxOf { it[0] }, 1e-4f)
        assertEquals(2.8f, corners.maxOf { it[2] }, 1e-4f)

        val json = BundleJson.parseToJsonElement(BundleJson.encodeToString(room)).jsonObject
        for (key in listOf("walls", "doors", "windows", "openings", "objects", "floors", "sections", "version", "story")) {
            assertTrue("room.$key", key in json)
        }
        val wall = json["walls"]!!.jsonArray.first().jsonObject
        assertEquals(JsonObject(emptyMap()), wall["category"]!!.jsonObject["wall"])
        assertEquals("null", wall["curve"].toString())
    }

    @Test
    fun verticalPlanesBecomeInwardFacingMergedWalls() {
        val front = wallPlane(cx = 0f, cz = -2f, nx = 0f, nz = 1f, along = 3f)
        val frontMore = wallPlane(cx = 1f, cz = -2.05f, nx = 0f, nz = 1f, along = 2f) // coplanar, overlapping
        val side = wallPlane(cx = 2f, cz = 0f, nx = -1f, nz = 0f, along = 3f)
        val tooSmall = wallPlane(cx = -2f, cz = 0f, nx = 1f, nz = 0f, along = 0.4f)
        val path = listOf(floatArrayOf(-0.5f, 1.5f, 0f), floatArrayOf(0.5f, 1.5f, 0f), floatArrayOf(0f, 1.5f, 0.5f))
        val room = PlaneLayout.build(listOf(front, frontMore, side, tooSmall), path)

        assertEquals(2, room.walls.size)
        val merged = room.walls.maxByOrNull { it.dimensions[0] }!!
        assertEquals(3.5f, merged.dimensions[0], 1e-3f)
        assertEquals(1f, merged.transform[10], 1e-4f) // normal +Z, into the room
        assertEquals(0.25f, merged.transform[12], 1e-3f)
        // app walls are never "high": both are ≥ 2 m, so medium
        assertTrue(room.walls.all { it.confidence.keys == setOf("medium") })
        assertEquals(2.4f, room.walls.first().dimensions[1], 1e-4f)
        checkBundleToRoomInvariants(room)
    }

    @Test
    fun yuvPlanesToNv21HandlesStridesAndPadding() {
        // 4×2 image, Y rows padded to 6 bytes; chroma 2×1, semi-planar (pixel stride 2)
        val semi = YuvPlanes(
            4, 2,
            byteArrayOf(1, 2, 3, 4, 0, 0, 5, 6, 7, 8), 6, 1,
            byteArrayOf(10, 0, 11), 6, 2,
            byteArrayOf(20, 0, 21), 6, 2,
        )
        val expected = listOf<Byte>(1, 2, 3, 4, 5, 6, 7, 8, 20, 10, 21, 11)
        assertEquals(expected, semi.toNv21().data.toList())
        // the same chroma planar (pixel stride 1)
        val planar = YuvPlanes(
            4, 2,
            byteArrayOf(1, 2, 3, 4, 0, 0, 5, 6, 7, 8), 6, 1,
            byteArrayOf(10, 11), 2, 1,
            byteArrayOf(20, 21), 2, 1,
        )
        assertEquals(expected, planar.toNv21().data.toList())

        // 8×4 → at most 4 wide: every other pixel and row
        val y = ByteArray(32) { it.toByte() }
        val u = ByteArray(8) { (100 + it).toByte() }
        val v = ByteArray(8) { (50 + it).toByte() }
        val small = YuvPlanes(8, 4, y, 8, 1, u, 4, 1, v, 4, 1).toNv21(maxWidth = 4)
        assertEquals(4, small.width)
        assertEquals(2, small.height)
        assertEquals(listOf<Byte>(0, 2, 4, 6, 16, 18, 20, 22, 50, 100, 52, 102), small.data.toList())
    }

    @Test
    fun coverageGridScoresAndMarksPhotos() {
        val grid = CoverageGrid()
        assertNull(grid.coverage)
        grid.addSeen(0.05f, 0.05f, -2f)  // straight ahead, 2 m
        grid.addSeen(0.05f, 0.05f, 2f)   // behind the camera
        grid.addSeen(0.05f, 0.05f, -6f)  // too far
        grid.addSeen(3f, 0.05f, -2f)     // far off-axis (> 30°)
        val identity = Matrices.pose(0f, 0f, 0f, 0f, 0f, 0f, 1f)
        val view = CoverageGrid.View(identity, 500f, 500f, 320f, 240f, 640, 480)
        assertEquals(4, grid.seenCount)
        assertEquals(1, grid.gain(view))
        grid.markPhotographed(view)
        assertEquals(0, grid.gain(view))
        assertEquals(3, grid.unphotographed)
        assertEquals(0.25f, grid.coverage!!, 1e-6f)
        val (seen, photographed) = grid.topDown()
        assertEquals(8, seen.size)
        assertEquals(2, photographed.size)
    }

    @Test
    fun unfinishedSessionIsCheckpointedAndCompletable() {
        val root = Files.createTempDirectory("sessions").toFile()
        try {
            val bundle = ScanBundle.create(root, LocalDateTime.of(2026, 10, 22, 17, 1, 2))
            assertEquals("2026-10-22 17.01.02", bundle.id)
            assertEquals("2026-10-22 17.01.02 2", ScanBundle.create(root, LocalDateTime.of(2026, 10, 22, 17, 1, 2)).id)
            val photo = PhotoRecord(
                file = "photos/0000.jpg", height = 1080, intrinsics = Matrices.intrinsics(1500f, 1500f, 960f, 540f),
                manual = false, room = ScanBundle.ROOM_INDEX, segment = 0, timestamp = 1.5,
                transform = Matrices.IDENTITY, width = 1920,
            )
            bundle.writePhotos(listOf(photo))
            bundle.writeRoom(ScanBundle.ROOM_INDEX, PlaneLayout.build(emptyList(), listOf(floatArrayOf(0f, 1.5f, 0f))))
            bundle.writeManifest(
                Manifest(
                    createdAt = "2026-10-22T17:01:02Z", device = "Pixel 10 Pro", house = ScanBundle.HOUSE_ID,
                    photoCount = 1, session = bundle.id, systemVersion = "Android 16 (API 36)",
                ),
            )
            assertTrue(bundle.file("photos/photos.json").isFile)
            assertTrue(bundle.file("rooms/room-0.arcore.json").isFile)
            val unfinished = bundle.summary()!!
            assertEquals(ScanBundle.UNFINISHED_NAME, unfinished.name)
            assertEquals(0, unfinished.roomIndex)

            val completed = bundle.completeUnfinished()!!
            val room = completed.rooms.single()
            assertEquals(0, room.index)
            assertEquals("rooms/room-0.json", room.file)
            assertEquals(4, room.walls)
            assertEquals(completed, bundle.readManifest())
            assertNull("already complete", bundle.completeUnfinished())
            assertEquals(4, bundle.summary()!!.walls)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun segmentsAndEventsSerialize() {
        val info = CaptureInfo(
            arcoreSdk = "1.57.0",
            cameraConfig = CameraConfigInfo(30, 30, 1080, 1920, 1080, 1920),
            depthMode = "RAW_DEPTH_ONLY",
            events = listOf(CaptureEvent(12.3, "pause"), CaptureEvent(12.3, "resume")),
            segments = 2,
        )
        val json = BundleJson.parseToJsonElement(BundleJson.encodeToString(info)).jsonObject
        assertEquals("2", json["segments"]!!.jsonPrimitive.content)
        assertEquals("resume", json["events"]!!.jsonArray[1].jsonObject.string("what"))
        assertEquals("arcore-planes", json.string("layoutSource"))
        assertEquals("false", json["synthesized"]!!.jsonPrimitive.content)
        val photo = PhotoRecord(
            file = "photos/0000.jpg", height = 2, intrinsics = Matrices.intrinsics(1f, 1f, 1f, 1f),
            manual = true, room = 0, segment = 1, timestamp = 0.0, transform = Matrices.IDENTITY, width = 2,
        )
        val photoJson = BundleJson.parseToJsonElement(BundleJson.encodeToString(photo)).jsonObject
        assertEquals("1", photoJson["segment"]!!.jsonPrimitive.content)
    }

    /** What bundle_to_room.py relies on: ids, 16-float transforms, confidence, CCW floor, normals inside. */
    private fun checkBundleToRoomInvariants(room: RoomPlanRoom) {
        val corners = room.floors.single().polygonCorners
        assertTrue(corners.size >= 3)
        val xz = corners.map { floatArrayOf(it[0], it[2]) }
        assertTrue("floor polygon CCW seen from above", PlaneLayout.signedAreaSeenFromAbove(xz) > 0)
        for (wall in room.walls) {
            assertTrue(wall.identifier.isNotEmpty())
            assertEquals(16, wall.transform.size)
            assertEquals(3, wall.dimensions.size)
            assertEquals(1, wall.confidence.size)
            assertTrue(wall.confidence.keys.single() in setOf("medium", "low"))
            val t = wall.transform
            // u × up = n
            assertEquals(t[8], -t[2], 1e-5f)
            assertEquals(t[10], t[0], 1e-5f)
            assertTrue("wall faces into the floor polygon", inside(xz, t[12] + t[8] * 0.05f, t[14] + t[10] * 0.05f))
        }
        assertEquals("unique identifiers", room.walls.size, room.walls.map(RoomPlanElement::identifier).toSet().size)
    }

    /** bundle_to_room.py's even-odd point-in-polygon test. */
    private fun inside(poly: List<FloatArray>, x: Float, z: Float): Boolean {
        var hit = false
        for (i in poly.indices) {
            val (x1, z1) = poly[i]
            val (x2, z2) = poly[(i + 1) % poly.size]
            if ((z1 > z) != (z2 > z) && x < x1 + (z - z1) * (x2 - x1) / (z2 - z1)) hit = !hit
        }
        return hit
    }

    /** A vertical ARCore plane: local +Y = normal (nx, 0, nz), local +X horizontal along the wall. */
    private fun wallPlane(cx: Float, cz: Float, nx: Float, nz: Float, along: Float): PlaneLayout.PlaneInput {
        val ax = nz; val az = -nx // horizontal, ⟂ normal
        // local Z = X × Y = (0, az·nx − ax·nz, 0): straight down
        val pose = floatArrayOf(ax, 0f, az, 0f, nx, 0f, nz, 0f, 0f, az * nx - ax * nz, 0f, 0f, cx, 1f, cz, 1f)
        return PlaneLayout.PlaneInput(PlaneLayout.Kind.WALL, pose, along, 2f, floatArrayOf(-along / 2, -1f, along / 2, -1f, along / 2, 1f, -along / 2, 1f))
    }

    private fun JsonObject.string(key: String) = this[key]!!.jsonPrimitive.content

    private fun assertClose(expected: FloatArray, actual: FloatArray) {
        for (i in expected.indices) assertEquals("[$i]", expected[i], actual[i], 1e-5f)
    }
}
