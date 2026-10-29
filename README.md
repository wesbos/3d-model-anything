# 3D Model Anything

[![Watch the video: 3D Model Anything](docs/images/thumb-1.png)](https://www.youtube.com/watch?v=JGQCcCzuS88)

Capture a room on an iPhone, then use its geometry and photographs to build an editable Three.js scene with an AI coding agent.

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

The iOS app can optionally record compass observations during scanning; recording is off for every new session. Enable **Record compass directions** before scanning or while paused. Allow Location While Using the App for true north; otherwise readings are marked magnetic north. Direction observations, accuracy and matching camera poses travel in room exports. Reconstruction preserves north through room rotations and the viewer labels outward wall/window directions. See [compass capture](docs/compass-capture.md) for the contract and remaining device validation.

To check directions immediately, convert the export with `bundle_to_room.py`, open `/inspect.html` in the local viewer and select the converted `room.json`. **3D** and **Floor plan** show recorded north and outward wall/window bearings before detailed reconstruction.

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
