import './seed-random';
import '../src/asset-base';
// glTF export of a rebuilt room, driven by tools/export-room.mjs (no manual use):
//   /tools/export.html?room=<id>  ->  <id>.glb, <id>-lidar.glb, <id>-photos.glb through window.__exportSave
// The room is built but never optimize()d, so every pipe, wall and prop stays its own named node.
// Math.random is seeded (./seed-random), so procedural textures are reproducible; Date.now() is not patched.
import * as THREE from 'three';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { roomById } from '../../../demos/index';
import type { BuiltRoom } from '../../../packages/room-runtime/types';

declare global {
  interface Window { __exportSave?: (message: string) => void; __exportReport?: unknown; __exportError?: string }
}

const id = new URLSearchParams(location.search).get('room') ?? '';
const CHUNK = 3 * 1024 * 1024; // multiple of 3 so base64 chunks concatenate

// --- delivery to the Node driver -------------------------------------------------------------

async function toBase64(bytes: Uint8Array) {
  const url = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as string);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(new Blob([bytes as BlobPart]));
  });
  return url.slice(url.indexOf(',') + 1);
}

async function deliver(file: string, buffer: ArrayBuffer) {
  if (!window.__exportSave) throw new Error('window.__exportSave is missing: run this page through tools/export-room.mjs');
  const bytes = new Uint8Array(buffer);
  for (let offset = 0; offset < bytes.length; offset += CHUNK) {
    window.__exportSave(JSON.stringify({ file, offset, total: bytes.length, data: await toBase64(bytes.subarray(offset, offset + CHUNK)) }));
  }
}

// --- naming ----------------------------------------------------------------------------------

const clean = (s: string) => s.replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
const geometryKind = (m: THREE.Mesh) => clean(m.geometry.type.replace('Geometry', '')).toLowerCase();
const materialOf = (m: THREE.Mesh) => ([] as THREE.Material[]).concat(m.material)[0];

/** Compass side a wall faces out to (north = -z, as in the plan views). */
function compass(def: BuiltRoom['walls'][number]['def']) {
  const ox = -def.n.x, oz = -def.n.z;
  return Math.abs(ox) > Math.abs(oz) ? (ox > 0 ? 'east' : 'west') : (oz > 0 ? 'south' : 'north');
}

/** Give every material a name (palette key when the demo set one, else type + colour). */
function nameMaterials(root: THREE.Object3D) {
  root.traverse(o => {
    if (!(o as THREE.Mesh).isMesh) return;
    for (const mat of ([] as THREE.Material[]).concat((o as THREE.Mesh).material)) {
      if (mat.name) continue;
      const color = (mat as THREE.MeshStandardMaterial).color;
      mat.name = `${mat.type.replace('Mesh', '').replace('Material', '').toLowerCase()}_${color ? color.getHexString() : 'none'}`;
    }
  });
}

/** Deterministic unique names: anonymous nodes are described by parent, geometry and material; clashes get _NN. */
function nameNodes(root: THREE.Object3D, fixed: Set<THREE.Object3D>) {
  const base = new Map<THREE.Object3D, string>();
  const counts = new Map<string, number>();
  root.traverse(o => {
    if (o === root) return;
    let name = fixed.has(o) ? o.name : clean(o.name || (o.userData.exportName as string | undefined) || '');
    if (!name) {
      const parent = o.parent && o.parent !== root ? base.get(o.parent) ?? '' : '';
      const mesh = o as THREE.Mesh;
      name = mesh.isMesh ? `${parent ? parent + '_' : ''}${geometryKind(mesh)}_${materialOf(mesh).name}` : `${parent ? parent + '_' : ''}group`;
    }
    base.set(o, name);
    counts.set(name, (counts.get(name) ?? 0) + 1);
  });
  const seen = new Map<string, number>();
  root.traverse(o => {
    if (o === root) return;
    const name = base.get(o)!;
    if (counts.get(name)! < 2 || fixed.has(o)) { o.name = name; return; }
    const n = (seen.get(name) ?? 0) + 1;
    seen.set(name, n);
    o.name = `${name}_${String(n).padStart(2, '0')}`;
  });
}

/** Keep only plain, serialisable userData (physics tags); the rest is runtime state. */
function cleanUserData(root: THREE.Object3D) {
  root.traverse(o => {
    const physics = o.userData.physics;
    o.userData = physics ? { physics: JSON.parse(JSON.stringify(physics)) } : {};
  });
}

// --- model preparation ------------------------------------------------------------------------

function group(name: string, parent?: THREE.Object3D) {
  const g = new THREE.Group();
  g.name = name;
  parent?.add(g);
  return g;
}

/** Re-parent keeping the world transform. */
const move = (o: THREE.Object3D, to: THREE.Object3D) => { to.attach(o); };

function arrange(room: BuiltRoom) {
  const root = group(id);
  const shell = group('shell', root), networks = group('networks'), fixtures = group('fixtures'), props = group('props');
  const fixed = new Set<THREE.Object3D>([root, shell, networks, fixtures, props]);
  room.group.updateMatrixWorld(true);

  const wallGroups = new Map(room.walls.map((w, i) => [w.group, { def: w.def, index: i }]));
  const ceilings = new Set(room.ceiling);
  const label = (o: THREE.Object3D) => o.name || (o.userData.exportName as string | undefined) || '';
  const shellNames = /^(floor|structure|steelwork)$/;
  const networkNames = /^(pipework|pipes|ducts|networks)$/;
  const wrapperNames = /^(services|clutter|furniture)$/;

  const doors: Record<string, number> = {};
  const place = (o: THREE.Object3D) => {
    const wall = wallGroups.get(o as THREE.Group);
    if (wall) {
      o.name = `wall_${String(wall.index).padStart(2, '0')}_${compass(wall.def)}`;
      fixed.add(o);
      o.children.filter(c => c.name === 'door').forEach(c => { const side = compass(wall.def); doors[side] = (doors[side] ?? 0) + 1; c.name = `door_${side}_${String(doors[side]).padStart(2, '0')}`; fixed.add(c); });
      return move(o, shell);
    }
    if (ceilings.has(o)) { fixed.add(o); return move(o, shell); }
    if (shellNames.test(label(o))) return move(o, shell);
    if (networkNames.test(label(o))) return move(o, networks);
    if (wrapperNames.test(label(o)) && o.children.length) { for (const c of [...o.children]) place(c); return; }
    if (/^(floodlight|grille)/.test(label(o))) return move(o, fixtures);
    move(o, props);
  };
  for (const child of [...room.group.children]) place(child);

  // run groups of a pipe network are named after the run (L1, N2, ...)
  for (const net of networks.children) for (const run of net.children) if (/^[A-Z]+\d+/.test(run.name) && run.type === 'Group') run.name = `pipe_${run.name}`;

  for (const g of [networks, fixtures, props]) if (g.children.length) root.add(g);
  return { root, fixed };
}

const isHelper = (o: THREE.Object3D) => (o as THREE.Sprite).isSprite || (o as THREE.Line).isLine || (o as THREE.Points).isPoints
  || (o as unknown as { isReflector?: boolean }).isReflector;

/** Drop viewer-only objects (labels, helpers, the environment mirror); returns their names for the report. */
function stripViewerOnly(root: THREE.Object3D, room: BuiltRoom) {
  const mirror = room.environment.mirror;
  const doomed: THREE.Object3D[] = [];
  root.traverse(o => {
    const mesh = o as THREE.Mesh;
    if (isHelper(o) || (mirror && mesh.isMesh && ([] as THREE.Material[]).concat(mesh.material).includes(mirror))) doomed.push(o);
  });
  const names = doomed.map(o => `${o.type}:${o.name || '<anon>'}`);
  for (const o of doomed) o.removeFromParent();
  return names;
}

/** Light nodes for glTF: spots aim along -Z (three's target is ignored), hemisphere lights have no glTF equivalent. */
function arrangeLights(source: THREE.Group) {
  const lights = group('lights');
  const skipped: string[] = [];
  const hemispheres: unknown[] = [];
  source.updateMatrixWorld(true);
  const counters: Record<string, number> = {};
  for (const light of source.children.filter(c => (c as THREE.Light).isLight)) {
    const l = light as THREE.Light;
    if ((l as THREE.HemisphereLight).isHemisphereLight) {
      const h = l as THREE.HemisphereLight;
      hemispheres.push({ sky: `#${h.color.getHexString()}`, ground: `#${h.groundColor.getHexString()}`, intensity: h.intensity });
      skipped.push('HemisphereLight');
      continue;
    }
    const kind = l.type.replace('Light', '').toLowerCase();
    if ((l as THREE.SpotLight).isSpotLight) {
      const s = l as THREE.SpotLight;
      s.updateWorldMatrix(true, false);
      s.lookAt(s.target.getWorldPosition(new THREE.Vector3()));
      s.target.removeFromParent(); // some rooms parent the target to the light: it would export as an unnamed node
    }
    counters[kind] = (counters[kind] ?? 0) + 1;
    l.name = `${kind}_${String(counters[kind]).padStart(2, '0')}`;
    l.userData = {};
    lights.add(l);
  }
  lights.userData = { hemisphereLights: hemispheres, note: 'three.js light units (candela); hemisphere lights are not representable in glTF' };
  return { lights, skipped };
}

/** Instanced meshes become one mesh per instance (instance colours baked into a material copy): Blender's instancing import is patchy. */
function expandInstances(root: THREE.Object3D) {
  const list: THREE.InstancedMesh[] = [];
  root.traverse(o => { if ((o as THREE.InstancedMesh).isInstancedMesh) list.push(o as THREE.InstancedMesh); });
  let extra = 0;
  const matrix = new THREE.Matrix4(), tint = new THREE.Color();
  for (const im of list) {
    const holder = group(im.name || `${im.geometry.type.replace('Geometry', '').toLowerCase()}_instances`);
    holder.position.copy(im.position); holder.quaternion.copy(im.quaternion); holder.scale.copy(im.scale);
    const base = im.material as THREE.MeshStandardMaterial;
    const variants = new Map<string, THREE.Material>();
    for (let i = 0; i < im.count; i++) {
      let material: THREE.Material = base;
      if (im.instanceColor) {
        im.getColorAt(i, tint);
        const key = tint.getHexString();
        if (!variants.has(key)) {
          const copy = base.clone();
          copy.color.multiply(tint);
          copy.name = `${base.name || 'material'}_${key}`;
          variants.set(key, copy);
        }
        material = variants.get(key)!;
      }
      const mesh = new THREE.Mesh(im.geometry, material);
      mesh.name = holder.name.replace(/_instances$/, '');
      im.getMatrixAt(i, matrix);
      matrix.decompose(mesh.position, mesh.quaternion, mesh.scale);
      holder.add(mesh);
    }
    extra += im.count - 1;
    im.parent!.add(holder);
    im.removeFromParent();
  }
  return extra;
}

// --- textures ----------------------------------------------------------------------------------

/** Photographic textures stay JPEG instead of becoming large PNGs. */
function keepJpeg(root: THREE.Object3D) {
  root.traverse(o => {
    if (!(o as THREE.Mesh).isMesh) return;
    for (const mat of ([] as THREE.Material[]).concat((o as THREE.Mesh).material)) {
      for (const value of Object.values(mat)) {
        const tex = value as THREE.Texture;
        const src = (tex?.isTexture && (tex.image as HTMLImageElement | undefined)?.src) || '';
        if (/\.jpe?g(\?|$)/i.test(src)) tex.userData.mimeType = 'image/jpeg';
      }
    }
  });
}

/** Procedural DataTextures (raw RGBA bytes) become canvases: GLTFExporter can only encode drawable images. */
function rasterizeDataTextures(root: THREE.Object3D) {
  const done = new Set<THREE.Texture>();
  root.traverse(o => {
    if (!(o as THREE.Mesh).isMesh) return;
    for (const mat of ([] as THREE.Material[]).concat((o as THREE.Mesh).material)) {
      for (const value of Object.values(mat)) {
        const tex = value as THREE.Texture;
        const raw = tex?.isTexture && !done.has(tex) ? (tex.image as { data?: ArrayLike<number>; width: number; height: number } | undefined) : undefined;
        if (!raw?.data) continue;
        done.add(tex);
        if (!(raw.data instanceof Uint8Array || raw.data instanceof Uint8ClampedArray) || raw.data.length !== raw.width * raw.height * 4) {
          throw new Error(`texture "${tex.name || mat.name}" is not 8-bit RGBA data: convert it to an image before exporting`);
        }
        const canvas = document.createElement('canvas');
        canvas.width = raw.width; canvas.height = raw.height;
        canvas.getContext('2d')!.putImageData(new ImageData(new Uint8ClampedArray(raw.data), raw.width, raw.height), 0, 0);
        tex.image = canvas;
      }
    }
  });
}

// --- validation --------------------------------------------------------------------------------

function checkGeometry(root: THREE.Object3D) {
  let meshes = 0, triangles = 0, degenerate = 0;
  root.traverse(o => {
    const mesh = o as THREE.Mesh;
    if (!mesh.isMesh) return;
    meshes++;
    const pos = mesh.geometry.getAttribute('position');
    for (let i = 0; i < pos.count; i++) {
      if (!Number.isFinite(pos.getX(i) + pos.getY(i) + pos.getZ(i))) throw new Error(`NaN position in "${mesh.name}"`);
    }
    const index = mesh.geometry.index;
    const count = (index ? index.count : pos.count) / 3;
    const a = new THREE.Vector3(), b = new THREE.Vector3(), c = new THREE.Vector3();
    for (let t = 0; t < count; t++) {
      const [i, j, k] = index ? [index.getX(t * 3), index.getX(t * 3 + 1), index.getX(t * 3 + 2)] : [t * 3, t * 3 + 1, t * 3 + 2];
      a.fromBufferAttribute(pos, i); b.fromBufferAttribute(pos, j); c.fromBufferAttribute(pos, k);
      if (b.sub(a).cross(c.sub(a)).lengthSq() < 1e-16) degenerate++;
    }
    triangles += count;
  });
  return { meshes, triangles, degenerate };
}

// --- export --------------------------------------------------------------------------------------

/**
 * GLTFExporter appends image bufferViews in the order the async PNG/JPEG encodes finish, which varies
 * run to run. Rewrite the GLB with image data after the geometry, in image order, so bytes are stable.
 */
function canonicalizeGlb(glb: ArrayBuffer) {
  const view = new DataView(glb);
  const jsonLength = view.getUint32(12, true);
  const json = JSON.parse(new TextDecoder().decode(new Uint8Array(glb, 20, jsonLength)));
  if (!json.bufferViews) return glb; // camera-only file: no binary chunk
  const binStart = 20 + jsonLength + 8;
  const bin = new Uint8Array(glb, binStart, view.getUint32(binStart - 8, true));
  const views: { buffer: number; byteOffset?: number; byteLength: number }[] = json.bufferViews ?? [];
  const imageViews: number[] = (json.images ?? []).map((im: { bufferView: number }) => im.bufferView);
  const isImage = new Set(imageViews);
  const order = [...views.keys()].filter(i => !isImage.has(i)).concat(imageViews);
  const remap = new Map(order.map((oldIndex, newIndex) => [oldIndex, newIndex]));
  const parts: Uint8Array[] = [];
  let offset = 0;
  const rebuilt = order.map(oldIndex => {
    const v = views[oldIndex];
    const data = bin.subarray(v.byteOffset ?? 0, (v.byteOffset ?? 0) + v.byteLength);
    const padded = new Uint8Array(Math.ceil(data.length / 4) * 4);
    padded.set(data);
    parts.push(padded);
    const out = { ...v, byteOffset: offset };
    offset += padded.length;
    return out;
  });
  json.bufferViews = rebuilt;
  json.buffers[0].byteLength = offset;
  for (const a of json.accessors ?? []) if (a.bufferView !== undefined) a.bufferView = remap.get(a.bufferView);
  for (const im of json.images ?? []) im.bufferView = remap.get(im.bufferView);
  const jsonBytes = new TextEncoder().encode(JSON.stringify(json));
  const jsonPadded = new Uint8Array(Math.ceil(jsonBytes.length / 4) * 4).fill(0x20);
  jsonPadded.set(jsonBytes);
  const out = new Uint8Array(12 + 8 + jsonPadded.length + 8 + offset);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, 0x46546c67, true); dv.setUint32(4, 2, true); dv.setUint32(8, out.length, true);
  dv.setUint32(12, jsonPadded.length, true); dv.setUint32(16, 0x4e4f534a, true);
  out.set(jsonPadded, 20);
  const binHeader = 20 + jsonPadded.length;
  dv.setUint32(binHeader, offset, true); dv.setUint32(binHeader + 4, 0x004e4942, true);
  let at = binHeader + 8;
  for (const part of parts) { out.set(part, at); at += part.length; }
  return out.buffer;
}

async function exportGlb(root: THREE.Object3D, file: string) {
  const buffer = await new GLTFExporter().parseAsync(root, { binary: true, onlyVisible: false, maxTextureSize: 2048 }) as ArrayBuffer;
  const stable = canonicalizeGlb(buffer);
  await deliver(file, stable);
  return stable.byteLength;
}

async function main() {
  const module = roomById(id);
  if (module.id !== id) throw new Error(`unknown room "${id}"`);
  const room = await module.build();

  room.group.updateMatrixWorld(true);
  if (!room.group.matrixWorld.equals(new THREE.Matrix4())) throw new Error('room group is not at the origin: the exported frame would differ from the viewer');

  let meshesBefore = 0; // what optimize() would report as meshesBefore
  room.group.traverseVisible(o => { if ((o as THREE.Mesh).isMesh) meshesBefore++; });

  const { root, fixed } = arrange(room);
  const excluded = stripViewerOnly(root, room);
  const instancesExpanded = expandInstances(root);
  nameMaterials(root);
  nameNodes(root, fixed);
  cleanUserData(root);
  keepJpeg(root);
  rasterizeDataTextures(root);

  const { lights, skipped } = arrangeLights(room.lights);
  root.add(lights);
  const stats = checkGeometry(root);
  root.userData = { room: id, source: 'model', units: 'meters', up: '+Y', frame: 'room', meshesBefore };

  const notes: string[] = [];
  const report: Record<string, unknown> = { room: id, meshesBefore, instancesExpanded, ...stats, excluded, skippedLights: skipped, notes, files: {} as Record<string, number> };
  const files = report.files as Record<string, number>;
  files[`${id}.glb`] = await exportGlb(root, `${id}.glb`);

  // LiDAR scan: the viewer adds it to the scene untransformed, so the model's frame needs no baking
  if (room.referenceKind !== 'scan') notes.push(`no ${id}-lidar.glb: the reference is a RoomPlan layout, not a scan`);
  else if (room.referenceAvailable === false) notes.push(`no ${id}-lidar.glb: the scan is not available for this room (referenceAvailable is false)`);
  else {
    const scan = await room.loadReference().catch(error => { throw new Error(`cannot load the scan of "${id}" (${error}): produce it first or set referenceAvailable = false`); });
    scan.name = 'scan';
    scan.traverse(o => {
      if ((o as THREE.Mesh).isMesh) { o.name = 'lidar_mesh'; ([] as THREE.Material[]).concat((o as THREE.Mesh).material).forEach(m => { m.name = 'lidar_vertex_color'; }); }
    });
    const lidar = group(`${id}_lidar`);
    lidar.userData = { room: id, source: 'lidar', units: 'meters', up: '+Y', frame: 'room', note: 'unlit, colour is the COLOR_0 vertex attribute' };
    lidar.add(scan);
    lidar.updateMatrixWorld(true);
    if (!scan.matrixWorld.equals(new THREE.Matrix4())) throw new Error('the scan carries a transform; bake it into the file instead');
    report.lidar = checkGeometry(lidar);
    files[`${id}-lidar.glb`] = await exportGlb(lidar, `${id}-lidar.glb`);
  }

  if (!room.photos?.length) notes.push(`no ${id}-photos.glb: the room has no posed photos`);
  else {
    const photos = group(`${id}_photos`);
    photos.userData = { room: id, source: 'photos', units: 'meters', up: '+Y', frame: 'room', imageFolder: `data/web-assets/${id}/photos`, note: 'cameras look down -Z; node name carries the photo index' };
    room.photos.forEach((p, i) => {
      const cam = new THREE.PerspectiveCamera(p.fovY, p.aspect, 0.02, 50);
      const index = String(i).padStart(4, '0');
      cam.name = `photo_${index}`;
      cam.position.fromArray(p.position);
      cam.up.fromArray(p.up);
      cam.lookAt(cam.position.clone().add(new THREE.Vector3(...p.forward)));
      cam.userData = { image: `${index}.jpg` };
      photos.add(cam);
    });
    report.photoCount = room.photos.length;
    files[`${id}-photos.glb`] = await exportGlb(photos, `${id}-photos.glb`);
  }
  return report;
}

try {
  window.__exportReport = await main();
} catch (error) {
  window.__exportError = String((error as Error)?.stack ?? error);
  console.error(window.__exportError);
}
document.body.dataset.ready = '1';
