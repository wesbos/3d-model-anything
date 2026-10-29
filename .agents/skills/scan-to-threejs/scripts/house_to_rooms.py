#!/usr/bin/env python3
"""Export active rooms from a house-project/1 folder with room-to-house placements.

Uses only the Python standard library. Leaves captures and house.json unchanged.
Output is a new directory containing index.json and numbered room JSON files.
Unaligned rooms are reported in the index, never placed using identity guesses.
"""
import argparse
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil

from bundle_to_room import mat, mul
from compass import direction


def flatten(m):
    return [m[r][c] for c in range(4) for r in range(4)]


def rigid(values):
    if not isinstance(values, list) or len(values) != 16 or not all(
        isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in values
    ):
        raise ValueError('expected 16 finite column-major matrix values')
    m = mat(values)
    if any(abs(m[3][i] - (1 if i == 3 else 0)) > 1e-4 for i in range(4)):
        raise ValueError('expected an affine transform')
    for i in range(3):
        for j in range(3):
            if abs(sum(m[k][i] * m[k][j] for k in range(3)) - (i == j)) > 1e-3:
                raise ValueError('expected rigid rotation, without scale/shear')
    det = (m[0][0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1])
           - m[0][1]*(m[1][0]*m[2][2]-m[1][2]*m[2][0])
           + m[0][2]*(m[1][0]*m[2][1]-m[1][1]*m[2][0]))
    if abs(det - 1) > 1e-3:
        raise ValueError('reflected coordinate frames are unsupported')
    return m


def inverse_rigid(m):
    out = [[m[c][r] if r < 3 and c < 3 else 0 for c in range(4)] for r in range(4)]
    out[3][3] = 1
    for r in range(3):
        out[r][3] = -sum(out[r][k] * m[k][3] for k in range(3))
    return out


def child(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root):
        raise ValueError(f'path escapes house folder: {relative}')
    return path


def keyed(items):
    result = {x['id']: x for x in items}
    if len(result) != len(items):
        raise ValueError('duplicate IDs in house metadata')
    return result


def export_house(root, out, room_id=None):
    root = root.resolve()
    house = json.loads((root / 'house.json').read_text())
    if house.get('format') != 'house-project/1':
        raise ValueError('expected house-project/1')
    zones, sessions = keyed(house['zones']), keyed(house['sessions'])
    keyed(house['rooms'])
    rooms = [r for r in house['rooms'] if room_id is None or r['id'] == room_id]
    if not rooms:
        raise ValueError('no matching rooms')
    if out.exists():
        raise ValueError('output directory already exists; choose a new output directory')
    out.parent.mkdir(parents=True, exist_ok=True)
    index = {'format': 'house-rebuild/1', 'house': house['id'], 'name': house['name'],
             'source': str(root), 'matrixOrder': 'column-major', 'rooms': []}
    with tempfile.TemporaryDirectory(prefix='.house-import-', dir=out.parent) as temp:
        stage = Path(temp)
        for number, room in enumerate(rooms):
            entry = {'id': room['id'], 'name': room['name'], 'zone': room['zone'],
                     'active': room.get('active'), 'status': 'blocked'}
            index['rooms'].append(entry)
            active = room.get('active')
            if not active:
                entry['reason'] = 'no active scan'
                continue
            try:
                session = sessions[active['session']]
                zone = zones[room['zone']]
                if session['zone'] != room['zone']:
                    raise ValueError('active session belongs to a different zone')
                alignment = session['alignment']
                if not zone.get('aligned'):
                    raise ValueError('zone placement is not aligned to the house')
                if alignment['method'] not in ('first', 'relocalized', 'manual', 'icp'):
                    raise ValueError('session needs alignment: ' + alignment['method'])
                session_to_house = mul(rigid(zone['toHouse']), rigid(alignment['toZone']))
                room_index = active['index']
                if type(room_index) is not int or room_index < 0:
                    raise ValueError('invalid active room index')
                bundle = child(root, 'sessions/' + session['id'])
                child(root, f'sessions/{session["id"]}/rooms/room-{room_index}.json')
                filename = f'room-{number:03d}.json'
                run = subprocess.run([sys.executable, str(Path(__file__).with_name('bundle_to_room.py')),
                                      str(bundle), '--room', str(room_index), '-o', str(stage / filename)],
                                     capture_output=True, text=True)
                if run.returncode:
                    raise ValueError('room conversion failed: ' + run.stderr.strip())
                converted = json.loads((stage / filename).read_text())
                world_to_room = rigid(converted['transform']['worldToRoom'])
                room_to_house = mul(session_to_house, inverse_rigid(world_to_room))
                converted['housePlacement'] = {'house': house['id'], 'zone': zone['id'],
                    'session': session['id'], 'room': room['id'], 'index': room_index,
                    'sessionToHouse': flatten(session_to_house), 'roomToHouse': flatten(room_to_house)}
                compass = converted.get('compass')
                if compass and compass.get('status') == 'aligned':
                    north = direction(room_to_house, compass['north'])
                    converted['housePlacement']['compass'] = {
                        'north': north, 'reference': compass['reference'],
                        'accuracyDegrees': compass['accuracyDegrees']}
                (stage / filename).write_text(json.dumps(converted, indent=2) + '\n')
                entry.update(status='ready', file=filename, bundle=str(bundle),
                             roomToHouse=flatten(room_to_house))
                if 'compass' in converted['housePlacement']:
                    entry['compass'] = converted['housePlacement']['compass']
            except (KeyError, ValueError, OSError) as error:
                entry['reason'] = str(error)
                candidate = stage / f'room-{number:03d}.json'
                if candidate.exists():
                    candidate.unlink()
        (stage / 'index.json').write_text(json.dumps(index, indent=2) + '\n')
        # All work is staged; never overwrite an existing export or the source bundles.
        out.mkdir()
        for path in stage.iterdir():
            shutil.move(str(path), out / path.name)
    return index


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('house', type=Path, help='unpacked folder containing house.json')
    parser.add_argument('-o', '--out', type=Path, required=True, help='new derived-output directory')
    parser.add_argument('--room', help='select one house room by its stable ID, not its name')
    args = parser.parse_args()
    try:
        index = export_house(args.house, args.out, args.room)
    except (ValueError, KeyError, OSError) as error:
        parser.error(str(error))
    for room in index['rooms']:
        print(f'{room["status"]}: {room["name"]}: {room.get("file", room.get("reason"))}')
    ready = sum(r['status'] == 'ready' for r in index['rooms'])
    print(f'{ready}/{len(index["rooms"])} rooms ready; inspect {args.out / "index.json"}')
    return 0 if ready == len(index['rooms']) else 2


if __name__ == '__main__':
    sys.exit(main())
