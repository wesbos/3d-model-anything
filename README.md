# 3D Model Anything

[![Watch the video: 3D Model Anything](docs/images/thumb-1.png)](https://www.youtube.com/watch?v=JGQCcCzuS88)

Capture a room on an iPhone or a Pixel, then use its geometry and photographs to build an editable Three.js scene with an AI coding agent.

[Open the office viewer](https://wesbos.github.io/3d-model-anything/) · [App support](https://wesbos.github.io/3d-model-anything/support.html)

This repository includes the **3D Model Anything iPhone app**, a **Three.js viewer**, the **scan-to-threejs agent skill**, and **Wes’s detailed office demo**.

The app records the evidence. The skill guides an agent through measurement, modeling and matched-camera visual comparisons. This is an iterative reconstruction workflow, not a one-click scan-to-perfect-model converter. The current workflow focuses on rooms and interiors.

## Run the viewer

Use Node.js 22.12+ (or a newer supported release).

```sh
npm ci
npm run dev
```

Open http://localhost:5188. Explore the office in dollhouse, walking, overhead, wireframe and knolling views. The playground is at `/play.html?room=office-v4&mode=fpv`.

```sh
npm run build
npm run preview
```

The demo includes the reconstructed office and selected textures. Original scans and photo collections are not distributed; Scan and Overlay are disabled for this example. Those modes remain available for your own rooms with reference assets.

## Capture your own space

See [the iPhone app](apps/house-capture/README.md) for building with Xcode, device requirements, scanning and sharing. Scanning needs a LiDAR-equipped iPhone or iPad. Non-LiDAR devices can import and review scans.

The app is source-available here; an App Store release is a separate distribution step. Do not assume an App Store download is available yet.

Export a room or session through the system share sheet and extract it into an ignored `data/captures-in/<room>/` directory. Exports keep the existing `house-capture/5` contract; changing the app name does not change the files.

## Capture on Android (Pixel)

[The Android app](apps/house-capture-android/README.md) records a room on an ARCore Depth API phone; it is developed for the Pixel 10 Pro. It saves camera poses, posed photos (the largest CPU image ARCore offers, expected 1920×1080), raw ARCore depth frames and detected planes into the same `house-capture/5` session zip.

Pixels have no LiDAR and no RoomPlan, so the app writes only a plane-derived room layout. Walls, doors, windows, openings and furniture boxes are synthesized offline from the depth frames by `android_synthesize_room.py` before the skill converts the room; see [Android bundles](.agents/skills/scan-to-threejs/references/house-capture.md#android-bundles). Detected openings and objects are candidates to confirm with photos.

The debug APK is built by the `Build Android app` workflow (`.github/workflows/android.yml`); download the `house-capture-android-debug` artifact from a run, or build with Android Studio. The app has not yet been validated on a physical device.

## Use the skill

The skill lives at `.agents/skills/scan-to-threejs/SKILL.md`. Open this repository in an agent that supports local skills and ask it to use **scan-to-threejs** with your extracted export. You can also copy that skill directory into your agent's skill directory; the companion viewer/runtime in this repo is still needed for its capture workflow.

Example request:

> Use scan-to-threejs to rebuild the room in data/captures-in/my-room. Inspect the measurements and photos, create an editable scene, and compare rendered views with the original photographs.

Start with [the format guide](.agents/skills/scan-to-threejs/references/house-capture.md) and [project layout](.agents/skills/scan-to-threejs/references/project-layout.md). Helpers need Python 3; photo comparisons need Pillow, and optional depth reconstruction needs NumPy, Open3D and Pillow. Capture scripts use the `agent-browser` CLI.

A new room goes in `demos/<id>/` and is registered in `demos/index.ts`. The office example retains its earlier reconstruction layers (`office-v2`, `office-latest`, `office-v4`) to preserve the final geometry.

## Privacy and licensing

Only the office example is distributed. No other rooms, connected-house layout, original scan bundles, or development Git history are included. Keep your captures private; inspect assets before publishing your own demo.

Reusable source code and the skill are MIT licensed. The supplied office images/textures have separate [asset terms](ASSETS-LICENSE.md). Third-party marks, artwork and depicted products are not licensed by the code license.

See [release status](docs/release-status.md) for validation and iPhone distribution steps.
