import "@phosphor-icons/web/regular";
import "./style.css";
import * as THREE from "three/webgpu";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";

// Contrato de datos (lo genera tools/src/cli/convert.ts):
//   map-data/<disco>/index.json  → recursos sueltos (coches, secciones)
//   map-data/<disco>/world.json  → secciones de Rockport con centro y radio
interface Item { id: string; group: string; label: string; glb: string; tris: number; verts: number; source: string }
interface Index { disc: string; generated: string; upAxis: "Z"; items: Item[] }
interface WorldSection { name: string; number: number; centre: [number, number]; radius: number; glb: string; instances: number; tris: number }

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const stage = $("stage");

const renderer = new THREE.WebGPURenderer({ antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
stage.prepend(renderer.domElement);
await renderer.init();
$("backend").textContent = (renderer.backend as { isWebGPUBackend?: boolean }).isWebGPUBackend ? "WebGPU · Metal" : "WebGL 2";

// Coordenadas del juego: Z arriba [verificado en el código del escenario: la sombra suma en v3.z].
THREE.Object3D.DEFAULT_UP.set(0, 0, 1);
const scene = new THREE.Scene();
const SKY = 0x1c2a33;
scene.background = new THREE.Color(SKY);
scene.fog = new THREE.Fog(SKY, 1500, 9000);
const camera = new THREE.PerspectiveCamera(55, 1, 0.5, 80000);
camera.up.set(0, 0, 1);
camera.position.set(6, -6, 4);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.maxPolarAngle = Math.PI * 0.495;

scene.add(new THREE.HemisphereLight(0xdfe8ff, 0x2a2416, 1.4));
const sun = new THREE.DirectionalLight(0xffe2b0, 2.2);
sun.position.set(30, -20, 50);
scene.add(sun);

const content = new THREE.Group();   // recurso suelto (coche o sección)
const city = new THREE.Group();      // Rockport completo
const bounds = new THREE.Group();    // círculos de sección
bounds.visible = false;
scene.add(content, city, bounds);
const loader = new GLTFLoader();
let index: Index | null = null;
let world: WorldSection[] = [];
let current: Item | null = null;
let selected: THREE.Object3D | null = null;
const selBox = new THREE.BoxHelper(new THREE.Object3D(), 0x4dff9a);
selBox.visible = false;
scene.add(selBox);

function resize() {
  const { clientWidth: w, clientHeight: h } = stage;
  renderer.setSize(w, h, false);
  camera.aspect = w / Math.max(h, 1);
  camera.updateProjectionMatrix();
}
new ResizeObserver(resize).observe(stage);

async function loadGlb(path: string) {
  const gltf = await loader.loadAsync(`/${index!.disc}/${path}`);
  gltf.scene.rotation.x = Math.PI / 2; // GLB Y-arriba (glTF) → coordenadas del juego Z-arriba
  return gltf.scene;
}
const countTris = (o: THREE.Object3D) => { let t = 0; o.traverse(x => { const m = x as THREE.Mesh; if (m.isMesh) t += (m.geometry.index?.count ?? m.geometry.attributes.position.count) / 3; }); return t; };

// ---------- Lista de recursos ----------
const tree = $("tree");
function renderTree(filter = "") {
  tree.innerHTML = "";
  if (!index) return;
  const f = filter.trim().toLowerCase();
  const groups = new Map<string, Item[]>();
  for (const it of index.items) {
    if (f && !`${it.label} ${it.id}`.toLowerCase().includes(f)) continue;
    (groups.get(it.group) ?? groups.set(it.group, []).get(it.group)!).push(it);
  }
  for (const [g, items] of groups) {
    const head = document.createElement("li");
    head.className = "group";
    head.textContent = `${g} · ${items.length}`;
    tree.append(head);
    for (const it of items.slice(0, 400)) {
      const li = document.createElement("li");
      const b = document.createElement("button");
      b.innerHTML = `<span>${it.label}</span><small>${(it.tris / 1000).toFixed(1)}k</small>`;
      b.setAttribute("aria-current", String(current?.id === it.id));
      b.onclick = () => open(it);
      li.append(b);
      tree.append(li);
    }
  }
}
$<HTMLInputElement>("filter").addEventListener("input", e => renderTree((e.target as HTMLInputElement).value));

async function open(it: Item) {
  current = it;
  renderTree($<HTMLInputElement>("filter").value);
  select(null);
  const sec = it.id.startsWith("sec:") ? world.find(w => `sec:${w.name}` === it.id) : undefined;
  if (sec && city.children.length) { flyTo(sec); return; } // con la ciudad cargada, solo volamos allí
  content.clear();
  const obj = await loadGlb(it.glb);
  content.add(obj);
  $("tri-count").textContent = Math.round(countTris(obj)).toLocaleString("es-ES");
  frame(obj);
}

function frame(obj: THREE.Object3D) {
  const box = new THREE.Box3().setFromObject(obj);
  if (box.isEmpty()) return;
  const c = box.getCenter(new THREE.Vector3()), r = box.getSize(new THREE.Vector3()).length() * 0.9 || 1;
  controls.target.copy(c);
  camera.position.copy(c).add(new THREE.Vector3(r, -r, r * 0.6));
}
/** Encuadra la ciudad por los centros de sección (hay geometría de horizonte muy lejana que estira la caja). */
function frameCity() {
  const xs = world.filter(s => s.radius).map(s => s.centre[0]), ys = world.filter(s => s.radius).map(s => s.centre[1]);
  if (!xs.length) return;
  const cx = (Math.min(...xs) + Math.max(...xs)) / 2, cy = (Math.min(...ys) + Math.max(...ys)) / 2;
  const span = Math.max(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys));
  controls.target.set(cx, cy, 0);
  camera.position.set(cx, cy - span * 0.75, span * 0.9);
}
function flyTo(s: WorldSection) {
  const c = new THREE.Vector3(s.centre[0], s.centre[1], 0);
  controls.target.copy(c);
  camera.position.copy(c).add(new THREE.Vector3(s.radius * 1.2, -s.radius * 1.2, s.radius));
}

// ---------- Ciudad completa ----------
const btn = $<HTMLButtonElement>("load-city");
btn.onclick = async () => {
  if (!world.length) return;
  btn.disabled = true;
  content.clear();
  current = null;
  renderTree($<HTMLInputElement>("filter").value);
  // Primero lo más cercano a la cámara, en lotes de 6 peticiones.
  const t = controls.target;
  const queue = [...world].sort((a, b) => Math.hypot(a.centre[0] - t.x, a.centre[1] - t.y) - Math.hypot(b.centre[0] - t.x, b.centre[1] - t.y));
  let done = 0, tris = 0, failed = 0;
  const status = $("city-status"), bar = $("city-bar");
  const worker = async () => {
    for (let s = queue.shift(); s; s = queue.shift()) {
      try { const o = await loadGlb(s.glb); o.name = s.name; city.add(o); tris += countTris(o); }
      catch { failed++; }
      done++;
      bar.style.width = `${(done / world.length) * 100}%`;
      status.textContent = `${done} / ${world.length} secciones · ${(tris / 1e6).toFixed(2)} M tris${failed ? ` · ${failed} con error` : ""}`;
      $("tri-count").textContent = Math.round(tris).toLocaleString("es-ES");
    }
  };
  frameCity();
  await Promise.all(Array.from({ length: 6 }, worker));
  btn.innerHTML = `<i class="ph ph-check"></i>Ciudad cargada`;
};

function buildBounds() {
  bounds.clear();
  const mat = new THREE.LineBasicMaterial({ color: 0xffb21a, transparent: true, opacity: 0.45 });
  for (const s of world) {
    if (!s.radius) continue;
    const pts = Array.from({ length: 33 }, (_, i) => { const a = (i / 32) * Math.PI * 2; return new THREE.Vector3(s.centre[0] + Math.cos(a) * s.radius, s.centre[1] + Math.sin(a) * s.radius, 2); });
    bounds.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), mat));
  }
}
$<HTMLInputElement>("show-bounds").addEventListener("change", e => (bounds.visible = (e.target as HTMLInputElement).checked));

// ---------- Selección e inspector ----------
const ray = new THREE.Raycaster();
const ptr = new THREE.Vector2();
let downAt = { x: 0, y: 0 };
renderer.domElement.addEventListener("pointerdown", e => (downAt = { x: e.clientX, y: e.clientY }));
renderer.domElement.addEventListener("pointerup", e => {
  if (Math.hypot(e.clientX - downAt.x, e.clientY - downAt.y) > 4) return; // fue un arrastre
  const r = renderer.domElement.getBoundingClientRect();
  ptr.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
  ray.setFromCamera(ptr, camera);
  const hit = ray.intersectObjects([content, city], true)[0];
  select(hit?.object ?? null, hit?.point, hit?.face?.a);
});

/** Sube hasta el nodo que lleva los metadatos del conversor (extras de glTF). */
const owner = (o: THREE.Object3D) => { let n: THREE.Object3D | null = o; while (n && !Object.keys(n.userData ?? {}).length) n = n.parent; return n ?? o; };
const pickBox = new THREE.Box3Helper(new THREE.Box3(), 0x4dff9a);
pickBox.visible = false;
scene.add(pickBox);
function select(o: THREE.Object3D | null, point?: THREE.Vector3, vertex?: number) {
  selected = o ? owner(o) : null;
  selBox.visible = false; pickBox.visible = false;
  const dl = $("inspector");
  if (!selected || !o) { dl.innerHTML = `<dt>Selección</dt><dd class="muted">Haz clic en una pieza</dd>`; return; }
  const mesh = o as THREE.Mesh;
  const ids = mesh.geometry?.getAttribute("_id") as THREE.BufferAttribute | undefined;
  const objetos = selected.userData.objetos as Record<string, unknown>[] | undefined;
  let meta: Record<string, unknown> = { ...selected.userData };
  delete meta.objetos; delete meta.name;
  if (ids && objetos && vertex !== undefined) {
    // Malla fusionada: el atributo _id del vértice dice qué objeto original es.
    const id = ids.getX(vertex);
    meta = { ...meta, ...objetos[id] };
    const pos = mesh.geometry.getAttribute("position"), box = new THREE.Box3(), v = new THREE.Vector3();
    for (let i = 0; i < ids.count; i++) if (ids.getX(i) === id) box.expandByPoint(v.fromBufferAttribute(pos, i));
    box.applyMatrix4(mesh.matrixWorld);
    pickBox.box.copy(box); pickBox.visible = true;
  } else { selBox.setFromObject(selected); selBox.visible = true; }
  const rows: [string, string][] = [
    ["Pieza", `<span class="hl">${String(meta["Modelo"] ?? selected.name ?? "—")}</span>`],
    ...Object.entries(meta).filter(([k]) => k !== "Modelo").map(([k, v]) => [k, String(v)] as [string, string]),
    ["Material", (mesh.material as THREE.Material)?.name || "—"],
  ];
  if (point) rows.push(["Punto", `${point.x.toFixed(1)}, ${point.y.toFixed(1)}, ${point.z.toFixed(1)}`]);
  dl.innerHTML = rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("");
}

// ---------- Marcadores (anotaciones de diseño) ----------
const markers: { id: number; source: string | null; pos: [number, number, number]; note: string }[] = [];
function addMarker() {
  const p = controls.target.clone();
  const m = { id: markers.length + 1, source: current?.id ?? (city.children.length ? "ciudad" : null), pos: [+p.x.toFixed(2), +p.y.toFixed(2), +p.z.toFixed(2)] as [number, number, number], note: "" };
  markers.push(m);
  const size = Math.max(0.5, camera.position.distanceTo(p) / 60);
  const pin = new THREE.Mesh(new THREE.ConeGeometry(size * 0.3, size, 4), new THREE.MeshBasicMaterial({ color: 0xffb21a }));
  pin.rotation.x = -Math.PI / 2; pin.position.copy(p).add(new THREE.Vector3(0, 0, size / 2));
  scene.add(pin);
  const li = document.createElement("li");
  li.innerHTML = `<b>#${m.id}</b> ${m.pos.join(", ")}`;
  $("markers").append(li);
}
$("export").onclick = () => {
  const blob = new Blob([JSON.stringify({ disc: index?.disc, markers }, null, 2)], { type: "application/json" });
  const a = Object.assign(document.createElement("a"), { href: URL.createObjectURL(blob), download: "marcadores.json" });
  a.click();
};

// ---------- Vuelo libre ----------
const keys = new Set<string>();
addEventListener("keydown", e => {
  if ((e.target as HTMLElement).tagName === "INPUT") return;
  keys.add(e.code);
  if (e.code === "KeyM") addMarker();
  if (e.code === "KeyF") { if (selected) frame(selected); else if (content.children.length) frame(content); else frameCity(); }
});
addEventListener("keyup", e => keys.delete(e.code));
const clock = new THREE.Clock();
let frames = 0, acc = 0;
renderer.setAnimationLoop(() => {
  const dt = Math.min(clock.getDelta(), 0.1);
  const speed = (keys.has("ShiftLeft") ? 5 : 1) * dt * Math.max(8, camera.position.distanceTo(controls.target) * 0.8);
  const fwd = new THREE.Vector3().subVectors(controls.target, camera.position).setZ(0).normalize();
  const right = new THREE.Vector3().crossVectors(fwd, camera.up).normalize();
  const mv = new THREE.Vector3();
  if (keys.has("KeyW")) mv.add(fwd); if (keys.has("KeyS")) mv.sub(fwd);
  if (keys.has("KeyD")) mv.add(right); if (keys.has("KeyA")) mv.sub(right);
  if (keys.has("KeyE")) mv.z += 1; if (keys.has("KeyQ")) mv.z -= 1;
  if (mv.lengthSq()) { mv.normalize().multiplyScalar(speed); camera.position.add(mv); controls.target.add(mv); }
  controls.update();
  // Niebla proporcional a la distancia: de lejos se ve la ciudad entera, de cerca hay profundidad.
  const dist = camera.position.distanceTo(controls.target);
  const fog = scene.fog as THREE.Fog;
  fog.near = Math.max(600, dist * 0.9); fog.far = Math.max(4000, dist * 3.5);
  const t = controls.target;
  $("cx").textContent = t.x.toFixed(1); $("cy").textContent = t.y.toFixed(1); $("cz").textContent = t.z.toFixed(1);
  frames++;
  if ((acc += dt) > 0.5) { $("fps").textContent = String(Math.round(frames / acc)); frames = 0; acc = 0; }
  renderer.render(scene, camera);
});

// ---------- Arranque ----------
const disc = new URLSearchParams(location.search).get("disc") ?? "SLES-53559";
try {
  const res = await fetch(`/${disc}/index.json`);
  if (!res.ok) throw new Error(String(res.status));
  index = (await res.json()) as Index;
  $("disc-tag").textContent = index.disc;
  $("empty").hidden = true;
  const w = await fetch(`/${disc}/world.json`);
  if (w.ok) { world = ((await w.json()) as { sections: WorldSection[] }).sections; buildBounds(); $("city-status").textContent = `${world.length} secciones disponibles`; }
  else { btn.disabled = true; $("city-status").textContent = "Sin world.json: ejecuta el conversor en modo world"; }
  renderTree();
  const first = index.items.find(i => i.group === "Coches") ?? index.items[0];
  if (first) await open(first);
} catch {
  $("disc-tag").textContent = disc;
}
resize();

// Solo para depuración desde la consola (contadores de dibujo, escena).
(window as unknown as { __rockport: unknown }).__rockport = { renderer, scene, camera, controls, city };
