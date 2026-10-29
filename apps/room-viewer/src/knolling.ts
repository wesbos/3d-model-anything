import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { batchStatic } from '../../../packages/room-runtime/batch';
import { packObjects } from './knolling-pack';
import type { BuiltRoom } from '../../../packages/room-runtime/types';

interface Item { name: string; object: THREE.Object3D; size: THREE.Vector3; origin: THREE.Vector3; source: THREE.Object3D }
const inventory = new WeakMap<BuiltRoom, Item[]>();
const excluded = /^(slab|floor|ceiling|wall-|baseboard|crown|window|door(?:$|-)|plate-|beam|soffit|builtins-cabinetry|cabinet-door|oct7-charcoal|.*glow|.*halo)/i;
const label = (name: string) => name.replace(/^(oct7-|october-)/, '').replace(/[-_]/g, ' ').replace(/\b\w/g, c => c.toUpperCase());

/** Snapshot before static batching removes the original item boundaries. Geometry stays shared. */
export function collectInventory(room: BuiltRoom) {
  if (inventory.has(room)) return;
  room.group.updateMatrixWorld(true);
  const candidates: THREE.Object3D[] = [];
  const structural = new Set<THREE.Object3D>([room.group, ...room.walls.map(w => w.group), ...room.ceiling]);
  room.group.traverse(o => {
    if (structural.has(o) || !o.name || excluded.test(o.name) || o.name.includes(':')) return;
    const type = o.userData.physics?.type;
    if (type === 'dynamic' || type === 'static' || /^oct7-/.test(o.name)) candidates.push(o);
  });
  const candidateSet = new Set(candidates);
  const items: Item[] = [];
  for (const source of candidates) {
    // Separate nested possessions from their support (e.g. items standing on furniture).
    const copy = (node: THREE.Object3D): THREE.Object3D => {
      const clone = node.clone(false);
      for (const child of node.children) if (!candidateSet.has(child)) clone.add(copy(child));
      return clone;
    };
    const object = copy(source);
    source.matrixWorld.decompose(object.position, object.quaternion, object.scale);
    object.visible = true;
    object.updateMatrixWorld(true);
    const bounds = new THREE.Box3().setFromObject(object);
    if (bounds.isEmpty()) continue;
    const size = bounds.getSize(new THREE.Vector3());
    if (Math.max(size.x, size.y, size.z) < 0.015) continue;
    object.position.sub(bounds.getCenter(new THREE.Vector3()));
    object.updateMatrixWorld(true);
    items.push({ name: label(source.name), object, size, origin: bounds.getCenter(new THREE.Vector3()), source });
  }
  inventory.set(room, items.sort((a, b) => Math.max(b.size.x,b.size.z) * Math.max(b.size.y,b.size.z) - Math.max(a.size.x,a.size.z) * Math.max(a.size.y,a.size.z)));
}

/** Shared arrangement for the interactive view and deterministic animations. */
export function createKnollingLayout(room: BuiltRoom) {
  collectInventory(room);
  const items=inventory.get(room)??[];
  const objects=new THREE.Group();
  const originalGeometries=new Set<THREE.BufferGeometry>();
  const laidOut=items.map(item=>{
    const holder=new THREE.Group();const object=item.object.clone(true);holder.add(object);
    // Find the upright yaw that gives the tightest footprint before laying thin
    // vertical objects (screens, prints, tools) onto their broad face.
    let angle=0,area=Infinity;
    for(let i=0;i<36;i++){
      holder.rotation.y=i*Math.PI/72;holder.updateMatrixWorld(true);
      const size=new THREE.Box3().setFromObject(holder).getSize(new THREE.Vector3());
      if(size.x*size.z<area){area=size.x*size.z;angle=holder.rotation.y;}
    }
    holder.rotation.y=angle;holder.updateMatrixWorld(true);
    const upright=new THREE.Box3().setFromObject(holder).getSize(new THREE.Vector3());
    const flat=new THREE.Group();flat.add(holder);
    const staysUpright=/Rubber Plant|Workbench|Desk Slab Frame|Aeron Chair|Eames/i.test(item.name);
    if(!staysUpright&&upright.z<Math.min(upright.x,upright.y))flat.rotation.x=Math.PI/2;
    else if(!staysUpright&&upright.x<Math.min(upright.y,upright.z))flat.rotation.z=-Math.PI/2;
    // Lay labeled/display faces upward, rather than showing the backs of monitors
    // and framed prints. Weight emissive screen maps above generic body textures.
    flat.updateMatrixWorld(true);
    let faceScore=0;
    flat.traverse(node=>{
      if(!(node instanceof THREE.Mesh)||Array.isArray(node.material))return;
      const material=node.material as THREE.MeshStandardMaterial;
      if(!material.map&&!material.emissiveMap)return;
      const pos=node.geometry.getAttribute('position'),idx=node.geometry.index;
      const count=idx?idx.count:pos.count,step=Math.max(1,Math.floor(count/600))*3;
      const a=new THREE.Vector3(),b=new THREE.Vector3(),c=new THREE.Vector3();
      for(let i=0;i+2<count;i+=step){
        a.fromBufferAttribute(pos,idx?idx.getX(i):i).applyMatrix4(node.matrixWorld);
        b.fromBufferAttribute(pos,idx?idx.getX(i+1):i+1).applyMatrix4(node.matrixWorld);
        c.fromBufferAttribute(pos,idx?idx.getX(i+2):i+2).applyMatrix4(node.matrixWorld);
        faceScore+=b.sub(a).cross(c.sub(a)).y*(material.emissiveMap?5:1);
      }
    });
    if(!staysUpright&&faceScore<-.0001)flat.rotateOnWorldAxis(new THREE.Vector3(1,0,0),Math.PI);
    const orient=new THREE.Group();orient.add(flat);orient.updateMatrixWorld(true);
    const bounds=new THREE.Box3().setFromObject(orient);const size=bounds.getSize(new THREE.Vector3());
    flat.position.sub(bounds.getCenter(new THREE.Vector3()));flat.position.y+=size.y/2;
    orient.traverse(o=>{if(o instanceof THREE.Mesh){o.castShadow=true;o.receiveShadow=true;originalGeometries.add(o.geometry);}});
    objects.add(orient);return {orient,size,object};
  });
  const gap=.065;
  const packed=packObjects(laidOut.map(({size})=>({width:size.x,height:size.z})),gap);
  for(const p of packed.placements){const {orient}=laidOut[p.index];if(p.rotated)orient.rotation.y=Math.PI/2;orient.position.set(p.x+(p.width-gap)/2-packed.width/2,0,p.y+(p.height-gap)/2-packed.height/2);}
  objects.updateMatrixWorld(true);
  return {objects,items,laidOut,packed,originalGeometries};
}

let cleanup: (()=>void) | undefined;
export function stopKnolling() { cleanup?.(); cleanup=undefined; }
export async function showKnolling(host: HTMLElement, room: BuiltRoom, title: string) {
  stopKnolling();host.replaceChildren();
  const items=inventory.get(room)??[];
  const caption=document.createElement('header');
  const heading=document.createElement('h1');heading.textContent=title;
  const note=document.createElement('p');note.textContent=`${items.length} modeled objects & assemblies · Same scale · Drag to orbit · Right-drag to pan · Scroll to zoom`;
  const fitButton=document.createElement('button');fitButton.textContent='Fit all';
  caption.append(heading,note,fitButton);host.append(caption);
  if(!items.length){note.textContent='No individually modeled objects in this room yet.';return;}
  const renderer=new THREE.WebGLRenderer({antialias:true});
  renderer.setPixelRatio(Math.min(devicePixelRatio,1.5));
  renderer.toneMapping=THREE.AgXToneMapping;renderer.toneMappingExposure=1.05;
  renderer.shadowMap.enabled=true;renderer.shadowMap.type=THREE.PCFShadowMap;
  host.prepend(renderer.domElement);renderer.domElement.setAttribute('aria-label','Overhead knolling arrangement');
  const scene=new THREE.Scene();
  const surfaceColor=document.documentElement.dataset.theme==='dark'?'#20231f':'#d7d0c1';
  scene.background=new THREE.Color(surfaceColor);
  const studio=new RoomEnvironment(),pmrem=new THREE.PMREMGenerator(renderer);
  const environment=pmrem.fromScene(studio,.08);scene.environment=environment.texture;scene.environmentIntensity=.3;
  studio.dispose();pmrem.dispose();
  scene.add(new THREE.HemisphereLight('#fffaf0','#a59b85',2));
  const {objects,packed,originalGeometries}=createKnollingLayout(room);
  scene.add(objects);
  batchStatic(objects,[],{mergeDynamic:true});
  const floorMaterial=new THREE.MeshStandardMaterial({color:surfaceColor,roughness:1});
  const floorGeometry=new THREE.PlaneGeometry(200,200);
  const floor=new THREE.Mesh(floorGeometry,floorMaterial);floor.rotation.x=-Math.PI/2;floor.position.y=-.015;floor.receiveShadow=true;scene.add(floor);
  const light=new THREE.DirectionalLight('#fff8e9',2.8);light.position.set(-5,14,-4);light.castShadow=true;
  const extent=Math.max(packed.width,packed.height);
  Object.assign(light.shadow.camera,{left:-extent,right:extent,top:extent,bottom:-extent,near:.1,far:50});
  light.shadow.mapSize.set(4096,4096);light.shadow.normalBias=.012;light.shadow.bias=-.0001;scene.add(light);
  const camera=new THREE.OrthographicCamera(-1,1,1,-1,.1,100);
  camera.position.set(0,30,.001);camera.up.set(0,1,0);camera.lookAt(0,0,0);
  const controls=new OrbitControls(camera,renderer.domElement);controls.enableRotate=true;controls.enableDamping=false;controls.maxPolarAngle=Math.PI/2-.04;
  controls.screenSpacePanning=true;controls.mouseButtons.LEFT=THREE.MOUSE.ROTATE;controls.mouseButtons.RIGHT=THREE.MOUSE.PAN;controls.minZoom=.5;controls.maxZoom=18;
  let pending=0,disposed=false;
  const render=()=>{if(disposed||pending)return;pending=requestAnimationFrame(()=>{pending=0;renderer.render(scene,camera);renderer.shadowMap.autoUpdate=false;host.dataset.ready='1';});};
  const appearanceChanged=()=>{const color=document.documentElement.dataset.theme==='dark'?'#20231f':'#d7d0c1';scene.background=new THREE.Color(color);floorMaterial.color.set(color);render();};
  window.addEventListener('appearancechange',appearanceChanged);
  const fit=()=>{const aspect=host.clientWidth/host.clientHeight;const height=Math.max(packed.height+1.4,(packed.width+1)/aspect);camera.left=-height*aspect/2;camera.right=height*aspect/2;camera.top=height/2;camera.bottom=-height/2;camera.zoom=1;camera.position.set(0,30,.001);controls.target.set(0,0,0);camera.updateProjectionMatrix();controls.update();render();};
  const resize=()=>{renderer.setSize(host.clientWidth,host.clientHeight);fit();};
  const observer=new ResizeObserver(resize);observer.observe(host);
  controls.addEventListener('change',render);fitButton.addEventListener('click',fit);renderer.domElement.addEventListener('dblclick',fit);
  host.dataset.ready='0';host.dataset.items=String(items.length);resize();
  cleanup=()=>{disposed=true;window.removeEventListener('appearancechange',appearanceChanged);cancelAnimationFrame(pending);observer.disconnect();controls.dispose();environment.dispose();light.shadow.dispose();floorGeometry.dispose();floorMaterial.dispose();objects.traverse(o=>{if(o instanceof THREE.Mesh&&!originalGeometries.has(o.geometry))o.geometry.dispose();});renderer.dispose();renderer.forceContextLoss();};
}
