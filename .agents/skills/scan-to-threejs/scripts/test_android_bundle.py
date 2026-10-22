"""Synthetic Android (ARCore) bundle → android_synthesize_room.py → the existing skill scripts.
A ray-cast box room (rotated, floor below zero, a door, a window, a sofa and a table) stands in
for a real Pixel scan, so this checks the format and the layout algorithm on clean data only.
Run: python3 -m unittest discover -s <skill>/scripts -p 'test_*.py'
Requires numpy and Pillow.
"""
import contextlib
import io
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zlib

import numpy as np
from PIL import Image

from android_synthesize_room import element, synthesize, wall_frames, write_json
from bundle_to_room import col, mat
from prepare_photos import prepare
from reconstruct_bundle import sample_step

SCRIPTS = Path(__file__).resolve().parent
YAW, OFFSET = math.radians(17), np.array([0.7, -1.2, -0.4])  # room → world; floor at y = -1.2
HX, HZ, CEIL = 2.0, 1.5, 2.5  # room-local half extents and height (4 × 3 × 2.5 m)
DOOR = (0.15, 1.05, 2.05)  # on wall A (z = -HZ): x range, head height
WINDOW = (-0.6, 0.6, 0.9, 1.9)  # on wall B (x = +HX): z range, sill, head
BOXES = {'sofa': ((-1.6, 0.0, -1.25), (0.0, 0.45, -0.45)), 'table': ((0.3, 0.0, 0.4), (1.5, 0.75, 1.0))}
DEPTH_W, DEPTH_H, DEPTH_F = 160, 120, 130.0
R_WORLD = np.array([[math.cos(YAW), 0, math.sin(YAW)], [0, 1, 0], [-math.sin(YAW), 0, math.cos(YAW)]])


def to_world(p):
    return R_WORLD @ np.asarray(p, float) + OFFSET


def flat(m):
    return [float(v) for v in np.asarray(m).T.ravel()]  # → column-major


def camera(position, yaw, pitch):
    """Room-local camera-to-room pose, ARKit convention, phone upright (image up = sensor -x)."""
    f = np.array([math.cos(pitch) * math.cos(yaw), math.sin(pitch), math.cos(pitch) * math.sin(yaw)])
    up = np.array([0.0, 1, 0]) - math.sin(pitch) * f
    up /= np.linalg.norm(up)
    T = np.eye(4)
    T[:3, 0], T[:3, 2] = -up, -f
    T[:3, 1] = np.cross(T[:3, 2], T[:3, 0])
    T[:3, 3] = position
    return T


def raycast(c, D):
    """Distance t along rays c + t·D to the first surface; whether the ray went through the window glass."""
    t = np.full(len(D), np.inf)
    with np.errstate(divide='ignore', invalid='ignore'):
        def plane(axis, value, keep=lambda p: True):
            s = (value - c[axis]) / D[:, axis]
            p = c + s[:, None] * D
            ok = (s > 1e-6) & keep(p)
            np.minimum(t, np.where(ok, s, np.inf), out=t)
            return s, p
        plane(1, 0.0)
        plane(1, CEIL)
        plane(2, -HZ, lambda p: (np.abs(p[:, 0]) <= HX) & ~((p[:, 0] > DOOR[0]) & (p[:, 0] < DOOR[1]) & (p[:, 1] < DOOR[2])))
        plane(2, HZ, lambda p: np.abs(p[:, 0]) <= HX)
        plane(0, -HX, lambda p: np.abs(p[:, 2]) <= HZ)
        s_win, p_win = plane(0, HX, lambda p: (np.abs(p[:, 2]) <= HZ) & ~(
            (p[:, 2] > WINDOW[0]) & (p[:, 2] < WINDOW[1]) & (p[:, 1] > WINDOW[2]) & (p[:, 1] < WINDOW[3])))
        plane(2, -HZ - 1.5)  # the next room, seen through the door
        plane(0, HX + 2.5)  # outside, seen through the window
        for lo, hi in BOXES.values():
            a, b = (np.array(lo) - c) / D, (np.array(hi) - c) / D
            near, far = np.minimum(a, b).max(1), np.maximum(a, b).min(1)
            np.minimum(t, np.where((near <= far) & (near > 1e-6), near, np.inf), out=t)
    glass = (s_win > 0) & (s_win < t) & (p_win[:, 2] > WINDOW[0]) & (p_win[:, 2] < WINDOW[1]) & \
        (p_win[:, 1] > WINDOW[2]) & (p_win[:, 1] < WINDOW[3])
    return t, glass


def jpeg_exif6(path, size, color):
    exif = Image.Exif()
    exif[0x0112] = 6
    Image.new('RGB', size, color).save(path, quality=85, exif=exif)


def build_bundle(root):
    """A house-capture/5 bundle shaped like the Android app's export (before synthesis)."""
    for sub in ('rooms', 'photos', 'depth'):
        (root / sub).mkdir(parents=True)
    rng = np.random.default_rng(7)
    k = np.array([[DEPTH_F, 0, (DEPTH_W - 1) / 2], [0, DEPTH_F, (DEPTH_H - 1) / 2], [0, 0, 1]])
    kp = [1450.0, 0, 0, 0, 1450.0, 0, 960.0, 540.0, 1]
    v, u = np.mgrid[0:DEPTH_H, 0:DEPTH_W]
    rays = np.c_[(u.ravel() - k[0, 2]) / k[0, 0], (v.ravel() - k[1, 2]) / k[1, 1], np.ones(u.size)]
    frames, photos, cams = [], [], []
    M = np.eye(4)
    M[:3, :3], M[:3, 3] = R_WORLD, OFFSET
    for i in range(36):
        phi = 2 * math.pi * i / 36
        pitch = math.radians((-35, 0, 30)[i % 3])
        yaw = phi + (math.pi if i % 3 == 0 else 0) + rng.uniform(-0.12, 0.12)  # tilted down = looking across the room
        local = camera([0.9 * math.cos(phi), 1.5, 0.9 * math.sin(phi)], yaw, pitch)
        world = M @ local
        cams.append(world[:3, 3])
        D = rays @ (local[:3, :3] @ np.diag([1.0, -1, -1])).T  # OpenCV pixel rays in room coordinates
        t, glass = raycast(local[:3, 3], D)
        depth = np.where(np.isfinite(t), t, 0).astype('<f2').reshape(DEPTH_H, DEPTH_W)
        conf = np.where(glass, 1, 2).astype(np.uint8)
        conf[(rng.random(conf.size) < 0.1) | ~np.isfinite(t)] = 0
        name = f'depth/{i:05d}'
        (root / f'{name}.f16z').write_bytes(zlib.compress(depth.tobytes(), 1)[2:-4])  # raw DEFLATE
        (root / f'{name}.conf').write_bytes(conf.tobytes())
        Image.new('RGB', (640, 480), (128, 128, 128)).save(root / f'{name}.jpg', quality=80)
        intrinsics = [DEPTH_F, 0, 0, 0, DEPTH_F, 0, k[0, 2], k[1, 2], 1]
        frames.append({'file': f'{name}.f16z', 'confidence': f'{name}.conf', 'rgb': f'{name}.jpg',
                       'rgbIntrinsics': [DEPTH_F * 4, 0, 0, 0, DEPTH_F * 4, 0, k[0, 2] * 4, k[1, 2] * 4, 1], 'camera': {},
                       'room': 0, 'timestamp': i * 0.5, 'width': DEPTH_W, 'height': DEPTH_H,
                       'transform': flat(world), 'intrinsics': intrinsics,
                       'arcore': {'textureWidth': 1920, 'textureHeight': 1080, 'textureIntrinsics': kp, 'depthTimestamp': i * 0.5}})
        if i % 3 == 1:
            n = len(photos)
            jpeg_exif6(root / f'photos/{n:04d}.jpg', (1920, 1080), (40 + 15 * n, 120, 200 - 10 * n))
            photos.append({'file': f'photos/{n:04d}.jpg', 'room': 0, 'timestamp': i * 0.5, 'width': 1920, 'height': 1080,
                           'transform': flat(world), 'intrinsics': kp, 'tracking': 'normal', 'manual': False,
                           'exposure': 1 / 60, 'blurPixels': 0.5, 'pass': 'scan', 'highRes': False})
    (root / 'depth/frames.json').write_text(json.dumps(frames))
    (root / 'photos/photos.json').write_text(json.dumps(photos))

    # the app's fallback layout (PlaneLayout with < 2 vertical planes): camera-path box + 0.8 m
    cams = np.array(cams)
    floor = cams[:, 1].min() - 1.3
    (x0, z0), (x1, z1) = cams[:, [0, 2]].min(0) - 0.8, cams[:, [0, 2]].max(0) + 0.8
    corners = [(x0, z1), (x1, z1), (x1, z0), (x0, z0)]  # counter-clockwise seen from above
    walls = []
    for a, b in zip(corners, corners[1:] + corners[:1]):
        u = np.array([b[0] - a[0], 0, b[1] - a[1]])
        length = np.linalg.norm(u)
        u /= length
        n = np.array([-u[2], 0, u[0]])
        center = [(a[0] + b[0]) / 2, floor + 1.2, (a[1] + b[1]) / 2]
        if n @ (np.array([(x0 + x1) / 2, 0, (z0 + z1) / 2]) - center) < 0:
            u, n = -u, -n
        walls.append(element({'wall': {}}, 'low', [length, 2.4, 0], center, u, n))
    floor_el = element({'floor': {}}, 'low', [0, 0, 0], [0, floor, 0], [1, 0, 0], [0, 0, 1])
    floor_el['polygonCorners'] = [[x, 0, z] for x, z in corners]
    room = {'version': 2, 'story': 0, 'walls': walls, 'doors': [], 'windows': [], 'openings': [], 'objects': [],
            'floors': [floor_el], 'sections': []}
    (root / 'rooms/room-0.json').write_text(json.dumps(room))
    (root / 'rooms/room-0.arcore.json').write_text(json.dumps(room))
    when = '2026-10-22T12:00:00Z'
    manifest = {
        'format': 'house-capture/5', 'createdAt': when, 'device': 'Pixel 10 Pro', 'systemVersion': 'Android 16 (API 36)',
        'coordinateSystem': 'ARCore world space: meters, +Y up (gravity), right-handed', 'house': 'test', 'houseName': 'Android',
        'session': '2026-10-22 12.00.00', 'zone': 'android', 'alignment': {'method': 'first', 'toZone': flat(np.eye(4))},
        'endedAt': when, 'rooms': [{'index': 0, 'name': 'Test room', 'file': 'rooms/room-0.json', 'usdz': '', 'capturedAt': when,
                                     'walls': 4, 'doors': 0, 'windows': 0, 'openings': 0, 'objects': 0, 'mesh': None, 'coverage': 0.5}],
        'structure': None, 'mesh': None, 'sceneReconstruction': 'none (ARCore)', 'photos': 'photos/photos.json',
        'photoCount': len(photos), 'depthFrames': 'depth/frames.json', 'depthFrameCount': len(frames), 'platform': 'android',
        'capture': {'engine': 'ARCore', 'arcoreSdk': '1.57.0', 'depthMode': 'RAW_DEPTH_ONLY', 'depthWidth': DEPTH_W,
                    'depthHeight': DEPTH_H, 'layoutSource': 'arcore-planes', 'synthesized': False}}
    (root / 'manifest.json').write_text(json.dumps(manifest))


def wall_truth():
    """Room-local wall centers and lengths → world centers."""
    return {'A': (to_world([0, CEIL / 2, -HZ]), 2 * HX), 'B': (to_world([HX, CEIL / 2, 0]), 2 * HZ),
            'C': (to_world([0, CEIL / 2, HZ]), 2 * HX), 'D': (to_world([-HX, CEIL / 2, 0]), 2 * HZ)}


def center(el):
    return np.array(col(mat(el['transform']), 3))


def run(*args):
    return subprocess.run([sys.executable, *map(str, args)], capture_output=True, text=True)


class AndroidBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.temp.name)
        cls.bundle = cls.base / 'bundle'
        build_bundle(cls.bundle)
        cls.raw = cls.base / 'raw'
        shutil.copytree(cls.bundle, cls.raw)
        with contextlib.redirect_stdout(io.StringIO()):
            cls.room = synthesize(str(cls.bundle), 0, from_depth=True, write_bundle=True)
        cls.floor_y = mat(cls.room['floors'][0]['transform'])[1][3]
        truth = wall_truth()
        cls.match = {}  # truth name → synthesized wall
        for name, (ctr, _) in truth.items():
            cls.match[name] = min(cls.room['walls'], key=lambda w: np.linalg.norm((center(w) - ctr)[[0, 2]]))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_app_bundle_converts_unchanged(self):
        result = run(SCRIPTS / 'bundle_to_room.py', self.raw, '--room', 0, '-o', self.base / 'raw-room.json')
        self.assertEqual(result.returncode, 0, result.stderr)
        result = run(SCRIPTS / 'bundle_plan.py', self.raw, '--room', 0, '-o', self.base / 'raw-plan.png')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.base / 'raw-plan.png').exists())

    def test_synthesized_layout(self):
        walls = self.room['walls']
        self.assertEqual(len(walls), 4)
        self.assertEqual(len({w['identifier'] for w in self.match.values()}), 4)
        for name, (ctr, length) in wall_truth().items():
            w = self.match[name]
            self.assertAlmostEqual(w['dimensions'][0], length, delta=0.15, msg=name)
            self.assertAlmostEqual(w['dimensions'][1], CEIL, delta=0.1, msg=name)
            self.assertLess(np.linalg.norm((center(w) - ctr)[[0, 2]]), 0.15, name)
        self.assertAlmostEqual(self.floor_y, OFFSET[1], delta=0.05)
        poly = [(p[0], p[2]) for p in self.room['floors'][0]['polygonCorners']]
        area = abs(sum(poly[i - 1][0] * poly[i][1] - poly[i][0] * poly[i - 1][1] for i in range(len(poly)))) / 2
        self.assertAlmostEqual(area, 4 * HX * HZ, delta=0.1 * 4 * HX * HZ)
        self.assertTrue((self.bundle / 'rooms/room-0.arcore.json').exists())
        self.assertEqual(json.loads((self.bundle / 'rooms/room-0.arcore.json').read_text()),
                         json.loads((self.raw / 'rooms/room-0.json').read_text()))
        manifest = json.loads((self.bundle / 'manifest.json').read_text())
        rec = manifest['rooms'][0]
        self.assertEqual([rec[k] for k in ('walls', 'doors', 'windows', 'openings', 'objects')], [4, 1, 1, 0, 2])
        self.assertTrue(manifest['capture']['synthesized'])
        self.assertEqual(manifest['capture']['layoutSource'], 'android_synthesize_room.py')
        self.assertEqual(manifest['mesh']['file'], 'mesh/room-0.ply')
        with self.assertRaises(ValueError), contextlib.redirect_stdout(io.StringIO()):
            synthesize(str(self.bundle), 0, from_depth=True, write_bundle=True)

    def test_openings(self):
        self.assertEqual(len(self.room['doors']), 1)
        self.assertEqual(len(self.room['windows']), 1)
        self.assertEqual(self.room['openings'], [])
        door, window = self.room['doors'][0], self.room['windows'][0]
        self.assertEqual(door['parentIdentifier'], self.match['A']['identifier'])
        self.assertEqual(window['parentIdentifier'], self.match['B']['identifier'])
        self.assertTrue(door['category']['door']['isOpen'])
        self.assertAlmostEqual(center(door)[1] - door['dimensions'][1] / 2, self.floor_y, places=3)
        self.assertTrue(0.8 <= door['dimensions'][0] <= 1.0, door['dimensions'])
        self.assertAlmostEqual(center(door)[1] + door['dimensions'][1] / 2 - self.floor_y, DOOR[2], delta=0.1)
        sill = center(window)[1] - window['dimensions'][1] / 2 - self.floor_y
        self.assertTrue(0.8 <= sill <= 1.0, sill)
        self.assertAlmostEqual(window['dimensions'][0], WINDOW[1] - WINDOW[0], delta=0.1)

    def test_objects(self):
        objects = self.room['objects']
        self.assertEqual(len(objects), 2)
        for name, (lo, hi) in BOXES.items():
            ctr = to_world((np.array(lo) + np.array(hi)) / 2)
            o = min(objects, key=lambda o: np.linalg.norm(center(o) - ctr))
            self.assertIn(next(iter(o['category'])), {'sofa', 'table', 'storage'})
            self.assertLess(np.linalg.norm(center(o) - ctr), 0.2, name)
            size = np.array(hi) - np.array(lo)
            w, h, d = o['dimensions']
            np.testing.assert_allclose(sorted([w, d]), sorted([size[0], size[2]]), atol=0.2, err_msg=name)
            self.assertAlmostEqual(h, size[1], delta=0.2, msg=name)

    def test_ply_schema(self):
        data = (self.bundle / 'mesh/room-0.ply').read_bytes()
        end = data.index(b'end_header\n') + len(b'end_header\n')
        header = [line for line in data[:end].decode().splitlines() if not line.startswith('comment')]
        self.assertEqual(header[:2], ['ply', 'format binary_little_endian 1.0'])
        vertices, faces = int(header[2].split()[2]), int(header[14].split()[2])
        self.assertEqual(header[2:], [
            f'element vertex {vertices}', 'property float x', 'property float y', 'property float z',
            'property float nx', 'property float ny', 'property float nz', 'property float coverage',
            'property uchar red', 'property uchar green', 'property uchar blue', 'property uchar inroom',
            f'element face {faces}', 'property list uchar uint vertex_indices', 'property uchar class', 'end_header'])
        self.assertGreater(faces, 0)
        self.assertEqual(len(data) - end, vertices * 32 + faces * 14)
        manifest = json.loads((self.bundle / 'manifest.json').read_text())
        self.assertEqual((manifest['mesh']['vertices'], manifest['mesh']['faces']), (vertices, faces))
        verts = np.frombuffer(data, np.dtype([('p', '<f4', 7), ('rgb', 'u1', 3), ('inroom', 'u1')]), vertices, end)
        self.assertTrue((verts['inroom'] == 1).all())
        face = np.frombuffer(data, np.dtype([('n', 'u1'), ('i', '<u4', 3), ('class', 'u1')]), faces, end + vertices * 32)
        self.assertTrue((face['n'] == 3).all() and face['i'].max() < vertices)
        self.assertTrue({1, 2, 3} <= set(np.unique(face['class']).tolist()))

    def test_pipeline_end_to_end(self):
        out = self.base / 'room.json'
        result = run(SCRIPTS / 'bundle_to_room.py', self.bundle, '--room', 0, '-o', out)
        self.assertEqual(result.returncode, 0, result.stderr)
        r = json.loads(out.read_text())
        self.assertEqual(len(r['walls']), 4)
        for w in r['walls']:
            self.assertGreater(max(abs(w['u'][0]), abs(w['u'][2])), 0.99)
        self.assertEqual(sum(len(w['openings']) for w in r['walls']), 2)
        self.assertEqual(sorted(o['kind'] for w in r['walls'] for o in w['openings']), ['door', 'window'])
        self.assertEqual(len(r['objects']), 2)
        self.assertEqual(len(r['photos']), 12)
        photos = self.base / 'upright'
        self.assertEqual(prepare(self.bundle, out, photos, max_edge=1920), 12)
        with Image.open(photos / '0000.jpg') as first:
            self.assertEqual(first.size, (1080, 1920))

    def test_reconstruct_bounds_sampling_step(self):
        self.assertLessEqual(sample_step(90, 160), 4)
        self.assertLessEqual(sample_step(120, 160), 4)
        self.assertEqual(sample_step(10, 10), 1)
        self.assertEqual(sample_step(192, 256), 16)  # iPhone LiDAR depth: unchanged

    def test_default_room_and_degenerate_geometry(self):
        out = self.base / 'cli'
        result = run(SCRIPTS / 'android_synthesize_room.py', self.raw, '-o', out, '--no-objects')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads((out / 'room-0.json').read_text())['walls']), 4)
        walls = wall_frames([(0, 0), (2, 0), (2, 0), (2, 1), (0, 1)], 0.0, 2.5)  # repeated corner
        self.assertEqual(len(walls), 4)
        self.assertTrue(all(np.isfinite(w['u']).all() for w in walls))
        with self.assertRaises(ValueError):
            write_json(str(self.base / 'nan.json'), {'x': float('nan')})


if __name__ == '__main__':
    unittest.main()
