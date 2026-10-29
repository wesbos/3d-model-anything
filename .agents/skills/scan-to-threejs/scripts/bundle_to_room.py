#!/usr/bin/env python3
"""Convert one room of a House Capture bundle into room coordinates for the
three.js rebuild: floor at y=0, walls aligned to X/Z, room centered.

usage: bundle_to_room.py <bundle_dir> [--room N] [-o room.json] [--plan plan.png] [--turn K]

Output JSON:
  transform  worldToRoom (column-major 4x4) + theta/center/floorY it was built from
  polygon    floor outline [[x, z], ...] in room coords (counter-clockwise seen from above)
  walls      [{index, a, b, height, origin, u, n, length, openings: [{kind, u0, u1, v0, v1}]}]
             origin = interior face, left end, floor; u runs left→right seen from inside;
             n points into the room; u × up = n (the WallDef convention in shell.ts)
  objects    [{category, center, size, rotY, front}]  (rotY turns local +z to `front`)
  photos     [{file, position, forward, up, fovY, aspect}] in room coords, upright (portrait) framing
--plan draws the result with wall indices and u ticks every 0.5 m for annotating.
"""
import argparse
import json
import math
import os
from compass import bearing, read_compass, photo_compass


def mat(t):
    return [[t[c * 4 + r] for c in range(4)] for r in range(4)]


def col(m, c):
    return [m[0][c], m[1][c], m[2][c]]


def mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def apply(m, p, w=1.0):
    v = [p[0], p[1], p[2], w]
    return [sum(m[i][k] * v[k] for k in range(4)) for i in range(3)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('bundle')
    ap.add_argument('--room', type=int, default=None, help='room index (default: structure.json, all rooms)')
    ap.add_argument('-o', default=None)
    ap.add_argument('--plan', default=None)
    ap.add_argument('--turn', type=int, default=0, help='extra quarter turns (90° each, counter-clockwise seen from above) to match another scan')
    a = ap.parse_args()

    src = os.path.join(a.bundle, 'structure.json' if a.room is None else f'rooms/room-{a.room}.json')
    S = json.load(open(src))
    walls = S['walls']

    # --- floor height: floor surface if present, else wall bottoms --------------
    if S.get('floors'):
        floorY = mat(S['floors'][0]['transform'])[1][3]
    else:
        floorY = min(mat(w['transform'])[1][3] - w['dimensions'][1] / 2 for w in walls)

    # --- heading: length-weighted wall direction mod 90° -------------------------
    sx = sy = 0.0
    for w in walls:
        x = col(mat(w['transform']), 0)
        ang = math.atan2(x[2], x[0]) * 4  # ×4 folds 90° symmetry
        sx += math.cos(ang) * w['dimensions'][0]
        sy += math.sin(ang) * w['dimensions'][0]
    theta = math.atan2(sy, sx) / 4  # walls run at theta (+k·90°) in world x/z
    theta -= a.turn * math.pi / 2

    # rotate by -theta about Y (x/z plane), then center
    c, s = math.cos(-theta), math.sin(-theta)
    # rotation that maps world direction at angle theta (atan2(z, x)) onto +x
    R = [[c, 0, -s, 0], [0, 1, 0, 0], [s, 0, c, 0], [0, 0, 0, 1]]
    ends = []
    for w in walls:
        m = mat(w['transform'])
        ctr, x = col(m, 3), col(m, 0)
        hw = w['dimensions'][0] / 2
        for sgn in (-1, 1):
            ends.append(apply(R, [ctr[0] + x[0] * sgn * hw, 0, ctr[2] + x[2] * sgn * hw]))
    cx = (min(e[0] for e in ends) + max(e[0] for e in ends)) / 2
    cz = (min(e[2] for e in ends) + max(e[2] for e in ends)) / 2
    T = [[1, 0, 0, -cx], [0, 1, 0, -floorY], [0, 0, 1, -cz], [0, 0, 0, 1]]
    W2R = mul(T, R)  # world → room
    to_room = lambda p: apply(W2R, p)
    dir_room = lambda d: apply(W2R, d, 0.0)
    compass = read_compass(a.bundle, a.room, W2R)

    # --- floor polygon (for inside/outside tests) --------------------------------
    poly = None
    if S.get('floors') and S['floors'][0].get('polygonCorners'):
        fm = mat(S['floors'][0]['transform'])
        poly = [to_room(apply(fm, [p[0], p[1], p[2]])) for p in S['floors'][0]['polygonCorners']]
        poly = [[round(p[0], 4), round(p[2], 4)] for p in poly]

    def inside(x, z):
        if not poly:
            return True
        hit = False
        for i in range(len(poly)):
            (x1, z1), (x2, z2) = poly[i], poly[(i + 1) % len(poly)]
            if (z1 > z) != (z2 > z) and x < x1 + (z - z1) * (x2 - x1) / (z2 - z1):
                hit = not hit
        return hit

    if poly:  # make it counter-clockwise seen from above (+y): signed area in x/(-z)
        area = sum(poly[i][0] * -poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * -poly[i][1] for i in range(len(poly)))
        if area < 0:
            poly.reverse()

    # --- walls ---------------------------------------------------------------------
    kids = {}
    for kind in ('doors', 'windows', 'openings'):
        for e in S.get(kind, []):
            kids.setdefault(e.get('parentIdentifier'), []).append((kind[:-1], e))

    out_walls = []
    centroid = [sum(to_room(col(mat(wall['transform']), 3))[k] for wall in walls) / len(walls) for k in (0, 2)]
    for i, w in enumerate(walls):
        m = mat(w['transform'])
        ctr = to_room(col(m, 3))
        u = dir_room(col(m, 0))
        length, height = w['dimensions'][0], w['dimensions'][1]
        n = [-u[2], 0, u[0]]  # u × up
        mid = [ctr[0], ctr[2]]
        points_inside = (inside(mid[0] + n[0] * 0.05, mid[1] + n[2] * 0.05) if poly else
                         (centroid[0] - mid[0]) * n[0] + (centroid[1] - mid[1]) * n[2] >= 0)
        if not points_inside:
            u = [-u[0], 0, -u[2]]
            n = [-n[0], 0, -n[2]]
        facing = bearing([-n[0], 0, -n[2]], compass)
        origin = [ctr[0] - u[0] * length / 2, 0, ctr[2] - u[2] * length / 2]
        b = [origin[0] + u[0] * length, origin[2] + u[2] * length]
        openings = []
        for kind, e in kids.get(w['identifier'], []):
            em = mat(e['transform'])
            ec = to_room(col(em, 3))
            du = (ec[0] - origin[0]) * u[0] + (ec[2] - origin[2]) * u[2]
            ew, eh = e['dimensions'][0], e['dimensions'][1]
            v0 = ec[1] - eh / 2
            openings.append({
                'kind': kind,
                'u0': round(du - ew / 2, 3), 'u1': round(du + ew / 2, 3),
                'v0': 0.0 if v0 < 0.06 else round(v0, 3), 'v1': round(ec[1] + eh / 2, 3),
                'isOpen': bool(e['category'].get('door', {}).get('isOpen', False)) if kind == 'door' else None,
            })
            if facing:
                openings[-1]['facing'] = facing.copy()
        out_walls.append({
            'index': i,
            'a': [round(origin[0], 4), round(origin[2], 4)],
            'b': [round(b[0], 4), round(b[1], 4)],
            'height': round(height, 3),
            'origin': [round(v, 4) for v in origin],
            'u': [round(v, 5) for v in u],
            'n': [round(v, 5) for v in n],
            'length': round(length, 4),
            'confidence': next(iter(w['confidence'])),
            'openings': sorted(openings, key=lambda o: o['u0']),
        })
        if facing:
            out_walls[-1]['facing'] = facing

    # --- objects -------------------------------------------------------------------
    objects = []
    for o in S.get('objects', []):
        m = mat(o['transform'])
        ctr = to_room(col(m, 3))
        f = dir_room(col(m, 2))
        objects.append({
            'category': next(iter(o['category'])),
            'center': [round(v, 3) for v in ctr],
            'size': [round(v, 3) for v in o['dimensions']],
            'rotY': round(math.atan2(f[0], f[2]), 4),
            'front': [round(f[0], 3), round(f[2], 3)],
        })

    # --- photos (upright framing: image up = sensor -x, right = sensor +y) -----------
    photos = []
    pj = os.path.join(a.bundle, 'photos/photos.json')
    for p in (json.load(open(pj)) if os.path.exists(pj) else []):
        if a.room is not None and p['room'] != a.room:
            continue
        pm = mat(p['transform'])
        pos = to_room(col(pm, 3))
        fwd = dir_room([-v for v in col(pm, 2)])
        up = dir_room([-v for v in col(pm, 0)])
        fx = p['intrinsics'][0]
        # upright image is height=sensor width; vertical fov spans the sensor's x axis
        fovY = math.degrees(2 * math.atan(p['width'] / 2 / fx))
        photos.append({
            'file': p['file'], 'position': [round(v, 4) for v in pos], 'forward': [round(v, 5) for v in fwd],
            'up': [round(v, 5) for v in up], 'fovY': round(fovY, 3), 'aspect': round(p['height'] / p['width'], 5),
            'blurPixels': p.get('blurPixels'),
        })
        measured_heading = photo_compass(p, fwd, compass, W2R)
        if measured_heading:
            photos[-1]['compass'] = measured_heading

    result = {
        'source': os.path.basename(os.path.normpath(a.bundle)) + ('' if a.room is None else f' room {a.room}'),
        'transform': {'theta': theta, 'center': [cx, cz], 'floorY': floorY,
                      'worldToRoom': [W2R[r][c] for c in range(4) for r in range(4)]},
        'polygon': poly, 'walls': out_walls, 'objects': objects, 'photos': photos,
    }
    if compass is not None:
        result['compass'] = compass
    out = a.o or os.path.join(a.bundle, 'room.json')
    json.dump(result, open(out, 'w'), indent=1)

    xs = [p for w in out_walls for p in (w['a'][0], w['b'][0])]
    zs = [p for w in out_walls for p in (w['a'][1], w['b'][1])]
    print(f'room {max(xs) - min(xs):.2f} × {max(zs) - min(zs):.2f} m, heights {sorted({w["height"] for w in out_walls})}, '
          f'{len(out_walls)} walls, {len(objects)} objects, {len(photos)} photos → {out}')
    for w in out_walls:
        ops = ', '.join(f"{o['kind']} u{o['u0']:.2f}-{o['u1']:.2f} v{o['v0']:.2f}-{o['v1']:.2f}" for o in w['openings'])
        print(f"  wall {w['index']:2d}: ({w['a'][0]:6.2f},{w['a'][1]:6.2f}) → ({w['b'][0]:6.2f},{w['b'][1]:6.2f})  "
              f"len {w['length']:.2f} h {w['height']:.2f}  n ({w['n'][0]:.0f},{w['n'][2]:.0f})  {ops}")
    for o in objects:
        print(f"  {o['category']:12s} center ({o['center'][0]:.2f},{o['center'][2]:.2f}) size {o['size']} rotY {math.degrees(o['rotY']):.0f}°")

    if a.plan:
        plan(result, a.plan)


def plan(r, path, ppm=140):
    from PIL import Image, ImageDraw
    pts = [p for w in r['walls'] for p in (w['a'], w['b'])]
    minx, maxx = min(p[0] for p in pts) - 0.5, max(p[0] for p in pts) + 0.5
    minz, maxz = min(p[1] for p in pts) - 0.5, max(p[1] for p in pts) + 0.5
    img = Image.new('RGB', (int((maxx - minx) * ppm), int((maxz - minz) * ppm)), (18, 18, 22))
    d = ImageDraw.Draw(img)
    P = lambda x, z: ((x - minx) * ppm, (z - minz) * ppm)
    for g in range(math.floor(minx * 2), math.ceil(maxx * 2) + 1):
        d.line([P(g / 2, minz), P(g / 2, maxz)], fill=(60, 60, 75) if g % 2 == 0 else (35, 35, 45))
        if g % 2 == 0:
            d.text(P(g / 2 + 0.02, minz + 0.05), f'x{g / 2:.0f}', fill=(0, 200, 255))
    for g in range(math.floor(minz * 2), math.ceil(maxz * 2) + 1):
        d.line([P(minx, g / 2), P(maxx, g / 2)], fill=(60, 60, 75) if g % 2 == 0 else (35, 35, 45))
        if g % 2 == 0:
            d.text(P(minx + 0.03, g / 2 + 0.02), f'z{g / 2:.0f}', fill=(255, 200, 0))
    for o in r['objects']:
        cx, cz = o['center'][0], o['center'][2]
        hw, hd, a = o['size'][0] / 2, o['size'][2] / 2, o['rotY']
        # local x axis = (cos a, -sin a), local z (front) = (sin a, cos a)
        corners = [(cx + math.cos(a) * sx * hw + math.sin(a) * sz * hd, cz - math.sin(a) * sx * hw + math.cos(a) * sz * hd)
                   for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        d.polygon([P(*p) for p in corners], outline=(230, 170, 60), fill=(70, 55, 30))
        d.text(P(cx, cz), o['category'], fill=(255, 210, 120))
    for w in r['walls']:
        d.line([P(*w['a']), P(*w['b'])], fill=(235, 235, 235) if w['height'] > 2.15 else (150, 150, 255), width=4)
        mx, mz = (w['a'][0] + w['b'][0]) / 2, (w['a'][1] + w['b'][1]) / 2
        d.text(P(mx + w['n'][0] * 0.15, mz + w['n'][2] * 0.15), str(w['index']), fill=(255, 255, 255))
        if w.get('facing'):
            f = w['facing']
            d.text(P(mx + w['n'][0] * .3, mz + w['n'][2] * .3),
                   f"{f['cardinal']} {f['degrees']:.0f} deg", fill=(120, 230, 255))
        for k in range(int(w['length'] / 0.5) + 1):  # u ticks
            t = k * 0.5
            px, pz = w['a'][0] + w['u'][0] * t, w['a'][1] + w['u'][2] * t
            q0, q1 = P(px, pz), P(px + w['n'][0] * 0.07, pz + w['n'][2] * 0.07)
            d.line([q0, q1], fill=(255, 120, 120))
        for o in w['openings']:
            p0 = (w['a'][0] + w['u'][0] * o['u0'], w['a'][1] + w['u'][2] * o['u0'])
            p1 = (w['a'][0] + w['u'][0] * o['u1'], w['a'][1] + w['u'][2] * o['u1'])
            d.line([P(*p0), P(*p1)], fill=(80, 200, 255) if o['kind'] == 'door' else (120, 255, 160), width=8)
    for i, ph in enumerate(r['photos']):
        x, z = ph['position'][0], ph['position'][2]
        f = ph['forward']
        n = math.hypot(f[0], f[2]) or 1
        d.line([P(x, z), P(x + f[0] / n * 0.3, z + f[2] / n * 0.3)], fill=(255, 90, 160), width=2)
        d.text(P(x, z), str(i), fill=(255, 150, 200))
    compass = r.get('compass')
    if compass and compass.get('status') == 'aligned':
        n = compass['north']
        x, z = maxx - .4, minz + .4
        d.line([P(x, z), P(x + n[0] * .3, z + n[2] * .3)], fill=(120, 230, 255), width=4)
        d.text(P(x, z + .05), f"N ({compass['reference']}) +/-{compass['accuracyDegrees']:.0f} deg", fill=(120, 230, 255))
    img.save(path)
    print(path)


if __name__ == '__main__':
    main()
