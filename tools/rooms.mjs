#!/usr/bin/env node
// Scripted stages from a raw House Capture export to glTF, for rooms that declare their capture in tools/rooms.json.
//   node tools/rooms.mjs list
//   node tools/rooms.mjs pipeline <room> [--dry-run] [--force]
// A stage whose output already exists is skipped (--force reruns all but prepare_photos, which refuses an existing dir).
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { repoRoot, ToolError } from './lib/browser.mjs';

const registry = JSON.parse(fs.readFileSync(path.join(repoRoot, 'tools/rooms.json'), 'utf8')).rooms;
const scripts = '.agents/skills/scan-to-threejs/scripts';
const abs = rel => path.join(repoRoot, rel);

const PIPELINE_FIELDS = ['capture', 'roomIndex', 'mesh', 'scans', 'makeAssets'];

function stages(r) {
  const roomJson = `data/demos/${r.id}/room.json`;
  const photos = `data/web-assets/${r.id}/photos`;
  return [
    { name: 'bundle_to_room', output: roomJson, inputs: [`${scripts}/bundle_to_room.py`, r.capture], python: [`${scripts}/bundle_to_room.py`, r.capture, '--room', String(r.roomIndex), '-o', roomJson], prepare: () => fs.mkdirSync(abs(path.dirname(roomJson)), { recursive: true }) },
    { name: 'prepare_photos', output: photos, never: true, inputs: [`${scripts}/prepare_photos.py`, r.capture, roomJson], python: [`${scripts}/prepare_photos.py`, r.capture, roomJson, photos], prepare: () => fs.mkdirSync(abs(path.dirname(photos)), { recursive: true }) },
    { name: 'reconstruct_bundle', output: `${r.scans}/scan_room.ply`, inputs: [`${scripts}/reconstruct_bundle.py`, r.capture, r.mesh, roomJson], python: [`${scripts}/reconstruct_bundle.py`, r.capture, '--mesh', r.mesh, '--room', roomJson, '-o', r.scans] },
    { name: 'make-assets', output: `data/web-assets/${r.id}/scan.glb`, inputs: [r.makeAssets, `${r.scans}/scan_room.ply`, photos], python: [r.makeAssets] },
    { name: 'export', output: `data/exports/${r.id}/${r.id}.glb`, always: true, node: ['tools/export-room.mjs', r.id] },
  ];
}

function interpreter(dryRun) {
  const py = process.env.PYTHON || process.env.CAP_PYTHON;
  if (py) return py;
  if (dryRun) return '$PYTHON';
  throw new ToolError('no Python interpreter: set PYTHON (or CAP_PYTHON) to one with tools/requirements.txt installed (pip install -r tools/requirements.txt)');
}

function pipeline(id, { dryRun, force }) {
  const room = registry.find(r => r.id === id);
  if (!room) throw new ToolError(`unknown room "${id}" (node tools/rooms.mjs list)`);
  const absent = PIPELINE_FIELDS.filter(k => room[k] === undefined);
  if (absent.length) throw new ToolError(`room "${id}" has no capture pipeline in tools/rooms.json (missing ${absent.join(', ')}); see "Adding a room" in docs/export.md`);
  const python = interpreter(dryRun);
  for (const s of stages(room)) {
    const exists = fs.existsSync(abs(s.output));
    if (exists && !s.always && (!force || s.never)) {
      console.log(`[skip] ${s.name}: ${s.output} already exists${s.never && force ? ' (prepare_photos never overwrites)' : ''}`);
      continue;
    }
    const missing = (s.inputs ?? []).filter(i => !fs.existsSync(abs(i)));
    const [cmd, args] = s.node ? [process.execPath, s.node] : [python, s.python];
    console.log(`[${dryRun ? 'dry-run' : 'run'}] ${s.name}: ${s.node ? 'node' : path.basename(python)} ${args.join(' ')}`);
    if (dryRun) { if (missing.length) console.log(`          missing inputs (an earlier stage may create them): ${missing.join(', ')}`); continue; }
    if (missing.length) throw new ToolError(`${s.name}: missing input ${missing.join(', ')}`);
    s.prepare?.();
    const r = spawnSync(cmd, args, { cwd: repoRoot, stdio: 'inherit' });
    if (r.status !== 0) throw new ToolError(`stage ${s.name} failed (exit ${r.status}); stopping`);
  }
}

function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (command === 'list') {
    for (const r of registry) {
      if (PIPELINE_FIELDS.some(k => r[k] === undefined)) { console.log(`${r.id}\tno capture pipeline (export only)`); continue; }
      const have = ['capture', 'mesh', 'scans'].map(k => `${k}:${fs.existsSync(abs(r[k])) ? 'yes' : 'no'}`).join(' ');
      console.log(`${r.id}\troom ${r.roomIndex}\t${r.capture}\t${have}`);
    }
  } else if (command === 'pipeline') {
    const flags = rest.filter(a => a.startsWith('-'));
    const unknown = flags.filter(f => !['--dry-run', '--force'].includes(f));
    if (unknown.length) throw new ToolError(`unknown option ${unknown[0]}`);
    const ids = rest.filter(a => !a.startsWith('-'));
    if (ids.length !== 1) throw new ToolError('usage: rooms.mjs pipeline <room> [--dry-run] [--force]');
    pipeline(ids[0], { dryRun: flags.includes('--dry-run'), force: flags.includes('--force') });
  } else {
    throw new ToolError('usage: rooms.mjs list | pipeline <room> [--dry-run] [--force]');
  }
}

try { main(); } catch (error) {
  console.error(error instanceof ToolError ? `error: ${error.message}` : error);
  process.exit(1);
}
