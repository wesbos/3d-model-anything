#!/usr/bin/env node
// Export rebuilt rooms and their LiDAR scans to Blender-ready glTF, deterministically.
//   node tools/export-room.mjs office-v4 [<room> ...] | --all   [--out data/exports]
// Writes <out>/<room>/<room>.glb, plus <room>-lidar.glb and <room>-photos.glb when the room has a scan / posed photos,
// and <out>/manifest.json (sha256 per file).
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { launchBrowser, repoRoot, startServer, ToolError } from './lib/browser.mjs';

const registry = JSON.parse(fs.readFileSync(path.join(repoRoot, 'tools/rooms.json'), 'utf8')).rooms;

function parseArgs(argv) {
  const out = { rooms: [], out: path.join(repoRoot, 'data/exports') };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--all') out.rooms = registry.map(r => r.id);
    else if (a === '--out') out.out = path.resolve(argv[++i] ?? '');
    else if (a.startsWith('-')) throw new ToolError(`unknown option ${a}`);
    else out.rooms.push(a);
  }
  if (!out.rooms.length) throw new ToolError(`usage: export-room.mjs <room...>|--all [--out dir]   rooms: ${registry.map(r => r.id).join(', ')}`);
  for (const id of out.rooms) if (!registry.some(r => r.id === id)) throw new ToolError(`unknown room "${id}" (see tools/rooms.json)`);
  return out;
}

async function exportRoom(page, base, id, outDir) {
  const files = new Map(); // name -> { chunks, received, total }
  await page.binding('__exportSave', payload => {
    const m = JSON.parse(payload);
    let f = files.get(m.file);
    if (!f || m.offset === 0) files.set(m.file, (f = { chunks: [], received: 0, total: m.total }));
    f.chunks.push(Buffer.from(m.data, 'base64'));
    f.received += f.chunks.at(-1).length;
  });
  await page.goto(`${base}/tools/export.html?room=${id}`);
  await page.waitFor('document.body.dataset.ready === "1" && (window.__exportReport || window.__exportError)', 300_000);
  const error = await page.eval('window.__exportError || ""');
  if (error) throw new ToolError(`export page failed for ${id}:\n${error}`);
  const report = await page.eval('window.__exportReport');
  if (page.errors.length) throw new ToolError(`console errors while exporting ${id}:\n${page.errors.slice(0, 5).join('\n')}`);

  fs.mkdirSync(outDir, { recursive: true });
  const entries = {};
  for (const [name, f] of [...files].sort(([a], [b]) => (a < b ? -1 : 1))) {
    const bytes = Buffer.concat(f.chunks);
    if (bytes.length !== f.total || report.files[name] !== f.total) throw new ToolError(`${name}: received ${bytes.length} of ${f.total} bytes`);
    const tmp = path.join(outDir, `${name}.tmp`);
    fs.writeFileSync(tmp, bytes);
    fs.renameSync(tmp, path.join(outDir, name));
    entries[name] = { bytes: bytes.length, sha256: crypto.createHash('sha256').update(bytes).digest('hex') };
  }
  if (!entries[`${id}.glb`]) throw new ToolError(`no model file received for ${id}`);
  for (const optional of [`${id}-lidar.glb`, `${id}-photos.glb`]) if (!entries[optional]) fs.rmSync(path.join(outDir, optional), { force: true }); // stale file from an earlier export
  return { files: entries, meshesBefore: report.meshesBefore, excluded: report.excluded, skippedLights: report.skippedLights, geometry: report };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const server = await startServer();
  const browser = await launchBrowser().catch(async e => { await server.close(); throw e; });
  const manifest = {};
  try {
    for (const id of args.rooms) {
      const page = await browser.newPage();
      const started = Date.now();
      manifest[id] = await exportRoom(page, server.url, id, path.join(args.out, id));
      const { files } = manifest[id];
      console.log(`${id}: ${Object.entries(files).map(([n, f]) => `${n} ${(f.bytes / 1e6).toFixed(2)} MB`).join(', ')} (${((Date.now() - started) / 1000).toFixed(1)} s)`);
      for (const note of manifest[id].geometry.notes) console.log(`  note: ${note}`);
    }
  } finally {
    await browser.close();
    await server.close();
  }
  const manifestPath = path.join(args.out, 'manifest.json');
  const previous = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath, 'utf8')) : {};
  fs.mkdirSync(args.out, { recursive: true });
  fs.writeFileSync(manifestPath, JSON.stringify({ ...previous, ...manifest }, null, 2) + '\n');
  console.log(`manifest: ${manifestPath}`);
}

main().then(() => process.exit(0), error => {
  console.error(error instanceof ToolError ? `error: ${error.message}` : error);
  process.exit(1);
});
