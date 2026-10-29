import type { RoomLayout } from '../../../packages/room-runtime/types';

/** SVG plan: no perspective or lighting, with the same meter coordinates as the scan. */
export function showLayout(host: HTMLElement, room: RoomLayout, name: string) {
  const ns = 'http://www.w3.org/2000/svg';
  const el = (tag: string, attrs: Record<string, string | number> = {}, text?: string) => {
    const node = document.createElementNS(ns, tag);
    for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, String(value));
    if (text) node.textContent = text;
    return node;
  };
  host.replaceChildren();
  const header = document.createElement('header');
  const title = document.createElement('h1'); title.textContent = `${name} · Layout`;
  const xs = room.polygon.map(p => p[0]), zs = room.polygon.map(p => p[1]);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minZ = Math.min(...zs), maxZ = Math.max(...zs);
  const width = maxX - minX, height = maxZ - minZ;
  const outlines = room.rooms ?? [{name, polygon: room.polygon, color:'var(--plan-floor)'}];
  const area = outlines.reduce((total, r) => total + Math.abs(r.polygon.reduce((sum, a, i) => {
    const b = r.polygon[(i + 1) % r.polygon.length]; return sum + a[0] * b[1] - b[0] * a[1];
  }, 0)) / 2, 0);
  const subtitle = document.createElement('p');
  subtitle.textContent = `${width.toFixed(2)} × ${height.toFixed(2)} m overall · Approx. ${area.toFixed(1)} m² / ${Math.round(area * 10.764)} sq ft`;
  const note = document.createElement('p');
  note.textContent = room.note ?? 'Scan measurements; furniture labels are automatic detections. Not compass-oriented.';
  const fit = document.createElement('button'); fit.textContent = room.rooms ? 'Fit house' : 'Fit room';
  header.append(title, subtitle, note, fit); host.append(header);
  const svg = el('svg', { role: 'img', 'aria-label': `${name} floor plan with walls, openings and furniture` });
  host.append(svg);
  const initial = [minX - .75, minZ - .65, width + 1.5, height + 1.3];
  let box = [...initial];
  const apply = () => svg.setAttribute('viewBox', box.join(' '));
  const reset = () => { box = [...initial]; apply(); }; reset();
  fit.onclick = reset; svg.addEventListener('dblclick', reset);
  for (const r of outlines) svg.append(el('polygon', { points: r.polygon.map(p => p.join(',')).join(' '), fill: r.color, 'fill-opacity': room.rooms ? .22 : 1 }));
  for (const [i, o] of room.objects.entries()) {
    const color = o.category === 'table' ? '#d8bd93' : o.category === 'storage' ? '#b8cbbd' : '#bcc9d5';
    const group = el('g', { transform: `translate(${o.center[0]} ${o.center[2]}) rotate(${-o.rotY * 180 / Math.PI})` });
    group.append(el('rect', { x: -o.size[0]/2, y: -o.size[2]/2, width: o.size[0], height: o.size[2], fill: color, stroke: '#73837d', 'stroke-width': .015 }));
    group.append(el('title', {}, `${i + 1}. ${o.category} — ${o.size[0].toFixed(2)} × ${o.size[2].toFixed(2)} m`));
    svg.append(group);
  }
  for (const w of room.walls) {
    svg.append(el('line', { x1:w.a[0], y1:w.a[1], x2:w.b[0], y2:w.b[1], stroke:'var(--plan-wall)', 'stroke-width':.075 }));
    for (const o of w.openings) {
      const coords = { x1:w.a[0]+w.u[0]*o.u0, y1:w.a[1]+w.u[2]*o.u0, x2:w.a[0]+w.u[0]*o.u1, y2:w.a[1]+w.u[2]*o.u1 };
      svg.append(el('line', {...coords, stroke:'var(--plan-gap)', 'stroke-width':.085}));
      svg.append(el('line', {...coords, stroke:o.kind==='window'?'#258eaf':'#be753d', 'stroke-width':.025}));
    }
  }
  for (const [i,o] of room.objects.entries()) {
    // Numbered labels stay upright; the legend preserves categories without covering furniture.
    svg.append(el('text', { x:o.center[0], y:o.center[2], 'text-anchor':'middle', 'dominant-baseline':'central', 'font-size':.14, fill:'var(--plan-text)', stroke:'var(--plan-label-halo)', 'stroke-width':.045, 'paint-order':'stroke' }, String(i+1)));
  }
  for (const r of room.rooms ?? []) {
    const x=(Math.min(...r.polygon.map(p=>p[0]))+Math.max(...r.polygon.map(p=>p[0])))/2;
    const z=(Math.min(...r.polygon.map(p=>p[1]))+Math.max(...r.polygon.map(p=>p[1])))/2;
    svg.append(el('text',{x,y:z,'text-anchor':'middle','font-size':.26,'font-weight':600,fill:'var(--plan-text)',stroke:'var(--plan-label-halo)','stroke-width':.07,'paint-order':'stroke'},r.name));
  }
  svg.append(el('text',{x:(minX+maxX)/2,y:minZ-.25,'text-anchor':'middle','font-size':.17,fill:'var(--plan-muted)'},`${width.toFixed(2)} m`));
  svg.append(el('text',{x:maxX+.25,y:(minZ+maxZ)/2,transform:`rotate(90 ${maxX+.25} ${(minZ+maxZ)/2})`,'text-anchor':'middle','font-size':.17,fill:'var(--plan-muted)'},`${height.toFixed(2)} m`));
  const legend = document.createElement('aside');
  const key = document.createElement('p'); key.textContent = 'Blue: windows · Orange: doors/openings'; legend.append(key);
  const list = document.createElement('ol');
  for (const o of room.objects) { const li=document.createElement('li'); li.textContent=o.category; list.append(li); }
  legend.append(list); host.append(legend);
  let drag: { x:number; y:number; box:number[]; scale:number } | undefined;
  svg.addEventListener('pointerdown', e => {
    const event=e as PointerEvent; if(event.button!==0)return;
    const rect=svg.getBoundingClientRect();
    drag={x:event.clientX,y:event.clientY,box:[...box],scale:Math.max(box[2]/rect.width,box[3]/rect.height)};
    (svg as SVGSVGElement).setPointerCapture(event.pointerId);
  });
  svg.addEventListener('pointermove', e => { if(!drag)return; const event=e as PointerEvent; box=[drag.box[0]-(event.clientX-drag.x)*drag.scale,drag.box[1]-(event.clientY-drag.y)*drag.scale,...drag.box.slice(2)];apply(); });
  svg.addEventListener('pointerup',()=>{drag=undefined;});svg.addEventListener('pointercancel',()=>{drag=undefined;});
  svg.addEventListener('wheel', e => {
    e.preventDefault(); const event=e as WheelEvent;
    const factor=Math.exp(Math.max(-.2,Math.min(.2,event.deltaY*.001)));
    const next=box[2]*factor; if(next<initial[2]*.25||next>initial[2]*4)return;
    box=[box[0]+box[2]*(1-factor)/2,box[1]+box[3]*(1-factor)/2,box[2]*factor,box[3]*factor];apply();
  },{passive:false});
}
