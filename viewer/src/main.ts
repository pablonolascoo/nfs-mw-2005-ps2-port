import "@phosphor-icons/web/regular";
import "./style.css";
import * as THREE from "three/webgpu";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { loadTile, loadPackedTile } from "./tile-loader";

// Contrato de datos (lo genera tools/src/cli/convert.ts):
//   map-data/<disco>/index.json  → recursos sueltos (coches, secciones)
//   map-data/<disco>/world.json  → secciones de Rockport con centro y radio
interface Item { id: string; group: string; label: string; glb: string; tris: number; verts: number; source: string }
interface Index { disc: string; generated: string; upAxis: "Z"; items: Item[] }
interface WorldSection { name: string; number: number; centre: [number, number]; radius: number; glb: string; instances: number; tris: number }
interface Group { name: string; hash: string; number: number; kind: "carrera" | "candado" | "puerta" | "otro"; barrier: boolean; driveThrough: boolean; objects: number; glb: string; min: number[]; max: number[] }
interface Zone { collection: string; zoneType: "safehouse" | "carlot" | "customshop"; position: [number, number, number]; radius: number; respawn?: { position: [number, number, number]; rotation: number } }
interface Tile { id: string; x: number; y: number; size: number; near: string; far: string; tris: number; farTris: number; objects: number; zMin: number; zMax: number }

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const stage = $("stage");

const renderer = new THREE.WebGPURenderer({ antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2)); // luego la ajusta la resolución dinámica
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
let tiles: Tile[] = [];
let groups: Group[] = [];
let zones: Zone[] = [];
// Caché de texturas propia: cada textura del juego se sube una vez a la GPU y la comparten todas las casillas.
// (No usamos THREE.Cache: al liberar una casilla cerraría imágenes que otras siguen usando.)
const sharedTex = new Map<string, THREE.Texture>();
function shareTextures(o: THREE.Object3D) {
  o.traverse(x => {
    const m = x as THREE.Mesh;
    if (!m.isMesh) return;
    for (const mat of ([] as THREE.Material[]).concat(m.material) as THREE.MeshBasicMaterial[]) {
      const t = mat.map; if (!t) continue;
      const key = mat.name || t.uuid, hit = sharedTex.get(key);
      if (hit && hit !== t) { mat.map = hit; t.dispose(); } else sharedTex.set(key, t);
    }
  });
}
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
  shareTextures(gltf.scene);
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
  if (sec && (streaming || !sec.glb)) { flyTo(sec); return; } // con la ciudad cargada, solo volamos allí
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

// ---------- Ciudad completa: casillas con dos niveles de detalle (HLOD) ----------
// Lejos: una malla por casilla con color por vértice (1 llamada de dibujo). Cerca: detalle con texturas, cargado bajo demanda.
const NEAR = 650, KEEP = 1100, MAX_NEAR = 28;
const packed = new URLSearchParams(location.search).get("packed") !== "0"; // arrays de texturas: 2 llamadas por casilla
interface TileState { t: Tile; far?: THREE.Object3D; near?: THREE.Object3D; ready?: boolean; loading?: boolean; lastUsed: number; box: THREE.Box3 }
const tileState = new Map<string, TileState>();
let streaming = false;
const btn = $<HTMLButtonElement>("load-city");
btn.onclick = async () => {
  if (!tiles.length && !world.length) return;
  btn.disabled = true;
  content.clear(); current = null;
  renderTree($<HTMLInputElement>("filter").value);
  frameCity();
  setLayer("candado", $<HTMLInputElement>("layer-candado").checked); setLayer("puerta", $<HTMLInputElement>("layer-puerta").checked);
  const status = $("city-status"), bar = $("city-bar");
  const queue = [...tiles];
  let done = 0;
  for (const t of tiles) tileState.set(t.id, { t, lastUsed: 0, box: new THREE.Box3(new THREE.Vector3(t.x, t.y, t.zMin), new THREE.Vector3(t.x + t.size, t.y + t.size, t.zMax)) });
  const worker = async () => {
    for (let t = queue.shift(); t; t = queue.shift()) {
      try { const o = await loadTile(`/${index!.disc}/${t.far}`, tileMaterials); o.name = `far ${t.id}`; city.add(o); tileState.get(t.id)!.far = o; } catch { /* casilla sin nivel lejano */ }
      bar.style.width = `${(++done / tiles.length) * 100}%`;
      status.textContent = `Ciudad lejana: ${done} / ${tiles.length} casillas`;
    }
  };
  await Promise.all(Array.from({ length: 8 }, worker));
  streaming = true;
  btn.innerHTML = `<i class="ph ph-check"></i>Ciudad cargada`;
};

const camPos = new THREE.Vector3();
let lastStream = 0, nearLoading = 0;
const pendingAdd: (() => void)[] = [];
const tileMaterials = new Map<string, THREE.Material>(); // materiales compartidos entre casillas (mismo pipeline, menos estado)
const reveal: { s: TileState; meshes: THREE.Object3D[] }[] = [];
const REVEAL_PER_FRAME = +(new URLSearchParams(location.search).get("reveal") ?? 12) || 1e9; // el primer dibujo de cada malla prepara sus recursos: se reparte entre fotogramas
function revealStep() {
  let n = REVEAL_PER_FRAME;
  while (reveal.length && n > 0) {
    const r = reveal[0];
    const m = r.meshes.shift();
    if (m) { m.visible = true; n--; continue; }
    reveal.shift(); r.s.ready = true;
  }
}
function streamTiles(now: number) {
  const add = pendingAdd.shift(); uploadFrame = !!add || reveal.length > 0; add?.(); // una casilla nueva por fotograma
  revealStep();
  if (!streaming || now - lastStream < 200) return;
  lastStream = now;
  camPos.copy(camera.position);
  const states = [...tileState.values()].map(s => ({ s, d: s.box.distanceToPoint(camPos) })).sort((a, b) => a.d - b.d);
  let nearCount = 0, visTris = 0;
  for (const { s, d } of states) {
    const wantNear = d < NEAR && nearCount < MAX_NEAR;
    if (wantNear) {
      nearCount++; s.lastUsed = now;
      if (!s.near && !s.loading && nearLoading < 2) {
        s.loading = true; nearLoading++;
        // Se precompila (pipelines) fuera del fotograma y se añade a la escena en la cola: como mucho una casilla por fotograma.
        (packed ? loadPackedTile(`/${index!.disc}/${s.t.near}`, renderer) : loadTile(`/${index!.disc}/${s.t.near}`, tileMaterials)).then(async o => {
          o.name = `near ${s.t.id}`;
          await renderer.compileAsync(o, camera, scene);
          // Las mallas se revelan poco a poco (presupuesto por fotograma); hasta entonces se ve la versión lejana.
          const meshes: THREE.Object3D[] = []; o.traverse(x => { if ((x as THREE.Mesh).isMesh) { x.visible = false; meshes.push(x); } });
          pendingAdd.push(() => { s.near = o; s.ready = false; city.add(o); reveal.push({ s, meshes }); });
        }).catch(() => {}).finally(() => { s.loading = false; nearLoading--; });
      }
    }
    const showNear = wantNear && !!s.near && !!s.ready;
    if (s.near) s.near.visible = showNear || (wantNear && !s.ready); // durante el revelado el grupo está visible, pero sus mallas se encienden poco a poco
    if (s.far) s.far.visible = !showNear;
    visTris += showNear ? s.t.tris : s.t.farTris;
    // Liberar detalle lejano para no agotar la memoria de vídeo
    if (s.near && s.ready && d > KEEP && now - s.lastUsed > 5000) { city.remove(s.near); dispose(s.near); s.near = undefined; s.ready = false; }
  }
  $("tri-count").textContent = Math.round(visTris).toLocaleString("es-ES");
  $("city-status").textContent = `${nearCount} casillas con detalle · ${tiles.length - nearCount} lejanas${nearLoading ? ` · cargando ${nearLoading}` : ""}`;
}
function dispose(o: THREE.Object3D) {
  o.traverse(x => {
    const m = x as THREE.Mesh;
    if (!m.isMesh) return;
    m.geometry.dispose();
    // materiales y texturas son compartidos entre casillas: solo se libera la geometría
  });
}

// ---------- Capas del juego: grupos de escenario (bloqueos) y zonas de garaje ----------
// El juego oculta estos objetos por defecto (ExcludeFlags 0x10) y los activa por carrera o progreso.
const layerGroups = { carrera: new THREE.Group(), candado: new THREE.Group(), puerta: new THREE.Group(), otro: new THREE.Group() };
const zoneLayer = new THREE.Group();
scene.add(...Object.values(layerGroups), zoneLayer);
const layerLoaded = new Set<string>();
async function setLayer(kind: keyof typeof layerGroups, on: boolean) {
  layerGroups[kind].visible = on;
  if (!on || layerLoaded.has(kind) || !index) return;
  layerLoaded.add(kind);
  const list = groups.filter(g => g.kind === kind);
  let i = 0;
  const worker = async () => { for (let g = list[i++]; g; g = list[i++]) { try { const o = await loadGlb(g.glb); o.name = g.name; o.userData = { ...o.userData, Grupo: g.name, Tipo: kind }; layerGroups[kind].add(o); } catch { /* grupo vacío */ } } };
  await Promise.all(Array.from({ length: 6 }, worker));
}
for (const kind of ["carrera", "candado", "puerta"] as const) {
  const box = $<HTMLInputElement>(`layer-${kind}`);
  box.addEventListener("change", () => setLayer(kind, box.checked));
}
const ZONE_COLORS = { safehouse: 0x4dff9a, carlot: 0x5cc8ff, customshop: 0xffb21a } as const;
const ZONE_LABEL = { safehouse: "Refugio", carlot: "Concesionario", customshop: "Taller" } as const;
function buildZones() {
  zoneLayer.clear();
  const list = $("zones"); list.innerHTML = "";
  for (const z of zones) {
    const c = ZONE_COLORS[z.zoneType];
    const ring = new THREE.Mesh(new THREE.RingGeometry(z.radius * 0.85, z.radius, 48), new THREE.MeshBasicMaterial({ color: c, transparent: true, opacity: 0.85, side: THREE.DoubleSide, depthWrite: false }));
    ring.position.set(z.position[0], z.position[1], z.position[2] + 0.15);
    const beam = new THREE.Mesh(new THREE.CylinderGeometry(0.25, 0.25, 60, 8), new THREE.MeshBasicMaterial({ color: c, transparent: true, opacity: 0.35, depthWrite: false }));
    beam.rotation.x = Math.PI / 2; beam.position.set(z.position[0], z.position[1], z.position[2] + 30);
    ring.userData = { Zona: z.collection.split("/").pop(), Tipo: ZONE_LABEL[z.zoneType], Radio: `${z.radius} m` };
    zoneLayer.add(ring, beam);
    const li = document.createElement("li"), b = document.createElement("button");
    b.innerHTML = `<span><i class="dot" style="background:#${c.toString(16).padStart(6, "0")}"></i>${ZONE_LABEL[z.zoneType]} ${z.collection.split("_").pop()}</span><small>${z.position[0].toFixed(0)}, ${z.position[1].toFixed(0)}</small>`;
    b.onclick = () => { const p = new THREE.Vector3(...z.position); controls.target.copy(p); camera.position.copy(p).add(new THREE.Vector3(35, -35, 25)); };
    li.append(b); list.append(li);
  }
  $("n-zonas").textContent = String(zones.length);
}
$<HTMLInputElement>("layer-zonas").addEventListener("change", e => (zoneLayer.visible = (e.target as HTMLInputElement).checked));

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
  const hit = ray.intersectObjects([content, city, zoneLayer, ...Object.values(layerGroups)], true)[0];
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
const slow: { t: number; stream: number; render: number; upload: boolean }[] = []; // fotogramas lentos (CPU), para depurar
let frames = 0, acc = 0;
// Resolución dinámica: mantiene 60 fps ajustando la densidad de píxeles según el tiempo de GPU de cada fotograma.
// Con vsync el intervalo entre fotogramas siempre es 16,7 ms, así que se mide cuánto tarda la GPU en terminar lo enviado.
const DPR_MAX = Math.min(devicePixelRatio, 2), DPR_MIN = 0.75;
let dpr = DPR_MAX, gpuEma = 8, lastAdjust = 0, probing = false, uploadFrame = false;
const gpuDevice = (renderer.backend as unknown as { device?: GPUDevice }).device;
function probeGpu() {
  if (!gpuDevice || probing) return;
  probing = true;
  const t0 = performance.now();
  const skip = uploadFrame; // los fotogramas que suben una casilla nueva son picos puntuales: no deciden la resolución
  gpuDevice.queue.onSubmittedWorkDone().then(() => { if (!skip) gpuEma = gpuEma * 0.85 + Math.min(performance.now() - t0, 30) * 0.15; probing = false; });
}
function adaptResolution(frameMs: number, now: number) {
  if (now - lastAdjust < 400) return;
  const cost = gpuEma;
  let next = dpr;
  if (cost > 14) next = Math.max(DPR_MIN, dpr - 0.1);
  else if (cost < 9 && dpr < DPR_MAX) next = Math.min(DPR_MAX, dpr + 0.1);
  if (next !== dpr) { dpr = +next.toFixed(2); renderer.setPixelRatio(dpr); resize(); lastAdjust = now; }
  $("dpr").textContent = `${Math.round((dpr / DPR_MAX) * 100)}%`;
}
renderer.setAnimationLoop(() => {
  const dt = Math.min(clock.getDelta(), 0.1);
  adaptResolution(dt * 1000, performance.now());
  const speed = (keys.has("ShiftLeft") ? 5 : 1) * dt * Math.max(8, camera.position.distanceTo(controls.target) * 0.8);
  const fwd = new THREE.Vector3().subVectors(controls.target, camera.position).setZ(0).normalize();
  const right = new THREE.Vector3().crossVectors(fwd, camera.up).normalize();
  const mv = new THREE.Vector3();
  if (keys.has("KeyW")) mv.add(fwd); if (keys.has("KeyS")) mv.sub(fwd);
  if (keys.has("KeyD")) mv.add(right); if (keys.has("KeyA")) mv.sub(right);
  if (keys.has("KeyE")) mv.z += 1; if (keys.has("KeyQ")) mv.z -= 1;
  if (mv.lengthSq()) { mv.normalize().multiplyScalar(speed); camera.position.add(mv); controls.target.add(mv); }
  controls.update();
  const tS = performance.now(); streamTiles(tS); const tStream = performance.now() - tS;
  // Niebla proporcional a la distancia: de lejos se ve la ciudad entera, de cerca hay profundidad.
  const dist = camera.position.distanceTo(controls.target);
  const fog = scene.fog as THREE.Fog;
  fog.near = Math.max(600, dist * 0.9); fog.far = Math.max(4000, dist * 3.5);
  const t = controls.target;
  $("cx").textContent = t.x.toFixed(1); $("cy").textContent = t.y.toFixed(1); $("cz").textContent = t.z.toFixed(1);
  frames++;
  if ((acc += dt) > 0.5) { $("fps").textContent = String(Math.round(frames / acc)); frames = 0; acc = 0; }
  const tR = performance.now(); renderer.render(scene, camera); const tRender = performance.now() - tR;
  if (tStream + tRender > 12) slow.push({ t: +performance.now().toFixed(0), stream: +tStream.toFixed(1), render: +tRender.toFixed(1), upload: uploadFrame });
  probeGpu();
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
  if (w.ok) { const wj = (await w.json()) as { sections: WorldSection[]; tiles?: Tile[]; groups?: Group[] }; world = wj.sections; tiles = wj.tiles ?? []; groups = wj.groups ?? [];
    for (const k of ["carrera", "candado", "puerta"] as const) $(`n-${k}`).textContent = String(groups.filter(g => g.kind === k).length);
    const zr = await fetch(`/${disc}/zones.json`); if (zr.ok) { zones = ((await zr.json()) as { zones: Zone[] }).zones; buildZones(); } buildBounds(); $("city-status").textContent = `${world.length} secciones · ${tiles.length} casillas`; if (!tiles.length) { btn.disabled = true; $("city-status").textContent = "Ejecuta el conversor en modo tiles"; } }
  else { btn.disabled = true; $("city-status").textContent = "Sin world.json: ejecuta el conversor en modo world"; }
  renderTree();
  const first = index.items.find(i => i.group === "Coches") ?? index.items[0];
  if (first) await open(first);
} catch {
  $("disc-tag").textContent = disc;
}
resize();

// Solo para depuración desde la consola (contadores de dibujo, escena).
/** Banco de pruebas: dibuja n fotogramas esperando a la GPU en cada uno (funciona aunque la pestaña no se vea). */
async function bench(n = 30, w = 1920, h = 1080, dpr = 1) {
  const prevDpr = renderer.getPixelRatio(); renderer.setPixelRatio(dpr);
  const prev = renderer.getSize(new THREE.Vector2());
  renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix();
  const device = (renderer.backend as unknown as { device?: GPUDevice }).device;
  const times: number[] = [];
  for (let i = 0; i < 6; i++) { renderer.render(scene, camera); if (device) await device.queue.onSubmittedWorkDone(); } // calentamiento tras cambiar resolución
  for (let i = 0; i < n; i++) {
    const t0 = performance.now();
    renderer.render(scene, camera);
    if (device) await device.queue.onSubmittedWorkDone();
    times.push(performance.now() - t0);
  }
  const info = { drawCalls: renderer.info.render.drawCalls, triangulos: renderer.info.render.triangles, resolucion: `${w}x${h}@${renderer.getPixelRatio()}` };
  renderer.setPixelRatio(prevDpr); renderer.setSize(prev.x, prev.y, false); camera.aspect = prev.x / Math.max(prev.y, 1); camera.updateProjectionMatrix();
  times.sort((a, b) => a - b);
  return { medianaMs: +times[n >> 1].toFixed(2), p95Ms: +times[Math.floor(n * 0.95)].toFixed(2), fpsEstimado: +(1000 / times[n >> 1]).toFixed(1), ...info };
}
(window as unknown as { __rockport: unknown }).__rockport = { renderer, scene, camera, controls, city, bench, frameCity, idle: () => nearLoading === 0 && pendingAdd.length === 0, slow };
