# 3D Model Anything

iPhone app that scans a whole house, over as many days as you like, into bundles the three.js
rebuild pipeline (`scan-to-threejs` skill) can use directly. Per room it records, on one ARSession:

- **RoomPlan** (headless): labeled walls, doors, windows, openings and furniture boxes.
- **LiDAR mesh**, drawn live as triangles by photo coverage (red needs photos, green is covered), saved as `mesh/room-N.ply`.
- **Posed photos**: sharp frames (or full-res stills) taken automatically where they add the most
  coverage, plus a shutter for close-ups. Exact camera pose + intrinsics per photo.
- **Depth frames**: 256×192 Float16 depth + confidence + a 640×480 color JPEG, up to 5/s.

Requires an iPhone or iPad **with LiDAR** running iOS 17+.

## Build

```sh
cd apps/house-capture
xcodegen generate          # regenerates HouseCapture.xcodeproj from project.yml (after adding files)
xcodebuild -project HouseCapture.xcodeproj -scheme HouseCapture -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build
```

Or open the project in Xcode, pick your team under *Signing & Capabilities*, and run on the phone.

## Rooms and scanning

The Fieldwork house screen shows a numbered room library with previews rendered from saved scans. Open a room for an interactive 3D preview, photo-detail view, sharing, and scan history. Warm paper surfaces, ink typography, orange actions and ruled sections carry through the house library and room pages. Sessions and Recently Deleted are collapsed below the room library. Thumbnail rendering is serialized and caches only small images; scans without cached photo colours use neutral clay geometry. Tap **Scan a room** to begin; internal tracking groups are created automatically. Open a saved room and choose **Continue scanning from this room** to recognize that location before scanning nearby. Maps of 35 MB or more, or groups with four rooms, automatically start fresh. Matching room names within the house adds to the room's history, even across internal tracking groups.

Name the room, tap **Scan**, then move around it until coverage improves. **Finish room** saves it; **Finish session** ends the visit. Tracking groups and coordinate transforms remain in the export format for later house assembly, but are not concepts the user needs to manage. Separate captures still need alignment before they can form a connected house model.

Swipe left on a room to move it and its history to **Recently Deleted**. Restore it there, or explicitly delete it permanently. Scan versions can be inspected, switched, compared and moved to Recently Deleted individually. Rename keeps a stable room ID; typing an identical name does not silently replace a different room. On permanent deletion, Sessions used only by that room are deleted; recordings shared with other rooms are retained. Room-specific layouts and meshes are removed from shared sessions. Empty tracking groups are removed automatically. Deletion invalidates affected tracking maps and merged previews to avoid reusing deleted geometry. Unrelated rooms and maps remain intact. Session deletion remains available under **Sessions**.

Every finished room is written to house.json and the bundle right away and the map is re-saved
after each room, so a crash costs at most the room in progress.

**Sharing**: open a saved room → *Share room (.zip)* → AirDrop. This exports the active scan's layout, mesh, photos and depth, excluding other scans and session-wide structures/maps. Original room indices and poses are preserved; the saved mesh may include nearby surfaces from the same capture session. To share an older version, select *Use this scan* first. The house screen's *Share whole house* and each session's *Share* remain available.
Everything is also in the Files app under 3D Model Anything.

**Photo preview** maps cropped photo textures onto the mesh, preserving image detail between
LiDAR vertices. It chooses sharp, unobstructed views and reuses photos from aligned earlier
sessions. Texture decoding shares a 48-megapixel budget across the house; areas without a
usable full-triangle photo keep their cached vertex colors.

## On disk

```
Documents/Houses/<house>/
  house.json                         zones, sessions (+ alignment), rooms (active + history)
  zones/<area>/worldmap.arworldmap   latest map of the area (NSKeyedArchiver, secure coding)
  zones/<area>/structure.json|usdz   RoomPlan merge of the area's active rooms (preview only)
  sessions/<yyyy-MM-dd HH.mm.ss>/    one session = one scan bundle, house-capture/5:
    manifest.json          rooms, files, device, alignment, world-map status, diagnostics (rewritten after every room)
    worldmap.arworldmap    the map at the end of the session
    structure.json|usdz    this session's rooms merged by RoomPlan
    rooms/room-N.json      CapturedRoom (RoomPlan's Codable JSON), .usdz, -mesh.usdz (detailed shapes)
    rooms/room-N-data.json raw CapturedRoomData (re-run RoomBuilder on it later)
    mesh/room-N.ply        LiDAR mesh at the end of room N (includes earlier rooms' surfaces;
                           `inroom` marks room N): binary PLY, per vertex x y z nx ny nz coverage
                           red green blue inroom, per face vertex_indices class
                           (0 none 1 wall 2 floor 3 ceiling 4 table 5 seat 6 window 7 door)
    mesh/room-N-colors.bin per-vertex photo colors, written by the in-app 3D preview
    photos/photos.json     [{ file, room, timestamp, width, height, transform, intrinsics, tracking,
                              manual, exposure, blurPixels, pass, highRes, camera }]
    photos/NNNN.jpg        up to 3024 px long edge, sensor orientation (EXIF 6)
    depth/frames.json      [{ file, confidence, rgb, rgbIntrinsics, camera, room, timestamp, width, height, transform, intrinsics }]
    depth/NNNNN.f16z       256×192 Float16 depth (m), raw DEFLATE: zlib.decompress(data, -15)
    depth/NNNNN.conf       256×192 UInt8 confidence (0–2)
    depth/NNNNN.jpg        640×480 color of the same frame
```

**Coordinates**: each session is in its own ARKit world: meters, +Y up (gravity), right-handed
(same as three.js). Into the house frame: `point_house = zone.toHouse × session.alignment.toZone ×
point_session` (column-major 4×4s in house.json; identity for `first`/`relocalized` sessions of the
first area). Photo `transform` is camera-to-world (camera looks down −Z); JPEG pixels are the raw
landscape sensor image and `intrinsics` (fx, fy, cx, cy) match them — ignore EXIF when projecting.
RoomPlan surface/object `transform`s are centered on the element; `dimensions` = width × height × depth.

`diagnostics.json` is checkpointed every five seconds during capture, including for an unfinished room.
It records bounded memory/thermal/frame-age samples, feature and mesh counts, configuration changes,
memory warnings, interruptions, and structured RoomPlan/ARKit/high-resolution-photo error chains
(domain, code, failure reason and recovery suggestion). ARKit errors are observed through the existing
ARSCNView delegate; the app does not replace RoomPlan's ARSession delegate. The same diagnostic fields
are included in the manifest when it is saved. A successful simulator check cannot reproduce or rule
out a device tracking failure; preserve the failing session and correlate its times with device logs.

`manifest.diagnostics`: RoomPlan's and the scan's AR configurations, frame-to-frame world jumps,
white balance, an event log (tracking / mapping status changes, pauses, map saves), how
relocalization went (seconds to *normal* / *verified*, residual) and periodic live-vs-saved mesh checks.

## Launch arguments (developer)

- `-selftest`: checks everything that doesn't need the camera (house.json round trips, session
  folders, room history, deleting sessions, the saved-mesh ghost + alignment check, earlier-photo
  loading, manifests, zipping). Runs in the simulator; prints `SELFTEST:` lines, exits 0/1.
  Copy a real bundle to the app's `Documents/selftest-bundle` to also time it on real data.
- `-autotest`: a hands-free room scan in a new "Autotest" house (phone on a desk), with a pause/resume,
  logs `AUTOTEST:` lines, finishes, exits. `-autotest-continue`: continues the newest Autotest house
  (relocalize → verify → scan → finish), logging the relocalization.
- `-diag`: probes how RoomPlan and ARKit's mesh/depth coexist on one ARSession (`DIAG:` lines).

Read logs with `xcrun devicectl device process launch --console --device <id> com.wesbos.housecapture -autotest`.

## Tracking recovery and photo reliability

During capture, a prominent warning explains excessive motion, insufficient visual detail,
relocalization, interruptions, or stale camera frames. Photos, depth recording, and coverage
input stop while tracking is unreliable; capture resumes after 1.5 seconds of fresh normal
tracking. A warning vibration marks tracking loss. Pausing remains a separate user action.
The view asks ARKit to attempt relocalization after interruptions without resetting the world;
Finish remains available (including while paused) if recovery does not succeed.

A fatal ARKit or RoomPlan error prevents adding another room to the failed session. Available
room data is preserved and the UI directs you to finish the session and start a new capture.
Recovery is not guaranteed, and sudden fatal failures may arrive without an earlier warning.

Regular video-frame photos are the default. Optional high-resolution automatic photos can be
selected before scanning; requests are at least three seconds apart and require nominal thermal
state and stable tracking. Manual photos use copied regular camera frames and cannot overlap a
pending photo operation. Finishing waits for accepted photo writes; overdue still callbacks are
invalidated so they cannot leak into the next room. JPEG write failures are surfaced in the UI.
This reduces optional capture load; it is not evidence that still capture caused the recorded
October 6 drift failure.

## Capture performance

Use a **Release** build for physical scanning; Debug builds disable Swift optimizations and
are intended for debugging. Coverage inputs are coalesced before the worker queue (one newest
snapshot per anchor). Work yields after two anchors, room-layout updates coalesce, and UI mesh
outputs coalesce before reaching the main thread. No geometry is downsampled in the saved mesh.
An export flushes pending accepted geometry before writing. Unchanged vertex positions and
normals reuse their current scores exactly; changed geometry is rescored. Saturated vertices
stop at the original score cap of 2 so triangle-average coverage colors remain consistent.
Diagnostics include pending and replaced mesh-update counts alongside queue delay.

`-selftest` exercises mailbox concurrency/fairness, scoring, cache invalidation, and pending
geometry export. Optionally copy `mesh/room-0.ply` and `photos/photos.json` to simulator
`Documents/coverage-benchmark/` to compare baseline and optimized scoring on actual geometry.
This benchmark uses photo poses without depth occlusion; it is not a live phone FPS benchmark.

## Capture guidance and review

**Photo detail** is the fraction of observed mesh area with useful photography, not the percentage of the room scanned. Inferred furniture backs, floors and ceilings do not reduce this number. Old scans also display their measured mesh coverage instead of the legacy mixed score. The finish recommendation checks measured walls, photo count and observed photo detail; it never blocks saving partial work. After two minutes with little progress, the app suggests inspecting gaps or saving rather than continuing indefinitely. Photo selection runs automatically in the background; there are no aiming markers or capture targets. Tracking loss pauses new capture and shows a recent reference photo to help recover the view. Saved data can still be kept.

Thermal pressure, memory warnings and long scans reduce depth recording, photo frequency and coverage evaluation work. High-resolution automatic photos are disabled under constrained budgets. After a large map or four rooms, save and start a fresh scan rather than extending the same map further.

After each room, **Review saved room in 3D** opens the textured preview. Use coverage colours to inspect missing photography. A room's **Connect to another room** action shows numbered doorway plans, supports a 180-degree orientation choice, and requires a combined preview before saving. This is manual doorway alignment; it does not claim an automatic verified registration. The reference room must already be placed in the house and both captures must have established tracking.

## Sharing and importing

Use the system share sheet to AirDrop exports or save them to Files. No Mac receiver or companion
app is required. The iOS app does not make network requests or request local-network access.
To review an exported room/session on another device, extract its ZIP in Files, then use the
home screen's import button to select the folder containing `manifest.json`. Imports create a new
house, preserve original room indices and scan coordinates, and never replace existing scans.
Whole-house folder import is not supported. Non-LiDAR devices can import, review and share.

## Release preparation

`Help & privacy` contains offline help and the privacy policy. Their authoritative content is
`HouseCapture/Support.json` and `HouseCapture/PrivacyPolicy.json`; `release/prepare-pages.py`
generates matching public HTML pages. Set real HTTPS privacy/support URLs in `project.yml`
before publishing. `release/app-store-metadata.json` and `release/release-checklist.txt` contain
store copy, review instructions and outstanding account/device checks. Run `release/validate.py`
against the archived `.app` for local checks; it intentionally fails while public URLs or store
metadata are unset. It does not replace Xcode Organizer validation or App Review.

Camera permission is checked before creating a capture. Scanning requires 500 MB available at
start/resume and pauses below 200 MB; this is a reserve, not a guarantee against other processes
using storage. Save errors are shown, and failed session saves can be retried without closing.
Backgrounding still pauses recording. Development launch modes are enabled only in Debug builds.
