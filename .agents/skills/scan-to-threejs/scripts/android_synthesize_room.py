#!/usr/bin/env python3
"""Synthesize what RoomPlan provides on iOS (walls, doors/windows/openings, object boxes)
for an Android (ARCore) House Capture bundle, from its depth frames or a fused point cloud.
The app only writes a rough plane-derived rooms/room-N.json; this replaces it so
bundle_to_room.py and the rest of the skill run unchanged.

usage: android_synthesize_room.py <bundle> [--room N] [--points recon/scan_world.ply | --from-depth]
                                  [--cell 0.03] [--min-wall 0.4] [--free-walls] [--no-objects]
                                  [--write-bundle] [-o out_dir] [--plan plan.png]

  1. points: back-project depth frames (confidence ≥ 1, 0.3–4 m, despeckled; normals from the
     depth-image gradient) or read a PLY with vertex normals or triangles; voxel-downsample
  2. floor/ceiling: 2 cm height histograms of up/down-facing points
  3. heading: horizontal normals folded ×4 (the bundle_to_room.py formula)
  4. wall evidence: cells whose vertical points fill most 10 cm bins from floor to ceiling
  5. wall lines: x/z histogram peaks in the heading frame (--free-walls: RANSAC lines)
  6. room polygon: floor points ∪ camera path, snapped to the wall lines; one wall per edge
  7. doors/windows/openings: depth rays that see through a wall rectangle
  8. objects: clusters left after removing floor, ceiling and walls → boxes, category by size

Doors, windows, openings and objects are candidates: confirm them with photos (photos_for.py).
Writes <out_dir>/room-N.json (default <bundle>/synth). --write-bundle instead replaces
rooms/room-N.json (the app's file is kept once as rooms/room-N.arcore.json), writes
mesh/room-N.ply in the iOS PLY schema and updates manifest.json; it refuses to synthesize a
room twice without --force. --plan draws the result with bundle_to_room.py. --room defaults to the
manifest's room when it lists exactly one (Android exports are one room per session).
Needs: pip install numpy pillow
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
import zlib

import numpy as np

from reconstruct_bundle import ARKIT_TO_CV, despeckle

UP = np.array([0.0, 1.0, 0.0])
PLY_TYPES = {'char': 'i1', 'int8': 'i1', 'uchar': 'u1', 'uint8': 'u1', 'short': '<i2', 'int16': '<i2',
             'ushort': '<u2', 'uint16': '<u2', 'int': '<i4', 'int32': '<i4', 'uint': '<u4', 'uint32': '<u4',
             'float': '<f4', 'float32': '<f4', 'double': '<f8', 'float64': '<f8'}
CLASS_COLORS = np.array([(150, 150, 150), (225, 225, 225), (190, 150, 110), (245, 245, 245)], np.uint8)  # none wall floor ceiling
SCRIPTS = os.path.dirname(os.path.abspath(__file__))


def read_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path) as fh:
        return json.load(fh)


def m4(t):
    return np.array(t, dtype=np.float64).reshape(4, 4).T  # column-major → row-major


# --- points ----------------------------------------------------------------------------

def room_frames(bundle, room):
    frames = read_json(os.path.join(bundle, 'depth/frames.json'), [])
    return [f for f in frames if f.get('room', room) == room]


def load_frame(bundle, f, min_conf=1):
    """Depth (m, 0 = invalid) with low-confidence pixels removed, intrinsics K, OpenCV camera-to-world,
    and the high-confidence (2) pixel mask (all True when the bundle has no confidence file)."""
    w, h = f['width'], f['height']
    with open(os.path.join(bundle, f['file']), 'rb') as fh:
        raw = fh.read()
    if f['file'].endswith('.f16z'):
        raw = zlib.decompress(raw, -15)
    depth = np.frombuffer(raw, dtype='<f2').astype(np.float32).reshape(h, w).copy()
    depth[~np.isfinite(depth)] = 0
    sure = np.ones((h, w), bool)
    if f.get('confidence') and os.path.exists(os.path.join(bundle, f['confidence'])):
        conf = np.fromfile(os.path.join(bundle, f['confidence']), dtype=np.uint8).reshape(h, w)
        depth[conf < min_conf] = 0
        sure = conf >= 2
    k = np.array(f['intrinsics'], dtype=np.float64).reshape(3, 3).T
    return despeckle(depth), k, m4(f['transform']) @ ARKIT_TO_CV, sure


def frame_points(depth, k, cam_to_world, near=0.3, far=4.0):
    """Back-project one depth image → world points and normals (cross product of the image gradients)."""
    h, w = depth.shape
    v, u = np.mgrid[0:h, 0:w]
    P = np.dstack([(u - k[0, 2]) * depth / k[0, 0], (v - k[1, 2]) * depth / k[1, 1], depth])
    dx, dy = np.zeros_like(P), np.zeros_like(P)
    dx[:, 1:-1] = P[:, 2:] - P[:, :-2]
    dy[1:-1] = P[2:] - P[:-2]
    n = np.cross(dx, dy)
    valid = (depth > near) & (depth < far)
    ok = valid.copy()
    ok[:, 1:-1] &= valid[:, 2:] & valid[:, :-2]
    ok[1:-1] &= valid[2:] & valid[:-2]
    ok[[0, -1]] = False
    ok[:, [0, -1]] = False
    norm = np.linalg.norm(n, axis=2)
    ok &= norm > 1e-9
    p, n = P[ok], n[ok] / norm[ok][:, None]
    n[np.einsum('ij,ij->i', n, p) > 0] *= -1  # face the camera
    R, t = cam_to_world[:3, :3], cam_to_world[:3, 3]
    return p @ R.T + t, n @ R.T


def voxel_down(p, n, cell):
    """One point per occupied voxel: mean position, mean (renormalized) normal."""
    key = np.floor(p / cell).astype(np.int64) + (1 << 20)
    key = (key[:, 0] << 42) | (key[:, 1] << 21) | key[:, 2]
    _, inv, cnt = np.unique(key, return_inverse=True, return_counts=True)
    inv = inv.ravel()
    ps = np.stack([np.bincount(inv, p[:, i], len(cnt)) for i in range(3)], 1) / cnt[:, None]
    ns = np.stack([np.bincount(inv, n[:, i], len(cnt)) for i in range(3)], 1)
    return ps, ns / np.maximum(np.linalg.norm(ns, axis=1, keepdims=True), 1e-9)


def pixel_rays(depth, k, cam_to_world, stride=1, near=0.3):
    """Valid pixels → world ray directions scaled so that point = camera + dir · depth, and those depths."""
    v, u = np.nonzero(depth[::stride, ::stride] > near)
    v, u = v * stride, u * stride
    dirs = np.c_[(u - k[0, 2]) / k[0, 0], (v - k[1, 2]) / k[1, 1], np.ones(len(u))] @ cam_to_world[:3, :3].T
    return dirs, depth[v, u].astype(np.float64)


def depth_points(loaded, cell):
    pts, nrm = [], []
    for depth, k, c2w, _ in loaded:
        p, n = frame_points(depth, k, c2w)
        if len(p):
            p, n = voxel_down(p, n, cell)
            pts.append(p)
            nrm.append(n)
    if not pts:
        raise ValueError('no valid depth pixels in the depth frames')
    return voxel_down(np.concatenate(pts), np.concatenate(nrm), cell)


def free_space(loaded, Rm, origin, shape, cell, stride=4, far=5.0):
    """Heading-frame cells that depth rays crossed on their way to a surface: the room's open floor area,
    even where the floor itself was hidden or never looked at. Only confident rays up to `far` meters
    carve, so long or noisy readings through windows and doorways don't open up the outside."""
    free = np.zeros(shape, bool)
    for depth, k, c2w, sure in loaded:
        dirs, z = pixel_rays(np.where(sure & (depth < far), depth, 0), k, c2w, stride)
        if not len(z):
            continue
        cam = c2w[:3, 3]
        start = cam[[0, 2]] @ Rm.T
        end = (cam + dirs * (z[:, None] * 0.97 - 0.03))[:, [0, 2]] @ Rm.T  # stop short of the surface
        steps = int(np.ceil(np.linalg.norm(end - start, axis=1).max() / (cell / 2))) + 1
        for s in np.linspace(0, 1, steps):
            ix = ((start + (end - start) * s - origin) / cell).astype(int)
            ok = (ix >= 0).all(1) & (ix < np.array(shape)).all(1)
            free[ix[ok, 0], ix[ok, 1]] = True
    return free


def read_ply(path):
    """Minimal PLY reader (ascii / binary little-endian) → vertices, vertex normals or None, triangles or None."""
    with open(path, 'rb') as fh:
        if fh.readline().strip() != b'ply':
            raise ValueError(f'{path}: not a PLY file')
        fmt, elements = None, []
        while True:
            line = fh.readline()
            if not line:
                raise ValueError(f'{path}: truncated header')
            parts = line.decode('ascii', 'replace').split()
            if not parts or parts[0] in ('comment', 'obj_info'):
                continue
            if parts[0] == 'format':
                fmt = parts[1]
            elif parts[0] == 'element':
                elements.append((parts[1], int(parts[2]), []))
            elif parts[0] == 'property':
                elements[-1][2].append(parts[1:])
            elif parts[0] == 'end_header':
                break
        body = fh.read()
    if fmt not in ('ascii', 'binary_little_endian'):
        raise ValueError(f'{path}: unsupported PLY format {fmt}')
    data, offset, tokens, pos = {}, 0, (body.split() if fmt == 'ascii' else None), 0
    for name, count, props in elements:
        if fmt == 'ascii':
            rows = []
            for _ in range(count):
                row = {}
                for prop in props:
                    if prop[0] == 'list':
                        k = int(tokens[pos])
                        row[prop[3]] = [float(t) for t in tokens[pos + 1:pos + 1 + k]]
                        pos += 1 + k
                    else:
                        row[prop[1]] = float(tokens[pos])
                        pos += 1
                rows.append(row)
            data[name] = {key: np.array([r[key] for r in rows]) for key in (rows[0] if rows else {})}
            continue
        fields = []
        for prop in props:
            if prop[0] == 'list':
                fields += [('count_' + prop[3], PLY_TYPES[prop[1]]), (prop[3], PLY_TYPES[prop[2]], (3,))]
            else:
                fields.append((prop[1], PLY_TYPES[prop[0]]))
        dt = np.dtype(fields)
        arr = np.frombuffer(body, dt, count, offset)
        offset += dt.itemsize * count
        for prop in props:
            if prop[0] == 'list' and count and (arr['count_' + prop[3]] != 3).any():
                raise ValueError(f'{path}: only triangle faces are supported')
        data[name] = {key: arr[key] for key in dt.names}
    v = data.get('vertex')
    if not v or 'x' not in v:
        raise ValueError(f'{path}: no vertex positions')
    V = np.c_[v['x'], v['y'], v['z']].astype(np.float64)
    N = np.c_[v['nx'], v['ny'], v['nz']].astype(np.float64) if 'nx' in v else None
    face = data.get('face', {})
    F = next((np.asarray(face[k]).astype(np.int64).reshape(-1, 3) for k in ('vertex_indices', 'vertex_index') if k in face), None)
    return V, N, (F if F is not None and len(F) else None)


def vertex_normals(V, F):
    fn = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])  # area-weighted
    N = np.zeros_like(V)
    for i in range(3):
        np.add.at(N, F[:, i], fn)
    return N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-12)


# --- rasters ------------------------------------------------------------------------------

def dilate(m, r=1):
    """Square (2r+1)² dilation (separable); also ORs integer bit masks."""
    for axis in (0, 1):
        p = np.pad(m, [(r, r) if a == axis else (0, 0) for a in (0, 1)])
        out = np.zeros_like(m)
        for d in range(2 * r + 1):
            out |= p[d:d + m.shape[0]] if axis == 0 else p[:, d:d + m.shape[1]]
        m = out
    return m


def erode(m, r=1):
    return ~dilate(~m, r)


def components(mask, diag=False):
    """Connected components of a boolean raster → (labels with -1 for background, count)."""
    h, w = mask.shape
    m = mask.tolist()
    labels = [[-1] * w for _ in range(h)]
    steps = [(1, 0), (-1, 0), (0, 1), (0, -1)] + ([(1, 1), (1, -1), (-1, 1), (-1, -1)] if diag else [])
    n = 0
    for y0, x0 in zip(*np.nonzero(mask)):
        if labels[y0][x0] >= 0:
            continue
        labels[y0][x0] = n
        stack = [(y0, x0)]
        while stack:
            y, x = stack.pop()
            for dy, dx in steps:
                yy, xx = y + dy, x + dx
                if 0 <= yy < h and 0 <= xx < w and m[yy][xx] and labels[yy][xx] < 0:
                    labels[yy][xx] = n
                    stack.append((yy, xx))
        n += 1
    return np.array(labels, np.int32).reshape(h, w), n


def largest(mask, diag=False):
    labels, n = components(mask, diag)
    if n == 0:
        return mask
    return labels == np.argmax(np.bincount(labels[labels >= 0]))


def fill_holes(mask):
    labels, n = components(~mask)
    border = set(labels[[0, -1]].ravel()) | set(labels[:, [0, -1]].ravel())
    holes = np.isin(labels, [i for i in range(n) if i not in border])
    return mask | holes


def outline(inside, xs, zs):
    """Largest boundary loop of a boolean cell grid (cell i, j spans xs[i]..xs[i+1] × zs[j]..zs[j+1])."""
    pad = np.pad(inside, 1)
    nxt = {}
    for i, j in zip(*np.nonzero(inside)):
        i, j = int(i), int(j)
        for missing, a, b in ((not pad[i + 1, j], (i, j), (i + 1, j)), (not pad[i + 2, j + 1], (i + 1, j), (i + 1, j + 1)),
                              (not pad[i + 1, j + 2], (i + 1, j + 1), (i, j + 1)), (not pad[i, j + 1], (i, j + 1), (i, j))):
            if missing:
                nxt.setdefault(a, []).append(b)
    best, best_area = [], 0
    while nxt:
        start = next(iter(nxt))
        loop, v = [], start
        while v in nxt:
            loop.append(v)
            ends = nxt[v]
            w = ends.pop(0)
            if not ends:
                del nxt[v]
            v = w
        pts = [(xs[i], zs[j]) for i, j in loop]
        area = sum(pts[k][0] * pts[k - 1][1] - pts[k - 1][0] * pts[k][1] for k in range(len(pts))) / 2
        if abs(area) > best_area:
            best, best_area = pts, abs(area)
    return drop_collinear(best)


def drop_collinear(pts, eps=1e-6):
    pts = [p for k, p in enumerate(pts) if math.dist(p, pts[k - 1]) > eps]
    changed = True
    while changed and len(pts) > 3:
        changed = False
        for k in range(len(pts)):
            a, b, c = pts[k - 1], pts[k], pts[(k + 1) % len(pts)]
            if abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])) < eps * max(math.dist(a, c), 1e-9):
                del pts[k]
                changed = True
                break
    return pts


def douglas_peucker(pts, eps):
    """Simplify a closed polygon."""
    if len(pts) < 4:
        return pts
    far = max(range(len(pts)), key=lambda k: math.dist(pts[0], pts[k]))

    def chain(c):
        keep, stack = {0, len(c) - 1}, [(0, len(c) - 1)]
        while stack:
            s, e = stack.pop()
            a, b = np.array(c[s]), np.array(c[e])
            d = b - a
            L = np.hypot(*d) or 1e-9
            best, bi = 0, None
            for k in range(s + 1, e):
                dist = abs(d[0] * (c[k][1] - a[1]) - d[1] * (c[k][0] - a[0])) / L
                if dist > best:
                    best, bi = dist, k
            if bi is not None and best > eps:
                keep.add(bi)
                stack += [(s, bi), (bi, e)]
        return [c[k] for k in sorted(keep)]

    return chain(pts[:far + 1])[:-1] + chain(pts[far:] + [pts[0]])[:-1]


def runs(values, gap):
    """Lengths of runs of sorted values with no gap larger than `gap`."""
    v = np.sort(values)
    if len(v) == 0:
        return []
    cut = np.nonzero(np.diff(v) > gap)[0]
    starts, ends = np.r_[0, cut + 1], np.r_[cut, len(v) - 1]
    return [(v[s], v[e]) for s, e in zip(starts, ends)]


def inside_poly(pts, poly):
    x, z = pts[:, 0], pts[:, 1]
    hit = np.zeros(len(pts), bool)
    with np.errstate(divide='ignore', invalid='ignore'):
        for k in range(len(poly)):
            (x1, z1), (x2, z2) = poly[k - 1], poly[k]
            hit ^= ((z1 > z) != (z2 > z)) & (x < x1 + (z - z1) * (x2 - x1) / (z2 - z1))
    return hit


def edge_distance(pts, poly):
    """Distance from each x/z point to the polygon's boundary."""
    best = np.full(len(pts), np.inf)
    for k in range(len(poly)):
        a, b = np.array(poly[k - 1]), np.array(poly[k])
        d = b - a
        t = np.clip((pts - a) @ d / max(d @ d, 1e-12), 0, 1)
        best = np.minimum(best, np.linalg.norm(pts - (a + t[:, None] * d), axis=1))
    return best


def rot2(theta):
    """2×2 rotation of [x, z]; rot2(-theta) maps the world direction atan2(z, x) = theta onto +x."""
    c, s = math.cos(theta), math.sin(theta)
    return np.array([[c, -s], [s, c]])


# --- layout -------------------------------------------------------------------------------

def peaks(values, lo, hi, step=0.02, min_frac=0.02):
    """Bin centers of local maxima (3-bin smoothed) that hold at least min_frac of the values."""
    if len(values) == 0 or hi <= lo:
        return []
    edges = np.arange(lo, hi + step, step)
    h, _ = np.histogram(values, edges)
    s = np.convolve(h, np.ones(3), 'same')
    centers = (edges[:-1] + edges[1:]) / 2
    return [centers[i] for i in range(len(s)) if s[i] >= min_frac * len(values) and s[i] == s[max(0, i - 2):i + 3].max()]


def floor_ceiling(points, normals, cams):
    y, ny = points[:, 1], normals[:, 1]
    up, down = y[ny > 0.8], y[ny < -0.8]
    refine = lambda v, c: float(np.median(v[np.abs(v - c) < 0.04]))
    fp = peaks(up, y.min(), y.max())
    if fp:
        floor = refine(up, fp[0])
    else:
        floor = float(cams[:, 1].min()) - 1.3 if len(cams) else float(y.min())
        print(f'warning: no floor seen; assuming {floor:.2f} m (1.3 m below the lowest camera)')
    cp = peaks(down, floor + 2.0, floor + 4.5)
    if cp:
        return floor, refine(down, cp[-1]), True, bool(fp)
    print('warning: no ceiling seen; assuming 2.5 m walls')
    return floor, floor + 2.5, False, bool(fp)


def heading(normals):
    h = normals[np.abs(normals[:, 1]) < 0.3]
    ang = np.arctan2(h[:, 2], h[:, 0]) * 4  # ×4 folds 90° symmetry
    w = np.hypot(h[:, 0], h[:, 2])
    return math.atan2(float((np.sin(ang) * w).sum()), float((np.cos(ang) * w).sum())) / 4


def wall_raster(pr, y, ny, floor, ceiling, seen_ceiling, origin, shape, cell, frac=None):
    """Cells whose (near-)vertical points cover enough 10 cm height bins between floor+0.2 and ceiling-0.2.
    With `frac` (partial walls, e.g. around a window) the cell must also reach the top 0.3 m, unlike furniture."""
    nb = max(1, min(60, int((ceiling - floor - 0.4) / 0.1)))
    sel = (np.abs(ny) < 0.5) & (y > floor + 0.2) & (y < ceiling - 0.2)
    b = np.minimum(((y[sel] - floor - 0.2) / 0.1).astype(np.int64), nb - 1)
    ix = ((pr[sel] - origin) / cell).astype(np.int64)
    bits = np.zeros(shape, np.int64)
    np.bitwise_or.at(bits, (ix[:, 0], ix[:, 1]), np.left_shift(np.int64(1), b))
    bits = dilate(bits, 1)  # voxels and raster cells don't line up; let neighbors share bins
    count = sum((bits >> k) & 1 for k in range(nb))
    if frac:
        return (count >= frac * nb) & ((bits >> max(0, nb - 3)) != 0)
    return count >= (0.55 if seen_ceiling else 0.40) * nb


def axis_lines(cells, min_wall, cell):
    """Wall offsets of constant x (axis 0) and constant z (axis 1): histogram peaks with a long enough run."""
    out = ([], [])
    for axis in (0, 1):
        v, along = cells[:, axis], cells[:, 1 - axis]
        edges = np.arange(v.min() - 0.05, v.max() + 0.1, 0.05)
        h, _ = np.histogram(v, edges)
        for i in np.argsort(-h, kind='stable'):
            if h[i] < 0.03 * len(v):
                break
            c = (edges[i] + edges[i + 1]) / 2
            if any(abs(c - o) < 0.15 for o in out[axis]):
                continue
            near = np.abs(v - c) < 0.075
            if any(e - s + cell >= min_wall for s, e in runs(along[near], 0.3)):
                out[axis].append(float(np.median(v[near])))
    return sorted(out[0]), sorted(out[1])


def ransac_lines(cells, cell, min_wall, min_inliers=40, iters=300):
    rng = np.random.default_rng(0)
    lines, rest = [], cells
    while len(rest) >= min_inliers and len(lines) < 32:
        best = None
        for _ in range(iters):
            i, j = rng.choice(len(rest), 2, replace=False)
            d = rest[j] - rest[i]
            if np.hypot(*d) < 0.2:
                continue
            e = d / np.hypot(*d)
            inl = np.abs((rest - rest[i]) @ np.array([-e[1], e[0]])) < cell
            if best is None or inl.sum() > best.sum():
                best = inl
        if best is None or best.sum() < min_inliers:
            break
        p = rest[best]
        q = p.mean(0)
        e = np.linalg.svd(p - q, full_matrices=False)[2][0]
        if any(hi - lo + cell >= min_wall for lo, hi in runs((p - q) @ e, 0.3)):
            lines.append((q, e))
        rest = rest[~best]
    return lines


def snap_to_lines(poly, lines, min_wall, tol=0.25, max_angle=15):
    """Put each polygon edge on the nearest roughly parallel line; merge edges sharing a line, drop
    short unmatched jogs between matched edges; vertices = intersections of consecutive lines."""
    sin_max = math.sin(math.radians(max_angle))
    edges = []  # (line index or None, point, unit direction, length)
    for k in range(len(poly)):
        a, b = np.array(poly[k]), np.array(poly[(k + 1) % len(poly)])
        length = float(np.hypot(*(b - a)))
        d = (b - a) / (length or 1e-9)
        best, best_dist = None, tol
        for li, (q, e) in enumerate(lines):
            if abs(d[0] * e[1] - d[1] * e[0]) > sin_max:
                continue
            dist = max(abs(e[0] * (p[1] - q[1]) - e[1] * (p[0] - q[0])) for p in (a, b))
            if dist < best_dist:
                best, best_dist = li, dist
        edges.append((best, a, d, length))
    changed = True
    while changed and len(edges) > 3:
        changed = False
        for k in range(len(edges)):
            prev, cur, nxt = edges[k - 1], edges[k], edges[(k + 1) % len(edges)]
            if cur[0] is not None and cur[0] == nxt[0]:
                edges[k] = (cur[0], cur[1], cur[2], cur[3] + nxt[3])
                del edges[(k + 1) % len(edges)]
                changed = True
                break
            if cur[0] is None and cur[3] < min_wall and prev[0] is not None and nxt[0] is not None:
                del edges[k]
                changed = True
                break
    out = []
    for k in range(len(edges)):
        (l1, a1, d1, _), (l2, a2, d2, _) = edges[k - 1], edges[k]
        q1, e1 = lines[l1] if l1 is not None else (a1, d1)
        q2, e2 = lines[l2] if l2 is not None else (a2, d2)
        den = e1[0] * e2[1] - e1[1] * e2[0]
        if abs(den) < math.sin(math.radians(10)):
            out.append(tuple(a2))
            continue
        t = ((q2[0] - q1[0]) * e2[1] - (q2[1] - q1[1]) * e2[0]) / den
        out.append((q1[0] + e1[0] * t, q1[1] + e1[1] * t))
    return drop_collinear(out, 1e-3)


def room_polygon(mask, origin, cell, walls, xlines, zlines, free_lines, cams, min_wall):
    """Open-floor mask (heading frame) → room polygon. Rectilinear: the wall lines cut the plane into
    rectangles; the room is the mostly-open rectangles reachable from the cameras without crossing a
    seen wall. --free-walls: the mask outline, simplified and snapped onto the RANSAC lines."""
    nx, nz = mask.shape
    if free_lines is not None:
        # walls (and wall around windows: `walls` is the weak mask here) block the open area;
        # an opening of 0.5 m radius cuts it off at doorways
        open_ = mask & ~dilate(walls, 1)
        r = max(1, int(round(0.5 / cell)))
        labels, n = components(dilate(erode(open_, r), r) & open_)
        cam_ix = np.clip(((cams - origin) / cell).astype(int), 0, np.array(mask.shape) - 1)
        hits = labels[cam_ix[:, 0], cam_ix[:, 1]] if len(cams) else np.array([], int)
        hits = hits[hits >= 0]
        if n == 0:
            return []
        keep = np.bincount(hits).argmax() if len(hits) else np.bincount(labels[labels >= 0]).argmax()
        room = fill_holes(labels == keep)
        loop = outline(room, origin[0] + cell * np.arange(nx + 1), origin[1] + cell * np.arange(nz + 1))
        return snap_to_lines(douglas_peucker(loop, max(0.1, 3 * cell)), free_lines, min_wall)
    ii, jj = np.nonzero(mask)
    lo, hi = origin + cell * np.array([ii.min(), jj.min()]), origin + cell * np.array([ii.max() + 1, jj.max() + 1])
    xs = sorted(set(xlines) | {v for v in (lo[0], hi[0]) if all(abs(v - x) > 0.25 for x in xlines)})
    zs = sorted(set(zlines) | {v for v in (lo[1], hi[1]) if all(abs(v - z) > 0.25 for z in zlines)})
    S = np.pad(mask.astype(np.int64).cumsum(0).cumsum(1), ((1, 0), (1, 0)))  # integral image
    xi = np.clip(np.round((np.array(xs) - origin[0]) / cell).astype(int), 0, nx)
    zi = np.clip(np.round((np.array(zs) - origin[1]) / cell).astype(int), 0, nz)
    ni, nj = len(xs) - 1, len(zs) - 1
    fill = np.zeros((ni, nj))
    for i in range(ni):
        for j in range(nj):
            area = (xi[i + 1] - xi[i]) * (zi[j + 1] - zi[j])
            if area > 0:
                fill[i, j] = (S[xi[i + 1], zi[j + 1]] - S[xi[i], zi[j + 1]] - S[xi[i + 1], zi[j]] + S[xi[i], zi[j]]) / area
    near = dilate(walls, 1)

    def backed(axis, k, lo, hi):  # wall-cell fraction along the shared border of two rectangles
        line = near[k, lo:hi] if axis == 0 else near[lo:hi, k]
        return line.mean() if len(line) else 0

    seeds = {(int(np.searchsorted(xs, c[0])) - 1, int(np.searchsorted(zs, c[1])) - 1) for c in cams}
    seeds = [s for s in seeds if 0 <= s[0] < ni and 0 <= s[1] < nj and fill[s] >= 0.5]
    if not seeds and fill.max() >= 0.5:
        seeds = [np.unravel_index(np.argmax(fill), fill.shape)]
    inside, stack = np.zeros((ni, nj), bool), list(seeds)
    for s in seeds:
        inside[s] = True
    while stack:
        i, j = stack.pop()
        for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            a, b = i + di, j + dj
            if not (0 <= a < ni and 0 <= b < nj) or inside[a, b] or fill[a, b] < 0.5:
                continue
            border = backed(0, xi[max(i, a)], zi[j], zi[j + 1]) if di else backed(1, zi[max(j, b)], xi[i], xi[i + 1])
            if border < 0.5:
                inside[a, b] = True
                stack.append((a, b))
    if not inside.any():
        return []
    return outline(inside, xs, zs)


def polygon_area(poly):
    return sum(poly[k - 1][0] * poly[k][1] - poly[k][0] * poly[k - 1][1] for k in range(len(poly))) / 2


def ccw_from_above(poly):
    """Counter-clockwise seen from above (+y): positive signed area in x/(-z), as bundle_to_room.py."""
    area = sum(poly[k][0] * -poly[(k + 1) % len(poly)][1] - poly[(k + 1) % len(poly)][0] * -poly[k][1] for k in range(len(poly)))
    return poly[::-1] if area < 0 else poly


def element(category, confidence, dims, center, u, n, parent=None):
    T = np.eye(4)
    T[:3, 0], T[:3, 1], T[:3, 2], T[:3, 3] = u, UP, n, center
    return {'identifier': str(uuid.uuid4()).upper(), 'category': category, 'confidence': {confidence: {}},
            'dimensions': [round(float(d), 4) for d in dims], 'transform': [round(float(v), 6) for v in T.T.ravel()],
            'parentIdentifier': parent, 'completedEdges': [], 'polygonCorners': [], 'curve': None, 'story': 0}


def wall_frames(poly, floor, height):
    """One wall per polygon edge: origin (interior face, left end, floor), u, n into the room, length."""
    P = np.array(poly)
    out = []
    for k in range(len(poly)):
        a, b = P[k], P[(k + 1) % len(poly)]
        length = float(np.hypot(*(b - a)))
        if length < 1e-3:
            continue
        u = np.array([(b - a)[0], 0, (b - a)[1]]) / length
        n = np.array([-u[2], 0, u[0]])  # u × up
        mid = (a + b) / 2
        if not inside_poly((mid + 0.05 * n[[0, 2]])[None], poly)[0]:
            u, n, a = -u, -n, b
        out.append({'origin': np.array([a[0], floor, a[1]]), 'u': u, 'n': n, 'length': length, 'height': height})
    return out


def find_openings(loaded, walls, floor, cell=0.03):
    """Per wall, a (u, v) vote grid: depth rays crossing the wall rectangle that measure well beyond it
    (or floor continuing behind it) vote 'through', rays that end on it vote 'solid'."""
    through = [np.zeros((max(1, math.ceil(w['length'] / cell)), max(1, math.ceil(w['height'] / cell)))) for w in walls]
    solid = [np.zeros_like(t) for t in through]
    for depth, k, c2w, _ in loaded:
        dirs, z = pixel_rays(depth, k, c2w)
        cam = c2w[:3, 3]
        meas = cam + dirs * z[:, None]
        scale = np.linalg.norm(dirs, axis=1)
        for w, th, so in zip(walls, through, solid):
            o, uu, n = w['origin'], w['u'], w['n']
            if n @ (cam - o) <= 0.05:
                continue
            dn = dirs @ n
            with np.errstate(divide='ignore', invalid='ignore'):
                t = (n @ (o - cam)) / dn
            hit = cam + dirs * t[:, None]
            su, sv = (hit - o) @ uu, hit[:, 1] - floor
            ok = (dn < -1e-6) & (t > 0) & (su >= 0) & (su < w['length']) & (sv >= 0) & (sv < w['height'])
            diff = (z - t) * scale
            behind = -(meas - o) @ n
            th_ok = ok & ((diff > 0.15) | ((meas[:, 1] < floor + 0.05) & (behind > 0.03)))
            so_ok = ok & (np.abs(diff) < 0.1) & ~th_ok
            for mask, grid in ((th_ok, th), (so_ok, so)):
                iu = np.minimum((su[mask] / cell).astype(int), grid.shape[0] - 1)
                iv = np.minimum((sv[mask] / cell).astype(int), grid.shape[1] - 1)
                np.add.at(grid, (iu, iv), 1)
    found = []
    for wi, (w, th, so) in enumerate(zip(walls, through, solid)):
        labels, n = components((th >= 2) & (th > so))
        for c in range(n):
            iu, iv = np.nonzero(labels == c)
            u0, u1, v0, v1 = iu.min() * cell, (iu.max() + 1) * cell, iv.min() * cell, (iv.max() + 1) * cell
            width, height = u1 - u0, v1 - v0
            if len(iu) < 0.5 * (np.ptp(iu) + 1) * (np.ptp(iv) + 1):
                continue  # a streak, not a rectangle
            if v0 <= 0.15 and width >= 0.5 and v1 >= 1.8:
                kind = 'door' if v1 <= 2.4 and width <= 1.4 and v1 < w['height'] - 0.05 else 'opening'
                v0 = 0.0
            elif 0.4 <= v0 <= 1.2 and v1 < min(2.4, w['height']) and width >= 0.4 and height >= 0.4:
                kind = 'window'
            else:
                continue
            found.append({'wall': wi, 'kind': kind, 'u0': u0, 'u1': u1, 'v0': v0, 'v1': v1})
    return found


def object_category(long, short, height):
    if long >= 1.8 and short >= 1.2 and 0.3 <= height <= 0.9:
        return 'bed'
    if long >= 1.4 and 0.6 <= short <= 1.2 and 0.35 <= height <= 1.1:
        return 'sofa'
    if 0.6 <= height <= 0.95 and long >= 0.6:
        return 'table'
    if long <= 0.7 and 0.7 <= height <= 1.2:
        return 'chair'
    return 'storage'


def find_objects(points, floor, ceiling, poly, Rm, cell=0.05):
    """Boxes around what is left after removing floor, ceiling, walls and everything outside the room."""
    xz = points[:, [0, 2]]
    y = points[:, 1]
    keep = (y > floor + 0.08) & (y < ceiling - 0.08) & inside_poly(xz, poly)
    keep[keep] &= edge_distance(xz[keep], poly) > 0.08
    p, py = xz[keep] @ Rm.T, y[keep]
    if len(p) == 0:
        return []
    origin = p.min(0) - cell
    ix = ((p - origin) / cell).astype(int)
    occ = np.zeros(tuple(ix.max(0) + 2), bool)
    occ[ix[:, 0], ix[:, 1]] = True
    labels, n = components(occ, diag=True)
    lab = labels[ix[:, 0], ix[:, 1]]
    centroid = np.array(poly).mean(0) @ Rm.T
    out = []
    for c in range(n):
        sel = lab == c
        area = (labels == c).sum() * cell * cell
        height = float(np.percentile(py[sel], 98)) - floor
        if height < 0.25 or area < 0.15:
            continue
        lo, hi = np.percentile(p[sel], 2, axis=0), np.percentile(p[sel], 98, axis=0)
        center, size = (lo + hi) / 2, (hi - lo) / 0.96  # 2-98 % of a uniformly sampled box
        axes = [np.array(a) for a in ((1, 0), (-1, 0), (0, 1), (0, -1))]
        front = max(axes, key=lambda a: a @ (centroid - center))
        depth_, width = size if front[0] else size[::-1]
        cw, fw = center @ Rm, front @ Rm  # back to world x/z
        f3 = np.array([fw[0], 0, fw[1]])
        out.append({'category': object_category(max(width, depth_), min(width, depth_), height),
                    'dims': [width, height, depth_], 'center': np.array([cw[0], floor + height / 2, cw[1]]),
                    'u': np.cross(UP, f3), 'n': f3})
    return out


# --- outputs ------------------------------------------------------------------------------

def point_classes(points, normals, floor, ceiling, poly):
    cls = np.zeros(len(points), np.uint8)
    cls[(edge_distance(points[:, [0, 2]], poly) < 0.08) & (np.abs(normals[:, 1]) < 0.5)] = 1
    cls[(np.abs(points[:, 1] - floor) < 0.05) & (normals[:, 1] > 0.7)] = 2
    cls[(np.abs(points[:, 1] - ceiling) < 0.05) & (normals[:, 1] < -0.7)] = 3
    return cls


def surfels(points, normals, cell):
    """A cell-sized quad (two triangles, wound around the normal) per point, so the PLY has faces."""
    a = np.where(np.abs(normals[:, 1:2]) > 0.9, [[1.0, 0, 0]], [[0, 1.0, 0]])
    t1 = np.cross(normals, a)
    t1 /= np.linalg.norm(t1, axis=1, keepdims=True)
    t2 = np.cross(normals, t1) * (cell / 2)
    t1 *= cell / 2
    V = np.stack([points - t1 - t2, points + t1 - t2, points + t1 + t2, points - t1 + t2], 1).reshape(-1, 3)
    b = np.arange(len(points))[:, None] * 4
    F = np.stack([np.c_[b, b + 1, b + 2], np.c_[b, b + 2, b + 3]], 1).reshape(-1, 3)
    return V, np.repeat(normals, 4, 0), F


def write_ply(path, V, N, colors, F, face_class):
    """Binary PLY with the iOS app's vertex/face schema (CoverageEngine.writePLY)."""
    vd = np.dtype([('x', '<f4'), ('y', '<f4'), ('z', '<f4'), ('nx', '<f4'), ('ny', '<f4'), ('nz', '<f4'),
                   ('coverage', '<f4'), ('red', 'u1'), ('green', 'u1'), ('blue', 'u1'), ('inroom', 'u1')])
    fd = np.dtype([('count', 'u1'), ('vertex_indices', '<u4', (3,)), ('class', 'u1')])
    verts = np.zeros(len(V), vd)
    for i, key in enumerate(('x', 'y', 'z')):
        verts[key], verts['n' + key] = V[:, i], N[:, i]
    verts['coverage'], verts['inroom'] = 1, 1
    verts['red'], verts['green'], verts['blue'] = colors[:, 0], colors[:, 1], colors[:, 2]
    faces = np.zeros(len(F), fd)
    faces['count'], faces['vertex_indices'], faces['class'] = 3, F, face_class
    header = ('ply\nformat binary_little_endian 1.0\n'
              'comment house-capture synthesized mesh (android_synthesize_room.py), ARCore world space (meters, +Y up)\n'
              'comment coverage: not measured (1)\n'
              'comment class: 0 none 1 wall 2 floor 3 ceiling 4 table 5 seat 6 window 7 door\n'
              f'element vertex {len(V)}\nproperty float x\nproperty float y\nproperty float z\n'
              'property float nx\nproperty float ny\nproperty float nz\nproperty float coverage\n'
              'property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar inroom\n'
              f'element face {len(F)}\nproperty list uchar uint vertex_indices\nproperty uchar class\nend_header\n')
    with open(path + '.tmp', 'wb') as fh:
        fh.write(header.encode())
        fh.write(verts.tobytes())
        fh.write(faces.tobytes())
    os.replace(path + '.tmp', path)


def write_json(path, data):
    with open(path + '.tmp', 'w') as fh:
        json.dump(data, fh, indent=1, allow_nan=False)
    os.replace(path + '.tmp', path)


def synthesize(bundle, room, points=None, from_depth=False, cell=0.03, min_wall=0.4, free_walls=False,
               objects=True, write_bundle=False, out_dir=None, plan=None, force=False, max_frames=400):
    """Build RoomPlan-shaped JSON for one room; see the module docstring. Returns the room dict."""
    if points and from_depth:
        raise ValueError('use either --points or --from-depth')
    manifest_path = os.path.join(bundle, 'manifest.json')
    manifest = read_json(manifest_path)
    capture = (manifest or {}).get('capture') or {}
    if write_bundle:
        if manifest is None:
            raise ValueError('--write-bundle needs the bundle manifest.json')
        if room in capture.get('synthesizedRooms', []) and not force:
            raise ValueError(f'rooms/room-{room}.json is already synthesized; pass --force to redo it '
                             f'(the app original stays in rooms/room-{room}.arcore.json)')
    out_file = None
    if out_dir or not write_bundle:
        out_dir = out_dir or os.path.join(bundle, 'synth')
        out_file = os.path.join(out_dir, f'room-{room}.json')
        if os.path.exists(out_file) and not force:
            raise ValueError(f'{out_file} exists; pass --force to overwrite')

    frames = room_frames(bundle, room)
    frames = frames[::max(1, math.ceil(len(frames) / max_frames))]
    photos_path = os.path.join(bundle, 'photos/photos.json')
    photos = [p for p in read_json(photos_path, []) if p.get('room', room) == room]
    cams = np.array([m4(x['transform'])[:3, 3] for x in frames + photos]).reshape(-1, 3)

    # 1. points
    mesh = None
    loaded = [load_frame(bundle, f) for f in frames]
    if points:
        V, N, F = read_ply(points)
        if N is None:
            if F is None:
                raise ValueError(f'{points}: needs vertex normals or triangles')
            N = vertex_normals(V, F)
        mesh = (V, N, F) if F is not None else None
        pts, nrm = voxel_down(V, N, cell)
        print(f'{len(V):,} points from {points} → {len(pts):,} at {cell * 100:.0f} cm')
    else:
        if not frames:
            raise ValueError('no depth frames for this room; pass --points <ply>')
        pts, nrm = depth_points(loaded, cell)
        print(f'{len(frames)} depth frames → {len(pts):,} points at {cell * 100:.0f} cm')

    # 2-3. floor, ceiling, heading
    floor, ceiling, seen_ceiling, seen_floor = floor_ceiling(pts, nrm, cams)
    theta = heading(nrm)
    Rm = rot2(-theta)
    pr = pts[:, [0, 2]] @ Rm.T
    print(f'floor y {floor:.3f}, ceiling {ceiling - floor:.2f} m above it, heading {math.degrees(theta):.1f}°')

    # 4-5. wall evidence and lines (in the heading frame)
    cam_r = cams[:, [0, 2]] @ Rm.T if len(cams) else np.zeros((0, 2))
    all_r = np.r_[pr, cam_r]
    origin = all_r.min(0) - 10 * cell
    shape = tuple(np.ceil((all_r.max(0) - origin) / cell).astype(int) + 10)
    walls_mask = wall_raster(pr, pts[:, 1], nrm[:, 1], floor, ceiling, seen_ceiling, origin, shape, cell)
    wall_cells = origin + (np.argwhere(walls_mask) + 0.5) * cell
    xlines, zlines, free_lines = [], [], None
    if free_walls:
        free_lines = ransac_lines(wall_cells, cell, min_wall) if len(wall_cells) else []
        print(f'{walls_mask.sum():,} wall cells → {len(free_lines)} lines')
    else:
        xlines, zlines = axis_lines(wall_cells, min_wall, cell) if len(wall_cells) else ([], [])
        print(f'{walls_mask.sum():,} wall cells → {len(xlines)} + {len(zlines)} axis lines')

    # 6. room polygon from free space + floor points + camera path footprint
    floor_sel = (np.abs(pts[:, 1] - floor) < 0.05) & (nrm[:, 1] > 0.7)
    mask = free_space(loaded, Rm, origin, shape, cell)
    ix = ((pr[floor_sel] - origin) / cell).astype(int)
    mask[ix[:, 0], ix[:, 1]] = True
    r = int(math.ceil(0.3 / cell))
    for c in cam_r:
        i, j = ((c - origin) / cell).astype(int)
        mask[max(0, i - r):i + r + 1, max(0, j - r):j + r + 1] = True
    mask = largest(fill_holes(erode(dilate(mask, 2), 2)))
    barrier = walls_mask  # --free-walls: partial wall evidence (wall below/above a window) also bounds the room
    if free_walls:
        barrier = wall_raster(pr, pts[:, 1], nrm[:, 1], floor, ceiling, seen_ceiling, origin, shape, cell, frac=0.25)
    poly_r = room_polygon(mask, origin, cell, barrier, xlines, zlines, free_lines, cam_r, min_wall) if mask.any() else []
    poly_r = drop_collinear([tuple(p) for p in poly_r], 1e-3) if len(poly_r) >= 3 else []
    if len(poly_r) < 3 or abs(polygon_area(poly_r)) < min_wall * min_wall:
        print('warning: no room polygon from the floor; using the bounding box of the wall cells and cameras')
        src = np.r_[wall_cells, cam_r] if len(wall_cells) + len(cam_r) else all_r
        lo, hi = src.min(0), src.max(0)
        mid, half = (lo + hi) / 2, np.maximum((hi - lo) / 2, max(min_wall, 0.5))  # never a degenerate box
        (x0, z0), (x1, z1) = mid - half, mid + half
        poly_r = [(x0, z0), (x1, z0), (x1, z1), (x0, z1)]
    poly = [tuple(p) for p in np.array(poly_r) @ Rm]  # back to world x/z
    poly = ccw_from_above(poly)

    # 7. walls, one per edge
    height = ceiling - floor
    walls = wall_frames(poly, floor, height)
    near_wall = dilate(walls_mask, 2)
    out = {'version': 2, 'story': 0, 'walls': [], 'doors': [], 'windows': [], 'openings': [], 'objects': [],
           'floors': [], 'sections': []}
    for w in walls:
        s = np.arange(cell / 2, w['length'], cell)
        p = (np.c_[w['origin'][0] + w['u'][0] * s, w['origin'][2] + w['u'][2] * s] - 0.03 * w['n'][[0, 2]]) @ Rm.T
        idx = np.clip(((p - origin) / cell).astype(int), 0, np.array(shape) - 1)
        backed = near_wall[idx[:, 0], idx[:, 1]].mean() if len(idx) else 0
        conf = 'high' if backed >= 0.6 else 'medium' if backed >= 0.25 else 'low'
        if not (seen_floor and seen_ceiling) and conf == 'high':
            conf = 'medium'
        ctr = w['origin'] + w['u'] * w['length'] / 2 + UP * height / 2
        out['walls'].append(element({'wall': {}}, conf, [w['length'], height, 0], ctr, w['u'], w['n']))
    out['floors'].append({**element({'floor': {}}, 'high' if seen_floor else 'low', [0, 0, 0], [0, floor, 0], [1, 0, 0], [0, 0, 1]),
                          'polygonCorners': [[round(float(x), 4), 0, round(float(z), 4)] for x, z in poly]})

    # 8. doors / windows / openings
    if frames:
        for o in find_openings(loaded, walls, floor):
            w, wall = walls[o['wall']], out['walls'][o['wall']]
            width, h = o['u1'] - o['u0'], o['v1'] - o['v0']
            ctr = w['origin'] + w['u'] * (o['u0'] + width / 2) + UP * (o['v0'] + h / 2)
            cat = {'door': {'isOpen': True}} if o['kind'] == 'door' else {o['kind']: {}}
            out[o['kind'] + 's'].append(element(cat, 'medium', [width, h, 0], ctr, w['u'], w['n'], wall['identifier']))
            print(f"  {o['kind']} candidate on wall {o['wall']}: u {o['u0']:.2f}-{o['u1']:.2f} v {o['v0']:.2f}-{o['v1']:.2f}"
                  ' — confirm with photos (photos_for.py)')
    else:
        print('no depth frames: skipping doors/windows/openings')

    # 9. objects
    if objects:
        for o in find_objects(pts, floor, ceiling, poly, Rm):
            out['objects'].append(element({o['category']: {}}, 'medium', o['dims'], o['center'], o['u'], o['n']))
            print(f"  {o['category']} candidate at ({o['center'][0]:.2f}, {o['center'][2]:.2f}) size "
                  f"{' × '.join(f'{d:.2f}' for d in o['dims'])} — confirm with photos")
    print(f"{len(out['walls'])} walls, {len(out['doors'])} doors, {len(out['windows'])} windows, "
          f"{len(out['openings'])} openings, {len(out['objects'])} objects")
    for i, w in enumerate(out['walls']):
        print(f"  wall {i}: {w['dimensions'][0]:.2f} × {w['dimensions'][1]:.2f} m  {next(iter(w['confidence']))}")

    # 10. write
    if out_file:
        os.makedirs(out_dir, exist_ok=True)
        write_json(out_file, out)
        print(out_file)
    if write_bundle:
        rooms_dir = os.path.join(bundle, 'rooms')
        os.makedirs(rooms_dir, exist_ok=True)
        room_path, original = os.path.join(rooms_dir, f'room-{room}.json'), os.path.join(rooms_dir, f'room-{room}.arcore.json')
        if os.path.exists(room_path) and not os.path.exists(original):
            shutil.copyfile(room_path, original)
        write_json(room_path, out)
        if mesh is not None:
            V, N, F = mesh
            vcls = point_classes(V, N, floor, ceiling, poly)
            fn = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
            fn /= np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)
            fcls = point_classes(V[F].mean(1), fn, floor, ceiling, poly)
        else:
            vcls = point_classes(pts, nrm, floor, ceiling, poly)
            V, N, F = surfels(pts, nrm, cell)
            fcls, vcls = np.repeat(vcls, 2), np.repeat(vcls, 4)
        os.makedirs(os.path.join(bundle, 'mesh'), exist_ok=True)
        mesh_file = f'mesh/room-{room}.ply'
        write_ply(os.path.join(bundle, mesh_file), V, N, CLASS_COLORS[vcls], F, fcls)
        record = {'file': mesh_file, 'anchors': 1, 'vertices': int(len(V)), 'faces': int(len(F))}
        for rec in manifest.get('rooms', []):
            if rec.get('index') == room:
                rec.update({k: len(out[k]) for k in ('walls', 'doors', 'windows', 'openings', 'objects')})
                rec['mesh'] = record
        manifest['mesh'] = record
        capture.update({'layoutSource': 'android_synthesize_room.py', 'synthesized': True,
                        'synthesizedRooms': sorted(set(capture.get('synthesizedRooms', [])) | {room})})
        manifest['capture'] = capture
        write_json(manifest_path, manifest)
        print(f'wrote rooms/room-{room}.json, {mesh_file} ({len(V):,} vertices, {len(F):,} faces), manifest.json')

    if plan:
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, 'rooms'))
            write_json(os.path.join(tmp, f'rooms/room-{room}.json'), out)
            if os.path.exists(photos_path):
                os.makedirs(os.path.join(tmp, 'photos'))
                shutil.copyfile(photos_path, os.path.join(tmp, 'photos/photos.json'))
            subprocess.run([sys.executable, os.path.join(SCRIPTS, 'bundle_to_room.py'), tmp, '--room', str(room),
                            '-o', os.path.join(tmp, 'room.json'), '--plan', plan], check=True)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('bundle')
    ap.add_argument('--room', type=int, default=None, help="room index (default: the manifest's only room)")
    src = ap.add_mutually_exclusive_group()
    src.add_argument('--points', help='PLY with vertex normals or triangles (e.g. recon/scan_world.ply from reconstruct_bundle.py)')
    src.add_argument('--from-depth', action='store_true', help='back-project the depth frames (default)')
    ap.add_argument('--max-frames', type=int, default=400, help='use every k-th depth frame so at most this many are read')
    ap.add_argument('--cell', type=float, default=0.03, help='voxel / raster cell in meters')
    ap.add_argument('--min-wall', type=float, default=0.4, help='shortest wall run kept, meters')
    ap.add_argument('--free-walls', action='store_true', help='walls at any angle (RANSAC) instead of a rectilinear room')
    ap.add_argument('--no-objects', action='store_true')
    ap.add_argument('--write-bundle', action='store_true', help='replace rooms/room-N.json, write mesh/room-N.ply, update manifest.json')
    ap.add_argument('--force', action='store_true', help='redo an already synthesized room / overwrite -o output')
    ap.add_argument('-o', default=None, help='output directory for room-N.json (default <bundle>/synth unless --write-bundle)')
    ap.add_argument('--plan', default=None, help='draw the result (bundle_to_room.py plan)')
    a = ap.parse_args()
    if a.room is None:
        rooms = (read_json(os.path.join(a.bundle, 'manifest.json')) or {}).get('rooms') or []
        if len(rooms) != 1:
            ap.error(f'pass --room: the manifest lists {len(rooms)} rooms')
        a.room = rooms[0]['index']
    try:
        synthesize(a.bundle, a.room, points=a.points, from_depth=a.from_depth, cell=a.cell, min_wall=a.min_wall,
                   free_walls=a.free_walls, objects=not a.no_objects, write_bundle=a.write_bundle, out_dir=a.o,
                   plan=a.plan, force=a.force, max_frames=a.max_frames)
    except (ValueError, OSError, KeyError) as error:
        ap.error(str(error))


if __name__ == '__main__':
    main()
