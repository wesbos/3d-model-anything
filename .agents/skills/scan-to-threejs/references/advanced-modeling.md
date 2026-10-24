# Large rooms, detail passes and performance

Use when the task needs area-based work, detailed objects, physics or performance tuning. Paths below use this repository layout; other projects may use different paths. Delegate only when that helps the requested work.

## Parallel build (big rooms)

Split the room into areas (e.g. built-ins wall, desk/workstation, wing/closet, walls+lights) and give
each worker one file `demos/<room>/parts/<area>.ts` exporting `build(ctx: PartContext)`
(example brief: `../assets/BRIEF.example.md`). The room
module loads `parts/*.ts` with `import.meta.glob`, wraps each build in try/catch, and honors
`?parts=a,b` so workers can render just their own area. Write a shared BRIEF.md first: coordinates,
walls table, soffits, reference files, render commands, rules (own file only, performance budget,
representative photo comparisons and a clear stopping criterion, final report). Give each worker its own `CAP_SESSION` (agent-browser
session) and `CAP_OUT`. Workers report shared-file problems (door handles, wall jogs) back instead of
editing the shell; you fix those and integrate. Include the approved visual benchmark and the
quality-first requirement in every worker brief. Split broad assignments further when needed to
give individual items proper attention; do not cap a worker at a quick pass. Review the worker's
actual renders and request further refinement when its objects remain schematic. After integrating: look for duplicate objects between
parts (grep names across parts), then tune lighting on the whole room: neutral hemisphere ground color
(a warm one tints the ceiling), per-room exposure, and bloom with a high threshold (~4.5, scene-linear)
so only HDR emissives (neon ×6, softbox faces ≈5) glow; lit walls must stay under it.

## Multiple rooms / whole house

Use one coordinate frame for the whole house. Within one session it is shared. For multi-session exports, use the active scans and validated placements from `house_to_rooms.py`; see [house-capture.md](house-capture.md). With separate
GLBs, align each room to its neighbor through the shared doorway (same opening, matching jamb
positions) before modeling. Put each room in its own module (`demos/<name>/`) implementing
`RoomModule` (build → group, lights, walls for cutaway, walkable(), camera defaults, reference
layer, photos), register it in `demos/index.ts`, and the viewer/capture page picks it up
(`?room=<id>`). Several scans of the same room from one session start usually land in nearly the
same frame: compare their desk/table centers, and borrow furniture boxes RoomPlan found in one
scan but not another.

## HD pass (per-item detail), play mode, performance budget

For a detailed reconstruction, include a per-item detail pass consistent with the requested scope. Inspect each visible object against all useful
photo angles: model its specific silhouette, layered construction, edge profiles, upholstery folds
and seams, hardware, and distinctive accessories. Use primitives as construction components, not
as substitutes for the final shape. Match recognizable toys and clutter individually when references
permit; repeated generic toy cars or colored blocks are not equivalent to the photographed objects.

Use rectified source imagery for visible graphics and suitable physically based textures for
surfaces. Check texel scale and alternate views. Remove baked shadows and seam bands from repeating
fabric crops; do not stretch a whole-object photograph across unrelated geometry. Inspect roughness
and lighting against photos so metal, plastic, cloth, and wood remain visibly distinct. Preserve
subtle surface variation without introducing noise or exaggerated bump detail.

Once layout is right, "looks like a 90s video game" is fixed per object, not globally: one worker per
object group, each owning `demos/<room>/items/<item>.ts` (auto-loaded by `import.meta.glob`, files
starting with `_` are shared helpers; `?items=a`, `?hideItems=a` for isolated/AB renders), removing the
object's old block from its part file with a one-line pointer comment. What moved the needle:
real product dimensions (look them up), custom geometry (lathe/extrude-with-bevel/tube along photo-
traced curves), rectified photo crops for every label/graphic/screen (PIL perspective transform),
CC0 PBR maps (fetch_textures.py), photo comparisons until the significant discrepancies are resolved. Example brief:
`../assets/BRIEF.example.md`.

Physics tagging for the Rapier play mode (`play.html`, `packages/room-physics/* and apps/room-viewer/src/play/*`): tag the top-level Object3D of
every separable thing `userData.physics = {type:'dynamic', mass, shape?, surface?} | {type:'static'} |
{type:'none'}` (shape: box/sphere/cylinder/hull/decompose; cables, glows, cloth → none). Each throwable
must be its own object (never merged into a static batch).

Optimize runtime without lowering the visual acceptance standard. Prefer batching, instancing,
idle rendering, and measured lighting changes before removing visible detail. Compare full-quality
stills before and after optimization; keep a quality rendering path when a cheaper approximation
visibly changes the result. Interactive responsiveness does not impose an authoring time budget.

Performance traps found the hard way (M1 Max, 1400×900):
- **Forward-light count dominates.** Every light is evaluated on every lit pixel and HD physical
  materials make each one expensive, superlinearly (1 light ≈ 7 ms, 5 ≈ 15, 10 ≈ 40, 21 ≈ 84 ms).
  Budget ≈ 8–9 lights per room: the shadowed key lights + a few `userData.keep` item lights; drop
  small "glow" point lights (emissive + bloom carry them). Tag `userData.keep` *before* `addLight`
  (the budget decides at that call; a tag set afterwards silently drops the light). A/B the removed lights against photos —
  they rarely matter. Keep `?alllights` for the full rig.
- **`transmission` is expensive**: it re-renders the whole scene every frame. Prefer alpha
  (`transparent`, low opacity, `depthWrite:false`) for bottles, bins, lids when comparisons show
  equivalent appearance. If refraction is necessary for fidelity, retain it in the quality path
  and optimize its runtime cost rather than silently replacing it with visibly inferior glass.
- Merge static meshes by material (`packages/room-runtime/batch.ts`, `room.optimize()`), also in play mode (without
  `static:true`, so dynamic bodies stay separate). Viewer may merge bodies too (`static:true`).
- Clearcoat roughness < 0.05 under strong lights overflows half floats → black frames; anisotropy
  without tangents → NaNs. Floor/guard both globally (render.ts NaN-safe `opaque_fragment`).
- Measure with fresh browser sessions (a reused session accumulates GPU memory and gets slower),
  use the rAF frame interval, not GPU timer queries (tile-based GPUs overlap passes), and check
  `photoanalysisd`/other GPU users before trusting a number.

Interactive viewer performance:
- Profile navigation at the actual viewport and device pixel ratio; a small static capture is not a navigation benchmark. Record median and p95 rAF intervals in fresh sessions with the same camera movement.
- For static rooms, redraw only when camera, room, source, visibility or viewport changes. Keep controls updating for damping; invalidate after async reference loads and mode changes. Skip rendering in hidden tabs and Layout mode.
- Reduce drawing-buffer resolution during navigation, adapt conservatively to sustained slow frames, then restore full resolution after settling. Resize the renderer and composer together. Keep capture-page output at its requested resolution.
- Refresh opaque/transparent visibility lists on rendered frames so cutaway and source changes cannot use stale lists. Verify Scan, Overlay, Layout, walking, resize and idle draw counts, and inspect full-resolution before/after stills.
