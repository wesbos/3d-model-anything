"""Carry measured compass evidence from an AR session into a rotated room.

Bearings run clockwise from recorded north. Surface bearings point out of the
room (through the wall/window), not toward the camera that photographed it.
"""
import json
import math
from pathlib import Path


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def direction(matrix, vector):
    out = [sum(matrix[r][c] * vector[c] for c in range(3)) for r in range(3)]
    length = math.hypot(out[0], out[2])
    if length < 1e-6:
        raise ValueError('compass north has no horizontal component')
    return [out[0] / length, 0, out[2] / length]


def bearing(vector, compass):
    if not compass or compass.get('status') != 'aligned':
        return None
    north = compass['north']
    east = [-north[2], 0, north[0]]
    degrees = math.degrees(math.atan2(sum(a*b for a, b in zip(vector, east)),
                                     sum(a*b for a, b in zip(vector, north)))) % 360
    return {'degrees': round(degrees, 1) % 360,
            'cardinal': ('N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW')[int((degrees + 22.5) / 45) % 8],
            'reference': compass['reference'], 'accuracyDegrees': compass['accuracyDegrees']}


def usable(sample):
    north, accuracy = sample.get('northInSession'), sample.get('headingAccuracy')
    time, frame, offset = sample.get('timestamp'), sample.get('frameTimestamp'), sample.get('poseTimeOffsetSeconds')
    return (not sample.get('rejection') and finite(accuracy) and 0 <= accuracy <= 25
            and finite(time) and finite(frame) and abs(time - frame) <= .15
            and finite(offset) and 0 <= offset <= .15
            and isinstance(north, list) and len(north) == 3 and all(finite(v) for v in north)
            and abs(north[1]) <= .05 and .8 <= math.hypot(north[0], north[2]) <= 1.2
            and sample.get('reference') in ('true', 'magnetic'))


def read_compass(bundle, room, world_to_room):
    root = Path(bundle).resolve()
    manifest_path = root / 'manifest.json'
    if not manifest_path.exists():
        return None
    manifest = json.loads(manifest_path.read_text())
    relative = manifest.get('compass')
    if not relative:
        return None
    if not isinstance(relative, str) or Path(relative).is_absolute():
        raise ValueError('invalid compass file path')
    path = (root / relative).resolve()
    if not path.is_relative_to(root):
        raise ValueError('compass file escapes bundle')
    samples = json.loads(path.read_text())
    if not isinstance(samples, list) or any(not isinstance(s, dict) for s in samples):
        raise ValueError('compass recording must contain an array of observations')
    samples = [s for s in samples if room is None or s.get('room') == room]
    result = {'status': 'unavailable', 'sampleCount': 0, 'totalSamples': len(samples),
              'sourceFile': relative, 'samples': samples,
              'reason': 'No valid synchronized compass readings were recorded.'}
    groups = {'true': [], 'magnetic': []}
    for sample in samples:
        if usable(sample):
            groups[sample['reference']].append(sample)
    # Never average magnetic north with true north. Prefer true north once supported
    # by at least three observations; otherwise retain an explicitly magnetic basis.
    reference = 'true' if len(groups['true']) >= 3 else max(groups, key=lambda key: len(groups[key]))
    selected = groups[reference]
    if not selected:
        if samples:
            result.update(status='uncertain', reason='Compass accuracy or pose synchronization was insufficient.')
        return result
    result.update(status='uncertain', reference=reference, sampleCount=len(selected))
    if len(selected) < 3 or max(s['timestamp'] for s in selected) - min(s['timestamp'] for s in selected) < 1:
        result['reason'] = 'At least three consistent readings spanning one second are required.'
        return result
    angles = [math.atan2(s['northInSession'][0], -s['northInSession'][2]) for s in selected]
    weights = [1 / max(1, s['headingAccuracy'])**2 for s in selected]

    def mean(indices):
        x = sum(math.sin(angles[i]) * weights[i] for i in indices)
        z = sum(math.cos(angles[i]) * weights[i] for i in indices)
        return math.atan2(x, z), math.hypot(x, z) / sum(weights[i] for i in indices)

    def distance(a, b):
        return abs(math.degrees(math.atan2(math.sin(a-b), math.cos(a-b))))

    center, agreement = mean(range(len(selected)))
    inliers = [i for i, angle in enumerate(angles) if distance(angle, center) <= 20]
    if agreement < .9 or len(inliers) < max(3, math.ceil(len(selected) * .7)):
        result['reason'] = 'Compass readings disagree; indoor magnetic interference may be present.'
        return result
    center, _ = mean(inliers)
    spread = max(distance(angles[i], center) for i in inliers)
    # Sensor error can be systematic: do not divide accuracy by sqrt(sample count).
    accuracy = max(selected[i]['headingAccuracy'] for i in inliers) + spread
    result.update(sampleCount=len(inliers), spreadDegrees=round(spread, 1), accuracyDegrees=round(accuracy, 1))
    if spread > 15 or accuracy > 25:
        result['reason'] = 'Measured direction uncertainty exceeds 25 degrees.'
        return result
    north = direction(world_to_room, [math.sin(center), 0, -math.cos(center)])
    result.update(status='aligned', north=[round(v, 7) for v in north])
    result.pop('reason', None)
    return result


def photo_compass(photo, forward, compass, world_to_room):
    """Use the observation linked by the app, rather than inventing a photo heading."""
    if not compass or not finite(photo.get('compassTimestamp')) or math.hypot(forward[0], forward[2]) < .25:
        return None
    sample = next((s for s in compass['samples'] if finite(s.get('timestamp'))
                   and abs(s['timestamp'] - photo['compassTimestamp']) < 1e-6), None)
    if not sample or not usable(sample):
        return None
    observation = {'status': 'aligned', 'north': direction(world_to_room, sample['northInSession']),
                   'reference': sample['reference'], 'accuracyDegrees': sample['headingAccuracy']}
    result = bearing(forward, observation)
    result['timestamp'] = sample['timestamp']
    return result
