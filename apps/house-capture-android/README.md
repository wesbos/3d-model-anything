# 3D Model Anything for Android

Android app that scans a room into a `house-capture/5` bundle the three.js rebuild pipeline
(`scan-to-threejs` skill) can use. Per room it records, on one ARCore session:

- **Posed photos**: frames taken automatically where they add the most coverage and only while the
  phone is steady, plus a shutter for close-ups. Exact camera pose + intrinsics per photo.
- **Depth frames**: ARCore raw depth (Float16 meters) + confidence, up to 5/s, each with the camera
  pose of the frame the depth was computed for (see [Depth pairing](#depth-pairing)), and a 640-wide
  color JPEG when that frame is the current one.
- **Planes**: horizontal and vertical ARCore planes, turned into a minimal RoomPlan-shaped
  `rooms/room-N.json` so a fresh export already converts.

There is no LiDAR, scene mesh or RoomPlan on Android. The app's walls are plane-derived and
low/medium confidence; doors, windows, openings and furniture boxes are not detected on the phone.
`android_synthesize_room.py` in the skill builds them offline from the depth frames (see
[Android bundles](../../.agents/skills/scan-to-threejs/references/house-capture.md#android-bundles)).

Requires an Android 10+ (API 29) phone with ARCore and the
[Depth API](https://developers.google.com/ar/devices). Developed for the Pixel 10 Pro. Without depth
support the app still records photos and planes, but the offline synthesizer has nothing to work with.

## Build

The `Build Android app` workflow (`.github/workflows/android.yml`) runs the unit tests and
`assembleDebug` on every push that touches this directory. Download the
`house-capture-android-debug` artifact from the run and install `app-debug.apk`
(`adb install app-debug.apk`).

Locally, open `apps/house-capture-android` in Android Studio, or (Gradle 8.9+ and JDK 17 installed):

```sh
cd apps/house-capture-android
gradle wrapper --gradle-version 8.9      # once; the wrapper is not committed
./gradlew testDebugUnitTest assembleDebug
```

Toolchain: AGP 8.7.3, Kotlin 2.0.21, Compose BOM 2024.12.01, ARCore 1.57.0, compile/target SDK 35,
min SDK 29. JVM unit tests (`app/src/test`) cover the bundle JSON, matrices, depth encoding, the
fallback layout, depth/pose pairing, the scan hints and the room verdict.

## Scanning

Tap **Scan a room**, name it (camera permission is asked here), then walk the room. The scan screen
uses solid ink panels so it stays readable over the camera:

- **Status**: tracking state (Tracking / Tracking limited / Tracking lost) and one next step: a
  tracking fix ("Move slower", "Point at something with texture", "Too dark"), a depth warning, a
  turn toward the side of the room depth hasn't seen yet ("Turn left: the area to your left hasn't
  been seen"), or "Looks complete".
- **Counters**: photos (flashes, with a haptic tick, on every saved photo), depth frames (red when
  no new depth frame was written for 5 s of normal tracking, with the most frequent reason in
  words below it) and **photo detail** (the photographed fraction of depth-observed cells, not the
  share of the room scanned).
- **Plan**: cells seen by depth (grey), well-photographed cells (green), walls ARCore found (thick
  blue), floors (thin blue), your path (ink line), photos (pink), the phone and its heading
  (orange), and a 1 m scale bar.

**Finish room** saves it. The room page then shows a verdict (good / usable / poor) with its
reasons (photos, depth frames, photo detail, tracking-loss time, walls, warnings such as "No
depth: walls are only an estimate"), the room size W × D, a plan of the saved walls with their
lengths and the photo positions, the depth outcome counts, the next steps, and a **Share room
(.zip)** button. There is no "continue scanning": one scan is one room. Delete a room from the
library with its trash icon.

- Move slowly and sideways so ARCore gets parallax; depth needs motion, not just rotation.
- Keep surfaces 0.5–5 m away. Blank walls, glass and mirrors return little or no depth.
- Light the room and point at textured areas when tracking warns about missing detail.
- Walk back to where you started (close the loop) to reduce drift.

Photos, depth and coverage input stop while tracking is not normal. One scan is one session folder
with one room, always room index 0. Pausing the app (a call, switching apps) and coming back starts a
new recording segment in the same room; ARCore may relocalize after a resume, so the segments are not
guaranteed to share one world frame. Time in the background is not counted.

Leaving a scan without **Finish room** keeps it in the library as an "Unfinished scan". The app
checkpoints photo and depth records and a plane layout every five seconds, so a scan that was left,
crashed or killed should lose only its last few seconds; sharing it adds the room entry first. A scan
that recorded nothing is deleted. These recovery paths are tested only off-device.

## On disk

```
files/Houses/android/sessions/<yyyy-MM-dd HH.mm.ss>/   one session = one scan bundle, house-capture/5:
  manifest.json            rooms, files, device, alignment; platform "android", capture (ARCore details)
  rooms/room-N.json        RoomPlan-shaped layout from ARCore planes (rewritten by the synthesizer)
  rooms/room-N.arcore.json the app's original plane layout, never overwritten
  photos/photos.json       [{ file, room, timestamp, width, height, transform, intrinsics, tracking,
                              manual, exposure, blurPixels, pass, highRes, camera, segment }]
  photos/NNNN.jpg          largest ARCore CPU image (expected 1920×1080), sensor orientation (EXIF 6)
  depth/frames.json        [{ file, confidence, rgb?, rgbIntrinsics?, camera?, room, timestamp, width,
                              height, transform, intrinsics, arcore, segment }]
  depth/NNNNN.f16z         raw depth, Float16 meters, raw DEFLATE: zlib.decompress(data, -15)
  depth/NNNNN.conf         UInt8 confidence (0–2, quantized from ARCore's 0–255)
  depth/NNNNN.jpg          640-wide color of the same frame (no EXIF)
```

Compared with an iPhone bundle there is no `structure.json|usdz`, `worldmap.arworldmap`,
`rooms/room-N-data.json`, `.usdz` or `mesh/` (`rooms[].usdz` is `""`; `manifest.mesh` is absent until
`android_synthesize_room.py --write-bundle` adds `mesh/room-N.ply`). Optional keys are omitted rather
than written as null; on a phone without depth there is no `depth/` data, `frames.json` or
`depthFrames`. New optional keys: `manifest.platform` (`"android"`), `manifest.capture` (engine,
ARCore SDK, chosen camera config, depth mode and size, `layoutSource`, `synthesized`, worst sampled
`thermal` status, `segments` count, `trackingLostSeconds`, `depthStats` (below), and
`events: [{t, what}]` with `pause`, `resume` and `tracking:<state>` at recorded seconds `t`),
per-record `segment` (0-based, on photos and depth frames) and per-depth-frame `arcore` (texture
size, texture intrinsics, `depthTimestamp`, `frameTimestamp`, `poseSource`, `poseOffsetMs`). The iOS
app and the Python scripts ignore unknown keys; no script reads `segment` yet. During capture the
manifest (with `rooms: []`), `photos.json`, `frames.json` and the plane layout are checkpointed every
five seconds; Finish room rewrites them and adds the room entry.

**Coordinates**: ARCore world space is meters, +Y up (gravity), right-handed — the same as an
ARKit session. Photo and depth `transform` is `Frame.getCamera().getPose()` (the sensor camera, not
the display-oriented pose) as a column-major 4×4, camera-to-world, looking down −Z. JPEG pixels are
the raw landscape sensor image and `intrinsics` (fx, fy, cx, cy) match them — ignore EXIF when
projecting. Depth intrinsics are ARCore's texture intrinsics scaled to the depth image size; the raw
values are kept in `arcore` so they can be corrected offline.

## Depth pairing

ARCore's raw depth updates about 10 times a second and is computed for an earlier camera frame than
the one being drawn. A depth image is recorded when its timestamp is new (different from the last
depth image the app looked at; an unchanged timestamp means ARCore reprojected old depth). The app
keeps the poses of the last ~3 s of tracked frames by timestamp and gives the depth frame:

- `timestamp` and `transform`: the frame whose timestamp equals the depth's (`arcore.poseSource:
  "exact"`), or else the nearest frame within 50 ms (`"nearest"`, with `arcore.poseOffsetMs`). With
  neither, the depth image is skipped and counted as `noPose`.
- `arcore.depthTimestamp`: the depth image's own timestamp; `arcore.frameTimestamp`: the frame being
  processed when it was read.
- `rgb`, `rgbIntrinsics` and `camera` only when the depth belongs to the current frame, since the
  app has no CPU image or exposure of earlier frames. They are optional for the scripts.

`manifest.capture.depthStats` counts every attempt so a scan can't record zero depth silently:
`outcomes` (`written`, `stale`, `noPose`, `busy`, `pose:exact`, `pose:nearest`,
`acquire:<Exception>`, `confidence:<Exception>`, `copy:<Exception>`, `writeFailed:<Exception>`),
`firstWrittenSeconds` and `lastUnmatchedOffsetMs` (depth minus nearest frame timestamp of the last
depth image without a pose). The same counts go to logcat once a second
(`adb logcat -s CaptureController`).

## Sharing and importing

Open a saved room → **Share room (.zip)**. The zip has `manifest.json` at its root, like the iOS
export. Extract it into an ignored `data/captures-in/<room>/` directory and follow
[Android bundles](../../.agents/skills/scan-to-threejs/references/house-capture.md#android-bundles).
The app makes no network requests. Exports keep the keys the iOS importer requires, so a
non-LiDAR iPhone may be able to import and review them (boxes only, no mesh) — not verified.

## Device tests

**Test 1 (Pixel 10 Pro, 61 s office scan, 2026-10-22)**: 38 photos at 1920×1080 with sane poses;
EXIF orientation 6 shows them upright. Tracking was normal for most of the scan. Depth mode was
`RAW_DEPTH_ONLY`, but **no depth frame was recorded** and nothing was logged. The app then accepted a
depth image only when its timestamp equalled the current camera frame's. ARCore's raw depth lags
the camera, so that probably never happened on this phone, and the failure was invisible. The app
now pairs depth with the pose of the frame it belongs to (above) and counts every outcome. Whether
this fixes depth on the Pixel 10 Pro is **not yet verified**: the next scan's `depthStats` will say.

## Not verified

The app is checked by the CI build, JVM unit tests and the one device test above. The following
still need a real Pixel 10 Pro:

1. Pose: `photos_for.py` points land where expected. (Image orientation was verified in test 1.)
2. Depth intrinsics between the CPU image and the depth map: synthesized walls line up with photos
   in `bundle_plan.py --room N`, and a known 3 m wall measures 3 ± 0.1 m.
3. Verified in test 1: the largest CPU camera config is 1920×1080.
4. Synthesized walls, openings and objects on a real room against a tape measure.
5. Drift on long scans (doubled walls).
6. Segments after a pause may not line up: whether ARCore keeps one world frame across
   pause/resume. Check `manifest.capture.segments`/`events` and compare walls per `segment`.
7. Depth/pose pairing: depth frames are recorded at all (`depthStats.outcomes.written`), most have
   `poseSource: "exact"`, and depth reprojected with those poses lines up with the photos.
8. Unfinished-scan recovery after the app is killed in the background.
9. Thermal behavior on long scans.
10. Exposure metadata for the blur gate (falls back to 1/60 s).
11. ARCore update prompt on devices with an older Google Play Services for AR.
12. Importing an Android zip on an iPhone.

No depth accuracy figure, reliable door/window/object detection, or equivalence to a LiDAR scan is
claimed.
