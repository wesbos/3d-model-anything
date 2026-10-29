---
name: scan-to-threejs
description: Rebuild editable Three.js rooms from 3D Model Anything iPhone exports, RoomPlan JSON, or GLB/glTF scans. Use for scan-based reconstruction and photo-guided refinement of modeled spaces.
---

# Scan to Three.js

Use captured geometry as measurement evidence and posed photos as visual evidence. Build editable geometry, then compare it against those inputs. Conversion produces a measured baseline; detailed reconstruction requires modeling and visual review.

## Inputs and coordinates

Read [house-capture.md](references/house-capture.md) for iPhone exports. The app's display name is 3D Model Anything; existing `house-capture/*` format identifiers and file layouts remain unchanged.

- For `house.json`, use `scripts/house_to_rooms.py` to select active scans and resolve placement. Separate sessions do not necessarily share a world frame.
- For a session or shared-room bundle containing `manifest.json`, use `scripts/bundle_to_room.py`. Preserve original room indices; a single-room export need not use index zero.
- For GLB/glTF, use `scripts/measure_scan.mjs`. Preserve original files and texture coordinates.
- Raw RoomPlan JSON supplies walls/openings and object bounds; it does not imply that photos or depth are present.

Use meters, +Y up and floor zero. Retain session-to-room and room-to-house transforms. Apply the same transformations to geometry, photo poses, lights and reference layers. Never infer session alignment from matching room names.

Preserve optional compass evidence. Converted `compass.north` is in room coordinates; raw `compass.samples` stay in session coordinates. Carry `compass` into `BuiltRoom.layout` for the viewer's measured wall/window labels. Rotate north with geometry. Retain true/magnetic reference, uncertainty, outward `facing` bearings and linked photo observations. Missing or uncertain readings must remain unlabeled. See `docs/compass-capture.md` in the companion repository.

## Project setup

Read [project-layout.md](references/project-layout.md) for the companion viewer and commands. Its public office is an optional worked example, not the dimensions or quality requirement for another person's room. In an existing project, adapt to its conventions rather than copying over its application.

Keep new personal captures and generated comparisons ignored by Git. The public demo explicitly includes selected office model assets; that is not permission to publish other captures. Set `S` to this skill's actual `scripts` directory and run helper commands from the target project.

## Measure, model, compare

Establish the floor, wall planes, openings, ceiling steps and object dimensions before adding detail. Use orthographic scan renders and multiple photos to resolve ambiguous shapes. Record uncertainty rather than inventing measurements.

Read [modeling.md](references/modeling.md) for geometry, materials and wall cutaways; read [advanced-modeling.md](references/advanced-modeling.md) for detailed modeling and performance. Match the user's requested fidelity. For a detailed reconstruction, compare silhouettes, construction, material scale, surface graphics and lighting at the intended viewing distance. RoomPlan boxes are bounds, not finished furniture.

Prepare photos in the converted room's array order with `prepare_photos.py`. Preserve the camera pose and intrinsics; see the format reference for sensor orientation. Use the matched-camera tools:

```sh
CAP_URL=http://localhost:5188 "$S/cmp.sh" plan 'room=my-room&view=top&ppm=110'
CAP_URL=http://localhost:5188 "$S/cmp_photo.sh" my-room 0 13 26
```

These tools capture and stitch comparisons; they do not evaluate similarity. Inspect the results, identify concrete discrepancies, fix the largest, and repeat. Do not crop by non-black pixels: empty scan regions are evidence and cropping changes framing. Set `CAP_PYTHON` if Pillow is installed in another Python environment.

Preserve visual quality while optimizing: favor batching, instancing and idle rendering. Compare before/after full-quality images. Independently verify functionality and appearance; a build passing does not establish visual accuracy.

## Delivery

Implement `RoomModule` and register it in `demos/index.ts`. Use `referenceAvailable: false` when reference assets are intentionally absent. Preserve optional photo poses for comparison tooling. Check the production build, relevant viewer modes and browser errors. Include matched-camera evidence and explain which details are measured, modeled or approximate. House assembly uses validated placements, not a hard-coded example floor plan.
