// Read exported GLBs with @gltf-transform/core and answer the questions the export checks ask.
import fs from 'node:fs';
import { Logger, NodeIO } from '@gltf-transform/core';

// core alone does not know the KHR_* extensions the exporter writes; its "missing optional extension" warnings are noise here
const io = new NodeIO().setLogger(new Logger(Logger.Verbosity.ERROR));
const bytesOf = file => new Uint8Array(fs.readFileSync(file));

export function readJson(file) {
  const b = fs.readFileSync(file);
  return JSON.parse(b.subarray(20, 20 + b.readUInt32LE(12)).toString('utf8'));
}

export async function readGlb(file) {
  return io.readBinary(bytesOf(file));
}

/** Meshes, triangles, NaN and degenerate counts over every primitive (indexed or not). */
export function geometryStats(doc) {
  let meshNodes = 0, primitives = 0, triangles = 0, degenerate = 0, nonFinite = 0;
  for (const node of doc.getRoot().listNodes()) {
    const mesh = node.getMesh();
    if (!mesh) continue;
    meshNodes++;
    for (const prim of mesh.listPrimitives()) {
      primitives++;
      const pos = prim.getAttribute('POSITION').getArray();
      for (let i = 0; i < pos.length; i++) if (!Number.isFinite(pos[i])) nonFinite++;
      const idx = prim.getIndices()?.getArray();
      const n = idx ? idx.length : pos.length / 3;
      for (let t = 0; t < n; t += 3) {
        const [a, b, c] = idx ? [idx[t], idx[t + 1], idx[t + 2]] : [t, t + 1, t + 2];
        const ux = pos[b * 3] - pos[a * 3], uy = pos[b * 3 + 1] - pos[a * 3 + 1], uz = pos[b * 3 + 2] - pos[a * 3 + 2];
        const vx = pos[c * 3] - pos[a * 3], vy = pos[c * 3 + 1] - pos[a * 3 + 1], vz = pos[c * 3 + 2] - pos[a * 3 + 2];
        const cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx;
        if (cx * cx + cy * cy + cz * cz < 1e-16) degenerate++;
      }
      triangles += n / 3;
    }
  }
  return { meshNodes, primitives, triangles, degenerate, nonFinite };
}

export function summary(doc, json) {
  const root = doc.getRoot();
  return {
    nodes: root.listNodes().length,
    meshes: root.listMeshes().length,
    materials: root.listMaterials().length,
    textures: root.listTextures().length,
    cameras: root.listCameras().length,
    extensions: json.extensionsUsed ?? [],
  };
}

const apply = (m, x, y, z) => [
  m[0] * x + m[4] * y + m[8] * z + m[12],
  m[1] * x + m[5] * y + m[9] * z + m[13],
  m[2] * x + m[6] * y + m[10] * z + m[14],
];

/** World-space vertices of every mesh whose ancestor path includes a node accepted by `filter(node)`. */
export function worldVertices(doc, filter = () => true) {
  const out = [];
  for (const node of doc.getRoot().listNodes()) {
    const mesh = node.getMesh();
    if (!mesh || !filter(node)) continue;
    const m = node.getWorldMatrix();
    for (const prim of mesh.listPrimitives()) {
      const pos = prim.getAttribute('POSITION').getArray();
      for (let i = 0; i < pos.length; i += 3) out.push(apply(m, pos[i], pos[i + 1], pos[i + 2]));
    }
  }
  return out;
}

export const bounds = pts => {
  const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
  for (const p of pts) for (let k = 0; k < 3; k++) { min[k] = Math.min(min[k], p[k]); max[k] = Math.max(max[k], p[k]); }
  return { min, max };
};

export const ancestors = node => {
  const names = [];
  for (let n = node; n; n = n.getParentNode()) names.push(n.getName());
  return names;
};

/**
 * Area-weighted surface samples (deterministic, seeded) of triangles that pass `accept(normal, centroid)`;
 * `filter(node)` selects mesh nodes.
 */
export function sampleSurface(doc, { filter, accept, count, seed = 12345 }) {
  const tris = [];
  let total = 0;
  for (const node of doc.getRoot().listNodes()) {
    const mesh = node.getMesh();
    if (!mesh || !filter(node)) continue;
    const m = node.getWorldMatrix();
    for (const prim of mesh.listPrimitives()) {
      const pos = prim.getAttribute('POSITION').getArray();
      const idx = prim.getIndices()?.getArray();
      const n = idx ? idx.length : pos.length / 3;
      for (let t = 0; t < n; t += 3) {
        const ids = idx ? [idx[t], idx[t + 1], idx[t + 2]] : [t, t + 1, t + 2];
        const [a, b, c] = ids.map(i => apply(m, pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]));
        const u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]], v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
        const nx = u[1] * v[2] - u[2] * v[1], ny = u[2] * v[0] - u[0] * v[2], nz = u[0] * v[1] - u[1] * v[0];
        const area = Math.hypot(nx, ny, nz) / 2;
        if (area < 1e-9) continue;
        const normal = [nx / (2 * area), ny / (2 * area), nz / (2 * area)];
        const centroid = [(a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3];
        if (!accept(normal, centroid)) continue;
        tris.push({ a, b, c, area });
        total += area;
      }
    }
  }
  let s = seed >>> 0;
  const rnd = () => { s = (s + 0x6d2b79f5) | 0; let t = Math.imul(s ^ (s >>> 15), 1 | s); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const cumulative = [];
  let acc = 0;
  for (const t of tris) { acc += t.area; cumulative.push(acc); }
  const points = [];
  for (let k = 0; k < count && tris.length; k++) {
    const target = rnd() * total;
    let lo = 0, hi = cumulative.length - 1;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (cumulative[mid] < target) lo = mid + 1; else hi = mid; }
    const { a, b, c } = tris[lo];
    let r1 = rnd(), r2 = rnd();
    if (r1 + r2 > 1) { r1 = 1 - r1; r2 = 1 - r2; }
    points.push([a[0] + r1 * (b[0] - a[0]) + r2 * (c[0] - a[0]), a[1] + r1 * (b[1] - a[1]) + r2 * (c[1] - a[1]), a[2] + r1 * (b[2] - a[2]) + r2 * (c[2] - a[2])]);
  }
  return { points, area: total };
}

/** Nearest-vertex distance from each query point to a point cloud (uniform grid, cell = `cell` metres). */
export function nearestDistances(cloud, queries, cell = 0.1) {
  const grid = new Map();
  const key = (x, y, z) => `${x},${y},${z}`;
  for (const p of cloud) {
    const k = key(Math.floor(p[0] / cell), Math.floor(p[1] / cell), Math.floor(p[2] / cell));
    (grid.get(k) ?? grid.set(k, []).get(k)).push(p);
  }
  return queries.map(q => {
    const cx = Math.floor(q[0] / cell), cy = Math.floor(q[1] / cell), cz = Math.floor(q[2] / cell);
    let best = Infinity;
    for (let r = 1; r <= 8 && best === Infinity; r++) { // widen the search until something is found
      for (let dx = -r; dx <= r; dx++) for (let dy = -r; dy <= r; dy++) for (let dz = -r; dz <= r; dz++) {
        const bucket = grid.get(key(cx + dx, cy + dy, cz + dz));
        if (bucket) for (const p of bucket) best = Math.min(best, Math.hypot(p[0] - q[0], p[1] - q[1], p[2] - q[2]));
      }
    }
    return best;
  });
}

export const percentile = (values, p) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
};
