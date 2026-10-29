# House Capture: session bundles and multi-session houses

Current app exports use `house-project/1` for a house and `house-capture/5` for each session.
Detect the files and inspect `format` before processing. An unpacked whole house contains
`house.json`, `zones/` and `sessions/`; a session contains `manifest.json`, `rooms/` and `photos/`.
Use the actual session folder with the bundle scripts, not the house root. The maintained app
reference is `apps/house-capture/README.md` in this repository.

## Whole-house import

```sh
python3 "$S/house_to_rooms.py" data/captures-in/my-house -o data/demos/my-house-import
# Optional: --room <stable-room-id> selects one house room.
```

The output directory must be new. The script never edits the source export. It:

- Reads each room's `active` reference, rather than choosing the newest session or merging history.
- Converts that session's `rooms/room-N.json` and matching photos into room-local coordinates.
- Exports `room-NNN.json` and an `index.json` recording names, source bundles, active references,
  ready/blocked status and placement matrices. Filenames are generated, not taken from room names.
- Reports absent active scans, missing/mismatched references and unaligned sessions/zones. Exit code
  2 means a partial/blocked export; inspect the index. It does not compute ICP or manual alignment.

The app stores column-major 4×4 matrices:

```text
sessionToHouse = zone.toHouse × session.alignment.toZone
roomToHouse    = sessionToHouse × inverse(worldToRoom)
pointHouse     = roomToHouse × pointRoom
```

Only zones with `aligned: true` and sessions with method `first`, `relocalized`, `manual` or `icp`
are placed. Identity matrices alone do not establish alignment. Matrices must be finite rigid
transforms. `first` means first in its zone, not necessarily first in the house.

`worldToRoom` still maps the original session frame to room space, so the existing depth and
photo tools work with each exported room and its recorded source bundle. It is not replaced by
a house transform. The output's `housePlacement` adds `sessionToHouse` and `roomToHouse`.

Apply `roomToHouse` when assembling modeled rooms, their lights, reference layers and camera
positions/directions. Preserve local wall/collision/cutaway conventions, or transform queries
back to room space. The current viewer displays individual rooms; this importer does not add a
combined-house viewer, merge meshes, align unknown scans, deduplicate shared walls or combine old
photos across sessions. History is kept in the original export; only active scans are exported.

## Current session contents

```text
manifest.json             format, rooms, device, alignment and diagnostics
structure.json|usdz       this session's RoomPlan merge
rooms/room-N.json          labeled RoomPlan geometry
rooms/room-N-data.json     raw CapturedRoomData, when recorded
mesh/room-N.ply            LiDAR mesh; can include earlier rooms (inroom marks the current room)
mesh/room-N-colors.bin     preview's cached per-vertex colors
photos/photos.json        filename, room, pose, intrinsics, dimensions, blur and exposure
photos/NNNN.jpg           original sensor pixels (EXIF orientation is separate)
depth/frames.json         depth/confidence/RGB paths, pose, intrinsics and dimensions
depth/NNNNN.f16z          Float16 meters, raw DEFLATE (zlib.decompress(raw, -15))
depth/NNNNN.conf          UInt8 confidence, 0–2
depth/NNNNN.jpg           low-resolution RGB for that depth frame
worldmap.arworldmap       saved ARKit map; not a mesh or a directly usable Three.js asset
```

Session coordinates are meters, +Y up, right-handed. Photo transforms are camera-to-session;
cameras look along −Z. Read dimensions/intrinsics from metadata instead of assuming a fixed size.
Original sensor pixels must stay unrotated when projecting with intrinsics. `bundle_to_room.py`
uses a clockwise 90° display rotation and derives upright camera framing accordingly.

The app can optionally export compass evidence at the path in `manifest.compass`, with `compassSampleCount` and linked photo `compassTimestamp`. The converter preserves raw observations and derives room-space `compass.north`, true/magnetic reference, uncertainty and outward wall/window `facing` bearings. Carry `compass` into `BuiltRoom.layout` and rotate its north with geometry. House imports include house-space north in `housePlacement.compass`. See `docs/compass-capture.md` in the companion repository for the contract and device validation limits.

## Prepare a session room and photos

```sh
python3 "$S/bundle_to_room.py" data/captures-in/my-room --room 0 -o data/demos/my-room.json
python3 "$S/prepare_photos.py" data/captures-in/my-room data/demos/my-room.json data/web-assets/my-room/photos
```

Choose the actual room index from the manifest; zero above is an example. For a whole-house
import, use `index.json`'s bundle and exported file instead of converting again. `prepare_photos.py`
requires Pillow and a new output directory. It rotates the raw sensor pixels once, resizes them,
and names them `0000.jpg`, `0001.jpg`, etc., in the converted room's `photos` order. Do not sort
original filenames and assume they match filtered room-photo indices. Set viewer photo URLs to
`/<room-id>/photos/NNNN.jpg`, preserving that order. The comparison script uses the same ordering.
For a custom photo location, set `PHOTO_DIR`; prepared images already upright must not rotate again.

The existing `cmp_photo.sh` renders one pair per requested index; make a contact sheet separately
when useful. It crops empty render margins for presentation, so use the uncropped model PNG for
pixel-coordinate measurements.

## Older exports

The bundle converter reads RoomPlan geometry and photo metadata shared by earlier exports.
`reconstruct_bundle.py` supports raw `.f16` depth and compressed `.f16z` depth (v4/v5). Its output
is session-world and optionally room-local reference geometry, not a cross-session fused house.
Some early bundles have no usable mesh/depth. Use their RoomPlan boxes and photos instead of
assuming those inputs exist. Inspect actual files before choosing a reconstruction route.

## First contact with a new bundle

Start with the plan: `python3 <skill>/scripts/bundle_plan.py <bundle> -o plan.png` draws walls
(by confidence), doors/windows, furniture boxes and every photo's position/direction, and prints
per-wall photo coverage using the app's own rule. If the room is saved but the session is still open, `structure.json` may not exist: pass `--room 0` (or the actual manifest room index) to both plan and conversion scripts. Do not duplicate room JSON into a fake session structure. Then look at a photo contact sheet: most blur
comes from auto photos taken while moving (fixed in later app versions: steady-only).

Observed in an app export (check the actual bundle version): top-level keys `doors floors
objects openings rooms sections version walls windows`; each element has `identifier`,
`category` (single-key object, e.g. `{"wall": {}}`, `{"door": {"isOpen": …}}`), `confidence`
(`{"high": {}}`), `dimensions` [w, h, d], `transform` (16 floats, **column-major**, translation
= last column), `parentIdentifier`, `completedEdges`, `polygonCorners`, `curve`, `story`.
Beautified walls come back with empty `completedEdges`/`polygonCorners`. Auto photos are
1920×1440 video frames; manual shutter photos try ARKit's high-res still first (size varies). RoomPlan reports a
single flat height per wall (which can miss local ceiling variations), so
take ceiling shape from photos/mesh.

If in doubt, inspect before assuming field names:

```sh
jq 'keys' structure.json                    # walls, doors, windows, openings, objects, floors, sections, …
jq '.walls[0]' structure.json               # expect: identifier, transform (16), dimensions (3), category, confidence, parentIdentifier?, polygonCorners?
jq '[.objects[].category | keys[0]] | group_by(.) | map({(.[0]): length}) | add' structure.json
```

`transform` is a 4×4 whose translation is the element's center. `dimensions` is
[width, height, depth], and depth is 0 for walls, doors and windows. The last 4 numbers are
`[x, y, z, 1]`. Wall center y can sit near 0 (it's in the session's world, not relative to the
floor), so get floorY from `floors` or the bottom of the walls (center.y − h/2).

## structure.json → WallDef

`python3 <skill>/scripts/bundle_to_room.py <bundle> [--room N] -o room.json --plan plan.png` does all
of the below: heading alignment, floor, CCW floor polygon, inward normals (point-in-polygon test),
openings in wall u/v, objects (center, size, rotY, front), and photo poses (position, forward, up,
fovY, aspect for the upright image). The plan PNG labels wall indices and u ticks every 0.5 m. The
steps are kept here for when you need to do it by hand:

For each wall: local x̂ = first column (along the wall), ŷ = up, ẑ = third column (normal).
1. `center` = translation, `w, h` = dimensions[0..1].
2. Point `n` into the room: flip ẑ if it points away from the room's centroid (the average of the
   wall centers for that room). If you flip n, also flip x̂ so `u × up = n` still holds.
3. `origin = center − u·w/2 − up·(center.y − floorY)`; `length = w`; wall top = `floorY + h`.
4. Doors/windows/openings with `parentIdentifier` = that wall: take their center relative to the
   wall origin → `u = dot(c − origin, u)`, `v = c.y − floorY`. Span `u ± width/2`,
   `v ± height/2`. Doors and openings whose bottom is within ~5 cm of the floor become `v0 = 0`
   notches. Windows default to `rect`; switch to `arch` if the photos show a round head.
5. Group rooms by the manifest's `rooms` (`rooms/room-N.json` elements carry the same
   identifiers). Shared walls between rooms appear once per room: model each room's face
   separately (slab thickness ≈ distance between the two parallel faces).
6. Rotate the whole house so the dominant wall direction lines up with X/Z (same azimuth trick as
   `measure_scan.mjs`, on wall normals), then translate so the floor is y = 0.

RoomPlan assumes flat ceilings and ignores trim. Get the ceiling from the available mesh/depth
(height histogram, same as the GLB workflow), and moldings from photos.

## Objects → furniture

Each object has a category (sofa, table, chair, bed, storage, television, fireplace, stairs,
toilet, sink, bathtub, oven, dishwasher, refrigerator, stove, washerDryer) plus an oriented box.
The box gives position, footprint, height and facing (local +z is usually the front; confirm
with a photo). Use it as the bounding volume for a hand-built piece from the recipes in
`modeling.md`, and use photos for the actual shape and material.

## Photos

`transform` is camera-to-world (camera looks down −Z). The image pixels are the raw sensor frame in
landscape (`width > height`; rotate 90° clockwise to view upright, as EXIF orientation 6 says;
PIL ignores EXIF by default, which is what you want for projection); `intrinsics` = [fx, 0, 0, 0, fy, 0, cx, cy, 1] (column-major) for
that image. To find the best photo of something at world point P:

```js
// camera-space point; ARKit camera: +x right, +y up, -z forward (in sensor orientation)
const pc = invert(transform) · [P, 1];
if (pc.z >= 0) continue;                          // behind the camera
const x = fx * (pc.x / -pc.z) + cx;               // image x (pixels, right)
const y = fy * (-pc.y / -pc.z) + cy;              // image y (pixels, down)
// in frame if 0 ≤ x < width && 0 ≤ y < height; prefer small |pc.z| and a view facing the surface
```

Write a small script that, for each wall or object, lists the 3 best photos (in frame, close,
frontal). Look at those rather than scrolling through hundreds. Crop them for texture sampling
(`ortho.py sample` works on any image if you pass pixel boxes via a quick PIL crop).

## Depth reconstruction (depth-enabled bundles)

v3 (`house-capture/3`) records depth frames during the single pass but the per-room PLY can be empty
(RoomPlan's session only exposes mesh anchors after the app enables them). `reconstruct_bundle.py`
rebuilds from depth instead: confidence ≥ 1, ≤ 3.5 m, 2 cm voxels, truncation 8 voxels. The original macOS Open3D setup returned no geometry from
`ScalableTSDFVolume`; the script tiles `UniformTSDFVolume` cubes.
Vertex colors: best photo per vertex by (cos × focal / distance × sharpness), visibility by raycasting
the mesh from each photo; glTF colors are linear, so convert from sRGB when writing the GLB.

## Legacy mesh + depth (v2 bundles)

Detail-pass photos are coverage-driven, so every surface should have a good photo; check the
per-room `photoCoverage` in the manifest, and the PLY's `coverage` attribute, to see what's thin.
Load `mesh/room-N.ply` with three's PLYLoader (map `coverage`/`inroom`/`class` via
`setCustomPropertyNameMapping`) and use it as the Scan/Overlay reference layer: colored by
class it's a far better reference than RoomPlan boxes, and orthographic captures of it (the
GLB workflow's step 2) give exact ceiling steps, soffits, built-ins and furniture silhouettes.
Depth frames are an RGB-D sequence (with the photos): project them to measure anything in view.

## Legacy mesh (v1 bundles)

`mesh.obj`, if present, is uncolored but dense. Load it with gltf-transform/three's OBJLoader or parse the
`v`/`f` lines directly. Use it like the Polycam mesh: height histograms for ceilings and soffits,
and orthographic renders for things RoomPlan skips (tray ceilings, built-ins, stairs, fireplace
depth). If `manifest.mesh` is null, the capture session didn't expose mesh anchors; fall back to
RoomPlan boxes plus photos.

## Fast validation of a new saved LiDAR mesh

When the per-room PLY already has usable triangles, skip TSDF fusion and color that geometry directly:

```sh
python3 "$S/reconstruct_bundle.py" <bundle> --mesh <bundle>/mesh/room-0.ply --room <converted-room.json> -o <new-output-directory>
```

PLY red/green coverage colors are diagnostic, not photographic textures. The reconstruction script
uses visibility-tested photos and depth RGB to color vertices, writes a `reconstruction.json` report,
and leaves unseen vertices gray. The colored-vertex fraction measures image projection coverage,
not room completeness or geometric accuracy. Inspect matching photo/mesh renders and the overhead
view for holes, thin objects, walls, and ceiling steps. Furniture detection boxes are only a schematic
baseline; do not label them a detailed reconstruction. Preserve the original PLY and source images.

The capture scripts use the server at `CAP_URL`. If it is a production preview, rebuild **after**
copying new public assets; otherwise the server may return index.html for a missing GLB. Check
asset response content type and browser errors when the capture-ready signal never arrives.
