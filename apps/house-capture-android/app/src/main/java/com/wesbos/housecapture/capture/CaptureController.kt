package com.wesbos.housecapture.capture

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.util.Log
import android.view.View
import com.google.ar.core.Camera
import com.google.ar.core.Frame
import com.google.ar.core.ImageMetadata
import com.google.ar.core.LightEstimate
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.google.ar.core.TrackingFailureReason
import com.google.ar.core.TrackingState
import com.wesbos.housecapture.BuildConfig
import com.wesbos.housecapture.bundle.ArcoreDepthInfo
import com.wesbos.housecapture.bundle.CameraConfigInfo
import com.wesbos.housecapture.bundle.CameraState
import com.wesbos.housecapture.bundle.CaptureEvent
import com.wesbos.housecapture.bundle.CaptureInfo
import com.wesbos.housecapture.bundle.DepthFrameRecord
import com.wesbos.housecapture.bundle.DepthStatsInfo
import com.wesbos.housecapture.bundle.Manifest
import com.wesbos.housecapture.bundle.Matrices
import com.wesbos.housecapture.bundle.PhotoRecord
import com.wesbos.housecapture.bundle.RoomPlanRoom
import com.wesbos.housecapture.bundle.RoomRecord
import com.wesbos.housecapture.bundle.ScanBundle
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.acos
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Records one room per session folder while ARCore tracks: auto photos when the view is steady and
 * adds coverage, manual photos on request, raw depth frames when the camera moved, and on finish the
 * plane-derived room JSON, photos.json, depth/frames.json and manifest.json. All of those except the
 * manifest's room entry are also checkpointed every 5 s, so a killed or abandoned scan stays usable.
 *
 * Threads: ARCore frames arrive on the GL thread, which only decides and bulk-copies pixels. Folder
 * creation, coverage scoring, NV21/JPEG, DEFLATE and every file write run on one writer thread,
 * with ≤ 3 photos and ≤ 3 depth frames in flight.
 */
class CaptureController(context: Context) : CaptureContract, ArSessionHost.Listener {
    private val app = context.applicationContext
    private val host = ArSessionHost(app, this)
    private val writer: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "bundle-writer") }

    private val mutableState = MutableStateFlow(CaptureState())
    override val state: StateFlow<CaptureState> = mutableState.asStateFlow()

    @Volatile private var info: ArSessionHost.SessionInfo? = null
    @Volatile private var recording: Recording? = null
    private val manualRequested = AtomicBoolean(false)

    // GL thread
    private var lastUiNanos = 0L
    private var lastPlaneCountNanos = 0L
    private var planeCount = 0

    /** Everything about the room being recorded. */
    private class Recording(val name: String, val createdAt: String) {
        /** the session folder; created on the writer thread, null until then or if that failed */
        @Volatile var bundle: ScanBundle? = null
        val grid = CoverageGrid()
        /** writer thread only */
        val photos = ArrayList<PhotoRecord>()
        /** writer thread only */
        val depth = ArrayList<DepthFrameRecord>()
        val photoCount = AtomicInteger()
        val manualCount = AtomicInteger()
        val depthCount = AtomicInteger()
        val photosInFlight = AtomicInteger()
        val depthInFlight = AtomicInteger()
        val checkpointQueued = AtomicBoolean()
        val topDownQueued = AtomicBoolean()
        /** camera positions (x, y, z) every ~10 cm; guarded by itself */
        val path = ArrayList<FloatArray>()
        /** x, z of every saved photo; guarded by itself */
        val photoPositions = ArrayList<Float>()
        /** guarded by itself */
        val events = ArrayList<CaptureEvent>()
        @Volatile var planes: List<PlaneLayout.PlaneInput> = emptyList()
        /** set on the main thread by finishRoom/release: the GL thread stops recording */
        @Volatile var stopped = false
        /** set on the writer thread when the room is being finalized: later writes are dropped */
        @Volatile var closed = false
        @Volatile var elapsedSeconds = 0.0
        @Volatile var depthWidth: Int? = null
        @Volatile var depthHeight: Int? = null
        @Volatile var thermal = PowerManager.THERMAL_STATUS_NONE
        /** recording segment; bumped on the first frame after a pause (ARCore may relocalize) */
        @Volatile var segment = 0
        /** the AR session was paused while recording (main thread sets, GL thread consumes) */
        @Volatile var resumePending = false
        /** pose of the last photo the writer accepted (auto-photo spacing) */
        @Volatile var lastAcceptedPhotoPose: FloatArray? = null
        @Volatile var topDown: Pair<FloatArray, FloatArray>? = null
        val depthStats = DepthStats()
        /** recorded seconds while tracking was not normal */
        @Volatile var trackingLostSeconds = 0.0

        // GL thread only
        var hadFrames = false
        var lastFrameNanos = 0L
        var lastNanos = 0L
        var lastPose: FloatArray? = null
        var angularRate = 0f
        var linearSpeed = 0f
        var lastPhotoAttemptNanos = Long.MIN_VALUE / 2
        var lastDepthNanos = Long.MIN_VALUE / 2
        var lastDepthPose: FloatArray? = null
        /** poses of recent tracked frames by timestamp: depth images belong to an earlier frame */
        val poseRing = PoseRing()
        /** timestamp of the last raw depth image looked at; an equal one is reprojected, not new */
        var lastDepthImageNanos: Long? = null
        /** seconds of normal tracking since the last written depth frame (or the start) */
        var trackedSinceDepth = 0.0
        var depthCountSeen = 0
        var lastDepthLogNanos = 0L
        var nextDepth = 0
        var lastSnapshotNanos = Long.MIN_VALUE / 2
        var lastCheckpointNanos = 0L
        var lastTracking: String? = null

        fun event(what: String) {
            synchronized(events) {
                events.add(CaptureEvent(Math.round(elapsedSeconds * 10) / 10.0, what))
                if (events.size > MAX_EVENTS) events.removeAt(0)
            }
        }
    }

    /** Everything a photo needs from its ARCore frame, copied on the GL thread. */
    private class PhotoCandidate(
        val pixels: YuvPlanes,
        val pose: FloatArray,
        /** CPU-image intrinsics: fx, fy, cx, cy, and the width they belong to */
        val intrinsics: FloatArray,
        val manual: Boolean,
        val exposure: Double?,
        val blur: Float,
        val camera: CameraState,
        val timestamp: Double,
        val segment: Int,
    )

    // --- CaptureContract ----------------------------------------------------------------------

    override fun createPreviewView(context: Context): View = host.createView(context)

    override fun onResume() = host.resume()

    override fun onPause() {
        recording?.takeIf { !it.stopped }?.let { rec ->
            rec.resumePending = true
            rec.event("pause")
        }
        host.pause()
    }

    /** The session folder is created on the writer thread; one session holds one room (index 0). */
    override fun startRoom(name: String) {
        if (recording != null) return
        val rec = Recording(name.trim().ifEmpty { "Room" }, Matrices.iso())
        manualRequested.set(false)
        recording = rec
        mutableState.update {
            CaptureState(
                // a session error before the room started stays FAILED until frames arrive (publish)
                phase = if (it.phase == Phase.FAILED) Phase.FAILED else Phase.STARTING,
                tracking = it.tracking,
                trackingWarning = it.trackingWarning,
                depthAvailable = info?.depthEnabled == true,
                planes = it.planes,
                error = it.error,
            )
        }
        writer.execute {
            try {
                rec.bundle = ScanBundle.create(app)
                checkpoint(rec)
            } catch (e: Exception) {
                Log.e(TAG, "Could not start a room", e)
                rec.stopped = true
                rec.closed = true
                if (recording === rec) recording = null
                mutableState.update { it.copy(phase = Phase.FAILED, error = "Could not start a scan: ${e.message}") }
            }
        }
    }

    override fun takePhoto() {
        if (recording != null) manualRequested.set(true)
    }

    override fun finishRoom() {
        val rec = recording ?: return
        rec.stopped = true
        recording = null
        mutableState.update { it.copy(phase = Phase.FINISHING) }
        // Single writer thread: every photo/depth write queued before this one is already done.
        writer.execute { finalize(rec) }
    }

    /**
     * Releases ARCore. A room still recording stops without being finished: queued writes complete
     * and everything is checkpointed (the library lists it as an unfinished scan, and sharing
     * completes it). A scan that recorded nothing is deleted instead of leaving an empty folder.
     */
    override fun release() {
        recording?.let { rec ->
            rec.stopped = true
            recording = null
            writer.execute {
                rec.closed = true
                val bundle = rec.bundle ?: return@execute
                if (rec.photos.isEmpty() && rec.depth.isEmpty()) bundle.dir.deleteRecursively() else checkpoint(rec)
            }
        }
        host.release()
        writer.shutdown()
    }

    // --- ArSessionHost.Listener ---------------------------------------------------------------

    override fun onSessionConfigured(info: ArSessionHost.SessionInfo) {
        this.info = info
        mutableState.update { it.copy(depthAvailable = info.depthEnabled, error = null) }
    }

    /** Before any frame was recorded, a session error means the scan can't start: FAILED. */
    override fun onError(message: String) {
        mutableState.update {
            if (it.phase == Phase.IDLE || it.phase == Phase.STARTING) it.copy(phase = Phase.FAILED, error = message)
            else it.copy(error = message)
        }
    }

    override fun onFrame(session: Session, frame: Frame) {
        val now = frame.timestamp
        if (now == 0L) return
        val camera = frame.camera
        val tracking = trackingOf(camera)
        val rec = recording?.takeIf { !it.stopped }

        if (rec != null) {
            if (rec.resumePending) {
                // The AR session was paused: ARCore may have relocalized, so later poses go into a
                // new segment, and motion/spacing state starts over.
                rec.resumePending = false
                if (rec.hadFrames) rec.segment++
                rec.event("resume")
                rec.lastFrameNanos = 0L
                rec.lastPose = null
                rec.lastDepthPose = null
                rec.lastAcceptedPhotoPose = null
                rec.poseRing.clear()
                rec.lastDepthImageNanos = null
            }
            // recorded time only: frame gaps over half a second (paused, backgrounded) don't count
            val dt = (now - rec.lastFrameNanos) / 1e9
            if (rec.lastFrameNanos != 0L && dt > 0 && dt < 0.5) {
                rec.elapsedSeconds += dt
                if (camera.trackingState != TrackingState.TRACKING) rec.trackingLostSeconds += dt
                else rec.trackedSinceDepth += dt
            }
            val written = rec.depthCount.get()
            if (written != rec.depthCountSeen) {
                rec.depthCountSeen = written
                rec.trackedSinceDepth = 0.0
            }
            if (now - rec.lastDepthLogNanos >= SECOND && info?.depthEnabled == true) {
                rec.lastDepthLogNanos = now
                Log.i(TAG, "depth @${"%.1f".format(Locale.ROOT, rec.elapsedSeconds)}s: ${rec.depthStats.summary()}")
            }
            rec.lastFrameNanos = now
            rec.hadFrames = true
            if (tracking.first != rec.lastTracking) {
                rec.lastTracking = tracking.first
                rec.event("tracking:${tracking.first}")
            }
        }
        if (now - lastPlaneCountNanos >= SECOND && rec == null) {
            lastPlaneCountNanos = now
            planeCount = trackedPlanes(session).size
        }
        if (rec == null || camera.trackingState != TrackingState.TRACKING) {
            publish(now, tracking, rec)
            return
        }

        val pose = poseMatrix(camera.pose)
        rec.poseRing.add(now, pose)
        updateMotion(rec, pose, now)
        considerDepth(rec, frame, camera, pose, now)
        considerPhoto(rec, frame, camera, pose, now)

        if (now - rec.lastSnapshotNanos >= SECOND) {
            rec.lastSnapshotNanos = now
            val planes = trackedPlanes(session).mapNotNull { planeInput(it) }
            rec.planes = planes
            planeCount = planes.size
            // the grid is walked on the writer thread; show the latest finished picture
            if (rec.topDownQueued.compareAndSet(false, true)) {
                writer.execute {
                    rec.topDown = rec.grid.topDown()
                    rec.topDownQueued.set(false)
                }
            }
            val (seen, photographed) = rec.topDown ?: Pair(FloatArray(0), FloatArray(0))
            val snapshot = CoverageSnapshot(
                seen = seen,
                photographed = photographed,
                planes = planes.map { PlaneLayout.footprint(it) },
                cameraX = pose[12],
                cameraZ = pose[14],
                headingRadians = atan2(-pose[10], -pose[8]),
                photoPositions = synchronized(rec.photoPositions) { rec.photoPositions.toFloatArray() },
                path = synchronized(rec.path) {
                    FloatArray(rec.path.size * 2) { i -> rec.path[i / 2][if (i % 2 == 0) 0 else 2] }
                },
            )
            publish(now, tracking, rec, snapshot, force = true)
        } else {
            publish(now, tracking, rec)
        }

        if (now - rec.lastCheckpointNanos >= 5 * SECOND && rec.checkpointQueued.compareAndSet(false, true)) {
            rec.lastCheckpointNanos = now
            rec.thermal = maxOf(rec.thermal, thermalStatus())
            writer.execute {
                rec.checkpointQueued.set(false)
                if (!rec.closed) checkpoint(rec)
            }
        }
    }

    // --- per-frame policies (GL thread) -------------------------------------------------------

    private fun updateMotion(rec: Recording, pose: FloatArray, now: Long) {
        val last = rec.lastPose
        val dt = (now - rec.lastNanos) / 1e9f
        if (last != null && dt > 0f && dt < 0.5f) {
            rec.linearSpeed = 0.7f * rec.linearSpeed + 0.3f * distance(last, pose) / dt
            rec.angularRate = 0.7f * rec.angularRate + 0.3f * angle(last, pose) / dt
        }
        rec.lastPose = pose
        rec.lastNanos = now
        synchronized(rec.path) {
            val tail = rec.path.lastOrNull()
            if (tail == null || distance3(tail, pose[12], pose[13], pose[14]) > 0.1f) {
                rec.path.add(floatArrayOf(pose[12], pose[13], pose[14]))
            }
        }
    }

    /**
     * ≤ 5/s, only after moving 4 cm or turning 0.06 rad, and only a depth image ARCore computed anew
     * (its timestamp differs from the last one seen). Raw depth lags the camera, so the record takes
     * the pose of the frame with the depth's timestamp from [PoseRing] (or the nearest within 50 ms,
     * flagged), and the color image only when the depth belongs to the current frame. Every outcome
     * is counted in [DepthStats].
     */
    private fun considerDepth(rec: Recording, frame: Frame, camera: Camera, pose: FloatArray, now: Long) {
        if (info?.depthEnabled != true) return
        if (rec.depthInFlight.get() >= MAX_IN_FLIGHT) {
            rec.depthStats.count(DepthStats.BUSY)
            return
        }
        if (now - rec.lastDepthNanos < SECOND / 5) return
        rec.lastDepthPose?.let { if (distance(it, pose) <= 0.04f && angle(it, pose) <= 0.06f) return }

        val acquired = acquireDepth(rec, frame, now) ?: return
        val (copy, take) = acquired
        val match = take.match
        val depthPose = match.pose
        val rgb = if (take.sameFrame) acquireImage(frame) else null
        rec.lastDepthNanos = now
        rec.lastDepthPose = depthPose
        rec.depthWidth = copy.width
        rec.depthHeight = copy.height

        // Depth is in the GPU texture's aspect: scale the texture intrinsics to the depth map.
        val texture = camera.textureIntrinsics
        val (tfx, tfy) = texture.focalLength
        val (tcx, tcy) = texture.principalPoint
        val (tw, th) = texture.imageDimensions
        val sx = copy.width.toFloat() / tw
        val sy = copy.height.toFloat() / th
        val view = CoverageGrid.View(depthPose, tfx * sx, tfy * sy, tcx * sx, tcy * sy, copy.width, copy.height)
        val imageK = imageIntrinsics(camera)
        val depthSeconds = match.frameNanos / 1e9

        val name = String.format(Locale.ROOT, "%05d", rec.nextDepth++)
        val base = DepthFrameRecord(
            arcore = ArcoreDepthInfo(
                depthTimestamp = (match.frameNanos + match.offsetNanos) / 1e9,
                frameTimestamp = now / 1e9,
                poseOffsetMs = if (match.source == PoseSource.NEAREST) match.offsetNanos / 1e6 else null,
                poseSource = match.source.key,
                textureHeight = th,
                textureIntrinsics = Matrices.intrinsics(tfx, tfy, tcx, tcy),
                textureWidth = tw,
            ),
            // exposure/ISO belong to the current frame: only kept when the depth is that frame's
            camera = if (take.sameFrame) cameraState(frame) else null,
            confidence = "depth/$name.conf",
            file = "depth/$name.f16z",
            height = copy.height,
            intrinsics = Matrices.intrinsics(tfx * sx, tfy * sy, tcx * sx, tcy * sy),
            room = ScanBundle.ROOM_INDEX,
            segment = rec.segment,
            timestamp = depthSeconds,
            transform = depthPose.toList(),
            width = copy.width,
        )
        val poseKey = "pose:${match.source.key}"
        rec.depthInFlight.incrementAndGet()
        writer.execute {
            try {
                val bundle = rec.bundle
                if (!rec.closed && bundle != null) {
                    DepthWriter.write(copy, bundle.file(base.file), bundle.file(base.confidence))
                    var record = base
                    if (rgb != null) {
                        val small = rgb.toNv21(maxWidth = RGB_WIDTH)
                        val path = "depth/$name.jpg"
                        small.writeJpeg(bundle.file(path), quality = 80)
                        record = base.copy(rgb = path, rgbIntrinsics = scaledIntrinsics(imageK, small.width))
                    }
                    rec.grid.addDepth(copy, view)
                    rec.depth.add(record)
                    rec.depthCount.incrementAndGet()
                    rec.depthStats.count(DepthStats.WRITTEN)
                    rec.depthStats.count(poseKey)
                    if (rec.depthStats.firstWrittenSeconds == null) {
                        rec.depthStats.firstWrittenSeconds = Math.round(rec.elapsedSeconds * 10) / 10.0
                    }
                }
            } catch (e: Exception) {
                rec.depthStats.count(DepthStats.exceptionKey("writeFailed", e))
                Log.w(TAG, "Depth frame ${base.file} not written", e)
            } finally {
                rec.depthInFlight.decrementAndGet()
            }
        }
    }

    /**
     * Manual photos whenever asked (≥ 0.3 s apart). Auto photo candidates when steady (< 0.6 rad/s,
     * predicted blur ≤ 6 px), ≥ 0.7 s apart, after moving 25 cm or turning 20° from the last saved
     * photo; the writer keeps a candidate only if it adds coverage ([accept]).
     */
    private fun considerPhoto(rec: Recording, frame: Frame, camera: Camera, pose: FloatArray, now: Long) {
        if (rec.photosInFlight.get() >= MAX_IN_FLIGHT) return
        val since = (now - rec.lastPhotoAttemptNanos) / 1e9
        val exposure = exposureSeconds(frame)
        val (fx) = camera.imageIntrinsics.focalLength
        val blur = fx * (exposure ?: FALLBACK_EXPOSURE).toFloat() * (rec.angularRate + rec.linearSpeed / 2)

        if (manualRequested.get()) {
            if (since >= 0.3 && submitPhoto(rec, frame, camera, pose, now, manual = true, exposure, blur)) {
                manualRequested.set(false)
            }
            return
        }
        if (since < 0.7 || rec.angularRate >= 0.6f || blur > 6f) return
        rec.lastAcceptedPhotoPose?.let { if (distance(it, pose) < 0.25f && angle(it, pose) < MIN_TURN) return }
        submitPhoto(rec, frame, camera, pose, now, manual = false, exposure, blur)
    }

    private fun submitPhoto(
        rec: Recording, frame: Frame, camera: Camera, pose: FloatArray, now: Long,
        manual: Boolean, exposure: Double?, blur: Float,
    ): Boolean {
        val pixels = acquireImage(frame) ?: return false
        rec.lastPhotoAttemptNanos = now
        val candidate = PhotoCandidate(
            pixels, pose, imageIntrinsics(camera), manual, exposure, blur,
            cameraState(frame), now / 1e9, rec.segment,
        )
        rec.photosInFlight.incrementAndGet()
        writer.execute {
            try {
                if (!rec.closed) accept(rec, candidate)
            } catch (e: Exception) {
                Log.w(TAG, "Photo not written", e)
            } finally {
                rec.photosInFlight.decrementAndGet()
            }
        }
        return true
    }

    // --- writer thread ------------------------------------------------------------------------

    /** Scores an auto candidate against the coverage grid; saves it (and marks its cells) if it helps. */
    private fun accept(rec: Recording, c: PhotoCandidate) {
        val bundle = rec.bundle ?: return
        val image = c.pixels.toNv21()
        val k = image.width / c.intrinsics[4]
        val view = CoverageGrid.View(
            c.pose, c.intrinsics[0] * k, c.intrinsics[1] * k, c.intrinsics[2] * k, c.intrinsics[3] * k,
            image.width, image.height,
        )
        if (!c.manual && rec.grid.seenCount >= 50) {
            // Until depth has seen something there is no coverage to gain; motion alone decides.
            val gain = rec.grid.gain(view)
            if (gain < 40 && (gain == 0 || gain < 0.15f * rec.grid.unphotographed)) return
        }
        val file = String.format(Locale.ROOT, "photos/%04d.jpg", rec.photos.size)
        PhotoWriter.write(image, bundle.file(file))
        rec.grid.markPhotographed(view)
        rec.photos.add(
            PhotoRecord(
                blurPixels = c.blur,
                camera = c.camera,
                exposure = c.exposure,
                file = file,
                height = image.height,
                intrinsics = scaledIntrinsics(c.intrinsics, image.width),
                manual = c.manual,
                room = ScanBundle.ROOM_INDEX,
                segment = c.segment,
                timestamp = c.timestamp,
                transform = c.pose.toList(),
                width = image.width,
            ),
        )
        rec.lastAcceptedPhotoPose = c.pose
        synchronized(rec.photoPositions) {
            rec.photoPositions.add(c.pose[12])
            rec.photoPositions.add(c.pose[14])
        }
        rec.photoCount.incrementAndGet()
        if (c.manual) rec.manualCount.incrementAndGet()
    }

    private fun layout(rec: Recording): RoomPlanRoom =
        PlaneLayout.build(rec.planes, synchronized(rec.path) { rec.path.toList() })

    /** Crash-safe state of an unfinished room: photos, depth frames, plane layout, manifest without the room entry. */
    private fun checkpoint(rec: Recording) {
        val bundle = rec.bundle ?: return
        try {
            bundle.writePhotos(rec.photos)
            if (depthRecorded(rec)) bundle.writeDepthFrames(rec.depth)
            bundle.writeRoom(ScanBundle.ROOM_INDEX, layout(rec))
            bundle.writeManifest(manifest(rec, emptyList(), endedAt = null))
        } catch (e: Exception) {
            Log.w(TAG, "Checkpoint failed", e)
        }
    }

    private fun finalize(rec: Recording) {
        rec.closed = true
        try {
            val bundle = checkNotNull(rec.bundle) { "the session folder was never created" }
            val room = layout(rec)
            bundle.writeRoom(ScanBundle.ROOM_INDEX, room)
            bundle.writePhotos(rec.photos)
            if (depthRecorded(rec)) bundle.writeDepthFrames(rec.depth)
            val record = ScanBundle.roomRecord(
                room, rec.name,
                coverage = rec.grid.coverage,
                photos = rec.photos.size,
                seconds = Math.round(rec.elapsedSeconds * 10) / 10.0,
            )
            val manifest = manifest(rec, listOf(record), endedAt = Matrices.iso())
            bundle.writeManifest(manifest)
            val summary = bundle.summary(manifest)
            mutableState.update { it.copy(phase = Phase.SAVED, lastSaved = summary) }
        } catch (e: Exception) {
            Log.e(TAG, "Could not save the room", e)
            mutableState.update { it.copy(phase = Phase.FAILED, error = "Could not save the room: ${e.message}") }
        }
    }

    private fun depthRecorded(rec: Recording) = info?.depthEnabled == true || rec.depth.isNotEmpty()

    private fun manifest(rec: Recording, rooms: List<RoomRecord>, endedAt: String?): Manifest {
        val info = info
        val depth = depthRecorded(rec)
        val bundle = checkNotNull(rec.bundle)
        return Manifest(
            capture = info?.let {
                CaptureInfo(
                    arcoreSdk = BuildConfig.ARCORE_SDK,
                    cameraConfig = CameraConfigInfo(
                        fpsMax = it.fpsMax, fpsMin = it.fpsMin,
                        imageHeight = it.imageHeight, imageWidth = it.imageWidth,
                        textureHeight = it.textureHeight, textureWidth = it.textureWidth,
                    ),
                    depthHeight = rec.depthHeight,
                    depthMode = if (it.depthEnabled) "RAW_DEPTH_ONLY" else "DISABLED",
                    depthStats = if (it.depthEnabled) {
                        DepthStatsInfo(
                            firstWrittenSeconds = rec.depthStats.firstWrittenSeconds,
                            lastUnmatchedOffsetMs = rec.depthStats.lastUnmatchedOffsetMs,
                            outcomes = rec.depthStats.snapshot(),
                        )
                    } else {
                        null
                    },
                    depthWidth = rec.depthWidth,
                    events = synchronized(rec.events) { rec.events.toList() },
                    segments = rec.segment + 1,
                    thermal = THERMAL_NAMES.getOrElse(rec.thermal) { "unknown" },
                    trackingLostSeconds = Math.round(rec.trackingLostSeconds * 10) / 10.0,
                )
            },
            createdAt = rec.createdAt,
            depthFrameCount = if (depth) rec.depth.size else null,
            depthFrames = if (depth) "depth/frames.json" else null,
            device = Build.MODEL,
            endedAt = endedAt,
            house = ScanBundle.HOUSE_ID,
            houseName = ScanBundle.HOUSE_NAME,
            photoCount = rec.photos.size,
            rooms = rooms,
            session = bundle.id,
            systemVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
        )
    }

    // --- helpers ------------------------------------------------------------------------------

    private fun publish(now: Long, tracking: Pair<String, String?>, rec: Recording?, snapshot: CoverageSnapshot? = null, force: Boolean = false) {
        if (!force && now - lastUiNanos < SECOND / 4) return
        lastUiNanos = now
        mutableState.update {
            // frames are arriving for an active room: a start-up error has cleared
            val running = rec != null && (it.phase == Phase.STARTING || it.phase == Phase.FAILED)
            it.copy(
                phase = if (running) Phase.SCANNING else it.phase,
                error = if (running) null else it.error,
                tracking = tracking.first,
                trackingWarning = tracking.second,
                photos = rec?.photoCount?.get() ?: it.photos,
                manualPhotos = rec?.manualCount?.get() ?: it.manualPhotos,
                depthFrames = rec?.depthCount?.get() ?: it.depthFrames,
                depthProblem = if (rec != null) DepthStats.describe(rec.depthStats.topProblem()) else it.depthProblem,
                depthStalled = rec != null && info?.depthEnabled == true && rec.trackedSinceDepth > DEPTH_STALL_SECONDS,
                trackingLostSeconds = rec?.trackingLostSeconds?.toInt() ?: it.trackingLostSeconds,
                planes = planeCount,
                coverage = rec?.grid?.coverage ?: it.coverage,
                elapsedSeconds = rec?.elapsedSeconds?.toInt() ?: it.elapsedSeconds,
                snapshot = snapshot ?: it.snapshot,
            )
        }
    }

    private fun trackingOf(camera: Camera): Pair<String, String?> = when (camera.trackingState) {
        TrackingState.TRACKING -> "normal" to null
        TrackingState.PAUSED -> {
            val reason = camera.trackingFailureReason
            "limited:${reason.name}" to when (reason) {
                TrackingFailureReason.INSUFFICIENT_LIGHT -> "Too dark: turn on more lights"
                TrackingFailureReason.EXCESSIVE_MOTION -> "Move slower"
                TrackingFailureReason.INSUFFICIENT_FEATURES -> "Point at something with texture (not a blank wall)"
                TrackingFailureReason.CAMERA_UNAVAILABLE -> "Camera unavailable: close other camera apps"
                else -> "Move the phone slowly from side to side to start tracking"
            }
        }
        else -> "notAvailable" to "Tracking lost: go back to where it last worked and move slowly"
    }

    /**
     * Raw depth + confidence copied out of ARCore when the depth image is new and a pose for its
     * timestamp is known; otherwise null, with the reason counted in the recording's [DepthStats].
     */
    private fun acquireDepth(rec: Recording, frame: Frame, frameNanos: Long): Pair<DepthCopy, DepthDecision.Take>? {
        val stats = rec.depthStats
        val depthImage = try {
            frame.acquireRawDepthImage16Bits()
        } catch (e: Exception) {
            // NotYetAvailable (too little motion or too early), NotTracking, ResourceExhausted, …
            stats.count(DepthStats.exceptionKey("acquire", e))
            return null
        }
        try {
            val depthNanos = depthImage.timestamp
            val decision = DepthPairing.decide(depthNanos, rec.lastDepthImageNanos, frameNanos, rec.poseRing)
            rec.lastDepthImageNanos = depthNanos
            if (decision is DepthDecision.Stale) {
                stats.count(DepthStats.STALE)
                return null
            }
            if (decision is DepthDecision.NoPose) {
                stats.count(DepthStats.NO_POSE)
                stats.lastUnmatchedOffsetMs = decision.offsetNanos?.let { it / 1e6 }
                return null
            }
            val take = decision as DepthDecision.Take
            val confidenceImage = try {
                frame.acquireRawDepthConfidenceImage()
            } catch (e: Exception) {
                stats.count(DepthStats.exceptionKey("confidence", e))
                return null
            }
            try {
                return Pair(DepthCopy.of(depthImage, confidenceImage), take)
            } catch (e: Exception) {
                stats.count(DepthStats.exceptionKey("copy", e))
                return null
            } finally {
                confidenceImage.close()
            }
        } finally {
            depthImage.close()
        }
    }

    /** The CPU camera image's planes (bulk copy), or null when ARCore has none for this frame. */
    private fun acquireImage(frame: Frame): YuvPlanes? {
        val image = try {
            frame.acquireCameraImage()
        } catch (e: Exception) {
            return null
        }
        try {
            return YuvPlanes.copy(image)
        } finally {
            image.close()
        }
    }

    private fun trackedPlanes(session: Session): List<Plane> =
        session.getAllTrackables(Plane::class.java).filter { it.trackingState == TrackingState.TRACKING && it.subsumedBy == null }

    private fun planeInput(plane: Plane): PlaneLayout.PlaneInput? {
        val kind = when (plane.type) {
            Plane.Type.HORIZONTAL_UPWARD_FACING -> PlaneLayout.Kind.FLOOR
            Plane.Type.HORIZONTAL_DOWNWARD_FACING -> PlaneLayout.Kind.CEILING
            Plane.Type.VERTICAL -> PlaneLayout.Kind.WALL
            else -> return null
        }
        val buffer = plane.polygon.duplicate()
        buffer.rewind()
        val polygon = FloatArray(buffer.remaining())
        buffer.get(polygon)
        return PlaneLayout.PlaneInput(kind, poseMatrix(plane.centerPose), plane.extentX, plane.extentZ, polygon)
    }

    /** fx, fy, cx, cy of the CPU image, plus the image width they belong to. */
    private fun imageIntrinsics(camera: Camera): FloatArray {
        val k = camera.imageIntrinsics
        val (fx, fy) = k.focalLength
        val (cx, cy) = k.principalPoint
        return floatArrayOf(fx, fy, cx, cy, k.imageDimensions[0].toFloat())
    }

    private fun exposureSeconds(frame: Frame): Double? = try {
        frame.imageMetadata.getLong(ImageMetadata.SENSOR_EXPOSURE_TIME) / 1e9
    } catch (e: Exception) {
        null
    }

    private fun cameraState(frame: Frame): CameraState {
        val iso = try {
            frame.imageMetadata.getInt(ImageMetadata.SENSOR_SENSITIVITY).toFloat()
        } catch (e: Exception) {
            null
        }
        val light = frame.lightEstimate
        return CameraState(
            ambientIntensity = if (light.state == LightEstimate.State.VALID) light.pixelIntensity * 1000f else null,
            iso = iso,
            shutter = exposureSeconds(frame),
        )
    }

    private fun thermalStatus(): Int =
        app.getSystemService(PowerManager::class.java)?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE

    private companion object {
        const val TAG = "CaptureController"
        const val SECOND = 1_000_000_000L
        const val MAX_IN_FLIGHT = 3
        const val MAX_EVENTS = 400
        const val RGB_WIDTH = 640
        const val FALLBACK_EXPOSURE = 1.0 / 60
        const val MIN_TURN = 0.349f // 20°
        val THERMAL_NAMES = listOf("none", "light", "moderate", "severe", "critical", "emergency", "shutdown")

        fun poseMatrix(pose: Pose): FloatArray = Matrices.pose(pose.tx(), pose.ty(), pose.tz(), pose.qx(), pose.qy(), pose.qz(), pose.qw())

        /** Column-major 3×3 for an image [width] pixels wide, from [imageIntrinsics]' fx, fy, cx, cy, width. */
        fun scaledIntrinsics(k: FloatArray, width: Int): List<Float> {
            val s = width / k[4]
            return Matrices.intrinsics(k[0] * s, k[1] * s, k[2] * s, k[3] * s)
        }

        fun distance(a: FloatArray, b: FloatArray) = distance3(a, b[12], b[13], b[14], offset = 12)

        fun distance3(a: FloatArray, x: Float, y: Float, z: Float, offset: Int = 0): Float {
            val dx = a[offset] - x; val dy = a[offset + 1] - y; val dz = a[offset + 2] - z
            return sqrt(dx * dx + dy * dy + dz * dz)
        }

        /** Angle between the two poses' viewing axes (column 2). */
        fun angle(a: FloatArray, b: FloatArray): Float =
            acos((a[8] * b[8] + a[9] * b[9] + a[10] * b[10]).coerceIn(-1f, 1f))
    }
}
