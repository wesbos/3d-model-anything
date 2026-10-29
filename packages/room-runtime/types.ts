import * as THREE from 'three';
import type { WallDef } from './walls';

export type V3 = [number, number, number];

/** A rebuilt room, ready to drop into the viewer (or the capture page) */
export interface BuiltRoom {
  layout?: RoomLayout;
  group: THREE.Group;
  lights: THREE.Group;
  /** walls with everything mounted on them, for the dollhouse cutaway */
  walls: { def: WallDef; group: THREE.Object3D }[];
  /** hidden when the camera is above this height */
  ceiling: THREE.Object3D[];
  wallTop: number;
  /** tone-mapping exposure for this room (default 1.1) */
  exposure?: number;
  /** optional glow on emissive surfaces */
  bloom?: { strength: number; radius: number; threshold: number };
  /** renderer settings (defaults: AgX tone mapping, PCF shadows, the pipeline's default AO, 256 px env capture) */
  render?: {
    toneMapping?: THREE.ToneMapping;
    shadowType?: THREE.ShadowMapType;
    ao?: AOSettings;
    /** cube size of the room's own environment capture */
    envSize?: number;
    /** re-capture the environment this many times (each adds a bounce of indirect light) */
    envBounces?: number;
    /** leave saturated (RGB/colored) lights out of the environment capture */
    envNeutral?: boolean;
  };
  /** can a walker stand here? (room-local x/z) */
  walkable(x: number, z: number): boolean;
  camera: { orbit: V3; target: V3; walk: V3; walkLook: V3 };
  /** where to capture the room's own environment map from, and an optional mirror */
  environment: { center: V3; intensity: number; mirror?: THREE.MeshStandardMaterial; mirrorAt?: V3 };
  /** the source capture for Scan/Overlay: the textured scan, or RoomPlan's boxes */
  loadReference(onProgress?: (p: number) => void): Promise<THREE.Object3D>;
  /** reference materials are unlit/baked (scan) or schematic (RoomPlan) */
  referenceAvailable?: boolean;
  referenceKind: 'scan' | 'layout';
  /**
   * Viewer-only draw-call reduction (merge static meshes by material). Called once before the
   * first render. `{ static: true }` (the viewer: nothing moves) also merges the dynamic
   * bodies; without it they stay separate objects (safe after building physics colliders).
   */
  optimize?(opts?: { static?: boolean }): { meshesBefore: number; meshesAfter: number; batches: number } | void;
  /** posed reference photos (House Capture bundles), in room coordinates */
  photos?: PhotoPose[];
}

/** GTAO tuning (see GTAOPass.updateGtaoMaterial); intensity = blend strength */
export interface AOSettings {
  radius?: number;
  distanceExponent?: number;
  thickness?: number;
  scale?: number;
  samples?: number;
  intensity?: number;
  /** compute AO at half resolution (cheaper, slightly softer edges) */
  halfRes?: boolean;
}

export interface PhotoPose {
  /** URL of the upright JPEG */
  url: string;
  position: number[];
  forward: number[];
  up: number[];
  fovY: number;
  aspect: number;
  /** Bearing from the compass observation linked to this photo. */
  compass?: CompassBearing & { timestamp?: number };
}

export interface CompassBearing {
  degrees: number;
  cardinal: string;
  reference: 'true' | 'magnetic';
  accuracyDegrees: number;
}

export interface RoomCompass {
  status: 'aligned' | 'uncertain' | 'unavailable';
  /** Horizontal unit north in the SAME coordinates as the room geometry. */
  north?: number[];
  reference?: 'true' | 'magnetic';
  accuracyDegrees?: number;
  spreadDegrees?: number;
  sampleCount: number;
  totalSamples: number;
  reason?: string;
  sourceFile?: string;
  /** Original observations remain in session coordinates. */
  samples?: unknown[];
}

export interface RoomModule {
  id: string;
  label: string;
  build(): Promise<BuiltRoom>;
}

/** Measured RoomPlan geometry in room-local meters, for the overhead plan. */
export interface RoomLayout {
  compass?: RoomCompass;
  rooms?: { name: string; polygon: number[][]; color: string }[];
  /** Optional provenance for a reviewed/annotated plan. */
  note?: string;
  polygon: number[][];
  walls: { a: number[]; b: number[]; u: number[]; length: number;
    facing?: CompassBearing;
    openings: { kind: string; u0: number; u1: number; v0?: number; v1?: number; facing?: CompassBearing }[] }[];
  objects: { category: string; center: number[]; size: number[]; rotY: number }[];
}
