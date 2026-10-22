package com.wesbos.housecapture.bundle

import android.content.Context
import com.wesbos.housecapture.capture.RoomSummary
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import java.io.File
import java.io.IOException
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * One capture session on disk: filesDir/Houses/<house>/sessions/<id>/, the same tree as the iOS app.
 *
 *     manifest.json          what's in the bundle (rewritten during capture and when the room is saved)
 *     rooms/room-0.json      RoomPlan-shaped layout from ARCore planes (one session = one room, index 0)
 *     rooms/room-0.arcore.json   the same, kept when android_synthesize_room.py rewrites room-0.json
 *     photos/photos.json     camera pose + intrinsics for every photo
 *     photos/NNNN.jpg        raw sensor-orientation pixels, EXIF orientation 6
 *     depth/frames.json      raw depth frames: pose + intrinsics (scaled to the depth map)
 *     depth/NNNNN.f16z/.conf/.jpg   Float16 meters (raw DEFLATE), UInt8 confidence 0–2, small RGB
 *
 * There is no mesh/ file: ARCore has no scene mesh; the offline synthesizer writes mesh/room-N.ply.
 * During capture every file above except the manifest's room entry is checkpointed every few
 * seconds, so a killed or abandoned scan is still a usable bundle ([completeUnfinished]).
 */
class ScanBundle(val dir: File) {
    val id: String get() = dir.name

    fun file(path: String): File = File(dir, path)

    /** Writes through a temp file + rename, so a crash never leaves half a JSON file behind. */
    fun writeText(path: String, text: String) {
        val target = file(path)
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, ".${target.name}.tmp")
        temp.writeText(text)
        if (!temp.renameTo(target)) {
            target.delete()
            if (!temp.renameTo(target)) throw IOException("Could not write $path")
        }
    }

    fun writeManifest(manifest: Manifest) = writeText("manifest.json", BundleJson.encodeToString(manifest))

    fun writePhotos(photos: List<PhotoRecord>) = writeText("photos/photos.json", BundleJson.encodeToString(photos))

    fun writeDepthFrames(frames: List<DepthFrameRecord>) =
        writeText("depth/frames.json", BundleJson.encodeToString(frames))

    fun writeRoom(index: Int, room: RoomPlanRoom) {
        val json = BundleJson.encodeToString(room)
        writeText("rooms/room-$index.json", json)
        writeText("rooms/room-$index.arcore.json", json)
    }

    /** rooms/room-N.json, or null if missing or unreadable */
    fun readRoom(index: Int): RoomPlanRoom? = try {
        BundleJson.decodeFromString<RoomPlanRoom>(file("rooms/room-$index.json").readText())
    } catch (e: Exception) {
        null
    }

    /**
     * An unfinished session (stopped, killed or crashed before Finish room) has checkpointed photos,
     * depth frames and a plane layout but no room in its manifest. Adds that room so the bundle
     * converts like a finished one; returns the updated manifest, or null if there is nothing to add.
     */
    fun completeUnfinished(name: String = UNFINISHED_NAME): Manifest? {
        val manifest = readManifest() ?: return null
        if (manifest.rooms.isNotEmpty()) return null
        val room = readRoom(ROOM_INDEX) ?: return null
        val completed = manifest.copy(
            rooms = listOf(roomRecord(room, name, capturedAt = manifest.createdAt)),
            endedAt = manifest.endedAt ?: Matrices.iso(),
        )
        writeManifest(completed)
        return completed
    }

    /** manifest.json, or null if missing or unreadable */
    fun readManifest(): Manifest? = try {
        BundleJson.decodeFromString<Manifest>(file("manifest.json").readText())
    } catch (e: Exception) {
        null
    }

    fun sizeBytes(): Long = dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }

    /** The library entry for this session, from its manifest (unfinished sessions have no room yet). */
    fun summary(manifest: Manifest? = readManifest()): RoomSummary? {
        manifest ?: return null
        val room = manifest.rooms.firstOrNull()
        return RoomSummary(
            sessionId = id,
            roomIndex = room?.index ?: ROOM_INDEX,
            name = room?.name ?: UNFINISHED_NAME,
            folderPath = dir.absolutePath,
            photos = manifest.photoCount,
            depthFrames = manifest.depthFrameCount ?: 0,
            walls = room?.walls ?: 0,
            coverage = room?.coverage,
            bytes = sizeBytes(),
        )
    }

    companion object {
        val SUBFOLDERS = listOf("rooms", "photos", "depth")
        const val HOUSE_ID = "android"
        const val HOUSE_NAME = "Android"
        /** One session holds one room, so every Android bundle is `--room 0`. */
        const val ROOM_INDEX = 0
        const val UNFINISHED_NAME = "Unfinished scan"

        private val SESSION_NAME = DateTimeFormatter.ofPattern("yyyy-MM-dd HH.mm.ss", Locale.ROOT)

        fun sessionsDir(context: Context): File =
            File(context.filesDir, "Houses/$HOUSE_ID/sessions")

        /** Every session folder, newest first (session ids sort by time). */
        fun all(context: Context): List<ScanBundle> =
            sessionsDir(context).listFiles().orEmpty().filter { it.isDirectory }
                .sortedByDescending { it.name }
                .map { ScanBundle(it) }

        /** A new, empty session folder named after the current local time. Does file I/O: not on the main thread. */
        fun create(context: Context, now: LocalDateTime = LocalDateTime.now()): ScanBundle = create(sessionsDir(context), now)

        fun create(root: File, now: LocalDateTime = LocalDateTime.now()): ScanBundle {
            val base = SESSION_NAME.format(now)
            var dir = File(root, base)
            var n = 2
            while (dir.exists()) dir = File(root, "$base ${n++}")
            for (sub in SUBFOLDERS) {
                if (!File(dir, sub).mkdirs()) throw IOException("Could not create ${dir.name}/$sub")
            }
            return ScanBundle(dir)
        }

        /** The manifest entry for a room JSON: element counts come from the file itself. */
        fun roomRecord(
            room: RoomPlanRoom,
            name: String,
            capturedAt: String = Matrices.iso(),
            coverage: Float? = null,
            photos: Int? = null,
            seconds: Double? = null,
        ) = RoomRecord(
            capturedAt = capturedAt,
            coverage = coverage,
            detailPhotos = photos,
            detailSeconds = seconds,
            doors = room.doors.size,
            file = "rooms/room-$ROOM_INDEX.json",
            index = ROOM_INDEX,
            name = name,
            objects = room.objects.size,
            openings = room.openings.size,
            walls = room.walls.size,
            windows = room.windows.size,
        )
    }
}
