package com.wesbos.housecapture.bundle

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

// The house-capture/5 bundle, mirroring the iOS app's Codable types (ScanBundle.swift).
// Properties are declared alphabetically so the JSON reads like Swift's `.sortedKeys` output.
// Keys the iOS app doesn't know (platform, capture, arcore) are ignored by Swift's decoder.

const val BUNDLE_FORMAT = "house-capture/5"

@OptIn(ExperimentalSerializationApi::class)
val BundleJson = Json {
    prettyPrint = true
    encodeDefaults = true
    explicitNulls = false
    ignoreUnknownKeys = true
}

@Serializable
data class Manifest(
    val alignment: Alignment? = Alignment(),
    /** Android only: how this bundle was captured (ARCore, camera config, depth mode, layout source). */
    val capture: CaptureInfo? = null,
    val coordinateSystem: String = COORDINATE_SYSTEM,
    val createdAt: String,
    val depthFrameCount: Int? = null,
    val depthFrames: String? = null,
    val device: String,
    val endedAt: String? = null,
    val format: String = BUNDLE_FORMAT,
    val house: String,
    val houseName: String? = null,
    val mesh: MeshRecord? = null,
    val photoCount: Int = 0,
    val photos: String = "photos/photos.json",
    /** Android only: "android". iOS bundles have no platform key. */
    val platform: String? = "android",
    val rooms: List<RoomRecord> = emptyList(),
    val sceneReconstruction: String? = "none (ARCore)",
    val session: String,
    val structure: String? = null,
    val systemVersion: String,
    val zone: String = "android",
) {
    companion object {
        const val COORDINATE_SYSTEM =
            "ARCore world space of this capture session: meters, +Y up (gravity), right-handed. " +
                "Rooms and photo and depth poses all share it."
    }
}

@Serializable
data class Alignment(
    val method: String = "first",
    val note: String? = null,
    val residualMeters: Float? = null,
    val toZone: List<Float> = Matrices.IDENTITY,
)

@Serializable
data class CaptureInfo(
    val arcoreSdk: String,
    val cameraConfig: CameraConfigInfo,
    val depthHeight: Int? = null,
    /** "RAW_DEPTH_ONLY" or "DISABLED" */
    val depthMode: String,
    /** every outcome of trying to record a depth frame (see DepthStats), so zero depth is explained */
    val depthStats: DepthStatsInfo? = null,
    val depthWidth: Int? = null,
    val engine: String = "ARCore",
    /** pauses, resumes and tracking changes while recording (capped) */
    val events: List<CaptureEvent>? = null,
    /** "arcore-planes" from the app; android_synthesize_room.py rewrites it */
    val layoutSource: String = "arcore-planes",
    /**
     * recording segments: a new one starts after every pause/resume of the AR session, which may
     * relocalize ARCore's world. Photo and depth records carry their segment.
     */
    val segments: Int? = null,
    val synthesized: Boolean = false,
    /** worst PowerManager thermal status seen while recording */
    val thermal: String? = null,
    /** recorded seconds while ARCore tracking was not normal */
    val trackingLostSeconds: Double? = null,
)

@Serializable
data class DepthStatsInfo(
    /** recorded seconds when the first depth frame was written */
    val firstWrittenSeconds: Double? = null,
    /** depth timestamp minus the nearest camera frame's, for the last depth image with no pose (ms) */
    val lastUnmatchedOffsetMs: Double? = null,
    /** outcome → count: "written", "stale", "noPose", "acquire:<Exception>", "pose:exact", … */
    val outcomes: Map<String, Int> = emptyMap(),
)

@Serializable
data class CaptureEvent(
    /** seconds of recording (time spent paused is not counted) */
    val t: Double,
    /** "pause", "resume", "tracking:<state>" */
    val what: String,
)

@Serializable
data class CameraConfigInfo(
    val fpsMax: Int,
    val fpsMin: Int,
    val imageHeight: Int,
    val imageWidth: Int,
    val textureHeight: Int,
    val textureWidth: Int,
)

@Serializable
data class RoomRecord(
    val capturedAt: String,
    /** photographed fraction of the cells depth has seen (0–1) */
    val coverage: Float? = null,
    val detailPhotos: Int? = null,
    val detailSeconds: Double? = null,
    val doors: Int = 0,
    val file: String,
    val index: Int,
    val mesh: MeshRecord? = null,
    val name: String,
    val objects: Int = 0,
    val openings: Int = 0,
    /** RoomPlan's Quick Look export on iOS; there is none on Android */
    val usdz: String = "",
    val walls: Int = 0,
    val windows: Int = 0,
)

@Serializable
data class MeshRecord(
    val anchors: Int,
    val faces: Int,
    val file: String,
    val vertices: Int,
)

/**
 * One reference photo. The JPEG's pixels are the raw camera image in sensor orientation
 * (landscape); `intrinsics` match those pixels. EXIF orientation 6 shows it upright.
 */
@Serializable
data class PhotoRecord(
    val blurPixels: Float? = null,
    val camera: CameraState? = null,
    /** shutter time in seconds */
    val exposure: Double? = null,
    val file: String,
    val height: Int,
    val highRes: Boolean? = false,
    /** column-major 3×3: fx, 0, 0, 0, fy, 0, cx, cy, 1 */
    val intrinsics: List<Float>,
    val manual: Boolean,
    val pass: String? = "scan",
    val room: Int,
    /** Android only: recording segment (see CaptureInfo.segments) */
    val segment: Int? = null,
    val timestamp: Double,
    val tracking: String = "normal",
    /** camera-to-world, column-major 4×4; camera looks down −Z, +Y up, +X right (sensor orientation) */
    val transform: List<Float>,
    val width: Int,
)

@Serializable
data class CameraState(
    /** ARCore pixel intensity × 1000 (rough stand-in for ARKit's ~1000 = neutral) */
    val ambientIntensity: Float? = null,
    val colorTemperature: Float? = null,
    val exposureOffset: Float? = null,
    val iso: Float? = null,
    val shutter: Double? = null,
    val whiteBalance: List<Float>? = null,
    val whiteBalanceLocked: Boolean? = null,
)

@Serializable
data class DepthFrameRecord(
    /** Android only: the raw values the depth intrinsics were derived from */
    val arcore: ArcoreDepthInfo? = null,
    val camera: CameraState? = null,
    /** UInt8 0–2 */
    val confidence: String,
    /** Float16 meters, row-major, raw DEFLATE */
    val file: String,
    val height: Int,
    /** column-major 3×3, scaled to the depth map */
    val intrinsics: List<Float>,
    val rgb: String? = null,
    val rgbIntrinsics: List<Float>? = null,
    val room: Int,
    /** Android only: recording segment (see CaptureInfo.segments) */
    val segment: Int? = null,
    val timestamp: Double,
    val transform: List<Float>,
    val width: Int,
)

@Serializable
data class ArcoreDepthInfo(
    /** the depth image's own timestamp (seconds); the record's pose is the camera frame's at this time */
    val depthTimestamp: Double,
    /** timestamp of the camera frame being processed when the depth was read (seconds) */
    val frameTimestamp: Double? = null,
    /** "nearest" only: depth timestamp minus the paired pose's frame timestamp (ms) */
    val poseOffsetMs: Double? = null,
    /** "exact": the pose of the frame with the depth's timestamp; "nearest": the closest frame within 50 ms */
    val poseSource: String? = null,
    val textureHeight: Int,
    val textureIntrinsics: List<Float>,
    val textureWidth: Int,
)

// RoomPlan CapturedRoom JSON, as far as the skill's scripts read it.

@Serializable
data class RoomPlanRoom(
    val doors: List<RoomPlanElement> = emptyList(),
    val floors: List<RoomPlanElement> = emptyList(),
    val objects: List<RoomPlanElement> = emptyList(),
    val openings: List<RoomPlanElement> = emptyList(),
    val sections: List<JsonElement> = emptyList(),
    val story: Int = 0,
    val version: Int = 2,
    val walls: List<RoomPlanElement> = emptyList(),
    val windows: List<RoomPlanElement> = emptyList(),
)

@Serializable
data class RoomPlanElement(
    /** single-key object, e.g. {"wall": {}} */
    val category: JsonObject,
    val completedEdges: List<JsonElement> = emptyList(),
    /** {"high": {}}, {"medium": {}} or {"low": {}} */
    val confidence: JsonObject,
    val curve: JsonElement = JsonNull,
    /** width, height, depth (0 for walls and floors) */
    val dimensions: List<Float>,
    val identifier: String,
    val parentIdentifier: String? = null,
    val polygonCorners: List<List<Float>> = emptyList(),
    val story: Int = 0,
    /** column-major, centered on the element; local x along a wall, y up, z the wall normal */
    val transform: List<Float>,
) {
    companion object {
        /** {"<key>": {}} as RoomPlan encodes enum cases without payload */
        fun tag(key: String): JsonObject = buildJsonObject { put(key, JsonObject(emptyMap())) }
    }
}
