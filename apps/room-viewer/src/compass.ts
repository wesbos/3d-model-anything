import * as THREE from 'three';
import type { CompassBearing, RoomCompass, RoomLayout } from '../../../packages/room-runtime/types';
import './compass.css';

export function hasNorth(compass?: RoomCompass): compass is RoomCompass & {
  north: number[]; reference: 'true' | 'magnetic'; accuracyDegrees: number;
} {
  return compass?.status === 'aligned' && compass.north?.length === 3
    && compass.north.every(Number.isFinite) && Math.abs(compass.north[1]) < .05
    && Math.abs(Math.hypot(compass.north[0], compass.north[2]) - 1) < .1
    && (compass.reference === 'true' || compass.reference === 'magnetic')
    && typeof compass.accuracyDegrees === 'number' && Number.isFinite(compass.accuracyDegrees)
    && compass.accuracyDegrees >= 0 && compass.accuracyDegrees <= 25;
}

export function compassDescription(compass?: RoomCompass) {
  if (!compass) return 'Compass directions were not recorded.';
  if (!hasNorth(compass)) return `Directions uncertain. ${compass.reason ?? 'No reliable north alignment is available.'}`;
  return `Recorded ${compass.reference} north · ±${Math.ceil(compass.accuracyDegrees)}° estimated uncertainty · ${compass.sampleCount} readings`;
}

export function facingBearing(u: number[], compass?: RoomCompass): CompassBearing | undefined {
  if (!hasNorth(compass)) return;
  // u × up points inward; labels describe the opposite, outward direction.
  const outward = new THREE.Vector3(u[2], 0, -u[0]);
  const north = new THREE.Vector3(...compass.north);
  const east = new THREE.Vector3(-north.z, 0, north.x);
  const degrees = ((Math.atan2(outward.dot(east), outward.dot(north)) * 180 / Math.PI) + 360) % 360;
  return { degrees, cardinal: ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][Math.floor((degrees + 22.5) / 45) % 8],
    reference: compass.reference, accuracyDegrees: compass.accuracyDegrees };
}

export const formatBearing = (b: CompassBearing) => `${b.cardinal} · ${Math.round(b.degrees) % 360}°`;

/** DOM annotations stay legible without changing model materials or lighting. */
export class CompassOverlay {
  private root = document.createElement('div');
  private arrow = document.createElement('span');
  private labels: { node: HTMLElement; position: THREE.Vector3 }[] = [];
  private enabled = true;
  private north?: THREE.Vector3;
  private projected = new THREE.Vector3();
  private northInCamera = new THREE.Vector3();

  constructor(private host: HTMLElement, layout: RoomLayout, wallTop: number, invalidate: () => void) {
    this.root.className = 'compass-overlay';
    const card = document.createElement('div'); card.className = 'compass-card';
    const button = document.createElement('button'); button.type = 'button';
    button.textContent = 'Directions'; button.setAttribute('aria-pressed', 'true');
    const description = document.createElement('span'); description.textContent = compassDescription(layout.compass);
    this.arrow.className = 'compass-north'; this.arrow.textContent = '↑';
    this.arrow.setAttribute('aria-hidden', 'true');
    card.append(button, this.arrow, description); this.root.append(card); this.host.append(this.root);
    button.onclick = () => {
      this.enabled = !this.enabled;
      button.setAttribute('aria-pressed', String(this.enabled));
      this.root.classList.toggle('directions-off', !this.enabled);
      invalidate();
    };
    if (!hasNorth(layout.compass)) {
      this.root.classList.add('compass-uncertain'); button.disabled = true; this.arrow.hidden = true;
      return;
    }
    this.north = new THREE.Vector3(...layout.compass.north).normalize();
    for (const wall of layout.walls) {
      const bearing = facingBearing(wall.u, layout.compass);
      if (!bearing) continue;
      const windows = wall.openings.filter(o => o.kind === 'window');
      const inward = new THREE.Vector3(-wall.u[2], 0, wall.u[0]);
      for (const opening of windows.length ? windows : [undefined]) {
        const along = opening ? (opening.u0 + opening.u1) / 2 : wall.length / 2;
        const height = opening ? ((opening.v0 ?? .8) + (opening.v1 ?? 2)) / 2 : wallTop + .12;
        const position = new THREE.Vector3(wall.a[0] + wall.u[0] * along, height,
          wall.a[1] + wall.u[2] * along).addScaledVector(inward, .12);
        const node = document.createElement('span'); node.className = 'compass-label';
        node.textContent = `${opening ? 'Window' : 'Wall'} ${formatBearing(bearing)}`;
        node.title = `Faces outward from the room; ${bearing.reference} north, ±${Math.ceil(bearing.accuracyDegrees)}° estimated uncertainty`;
        this.root.append(node); this.labels.push({ node, position });
      }
    }
  }

  setVisible(visible: boolean) { this.root.hidden = !visible; }

  update(camera: THREE.Camera) {
    if (this.root.hidden || !this.enabled || !this.north) return;
    camera.updateMatrixWorld();
    const width = this.host.clientWidth, height = this.host.clientHeight;
    for (const { node, position } of this.labels) {
      this.projected.copy(position).project(camera);
      const p = this.projected;
      node.hidden = p.z < -1 || p.z > 1 || Math.abs(p.x) > .95 || Math.abs(p.y) > .95;
      if (!node.hidden) node.style.transform = `translate(${(p.x + 1) * width / 2}px, ${(1 - p.y) * height / 2}px) translate(-50%, -50%)`;
    }
    this.northInCamera.copy(this.north).transformDirection(camera.matrixWorldInverse);
    this.arrow.style.transform = `rotate(${Math.atan2(this.northInCamera.x, this.northInCamera.y)}rad)`;
    this.arrow.hidden = Math.hypot(this.northInCamera.x, this.northInCamera.y) < .05;
  }

  dispose() { this.root.remove(); }
}
