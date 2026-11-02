#!/usr/bin/env node
// Determinism and structure gate: export every room twice (separate processes), compare sha256, then run the tests.
//   node tools/export-check.mjs [room ...]     (default: every room in tools/rooms.json)
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { repoRoot } from './lib/browser.mjs';

const registry = JSON.parse(fs.readFileSync(path.join(repoRoot, 'tools/rooms.json'), 'utf8')).rooms;
const rooms = process.argv.length > 2 ? process.argv.slice(2) : registry.map(r => r.id);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'export-check-'));
const dirs = [path.join(tmp, 'run1'), path.join(tmp, 'run2')];

function run(args, env = {}) {
  const r = spawnSync(process.execPath, args, { cwd: repoRoot, stdio: 'inherit', env: { ...process.env, ...env } });
  return r.status === 0;
}

function hashes(dir) {
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8'));
  return Object.fromEntries(Object.entries(manifest).flatMap(([id, e]) => Object.entries(e.files).map(([name, f]) => [`${id}/${name}`, f.sha256])));
}

let failed = '';
try {
  for (const [i, dir] of dirs.entries()) {
    console.log(`--- export run ${i + 1} of 2`);
    if (!run(['tools/export-room.mjs', ...rooms, '--out', dir])) { failed = `export run ${i + 1} failed`; break; }
  }
  if (!failed) {
    const [a, b] = dirs.map(hashes);
    const diff = [...new Set([...Object.keys(a), ...Object.keys(b)])].filter(k => a[k] !== b[k]);
    if (diff.length) failed = `NOT DETERMINISTIC: sha256 differs between two runs for ${diff.join(', ')}`;
    else console.log(`--- determinism ok: ${Object.keys(a).length} files identical across two runs`);
  }
  if (!failed) {
    console.log('--- structural tests');
    if (!run(['--test', 'tools/export.test.mjs'], { EXPORT_DIR: dirs[0], EXPORT_ROOMS: rooms.join(',') })) failed = 'tools/export.test.mjs failed';
  }
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
if (failed) { console.error(`export:check FAILED: ${failed}`); process.exit(1); }
console.log('export:check passed');
