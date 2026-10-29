import { appURL } from './asset-base';
import { collectInventory, showKnolling, stopKnolling } from './knolling';
import { showLayout } from './layout';
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { PointerLockControls } from 'three/addons/controls/PointerLockControls.js';
import { ROOMS, roomById, type BuiltRoom } from '../../../demos/index';
import type { RoomModule } from '../../../packages/room-runtime/types';
import { configureRenderer, disposeMirror } from '../../../packages/room-runtime/lighting';
import { disposeObjects } from '../../../packages/room-runtime/dispose';
import { updateCameraDepth } from '../../../packages/room-runtime/camera-depth';
import { setMaxAnisotropy } from '../../../packages/room-runtime/materials';
import { applyRoomRendering, createPipeline, precompileRoomRendering } from '../../../packages/room-runtime/render';
import { installAppearanceToggle } from './appearance';

document.querySelector('.play-link')!.addEventListener('click', () => { location.href = appURL('play.html') + location.search; });

const EYE_HEIGHT = 1.6;
const WALK_SPEED = 1.5; // m/s
const RUN_SPEED = 3.5;

const canvas = document.querySelector<HTMLCanvasElement>('#scene')!;
const loaderEl = document.querySelector<HTMLDivElement>('#loader')!;
const hud = document.querySelector<HTMLDivElement>('#hud')!;
const viewport = document.querySelector<HTMLElement>('#viewport')!;
const controlsToggle = document.querySelector<HTMLButtonElement>('#controls-toggle')!;
function toggleControls(open: boolean) {
  document.body.classList.toggle('controls-open', open);
  controlsToggle.setAttribute('aria-expanded', String(open));
}
controlsToggle.addEventListener('click', () => toggleControls(controlsToggle.getAttribute('aria-expanded') !== 'true'));
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && document.body.classList.contains('controls-open')) {
    toggleControls(false);
    controlsToggle.focus();
  }
});

const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setSize(viewport.clientWidth, viewport.clientHeight);
setMaxAnisotropy(renderer.capabilities.getMaxAnisotropy());

const scene = new THREE.Scene();
scene.background = new THREE.Color('#111');
configureRenderer(renderer, scene);

const camera = new THREE.PerspectiveCamera(55, viewport.clientWidth / viewport.clientHeight, 0.05, 100);
const orbit = new OrbitControls(camera, canvas);
orbit.enableDamping = true;
orbit.maxDistance = 30;
orbit.minDistance = 0.25;
orbit.maxPolarAngle = Math.PI / 2 + 0.12;
orbit.zoomToCursor = true;
// Keep a little smoothing without the long glide that delays full-resolution rendering.
orbit.dampingFactor = 0.35;
orbit.rotateSpeed = 0.7;
orbit.screenSpacePanning = true;
canvas.tabIndex = 0;
orbit.listenToKeyEvents(canvas);
canvas.setAttribute('aria-label', 'Interactive room. Drag to orbit, scroll to zoom, double-click to focus. Home resets the view.');
const walk = new PointerLockControls(camera, canvas);
const pipeline = createPipeline(renderer, scene, camera);
let dirty = true;
let pendingFrame = 0;
function requestFrame() {
  if (!pendingFrame && !document.hidden) pendingFrame = requestAnimationFrame(renderFrame);
}
const invalidate = () => { dirty = true; requestFrame(); };
installAppearanceToggle(document.querySelector<HTMLButtonElement>('#appearance-toggle')!, appearance => {
  scene.background = new THREE.Color(appearance === 'dark' ? '#111' : '#e7e9e6');
  invalidate();
});
THREE.DefaultLoadingManager.onLoad = invalidate;
orbit.addEventListener('change', invalidate);
walk.addEventListener('change', invalidate);
// Preserve full resolution for a settled view; spend fewer pixels while navigating.
let movingRatio = Math.min(window.devicePixelRatio, 1);
let lastMotion = -Infinity;
let slowFrames = 0;
let fastFrames = 0;
let lastFrame = 0;
const renderedPosition = new THREE.Vector3(Infinity, Infinity, Infinity);
const renderedRotation = new THREE.Quaternion();
function resolution(ratio: number) {
  if (renderer.getPixelRatio() === ratio) return;
  renderer.setPixelRatio(ratio);
  pipeline.setPixelRatio(ratio);
  invalidate();
}


// --- Rooms -----------------------------------------------------------------

const walkButton = hud.querySelector<HTMLButtonElement>('[data-mode=walk]')!;
if (!canvas.requestPointerLock) {
  walkButton.disabled = true;
  walkButton.title = 'Walking requires a browser with mouse pointer lock.';
}

const roomSelect = document.querySelector<HTMLDivElement>('[data-group="room"]')!;
for (const r of ROOMS) {
  const b = document.createElement('button');
  b.textContent = r.label;
  b.dataset.room = r.id;
  b.addEventListener('click', () => loadRoom(r.id));
  roomSelect.append(b);
}

const roomBounds = new THREE.Box3();
let room: BuiltRoom | undefined;
let roomId = '';
let activeRoomId = '';
let roomRequest = 0;
const statusEl = document.querySelector<HTMLOutputElement>('#viewer-status')!;
const layoutHost = document.querySelector<HTMLElement>('#layout')!;
const knollingHost = document.querySelector<HTMLElement>('#knolling')!;
let reference: THREE.Object3D | undefined;
let referenceLoading: Promise<THREE.Object3D> | undefined;
let referenceEpoch = 0;
const built = new Map<string, Promise<BuiltRoom>>();
const cachedRooms = new Map<string, BuiltRoom>();
let renderedRoom: BuiltRoom | undefined;
let preparing: Promise<void> | undefined;
async function prepareRendering() {
  if (preparing) await preparing;
  if (room && renderedRoom !== room) {
    const owner = room;
    preparing = (async () => {
    // A cached room may still have its previous camera's cutaway applied.
    owner.walls.forEach(w => { w.group.visible = true; });
    owner.ceiling.forEach(c => { c.visible = true; });
    statusEl.textContent = 'Preparing room lighting…';
    pipeline.setSceneRenderer();
    await precompileRoomRendering(renderer, scene, owner, camera);
    if (room !== owner) return;
    applyRoomRendering(renderer, scene, owner, pipeline);
    renderedRoom = owner;
    statusEl.textContent = roomById(roomId).label;
    })();
    try { await preparing; } finally { preparing = undefined; invalidate(); }
  }
}

async function loadRoom(id: string, updated?: RoomModule) {
  const mod = updated ?? roomById(id);
  if (mod.id === roomId && !updated) return;
  if (updated) { saveLiveView(); built.delete(mod.id); }
  if (mode === 'walk') setMode('orbit');
  roomId = mod.id;
  const request = ++roomRequest;
  if (!room) loaderEl.classList.remove('done');
  loaderEl.querySelector<HTMLElement>('.fill')!.style.width = '0%';
  loaderEl.querySelector('.pct')!.textContent = '';
  hud.hidden = false;
  statusEl.textContent = `${updated ? 'Updating' : 'Loading'} ${mod.label}…`;
  let next: BuiltRoom;
  try {
    if (!built.has(mod.id)) built.set(mod.id, mod.build());
    next = await built.get(mod.id)!;
  } catch (error) {
    built.delete(mod.id);
    if (request === roomRequest) {
      roomId = room ? activeRoomId : '';
      loaderEl.classList.add('done');
      hud.hidden = false;
      statusEl.textContent = `Could not load ${mod.label}. Select the room to retry.`;
    }
    console.error(error);
    return;
  }
  if (request !== roomRequest) return; // switched again while building

  const replaced = updated ? cachedRooms.get(mod.id) : undefined;
  const oldReference = reference;
  cachedRooms.set(mod.id, next);
  const releaseReplaced = () => {
    const retained: THREE.Object3D[] = [...cachedRooms.values()].flatMap(r => [r.group, r.lights]);
    if (reference) retained.push(reference);
    if (replaced && replaced !== next) {
      if (replaced.environment.mirror !== next.environment.mirror) disposeMirror(replaced.environment.mirror);
      disposeObjects([replaced.group, replaced.lights], retained);
    }
    if (oldReference) disposeObjects([oldReference], retained);
  };
  if (room) scene.remove(room.group, room.lights);
  if (reference) scene.remove(reference);
  reference = undefined;
  referenceLoading = undefined;
  referenceEpoch++;
  room = next;
  activeRoomId = mod.id;
  transition = undefined;
  movingRatio = Math.min(window.devicePixelRatio, 1);
  slowFrames = fastFrames = 0;
  scene.add(room.group, room.lights);
  roomBounds.setFromObject(room.group);
  // The assembled house currently has no combined scan reference.
  hud.querySelectorAll<HTMLButtonElement>('[data-source]').forEach(button => {
    button.disabled = room?.referenceAvailable === false && ['scan', 'overlay'].includes(button.dataset.source ?? '');
  });
  if (room?.referenceAvailable === false && (source === 'scan' || source === 'overlay')) source = 'model';
  orbit.maxDistance = mod.id === 'house' ? 80 : 30;
  collectInventory(room);
  room.optimize?.({ static: true });
  if (mode !== 'layout' && mode !== 'knolling' && !['layout', 'knolling'].includes(new URLSearchParams(location.search).get('view') ?? '')) await prepareRendering();
  if (request !== roomRequest) { releaseReplaced(); return; }

  if (room.layout) showLayout(layoutHost, room.layout, mod.label);
  hud.querySelector<HTMLButtonElement>('[data-mode=layout]')!.disabled = !room.layout;
  if (mode === 'layout' && !room.layout) setMode('orbit');
  clearDamping();
  camera.position.copy(homePosition());
  orbit.target.set(...room.camera.target);
  restoreLiveView(mod.id);
  orbit.update();
  activate('room', mod.id);
  statusEl.textContent = mod.label;
  const url = new URL(location.href);
  if (url.searchParams.get('room') !== mod.id) url.searchParams.delete('camera');
  url.searchParams.set('room', mod.id);
  history.replaceState(null, '', url);
  loaderEl.classList.add('done');
  hud.hidden = false;
  await setSource(source, true);
  // HMR can rebuild hundreds of meshes repeatedly during an authoring session.
  // Release the superseded GPU allocations after the replacement is compiled.
  releaseReplaced();
  if (mode === 'knolling') void showKnolling(knollingHost, room, mod.label);
  invalidate();
}

function ensureReference() {
  const owner = room!, epoch = referenceEpoch;
  referenceLoading ??= owner.loadReference((p) => { if (room === owner && referenceEpoch === epoch && (source === 'scan' || source === 'overlay')) setProgress(p); }).then((r) => {
    // A reference may finish after the user returns to Rebuilt or selects another room.
    if (room === owner && referenceEpoch === epoch) {
      reference = r;
      r.visible = (source === 'scan' || source === 'overlay');
      scene.add(r);
      loaderEl.classList.add('done');
    }
    return r;
  }).catch(error => {
    if (room === owner && referenceEpoch === epoch) referenceLoading = undefined;
    throw error;
  });
  return referenceLoading;
}

function setProgress(p: number) {
  loaderEl.classList.remove('done');
  loaderEl.querySelector<HTMLDivElement>('.fill')!.style.width = `${Math.round(p * 100)}%`;
  loaderEl.querySelector('.pct')!.textContent = `${Math.round(p * 100)}%`;
}

// --- Source: rebuilt model, raw scan/layout, or both overlaid ----------------------

type Source = 'model' | 'scan' | 'overlay' | 'wireframe';
let source: Source = 'model';
// A render-only override keeps original textures/materials intact, including cached rooms.
const wireframeMaterial = new THREE.MeshBasicMaterial({
  color: '#9de2f0', wireframe: true, toneMapped: false, side: THREE.DoubleSide,
});
function renderWireframe() {
  const previous = scene.overrideMaterial;
  const shadows = renderer.shadowMap.enabled;
  try {
    scene.overrideMaterial = wireframeMaterial;
    renderer.shadowMap.enabled = false;
    renderer.setRenderTarget(null);
    // Draw the complete tree directly, including all house rooms, without AO/bloom.
    renderer.render(scene, camera);
  } finally {
    scene.overrideMaterial = previous;
    renderer.shadowMap.enabled = shadows;
  }
}


async function setSource(next: Source, force = false) {
  if (next === source && !force) return;
  source = next;
  if (!room) return;
  const owner = room, epoch = referenceEpoch;
  if (next === 'scan' || next === 'overlay') {
    try { await ensureReference(); }
    catch (error) {
      if (room === owner && referenceEpoch === epoch && source === next) {
        referenceLoading = undefined;
        loaderEl.classList.add('done');
        statusEl.textContent = 'Reference could not load. Select Scan or Overlay to retry.';
        await setSource('model', true);
      }
      console.error(error);
      return;
    }
  } else loaderEl.classList.add('done');
  if (source !== next || room !== owner || referenceEpoch !== epoch) return; // changed while loading
  room.group.visible = next !== 'scan';
  room.lights.visible = room.group.visible;
  if (reference) {
    reference.visible = next === 'scan' || next === 'overlay';
    if (room.referenceKind === 'scan') {
      reference.traverse((obj) => {
        if (!(obj instanceof THREE.Mesh)) return;
        const mat = obj.material as THREE.MeshBasicMaterial;
        mat.transparent = next === 'overlay';
        mat.opacity = next === 'overlay' ? 0.45 : 1;
        mat.depthWrite = next !== 'overlay';
        mat.needsUpdate = true;
      });
    }
  }
  activate('source', next);
  invalidate();
}

// --- Navigation modes ------------------------------------------------------

type Mode = 'orbit' | 'walk' | 'layout' | 'knolling';
let mode: Mode = 'orbit';
const savedOrbit = { position: new THREE.Vector3(), target: new THREE.Vector3() };

function setMode(next: Mode) {
  if (next === mode || !room || (next === 'layout' && !room.layout)) return;
  transition = undefined;
  keys.clear();
  walkVelocity.set(0, 0);
  clearDamping();
  if (next === 'walk') toggleControls(false);
  const previous = mode;
  mode = next;
  layoutHost.hidden = mode !== 'layout';
  canvas.hidden = mode === 'layout' || mode === 'knolling';
  knollingHost.hidden = mode !== 'knolling';
  document.body.classList.toggle('knolling-mode', mode === 'knolling');
  if (mode === 'knolling') void showKnolling(knollingHost, room, roomById(roomId).label);
  else stopKnolling();
  document.body.classList.toggle('layout-mode', mode === 'layout');
  hud.querySelector<HTMLElement>('[data-group=source]')!.hidden = mode === 'layout' || mode === 'knolling';
  const url = new URL(location.href);
  url.searchParams.set('view', mode);
  history.replaceState(null, '', url);

  if (mode === 'walk') {
    savedOrbit.position.copy(camera.position);
    savedOrbit.target.copy(orbit.target);
    orbit.enabled = false;
    camera.position.set(...room.camera.walk);
    camera.lookAt(...room.camera.walkLook);
    canvas.focus({ preventScroll: true });
    walk.lock();
  } else {
    if (walk.isLocked) walk.unlock();
    if (previous === 'walk') {
      camera.position.copy(savedOrbit.position);
      orbit.target.copy(savedOrbit.target);
    }
    orbit.enabled = true;
    orbit.update();
  }

  if (mode !== 'layout' && mode !== 'knolling') void prepareRendering();
  navigation.hidden = mode !== 'orbit';
  activate('mode', mode);
  invalidate();
  hud.querySelectorAll<HTMLElement>('.help').forEach((el) => {
    el.hidden = el.dataset.for !== mode;
  });
}

function activate(group: 'source' | 'mode' | 'room', value: string) {
  hud.querySelectorAll<HTMLButtonElement>(`[data-group="${group}"] button`).forEach((btn) => {
    btn.classList.toggle('active', btn.dataset[group] === value);
    btn.setAttribute('aria-pressed', String(btn.dataset[group] === value));
  });
}

hud.querySelectorAll<HTMLButtonElement>('button[data-mode]').forEach((btn) => {
  btn.addEventListener('click', () => setMode(btn.dataset.mode as Mode));
});
hud.querySelectorAll<HTMLButtonElement>('button[data-source]').forEach((btn) => {
  btn.addEventListener('click', () => setSource(btn.dataset.source as Source));
});

// Esc releases pointer lock; treat that as leaving walk mode
walk.addEventListener('unlock', () => { if (mode === 'walk') setMode('orbit'); });
// Browsers refuse re-locking right after an Esc, so fall back instead of getting stuck
document.addEventListener('pointerlockerror', () => setMode('orbit'));

// --- Dollhouse cutaway: hide walls between the camera and the room ---------

const mid = new THREE.Vector3();
const toCam = new THREE.Vector3();
function updateCutaway() {
  if (!room) return;
  const inside = mode === 'walk';
  for (const { def, group } of room.walls) {
    mid.copy(def.origin).addScaledVector(def.u, def.length / 2);
    group.visible = inside || toCam.copy(camera.position).sub(mid).dot(def.n) > 0;
  }
  for (const c of room.ceiling) c.visible = inside || camera.position.y < room.wallTop;
}

// --- Walk movement ---------------------------------------------------------

const keys = new Set<string>();
window.addEventListener('keydown', (e) => {
  if (e.target instanceof HTMLElement && (e.target.matches('input, select, textarea, button') || e.target.isContentEditable)) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (mode === 'walk' && ['KeyW', 'KeyA', 'KeyS', 'KeyD', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'ShiftLeft', 'ShiftRight'].includes(e.code)) {
    e.preventDefault();
    keys.add(e.code);
    requestFrame();
  }
  if (mode !== 'orbit') return;
  const views: Record<string, View> = { Home: 'home', Digit1: 'home', Digit2: 'top', Digit3: 'front', Digit4: 'side' };
  if (views[e.code]) { e.preventDefault(); preset(views[e.code]); }
  if (e.code === 'Equal' || e.code === 'Minus') { e.preventDefault(); zoom(e.code === 'Equal' ? 0.8 : 1.25); }
});
window.addEventListener('keyup', (e) => keys.delete(e.code));
window.addEventListener('blur', () => { keys.clear(); walkVelocity.set(0, 0); });

const before = new THREE.Vector3();
const movedPosition = new THREE.Vector3();
const walkVelocity = new THREE.Vector2();
const walkDirection = new THREE.Vector2();
function updateWalk(dt: number) {
  const forward = Number(keys.has('KeyW') || keys.has('ArrowUp')) - Number(keys.has('KeyS') || keys.has('ArrowDown'));
  const right = Number(keys.has('KeyD') || keys.has('ArrowRight')) - Number(keys.has('KeyA') || keys.has('ArrowLeft'));
  if (!walk.isLocked) { walkVelocity.set(0, 0); return; }

  const speed = keys.has('ShiftLeft') || keys.has('ShiftRight') ? RUN_SPEED : WALK_SPEED;
  walkDirection.set(right, forward).normalize().multiplyScalar(speed);
  walkVelocity.lerp(walkDirection, 1 - Math.exp(-14 * dt));
  if (walkVelocity.lengthSq() < 0.0001) { walkVelocity.set(0, 0); return; }
  before.copy(camera.position);
  walk.moveForward(walkVelocity.y * dt);
  walk.moveRight(walkVelocity.x * dt);
  // No collision with furniture, but stay inside the room (slide along walls)
  if (!room!.walkable(camera.position.x, camera.position.z)) {
    const moved = movedPosition.copy(camera.position);
    camera.position.set(moved.x, before.y, before.z);
    if (!room!.walkable(camera.position.x, camera.position.z)) {
      camera.position.set(before.x, before.y, moved.z);
      if (!room!.walkable(camera.position.x, camera.position.z)) camera.position.copy(before);
    }
  }
  camera.position.y = EYE_HEIGHT;
}

// --- Camera navigation -----------------------------------------------------

type View = 'home' | 'top' | 'front' | 'side';
const navigation = document.querySelector<HTMLElement>('#navigation')!;
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
let transition: { start: number; from: THREE.Vector3; to: THREE.Vector3; fromTarget: THREE.Vector3; toTarget: THREE.Vector3 } | undefined;
function clearDamping() {
  const damping = orbit.enableDamping;
  orbit.enableDamping = false;
  orbit.update();
  orbit.enableDamping = damping;
}
function moveCamera(position: THREE.Vector3, target: THREE.Vector3) {
  clearDamping();
  transition = { start: performance.now(), from: camera.position.clone(), to: position,
    fromTarget: orbit.target.clone(), toTarget: target };
  invalidate();
}
function homePosition() {
  const target = new THREE.Vector3(...room!.camera.target);
  return new THREE.Vector3(...room!.camera.orbit).sub(target).multiplyScalar(Math.max(1, 1.18 / camera.aspect)).add(target);
}
function preset(view: View) {
  if (!room || mode !== 'orbit') return;
  const target = new THREE.Vector3(...room.camera.target);
  const home = homePosition();
  const distance = home.distanceTo(target);
  const directions = { top: new THREE.Vector3(0, 1, 0.001), front: new THREE.Vector3(0, 0.18, 1), side: new THREE.Vector3(1, 0.18, 0) };
  moveCamera(view === 'home' ? home : directions[view].normalize().multiplyScalar(distance).add(target), target);
}
function zoom(factor: number) {
  if (mode !== 'orbit') return;
  const offset = camera.position.clone().sub(orbit.target);
  offset.setLength(THREE.MathUtils.clamp(offset.length() * factor, orbit.minDistance, orbit.maxDistance));
  moveCamera(orbit.target.clone().add(offset), orbit.target.clone());
}
navigation.querySelectorAll<HTMLButtonElement>('[data-view]').forEach(button => {
  button.addEventListener('click', () => preset(button.dataset.view as View));
});
navigation.querySelector<HTMLButtonElement>('[data-zoom=in]')!.addEventListener('click', () => zoom(0.8));
navigation.querySelector<HTMLButtonElement>('[data-zoom=out]')!.addEventListener('click', () => zoom(1.25));
orbit.addEventListener('start', () => { transition = undefined; lastMotion = performance.now(); requestFrame(); });
canvas.addEventListener('pointerdown', () => canvas.focus({ preventScroll: true }));
const raycaster = new THREE.Raycaster();
canvas.addEventListener('dblclick', event => {
  if (!room || mode !== 'orbit') return;
  const rect = canvas.getBoundingClientRect();
  raycaster.setFromCamera(new THREE.Vector2((event.clientX - rect.left) / rect.width * 2 - 1, -(event.clientY - rect.top) / rect.height * 2 + 1), camera);
  const meshes: THREE.Object3D[] = [];
  for (const root of [room.group, reference]) root?.traverseVisible(o => { if ((o as THREE.Mesh).isMesh) meshes.push(o); });
  const hit = raycaster.intersectObjects(meshes, false)[0];
  if (!hit) return;
  const offset = camera.position.clone().sub(hit.point);
  offset.setLength(THREE.MathUtils.clamp(offset.length() * 0.65, 0.6, orbit.maxDistance));
  moveCamera(hit.point.clone().add(offset), hit.point.clone());
});

type Quality = 'auto' | 'detail' | 'fast';
const qualitySelect = document.querySelector<HTMLSelectElement>('#quality')!;
let quality: Quality = 'auto';
qualitySelect.addEventListener('change', () => {
  quality = qualitySelect.value as Quality;
  movingRatio = Math.min(devicePixelRatio, 1);
  slowFrames = fastFrames = 0;
  invalidate();
});

// Portable camera bookmarks include the orbit target: position alone loses the view angle.
const cameraCoordinates = document.querySelector<HTMLOutputElement>('#camera-coordinates')!;
const cameraLink = document.querySelector<HTMLInputElement>('#camera-link')!;
const cameraCopyStatus = document.querySelector<HTMLElement>('#camera-copy-status')!;
function updateCameraHelper() {
  if (!room || mode !== 'orbit') return;
  const values = [...camera.position.toArray(), ...orbit.target.toArray(), camera.fov].map(n => Number(n.toFixed(5)));
  const coordinates = `Position (m)\n${values.slice(0,3).join(', ')}\nLooking at (m)\n${values.slice(3,6).join(', ')}`;
  if (cameraCoordinates.textContent !== coordinates) cameraCoordinates.textContent = coordinates;
  const url = new URL(location.href);
  url.searchParams.set('room', activeRoomId);
  url.searchParams.set('view', 'orbit');
  url.searchParams.set('camera', values.join(','));
  if (cameraLink.value !== url.href) {
    cameraLink.value = url.href;
    cameraCopyStatus.textContent = '';
  }
}
document.querySelector('#copy-camera-link')!.addEventListener('click', async () => {
  updateCameraHelper();
  try {
    await navigator.clipboard.writeText(cameraLink.value);
    cameraCopyStatus.textContent = 'View link copied';
  } catch {
    cameraLink.focus(); cameraLink.select();
    cameraCopyStatus.textContent = 'Copy the selected link to save this view.';
  }
});
function restoreCameraLink() {
  const encoded = new URLSearchParams(location.search).get('camera');
  if (!encoded) return;
  const values = encoded.split(',').map(Number);
  if (values.length !== 7 || values.some(n => !Number.isFinite(n) || Math.abs(n) > 1000)
    || values[6] < 10 || values[6] > 120) return;
  const position = new THREE.Vector3(...values.slice(0,3));
  const target = new THREE.Vector3(...values.slice(3,6));
  if (position.distanceTo(target) < orbit.minDistance || position.distanceTo(target) > orbit.maxDistance) return;
  clearDamping();
  camera.position.copy(position); orbit.target.copy(target);
  camera.fov = values[6]; camera.updateProjectionMatrix(); orbit.update(); invalidate();
}

// Keep the recorded angle across development rebuilds. Each room has its own
// session-only camera; a broken/stale entry must never prevent a room loading.
function saveLiveView() {
  if (!import.meta.env.DEV || !room || mode !== 'orbit' ) return;
  try {
    sessionStorage.setItem(`room-viewer:live:${activeRoomId}`, JSON.stringify({
      position: camera.position.toArray(), target: orbit.target.toArray(), quality,
    }));
  } catch { /* Private browsing can disable storage. */ }
}
function restoreLiveView(id: string) {
  if (!import.meta.env.DEV) return;
  try {
    const saved = JSON.parse(sessionStorage.getItem(`room-viewer:live:${id}`) ?? 'null');
    const valid = (v: unknown): v is number[] => Array.isArray(v) && v.length === 3
      && v.every(n => typeof n === 'number' && Number.isFinite(n) && Math.abs(n) < 1000);
    if (!valid(saved?.position) || !valid(saved?.target)) return;
    camera.position.fromArray(saved.position);
    orbit.target.fromArray(saved.target);
    if (['auto', 'detail', 'fast'].includes(saved.quality)) {
      quality = saved.quality;
      qualitySelect.value = quality;
    }
  } catch { /* Ignore malformed state. */ }
}
if (import.meta.hot) import.meta.hot.on('vite:beforeFullReload', saveLiveView);
window.addEventListener('pagehide', saveLiveView);

// --- Render only while something changes ----------------------------------

let previousTime = 0;
let renderedFrames = 0;
function renderFrame(time: number) {
  pendingFrame = 0;
  const dt = previousTime ? Math.min((time - previousTime) / 1000, 0.05) : 1 / 60;
  previousTime = time;
  if (mode === 'layout' || mode === 'knolling' || document.hidden || !room || preparing) { lastFrame = 0; previousTime = 0; return; }
  else if (mode === 'walk') updateWalk(dt);
  else if (transition) {
    const progress = reducedMotion.matches ? 1 : Math.min(1, (time - transition.start) / 350);
    const eased = 1 - Math.pow(1 - progress, 3);
    camera.position.lerpVectors(transition.from, transition.to, eased);
    orbit.target.lerpVectors(transition.fromTarget, transition.toTarget, eased);
    orbit.update();
    if (progress === 1) transition = undefined;
  } else orbit.update();
  updateCameraHelper();
  const moved = renderedPosition.distanceToSquared(camera.position) > 1e-10
    || 1 - Math.abs(renderedRotation.dot(camera.quaternion)) > 1e-10;
  if (moved) {
    lastMotion = time;
    // Only consecutive moving frames are useful; startup and idle aren't GPU pressure.
    const elapsed = lastFrame ? time - lastFrame : 0;
    slowFrames = elapsed > 24 && elapsed < 150 ? slowFrames + 1 : Math.max(0, slowFrames - 1);
    fastFrames = elapsed > 0 && elapsed < 19 ? fastFrames + 1 : 0;
    if (slowFrames >= 12) { movingRatio = Math.max(Math.min(devicePixelRatio, 0.65), movingRatio - 0.15); slowFrames = 0; }
    if (fastFrames >= 90) { movingRatio = Math.min(devicePixelRatio, 1, movingRatio + 0.1); fastFrames = 0; }
  }
  const moving = time - lastMotion < 80;
  const navigating = (quality === 'fast' || (quality === 'auto' && moving));
  resolution(navigating ? movingRatio : Math.min(devicePixelRatio, 2));
  // Auto changes pixel count while retaining the room's contact shading and glow.
  const effects = source !== 'scan' && (quality !== 'fast');
  if (pipeline.ao !== effects) { pipeline.ao = effects; dirty = true; }
  if (dirty || moved) {
    updateCutaway();
    updateCameraDepth(camera, roomBounds, mode === 'orbit' && (source === 'model' || source === 'wireframe'));
    if (source === 'wireframe') renderWireframe();
    else pipeline.render();
    renderedFrames++;
    renderedPosition.copy(camera.position);
    renderedRotation.copy(camera.quaternion);
    dirty = false;
  }
  lastFrame = moving ? time : 0;
  if (moving || transition || (mode === 'walk' && walk.isLocked && walkVelocity.lengthSq() > 0)) requestFrame();
  else { previousTime = 0; saveLiveView(); }
}

document.addEventListener('visibilitychange', () => {
  keys.clear();
  walkVelocity.set(0, 0);
  previousTime = lastFrame = 0;
  if (document.hidden && pendingFrame) { cancelAnimationFrame(pendingFrame); pendingFrame = 0; }
  else invalidate();
});
const viewportObserver = new ResizeObserver(() => {
  camera.aspect = viewport.clientWidth / viewport.clientHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(viewport.clientWidth, viewport.clientHeight);
  pipeline.setSize(viewport.clientWidth, viewport.clientHeight);
  invalidate();
});

viewportObserver.observe(viewport);

// Keep the canvas and shader cache alive while room modules are authored. The
// old scene remains visible until a replacement has finished building.
if (import.meta.hot) {
  import.meta.hot.accept('../../../demos/index', next => {
    if (next) void loadRoom(roomId, next.roomById(roomId));
  });
}

await loadRoom(new URLSearchParams(location.search).get('room') ?? ROOMS[0].id);

const initialView = new URLSearchParams(location.search).get('view');
if (initialView === 'layout' || initialView === 'knolling') setMode(initialView);
else restoreCameraLink();
updateCameraHelper();

if (import.meta.env.DEV) Object.assign(window, { __viewer: { renderer, scene, camera, pipeline, orbit,
  get room() { return room; }, get stats() { return { renderedFrames, pendingFrame, movingRatio, quality }; } } });

