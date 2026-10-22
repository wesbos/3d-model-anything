#!/usr/bin/env python3
"""Rebuild a colored, Polycam-style mesh from a House Capture bundle's LiDAR depth
frames + posed photos (works even when the bundle's own mesh is missing).

  1. TSDF-fuse every depth frame (pose + intrinsics from depth/frames.json)
  2. extract a triangle mesh, drop small floating bits, simplify
  3. color each vertex from the best photo that actually sees it: visibility by
     ray casting against the mesh itself, preference for close, head-on, sharp views

usage: reconstruct_bundle.py <bundle> [--room room.json] [--voxel 0.015] [--faces 400000] [--despeckle] [-o outdir]

Android (ARCore) bundles: raw depth is noisier and sparser than LiDAR; use
--voxel 0.03 --trunc 5 --despeckle.
Writes <outdir>/scan_world.ply (ARKit world coords) and, with --room (from
bundle_to_room.py), scan_room.ply + scan_room.glb in room coordinates for the viewer.
Needs: pip install open3d pillow numpy
"""
import argparse
import json
import os
import time
import zlib

import numpy as np
from PIL import Image

ARKIT_TO_CV = np.diag([1.0, -1.0, -1.0, 1.0])  # camera: +y up/-z forward → +y down/+z forward


def mat(cm):
    return np.array(cm, dtype=np.float64).reshape(4, 4).T  # column-major → row-major


LIDAR_MIN_SIDE = 192  # iPhone LiDAR depth is 256×192; ARCore raw depth is smaller (e.g. 160×120)


def sample_step(h, w):
    """Pixel stride for the bounds sample: every 16th pixel for LiDAR-sized depth (unchanged), ~40 samples
    across the short side for smaller (ARCore) depth images."""
    return 16 if min(h, w) >= LIDAR_MIN_SIDE else max(1, min(h, w) // 40)


def despeckle(depth, jump=0.1):
    """3×3 median of the valid neighbors; drops pixels next to a >10 % depth jump (flying pixels). 0 = invalid."""
    h, w = depth.shape
    p = np.pad(depth, 1, mode='edge')
    stack = np.stack([p[y:y + h, x:x + w] for y in range(3) for x in range(3)])
    jumpy = ((np.abs(stack - depth) > jump * depth) & (stack > 0)).any(0)
    stack = np.where(stack > 0, stack, np.nan)
    stack[4] = depth  # the center is never NaN, so the median below always has a value
    out = np.nanmedian(stack, axis=0).astype(depth.dtype)
    out[(depth <= 0) | jumpy] = 0
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('bundle')
    ap.add_argument('--mesh', help='existing session-world triangle mesh; skip depth fusion')
    ap.add_argument('--room', help='room.json from bundle_to_room.py (adds room-coordinate outputs)')
    ap.add_argument('--voxel', type=float, default=0.02)
    ap.add_argument('--trunc', type=float, default=8, help='TSDF truncation in voxels (wider = fewer holes on noisy LiDAR)')
    ap.add_argument('--faces', type=int, default=0, help='Open3D quadric simplification target (0 = off: it tears holes in fused meshes; simplify the GLB with gltf-transform instead)')
    ap.add_argument('--max-depth', type=float, default=3.5)
    ap.add_argument('--min-confidence', type=int, default=1)
    ap.add_argument('--despeckle', action='store_true', help='median-filter depth and drop flying pixels (ARCore raw depth)')
    ap.add_argument('-o', default=None)
    a = ap.parse_args()
    import open3d as o3d  # imported here so the helpers above work without it (test_android_bundle.py)

    out = a.o or os.path.join(a.bundle, 'recon')
    os.makedirs(out, exist_ok=True)
    t0 = time.time()

    # --- 1. TSDF fusion -------------------------------------------------------------
    # (ScalableTSDFVolume returns nothing in the Open3D 0.20 macOS wheels, so fuse into
    # a grid of overlapping UniformTSDFVolume cubes covering the scanned area)
    frames_path = os.path.join(a.bundle, 'depth/frames.json')
    frames = json.load(open(frames_path)) if os.path.exists(frames_path) else []
    if not a.mesh and not frames:
        ap.error('depth frames missing; provide --mesh for a saved LiDAR mesh')
    if a.mesh:
        mesh = o3d.io.read_triangle_mesh(a.mesh)
        if not mesh.has_triangles():
            ap.error('--mesh must contain triangles')
        print(f'loaded existing mesh: {len(mesh.triangles):,} triangles')
    else:
        loaded = []
        low_res = False
        lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
        for f in frames:
            w, h = f['width'], f['height']
            raw = open(os.path.join(a.bundle, f['file']), 'rb').read()
            if f['file'].endswith('.f16z'):
                raw = zlib.decompress(raw, -15)  # v4 bundles: raw DEFLATE
            depth = np.frombuffer(raw, dtype='<f2').astype(np.float32).reshape(h, w).copy()
            conf_path = os.path.join(a.bundle, f['confidence'])
            if os.path.exists(conf_path):
                conf = np.fromfile(conf_path, dtype=np.uint8).reshape(h, w)
                depth[conf < a.min_confidence] = 0
            depth[(depth > a.max_depth) | ~np.isfinite(depth)] = 0
            if a.despeckle:
                depth = despeckle(depth)
            k = np.array(f['intrinsics']).reshape(3, 3).T
            cam_to_world = mat(f['transform']) @ ARKIT_TO_CV
            # bounds from a sparse sample of back-projected points
            low_res |= min(h, w) < LIDAR_MIN_SIDE
            step = sample_step(h, w)
            ys, xs = np.mgrid[0:h:step, 0:w:step]
            z = depth[ys, xs].ravel()
            ok = z > 0
            pts = np.c_[(xs.ravel()[ok] - k[0, 2]) * z[ok] / k[0, 0], (ys.ravel()[ok] - k[1, 2]) * z[ok] / k[1, 1], z[ok], np.ones(ok.sum())]
            if len(pts):
                wp = (cam_to_world @ pts.T).T[:, :3]
                lo, hi = np.minimum(lo, wp.min(0)), np.maximum(hi, wp.max(0))
            loaded.append((depth, k, np.linalg.inv(cam_to_world)))
        if low_res or a.despeckle:  # sparse ARCore samples can miss the outermost surfaces; LiDAR runs are unchanged
            lo, hi = lo - 0.5, hi + 0.5
        tile = 3.5
        res = int(round(tile / a.voxel))
        pad = a.voxel * 3
        nx, nz = int(np.ceil((hi[0] - lo[0]) / (tile - pad))), int(np.ceil((hi[2] - lo[2]) / (tile - pad)))
        ny = int(np.ceil((hi[1] - lo[1]) / (tile - pad)))
        print(f'scan bounds {np.round(lo, 2)} … {np.round(hi, 2)} → {nx}×{ny}×{nz} tiles of {tile} m at {a.voxel * 100:.1f} cm')
        mesh = o3d.geometry.TriangleMesh()
        for ix in range(nx):
            for iy in range(ny):
                for iz in range(nz):
                    origin = lo + np.array([ix, iy, iz]) * (tile - pad)
                    vol = o3d.pipelines.integration.UniformTSDFVolume(
                        length=tile, resolution=res, sdf_trunc=a.voxel * a.trunc,
                        color_type=o3d.pipelines.integration.TSDFVolumeColorType.NoColor, origin=origin)
                    for depth, k, extrinsic in loaded:
                        h, w = depth.shape
                        intr = o3d.camera.PinholeCameraIntrinsic(w, h, k[0, 0], k[1, 1], k[0, 2], k[1, 2])
                        rgbd = o3d.geometry.RGBDImage.create_from_color_and_depth(
                            o3d.geometry.Image(np.zeros((h, w, 3), np.uint8)), o3d.geometry.Image(depth),
                            depth_scale=1.0, depth_trunc=a.max_depth, convert_rgb_to_intensity=False)
                        vol.integrate(rgbd, intr, extrinsic)
                    part = vol.extract_triangle_mesh()
                    print(f'  tile {ix},{iy},{iz}: {len(part.triangles):,} triangles')
                    mesh += part
        mesh.merge_close_vertices(a.voxel * 0.05)
        print(f'fused {len(frames)} depth frames → {len(mesh.triangles):,} triangles ({time.time() - t0:.0f}s)')

    # --- 2. clean + simplify ----------------------------------------------------------
    clusters, counts, _ = mesh.cluster_connected_triangles()
    clusters, counts = np.asarray(clusters), np.asarray(counts)
    mesh.remove_triangles_by_mask(counts[clusters] < 40)  # floating specks
    mesh.remove_unreferenced_vertices()
    if a.faces and len(mesh.triangles) > a.faces:
        mesh = mesh.simplify_quadric_decimation(a.faces)
    mesh.remove_degenerate_triangles()
    mesh.remove_unreferenced_vertices()
    mesh.compute_vertex_normals()
    V = np.asarray(mesh.vertices)
    N = np.asarray(mesh.vertex_normals)
    print(f'cleaned → {len(mesh.triangles):,} triangles, {len(V):,} vertices ({time.time() - t0:.0f}s)')

    # --- 3. color from photos -----------------------------------------------------------
    photos = json.load(open(os.path.join(a.bundle, 'photos/photos.json')))
    # v4 bundles also carry a 640×480 color image with every depth frame: use them as extra,
    # lower-weight views so surfaces no photo covered still get color
    for f in frames:
        if f.get('rgb'):
            with Image.open(os.path.join(a.bundle, f['rgb'])) as rgb:
                rgb_width, rgb_height = rgb.size
            photos.append({'file': f['rgb'], 'transform': f['transform'], 'intrinsics': f['rgbIntrinsics'],
                           'width': rgb_width, 'height': rgb_height, 'blurPixels': 3.0, 'lowres': True})
    scene = o3d.t.geometry.RaycastingScene()
    scene.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(mesh))
    best = np.zeros(len(V), np.float32)
    colors = np.full((len(V), 3), 0.5, np.float32)
    source = np.full(len(V), -1, np.int32)
    for pi, ph in enumerate(photos):
        T = mat(ph['transform'])
        cam = T[:3, 3]
        k = np.array(ph['intrinsics']).reshape(3, 3).T
        W, H = ph['width'], ph['height']
        c = (np.linalg.inv(T) @ np.c_[V, np.ones(len(V))].T).T
        d = -c[:, 2]
        with np.errstate(divide='ignore', invalid='ignore'):
            u = k[0, 0] * c[:, 0] / d + k[0, 2]
            v = k[1, 1] * -c[:, 1] / d + k[1, 2]
        to_cam = cam - V
        dist = np.linalg.norm(to_cam, axis=1)
        cos = np.einsum('ij,ij->i', N, to_cam) / np.maximum(dist, 1e-6)
        cand = (d > 0.2) & (d < 4.5) & (u >= 1) & (u < W - 2) & (v >= 1) & (v < H - 2) & (cos > 0.15)
        blur = ph.get('blurPixels') or 0
        sharp = 1.0 if blur <= 1.5 else max(0.3, 1 - (blur - 1.5) / 6)
        score = np.where(cand, cos * (k[0, 0] / np.maximum(d, 0.1)) * sharp, 0).astype(np.float32)
        if ph.get('lowres'):
            score *= 0.9  # prefer a real photo when one sees the point about as well
        cand &= score > best
        idx = np.nonzero(cand)[0]
        if len(idx) == 0:
            continue
        # visible = the first hit along the ray from the camera is (about) this vertex
        dirs = (V[idx] - cam) / dist[idx, None]
        rays = np.c_[np.repeat(cam[None], len(idx), 0), dirs].astype(np.float32)
        hit = scene.cast_rays(o3d.core.Tensor(rays))['t_hit'].numpy()
        vis = np.abs(hit - dist[idx]) < 0.02 + 0.01 * dist[idx]
        idx = idx[vis]
        if len(idx) == 0:
            continue
        img = np.asarray(Image.open(os.path.join(a.bundle, ph['file'])).convert('RGB'), dtype=np.float32) / 255
        # bilinear sample
        x, y = u[idx], v[idx]
        x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
        fx, fy = (x - x0)[:, None], (y - y0)[:, None]
        px = (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x0 + 1] * fx * (1 - fy)
              + img[y0 + 1, x0] * (1 - fx) * fy + img[y0 + 1, x0 + 1] * fx * fy)
        colors[idx] = px
        best[idx] = score[idx]
        source[idx] = pi
    covered = (source >= 0).mean()
    mesh.vertex_colors = o3d.utility.Vector3dVector(colors.astype(np.float64))
    print(f'colored from {len(photos)} photos: {covered:.0%} of vertices seen ({time.time() - t0:.0f}s)')
    o3d.io.write_triangle_mesh(os.path.join(out, 'scan_world.ply'), mesh)
    np.save(os.path.join(out, 'vertex_photo.npy'), source)
    with open(os.path.join(out, 'reconstruction.json'), 'w') as report:
        json.dump({'sourceMesh': a.mesh, 'depthFrames': len(frames), 'photoSources': len(photos),
                   'vertices': len(V), 'triangles': len(mesh.triangles),
                   'coloredVertexFraction': float(covered)}, report, indent=2)

    # --- 4. room coordinates -------------------------------------------------------------
    if a.room:
        r = json.load(open(a.room))
        W2R = mat(r['transform']['worldToRoom'])
        m2 = o3d.geometry.TriangleMesh(mesh)
        m2.transform(W2R)
        m2.compute_vertex_normals()
        o3d.io.write_triangle_mesh(os.path.join(out, 'scan_room.ply'), m2)
        # glTF vertex colors are linear; the photos are sRGB
        c = np.asarray(m2.vertex_colors)
        m2.vertex_colors = o3d.utility.Vector3dVector(np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4))
        o3d.io.write_triangle_mesh(os.path.join(out, 'scan_room.glb'), m2)
        print('wrote scan_room.ply / scan_room.glb (room coordinates)')
    print(f'done in {time.time() - t0:.0f}s → {out}')


if __name__ == '__main__':
    main()
