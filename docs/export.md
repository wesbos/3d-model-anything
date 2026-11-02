# Exporting rooms to Blender (glTF)

Deterministic, LLM-free export of a rebuilt room and, when the room has them, its LiDAR scan and its photo cameras.

## Prerequisites

- Node 22+ and `npm install` already done (no extra packages: the driver is headless Chrome over CDP).
- Google Chrome or Chromium. Set `CHROME_PATH` if it is not in a standard location.
- Python stages only: `PYTHON` (or `CAP_PYTHON`) pointing to an interpreter with `pip install -r tools/requirements.txt`.
- Your own captures and generated exports stay untracked (`data/captures-in`, `data/scans` and `data/exports` are git-ignored).

## Commands

```bash
npm run export:room -- office-v4      # one or more rooms
npm run export:all                    # every room in tools/rooms.json
npm run export:check                  # exports twice, compares sha256, runs tools/export.test.mjs
node tools/rooms.mjs list
node tools/rooms.mjs pipeline <room> [--dry-run] [--force]   # raw capture -> assets -> export
```

Output in `data/exports/` (override with `--out`):

| File | Content |
|---|---|
| `<room>/<room>.glb` | The rebuilt model: one named node per wall, pipe, door, fixture or prop, plus glTF lights. Never batched. |
| `<room>/<room>-lidar.glb` | The LiDAR scan: one unlit mesh, colour in `COLOR_0`. Only for rooms that ship a scan. |
| `<room>/<room>-photos.glb` | One camera per posed photo, named `photo_0000`... (`userData.image` is the file name in `data/web-assets/<room>/photos`). Only for rooms with posed photos. |
| `manifest.json` | Size and sha256 of every file, plus the build report. |

The two optional files are skipped, with a note in the console and in the manifest, when the room has no scan (`referenceAvailable: false` or a RoomPlan `layout` reference) or no `photos`. This is the case of `office-v4`, which only exports `office-v4.glb`; the matching checks in `export:check` are reported as skipped. A stale optional file from an earlier export is removed.

## Frame

Meters, +Y up. The model and the LiDAR scan share one frame, so import both with no transform; the photo cameras are in that frame too and look down -Z.

## Blender import

1. File > Import > glTF 2.0, pick `<room>.glb`, then `<room>-lidar.glb` and `<room>-photos.glb` the same way.
2. Blender converts Y-up to Z-up on import; leave the importer defaults and do not move the objects.
3. Materials arrive as basic PBR: the viewer's shadows, tone mapping and exposure are not exported.
4. Lights are glTF punctual lights in watts (Blender converts the units). Hemisphere lights have no glTF equivalent and are listed in `lights.userData`.
5. Photo cameras: select a `photo_NNNN` camera as the active camera to look through the original viewpoint.

## Dev server

The exporter starts its own vite server on a free port. It reuses a dev server already listening on `:5188` only if that server serves this checkout (another checkout's server would export the wrong code). Set `EXPORT_OWN_SERVER=1` to always start its own.

## Determinism

The export page never calls `optimize()`/batching, names every node (clashes get `_NN`), and rewrites the GLB so image data order does not depend on async encoding. `npm run export:check` exports all rooms twice in separate processes, fails if any sha256 differs, then runs the structural tests (unique names, one mesh per original object, clean geometry, model and scan alignment). The export page seeds `Math.random` (procedural textures stay reproducible); rooms must not use `Date.now` or other clocks.

## Scripted versus hand-authored

Only for rooms that declare a raw capture in `tools/rooms.json` (`office-v4` does not: no capture is distributed). Scripted (`node tools/rooms.mjs pipeline <room>`): `bundle_to_room.py`, `prepare_photos.py`, `reconstruct_bundle.py`, `demos/<room>/make-assets.py`, export. A stage whose output exists is skipped (`--force` reruns all but photos); a missing input or script stops the run with its name.
Authored by hand (with the scan-to-threejs skill): the room code in `demos/<room>/` (walls, props, materials, lights) and its registration in `demos/index.ts`.

## Adding a room

1. Register the demo in `demos/index.ts`, then add `{ "id": "<room>" }` to `tools/rooms.json`. The pipeline fields are optional and only used by `rooms.mjs`: `capture` (bundle directory), `roomIndex`, `mesh` (session-world `.ply`), `scans` (output directory) and `makeAssets` (your `demos/<room>/make-assets.py`).
2. For a room with a scan, `loadReference()` must resolve the scan and `referenceKind` must be `'scan'`; for photo cameras, set `room.photos`.
3. Optionally add `topLevel`, `minWalls`, `minLights`, `minPhotos` (counts only) under `rooms` in `tools/export-expectations.json`; override a default there when a room needs it (e.g. `maxDegenerateFraction`, `maxBytes`).
4. Run `npm run export:check`.
