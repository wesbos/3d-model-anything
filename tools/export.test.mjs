// Structural and numeric checks on exported rooms: node --test tools/export.test.mjs
// Environment: EXPORT_DIR (default data/exports), EXPORT_ROOMS (comma list, default every room in the manifest).
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { describe, it } from 'node:test';
import { repoRoot } from './lib/browser.mjs';
import * as G from './lib/glb.mjs';

const dir = path.resolve(process.env.EXPORT_DIR ?? path.join(repoRoot, 'data/exports'));
const expectations = JSON.parse(fs.readFileSync(path.join(repoRoot, 'tools/export-expectations.json'), 'utf8'));
const manifestPath = path.join(dir, 'manifest.json');
assert.ok(fs.existsSync(manifestPath), `${manifestPath} is missing: run npm run export:all first`);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const rooms = (process.env.EXPORT_ROOMS?.split(',') ?? Object.keys(manifest)).filter(Boolean);
const defaults = expectations.defaults;

const inShell = n => G.ancestors(n).includes('shell');
const inCeiling = n => G.ancestors(n).some(name => name.includes('ceiling'));

for (const id of rooms) {
  const want = { ...defaults, ...expectations.rooms[id] };
  const entry = manifest[id];
  const file = suffix => path.join(dir, id, `${id}${suffix}.glb`);
  const has = suffix => Boolean(entry.files[`${id}${suffix}.glb`]);

  describe(`${id}: rebuilt model`, async () => {
    const doc = await G.readGlb(file(''));
    const json = G.readJson(file(''));
    const sum = G.summary(doc, json);
    const geo = G.geometryStats(doc);

    it('files match the manifest hashes', () => {
      for (const [name, f] of Object.entries(entry.files)) {
        const bytes = fs.readFileSync(path.join(dir, id, name));
        assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), f.sha256, name);
      }
    });
    it('has the expected named hierarchy', () => {
      const root = doc.getRoot().listScenes()[0].listChildren()[0];
      assert.equal(root.getName(), id);
      const top = root.listChildren().map(n => n.getName());
      for (const name of want.topLevel) assert.ok(top.includes(name), `missing top-level group "${name}" (have ${top})`);
      const names = doc.getRoot().listNodes().map(n => n.getName());
      assert.ok(names.every(Boolean), 'every node has a name');
      assert.equal(new Set(names).size, names.length, 'node names are unique');
      assert.ok(names.some(n => n.includes('ceiling')), 'a ceiling node exists');
      assert.ok(names.filter(n => /^wall_\d{2}_(north|south|east|west)$/.test(n)).length >= want.minWalls, 'wall groups');
      assert.ok(!names.some(n => n.startsWith('batch')), 'no batched mega-mesh nodes');
    });
    it('keeps one mesh per original object (not batched)', () => {
      const expected = entry.meshesBefore + entry.geometry.instancesExpanded;
      assert.ok(Math.abs(geo.meshNodes - expected) / expected <= want.meshCountSlack, `${geo.meshNodes} mesh nodes vs ${expected} built`);
      const perMesh = doc.getRoot().listMeshes().map(m => m.listPrimitives().reduce((a, p) => a + (p.getIndices()?.getCount() ?? 0) / 3, 0));
      assert.ok(Math.max(...perMesh) <= want.maxMeshShareOfTriangles * geo.triangles, 'no mesh holds most of the triangles');
    });
    it('has clean geometry', () => {
      assert.equal(geo.nonFinite, 0, 'NaN or infinite positions');
      assert.ok(geo.degenerate / geo.triangles <= want.maxDegenerateFraction, `${geo.degenerate} degenerate of ${geo.triangles} triangles`);
    });
    it('embeds materials and textures', () => {
      assert.ok(sum.materials > 0 && sum.textures > 0);
      assert.ok((json.images ?? []).every(img => img.bufferView !== undefined && !img.uri), 'images are embedded');
      assert.ok(doc.getRoot().listMaterials().every(m => m.getName()), 'materials are named');
    });
    it('exports lights and stays under the size cap', () => {
      assert.ok(sum.extensions.includes('KHR_lights_punctual'));
      assert.ok(json.nodes.filter(n => n.extensions?.KHR_lights_punctual).length >= want.minLights);
      assert.ok(fs.statSync(file('')).size <= want.maxBytes.model);
    });
  });

  describe(`${id}: lidar and photos`, async () => {
    const lidar = has('-lidar') ? await G.readGlb(file('-lidar')) : null;
    const lidarJson = lidar && G.readJson(file('-lidar'));
    const geo = lidar && G.geometryStats(lidar);
    it('is one clean unlit vertex-coloured mesh under a "<room>_lidar" root', { skip: !lidar && `${id} has no LiDAR scan: nothing to check` }, () => {
      assert.equal(lidar.getRoot().listScenes()[0].listChildren()[0].getName(), `${id}_lidar`);
      assert.equal(geo.nonFinite, 0);
      assert.equal(geo.meshNodes, 1);
      assert.ok(lidarJson.extensionsUsed.includes('KHR_materials_unlit'));
      assert.ok(lidar.getRoot().listMeshes()[0].listPrimitives()[0].getAttribute('COLOR_0'), 'COLOR_0 present');
      assert.ok(fs.statSync(file('-lidar')).size <= want.maxBytes.lidar);
    });
    it('has one named camera per posed photo', { skip: !has('-photos') && `${id} has no posed photos: nothing to check` }, async () => {
      const photos = await G.readGlb(file('-photos'));
      const cams = photos.getRoot().listNodes().filter(n => n.getCamera());
      assert.ok(cams.length >= want.minPhotos);
      assert.equal(cams.length, entry.geometry.photoCount);
      assert.equal(cams[0].getName(), 'photo_0000');
      assert.ok(fs.statSync(file('-photos')).size <= want.maxBytes.photos);
    });
  });

  describe(`${id}: model and lidar share one frame`, async () => {
    if (!has('-lidar')) return it('is checked against the LiDAR scan', { skip: `${id} has no LiDAR scan: alignment cannot be checked` });
    const model = await G.readGlb(file(''));
    const lidar = await G.readGlb(file('-lidar'));
    const cloud = G.worldVertices(lidar);
    const a = want.alignment;
    const lb = G.bounds(cloud);
    const center = lb.min.map((v, k) => (v + lb.max[k]) / 2);
    it('has matching extents', () => {
      const mb = G.bounds(G.worldVertices(model, inShell));
      for (const k of [0, 2]) {
        assert.ok(Math.abs(mb.min[k] - lb.min[k]) <= a.bboxTolerance && Math.abs(mb.max[k] - lb.max[k]) <= a.bboxTolerance, `axis ${k}: model ${mb.min[k].toFixed(2)}..${mb.max[k].toFixed(2)} vs lidar ${lb.min[k].toFixed(2)}..${lb.max[k].toFixed(2)}`);
      }
    });
    it('puts the model floor on the LiDAR floor', () => {
      const bins = new Map();
      for (const p of cloud) if (p[1] > -0.3 && p[1] < 0.4) { const b = Math.round(p[1] / 0.01); bins.set(b, (bins.get(b) ?? 0) + 1); }
      const floor = [...bins].sort((x, y) => y[1] - x[1])[0][0] * 0.01;
      assert.ok(Math.abs(floor) <= a.floorTolerance, `LiDAR floor mode at y=${floor.toFixed(3)} (model floor is y=0)`);
    });
    it('lays model walls and floor on the scan surface', () => {
      const { points } = G.sampleSurface(model, {
        filter: n => inShell(n) && !inCeiling(n), count: a.samples,
        accept: (n, c) => {
          if (Math.abs(n[1]) > 0.9) return n[1] > 0.9 && c[1] < 0.3; // floor, facing up
          return Math.abs(n[1]) < 0.2 && n[0] * (center[0] - c[0]) + n[2] * (center[2] - c[2]) > 0; // wall faces turned to the room
        },
      });
      assert.ok(points.length > 100, 'enough shell samples');
      const d = G.nearestDistances(cloud, points).map(v => Math.min(v, 1));
      const p50 = G.percentile(d, 0.5), near = d.filter(v => v < 0.1).length / d.length;
      assert.ok(p50 <= a.p50Max, `median model-to-scan distance ${p50.toFixed(3)} m > ${a.p50Max}`);
      assert.ok(near >= a.within10cmMin, `only ${(near * 100).toFixed(0)}% of samples within 10 cm of the scan`);
    });
  });
}
