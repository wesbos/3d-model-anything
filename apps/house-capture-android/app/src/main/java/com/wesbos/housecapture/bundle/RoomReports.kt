package com.wesbos.housecapture.bundle

import com.wesbos.housecapture.capture.RoomReport
import com.wesbos.housecapture.capture.RoomSummary
import kotlinx.serialization.decodeFromString

/** Builds the room page's [RoomReport] from a session's files. */
object RoomReports {
    fun read(bundle: ScanBundle, summary: RoomSummary): RoomReport {
        val manifest = bundle.readManifest()
        val room = bundle.readRoom(ScanBundle.ROOM_INDEX)
        val photos = try {
            BundleJson.decodeFromString<List<PhotoRecord>>(bundle.file("photos/photos.json").readText())
        } catch (e: Exception) {
            emptyList()
        }
        return build(summary, manifest, room, photos)
    }

    /** Pure: everything the room page draws and judges, from the parsed bundle files. */
    fun build(summary: RoomSummary, manifest: Manifest?, room: RoomPlanRoom?, photos: List<PhotoRecord>): RoomReport {
        val walls = room?.walls.orEmpty()
        val segments = walls.map { wallSegment(it) }
        val floor = room?.floors?.firstOrNull()?.let { f ->
            val m = f.transform.toFloatArray()
            val out = FloatArray(f.polygonCorners.size * 2)
            f.polygonCorners.forEachIndexed { i, c ->
                if (c.size >= 3 && m.size == 16) {
                    val p = Matrices.transformPoint(m, c[0], c[1], c[2])
                    out[i * 2] = p[0]; out[i * 2 + 1] = p[2]
                }
            }
            out
        } ?: FloatArray(0)
        val positions = FloatArray(photos.size * 2)
        photos.forEachIndexed { i, p ->
            if (p.transform.size == 16) {
                positions[i * 2] = p.transform[12]
                positions[i * 2 + 1] = p.transform[14]
            }
        }
        val capture = manifest?.capture
        return RoomReport(
            summary = summary,
            walls = segments,
            wallConfidence = walls.map { it.confidence.keys.firstOrNull() ?: "low" },
            photoPositions = positions,
            floor = floor,
            seconds = manifest?.rooms?.firstOrNull()?.detailSeconds,
            trackingLostSeconds = capture?.trackingLostSeconds,
            depthMode = capture?.depthMode,
            depthStats = capture?.depthStats?.outcomes.orEmpty(),
            synthesized = capture?.synthesized == true,
            finished = manifest?.rooms?.isNotEmpty() == true,
        )
    }

    /** x0, z0, x1, z1: the wall's center ± half its width along its local x axis (column 0). */
    fun wallSegment(wall: RoomPlanElement): FloatArray {
        val t = wall.transform
        if (t.size != 16) return FloatArray(4)
        val half = (wall.dimensions.firstOrNull() ?: 0f) / 2
        val ux = t[0]; val uz = t[2]
        val cx = t[12]; val cz = t[14]
        return floatArrayOf(cx - ux * half, cz - uz * half, cx + ux * half, cz + uz * half)
    }
}
