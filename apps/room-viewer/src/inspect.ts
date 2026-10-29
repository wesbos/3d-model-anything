import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import type { RoomLayout } from '../../../packages/room-runtime/types';
import { CompassOverlay, compassDescription } from './compass';
import { showLayout } from './layout';
import { disposeObjects } from '../../../packages/room-runtime/dispose';
import './inspect.css';

type MeasuredLayout = Omit<RoomLayout, 'walls'> & { source?: string; walls: (RoomLayout['walls'][number] & { height?: number })[] };
const host = document.querySelector<HTMLElement>('#inspect-viewport')!;
const canvas = document.querySelector<HTMLCanvasElement>('#inspect-canvas')!;
const plan = document.querySelector<HTMLElement>('#inspect-plan')!;
const status = document.querySelector<HTMLElement>('#inspect-status')!;
const renderer = new THREE.WebGLRenderer({canvas, antialias:true});
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
const scene = new THREE.Scene(); scene.background = new THREE.Color('#142126');
scene.add(new THREE.HemisphereLight('#e4f1ff', '#716249', 3));
const key = new THREE.DirectionalLight('#ffffff', 2); key.position.set(4, 8, 5); scene.add(key);
const camera = new THREE.PerspectiveCamera(45, 1, .03, 150);
camera.position.set(8, 7, 8);
const controls = new OrbitControls(camera, canvas);
controls.minDistance = .5; controls.maxDistance = 80; controls.maxPolarAngle = Math.PI / 2;
let geometry = new THREE.Group(); scene.add(geometry);
let overlay: CompassOverlay | undefined;
let inPlan = false;
let walls: {group:THREE.Group; midpoint:THREE.Vector3; inward:THREE.Vector3}[] = [];
const finiteVector = (value: unknown, length: number): value is number[] => Array.isArray(value)
  && value.length === length && value.every(n => typeof n === 'number' && Number.isFinite(n) && Math.abs(n) < 10_000);

function readLayout(value: unknown): MeasuredLayout {
  const data = value as MeasuredLayout;
  if (!data || !Array.isArray(data.walls) || !data.walls.length || data.walls.length > 200
    || !data.walls.every(w => finiteVector(w.a, 2) && finiteVector(w.b, 2) && finiteVector(w.u, 3)
      && Number.isFinite(w.length) && w.length > 0 && w.length < 1_000
      && (w.height === undefined || Number.isFinite(w.height) && w.height > 0 && w.height < 100)
      && Array.isArray(w.openings) && w.openings.length < 100
      && w.openings.every(o => Number.isFinite(o.u0) && Number.isFinite(o.u1)
        && (o.v0 === undefined || Number.isFinite(o.v0)) && (o.v1 === undefined || Number.isFinite(o.v1))))
    || !Array.isArray(data.objects) || data.objects.length > 2_000
    || !data.objects.every(o => typeof o.category === 'string' && finiteVector(o.center, 3)
      && finiteVector(o.size, 3) && o.size.every(n => n > 0 && n < 1_000) && Number.isFinite(o.rotY))
    || !Array.isArray(data.polygon) || data.polygon.length < 3 || data.polygon.length > 2_000
    || !data.polygon.every(p => finiteVector(p, 2))) {
    throw new Error('Choose a room.json produced by bundle_to_room.py or house_to_rooms.py with a measured floor polygon.');
  }
  return data;
}

function render() {
  if (inPlan) return;
  for (const wall of walls) wall.group.visible = camera.position.clone().sub(wall.midpoint).dot(wall.inward) > 0;
  renderer.render(scene, camera);
  overlay?.update(camera);
}
controls.addEventListener('change', render);

function show(value: unknown, label: string) {
  const data = readLayout(value);
  scene.remove(geometry); disposeObjects([geometry]);
  geometry = new THREE.Group(); scene.add(geometry); walls = [];
  overlay?.dispose();
  const wallTop = Math.max(...data.walls.map(w => w.height ?? 2.8));
  const shape = new THREE.Shape(data.polygon.map(p => new THREE.Vector2(p[0], -p[1])));
  const floor = new THREE.Mesh(new THREE.ShapeGeometry(shape), new THREE.MeshStandardMaterial({color:'#c5b495', side:THREE.DoubleSide}));
  floor.rotation.x = -Math.PI / 2; geometry.add(floor);
  for (const wall of data.walls) {
    const group = new THREE.Group(); geometry.add(group);
    const height = wall.height ?? wallTop;
    const cuts = [...new Set([0, wall.length, ...wall.openings.flatMap(o => [o.u0, o.u1]).map(u => THREE.MathUtils.clamp(u, 0, wall.length))])].sort((a,b)=>a-b);
    const paint = new THREE.MeshStandardMaterial({color:'#8cabb1', roughness:.9});
    for (let i=1; i<cuts.length; i++) {
      const a=cuts[i-1], b=cuts[i], mid=(a+b)/2;
      const openings=wall.openings.filter(o => mid>o.u0 && mid<o.u1);
      const levels=[...new Set([0,height,...openings.flatMap(o=>[o.v0??0,o.v1??height]).map(v=>THREE.MathUtils.clamp(v,0,height))])].sort((a,b)=>a-b);
      for(let j=1;j<levels.length;j++) {
        const low=levels[j-1],high=levels[j],y=(low+high)/2;
        if(b-a<.001 || high-low<.001 || openings.some(o=>y>(o.v0??0)&&y<(o.v1??height))) continue;
        const mesh=new THREE.Mesh(new THREE.BoxGeometry(b-a,high-low,.07),paint);
        mesh.position.set(wall.a[0]+wall.u[0]*mid,y,wall.a[1]+wall.u[2]*mid);
        mesh.rotation.y=Math.atan2(-wall.u[2],wall.u[0]); group.add(mesh);
      }
    }
    walls.push({group,midpoint:new THREE.Vector3((wall.a[0]+wall.b[0])/2,0,(wall.a[1]+wall.b[1])/2),
      inward:new THREE.Vector3(-wall.u[2],0,wall.u[0])});
  }
  for(const object of data.objects) {
    const color=object.category==='table'?'#b88e59':object.category==='television'?'#2b3d49':'#698895';
    const mesh=new THREE.Mesh(new THREE.BoxGeometry(...object.size as [number,number,number]),new THREE.MeshStandardMaterial({color,roughness:.85}));
    mesh.position.fromArray(object.center); mesh.rotation.y=object.rotY; geometry.add(mesh);
  }
  const bounds=new THREE.Box3().setFromObject(geometry), center=bounds.getCenter(new THREE.Vector3());
  camera.aspect=host.clientWidth/host.clientHeight;
  const vertical=THREE.MathUtils.degToRad(camera.fov), horizontal=2*Math.atan(Math.tan(vertical/2)*camera.aspect);
  const radius=bounds.getBoundingSphere(new THREE.Sphere()).radius;
  const distance=radius/Math.sin(Math.min(vertical,horizontal)/2)*1.08;
  controls.target.copy(center); camera.position.copy(center).add(new THREE.Vector3(1,.85,1).normalize().multiplyScalar(distance));
  camera.near=Math.max(.02,distance/1000);camera.far=Math.max(100,distance*10);camera.updateProjectionMatrix();
  overlay=new CompassOverlay(host,data,wallTop,render);overlay.setVisible(!inPlan);
  showLayout(plan,data,label); controls.update(); render();
  status.textContent=`${label} · Measured geometry · ${compassDescription(data.compass)}`;
}

function mode(next: boolean) {
  inPlan=next;plan.hidden=!next;canvas.hidden=next;overlay?.setVisible(!next);
  document.querySelector('#model-view')!.setAttribute('aria-pressed',String(!next));
  document.querySelector('#plan-view')!.setAttribute('aria-pressed',String(next));
  const url=new URL(location.href);url.searchParams.set('view',next?'layout':'3d');history.replaceState(null,'',url);
  render();
}
document.querySelector('#model-view')!.addEventListener('click',()=>mode(false));
document.querySelector('#plan-view')!.addEventListener('click',()=>mode(true));
document.querySelector<HTMLInputElement>('#room-file')!.addEventListener('change',async event=>{
  const input=event.currentTarget as HTMLInputElement,file=input.files?.[0];if(!file)return;
  try { if(file.size>20_000_000)throw new Error('Choose a room JSON smaller than 20 MB.');show(JSON.parse(await file.text()),file.name); }
  catch(error) { status.textContent=error instanceof Error?error.message:String(error); }
  finally { input.value=''; }
});
new ResizeObserver(()=>{
  camera.aspect=host.clientWidth/host.clientHeight;camera.updateProjectionMatrix();
  renderer.setSize(host.clientWidth,host.clientHeight);render();
}).observe(host);

// Local development can open an ignored derived file without copying it into public assets.
if(import.meta.env.DEV) {
  const path=new URLSearchParams(location.search).get('data');
  if(path) {
    try {
      const url=new URL(path,location.href);if(url.origin!==location.origin)throw new Error('Use a local room JSON.');
      const response=await fetch(url);if(!response.ok)throw new Error('The local room JSON could not load.');
      show(await response.json(),'Your scan');
    } catch(error) { status.textContent=error instanceof Error?error.message:String(error); }
  }
}
mode(new URLSearchParams(location.search).get('view')==='layout');
