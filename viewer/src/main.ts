import "@phosphor-icons/web/regular";
import "./style.css";
import * as THREE from "three/webgpu";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { loadTile, loadPackedTile } from "./tile-loader";
import { Driver, makeCollider, carHolder } from "./drive";
import { buildRoads, type RoadsFile } from "./roads";
import { INTERIOR_FOR, analyzeInterior, RollerDoor, cutout, cutoutState, insideCutout, clipToBox, garageMod, mods, type GarageInfo } from "./garage";

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
// Cielo: el juego lo genera al vuelo (sus texturas no están en el disco). Degradado de tarde de Rockport.
const SKY = 0x8fa3ad;
scene.fog = new THREE.Fog(SKY, 1500, 9000);
const sky = await (async () => {
  const { positionWorld, cameraPosition, mix, color, smoothstep } = await import("three/tsl");
  const skyMat = new THREE.MeshBasicNodeMaterial({ side: THREE.BackSide, depthWrite: false, fog: false });
  const h = positionWorld.sub(cameraPosition).normalize().z;
  skyMat.colorNode = mix(mix(color(0x8fa3ad), color(0xd9c7a2), smoothstep(0.25, -0.02, h)), color(0x3d5a73), smoothstep(0.05, 0.7, h));
  const sky = new THREE.Mesh(new THREE.SphereGeometry(1, 32, 16), skyMat);
  sky.frustumCulled = false; sky.renderOrder = -10;
  scene.add(sky);
  return sky;
})();
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

// Agua: los modelos TRN_Ocean_* solo cubren franjas de costa a z = 0; el cuerpo de agua no es geometría del mapa.
// Hipótesis [H]: el juego dibuja un plano al nivel del mar. Aquí, plano de 40 km con ondulación procedural.
{
  const { positionWorld, sin, time, color, mix } = await import("three/tsl");
  const waterMat = new THREE.MeshBasicNodeMaterial({ transparent: true, depthWrite: false });
  const w = sin(positionWorld.x.mul(0.05).add(time.mul(0.8))).mul(sin(positionWorld.y.mul(0.043).sub(time.mul(0.6))));
  waterMat.colorNode = mix(color(0x22383f), color(0x3b5a62), w.mul(0.5).add(0.5));
  waterMat.opacity = 0.92;
  const water = new THREE.Mesh(new THREE.PlaneGeometry(40000, 40000), waterMat);
  water.position.set(2200, 1800, -0.2); water.renderOrder = 1; water.name = "agua (plano del mar)";
  scene.add(water);
}
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
let garageInfo: GarageInfo[] = [];
let carAttribs: Record<string, { tires: number[][] }> = {};
/** Color de la pintura del coche del jugador (?pintura=1f6fd1). El BMW M3 GTR de la historia es plata y azul. */
let playerPaint = "#" + (new URLSearchParams(location.search).get("pintura") ?? "aeb7c2").replace(/^#/, "");
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
  let obj = await loadGlb(it.glb);
  // Coches: 4 ruedas (TireOffsets) y pintura, igual que al conducir
  const carName = it.id.startsWith("car:") ? it.id.slice(4).toLowerCase() : "";
  if (carAttribs[carName]) obj = carHolder(obj, carAttribs[carName].tires, playerPaint).holder;
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
$("n-mods").textContent = mods.length ? mods.map(m => `${m.name} ${m.version}`).join(" · ") : "ninguno";
$<HTMLInputElement>("layer-zonas").addEventListener("change", e => (zoneLayer.visible = (e.target as HTMLInputElement).checked));
// Red de carreteras: se descarga (≈2 MB) solo la primera vez que se activa
let roadLayer: THREE.Group | null = null, roadLoading = false;
$<HTMLInputElement>("layer-carreteras").addEventListener("change", async e => {
  const on = (e.target as HTMLInputElement).checked;
  $("roads-legend").hidden = !on;
  if (roadLayer) { roadLayer.visible = on; return; }
  if (!on || roadLoading) return;
  roadLoading = true; $("n-carreteras").textContent = "cargando…";
  const r = await fetch(`/${disc}/roads.json`);
  if (!r.ok) { $("n-carreteras").textContent = "falta roads.json (bun src/cli/roads.ts)"; roadLoading = false; return; }
  const data = (await r.json()) as RoadsFile;
  roadLayer = buildRoads(data); scene.add(roadLayer);
  roadLayer.visible = $<HTMLInputElement>("layer-carreteras").checked;
  $("n-carreteras").textContent = `${data.nodes.length} nodos · ${data.segments.length} tramos`;
});

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

// ---------- Conducción ----------
const driver = new Driver();
let driving = false;
scene.add(driver.root);
driver.root.visible = false;
const pick = $<HTMLSelectElement>("car-pick");
async function loadCarInto(name: string) {
  const it = index?.items.find(i => i.id === `car:${name}`);
  if (it) driver.setModel(await loadGlb(it.glb), carAttribs[name.toLowerCase()]?.tires, playerPaint);
}
/** Busca suelo desde muy arriba (para aparecer). */
function groundFromSky(x: number, y: number) {
  const r = new THREE.Raycaster(new THREE.Vector3(x, y, 2000), new THREE.Vector3(0, 0, -1), 0, 4000);
  r.firstHitOnly = true;
  const hit = r.intersectObjects(driver.colliders, false)[0];
  return hit ? hit.point.z : null;
}
const pendingBvh: THREE.Mesh[] = [];
let lastColl = 0;
/** Colisionadores: casillas con detalle cerca del coche; el BVH se construye de una en una (sin tirones). */
function refreshColliders(now: number) {
  const m = pendingBvh.shift(); if (m) makeCollider(m);
  if (now - lastColl < 300) return; lastColl = now;
  const p = driver.root.position, list: THREE.Mesh[] = [];
  for (const s of tileState.values()) {
    if (!s.near || !s.ready || s.box.distanceToPoint(p) > 260) continue;
    s.near.traverse(o => { const mesh = o as THREE.Mesh; if (!mesh.isMesh || !/opaque|mask50/.test(String((mesh.material as THREE.Material).name))) return;
      if ((mesh.geometry as THREE.BufferGeometry & { boundsTree?: unknown }).boundsTree) list.push(mesh); }); // el BVH llega hecho desde el hilo de carga
  }
  driver.colliders = list;
}
async function startDriving() {
  if (!streaming) { btn.click(); await new Promise<void>(r => { const t = setInterval(() => { if (streaming) { clearInterval(t); r(); } }, 200); }); }
  await loadCarInto(pick.value);
  // Aparece junto al refugio 1 si no hay otra referencia; si la cámara mira a otro sitio, allí.
  const t = controls.target.clone();
  const zone = zones.find(z => z.collection.endsWith("safehouse_1"));
  const start = t.distanceTo(new THREE.Vector3()) < 10 && zone?.respawn ? new THREE.Vector3(...zone.respawn.position) : t;
  driver.root.position.copy(start);
  controls.enabled = false; driving = true; driver.root.visible = true;
  $("speedo").hidden = false; $("hint-drive").hidden = false; $("hint-fly").hidden = true;
  camera.position.set(start.x - 8, start.y, start.z + 4);
  // Espera a que haya suelo con colisión cargado y apoya el coche
  for (let i = 0; i < 100; i++) { refreshColliders(performance.now() + i * 400); const z = groundFromSky(start.x, start.y); if (z !== null) { start.z = z; break; } await new Promise(r => setTimeout(r, 100)); }
  driver.place(start, zone?.respawn ? THREE.MathUtils.degToRad(zone.respawn.rotation) : 0);
}
function stopDriving() {
  driving = false; controls.enabled = true; driver.root.visible = false;
  $("speedo").hidden = true; $("hint-drive").hidden = true; $("hint-fly").hidden = false;
  controls.target.copy(driver.root.position); controls.update();
}
$("drive").onclick = () => (driving ? stopDriving() : startDriving());

// ---------- Garajes sin pantallas de carga ----------
// Fases: cerrada → abriendo (E) → dentro (la puerta se cierra) → aparcado → saliendo (E) → cerrada.
interface Placed { zone: Zone; obj: THREE.Object3D; door: RollerDoor; spot: THREE.Mesh; meshes: THREE.Mesh[]; box: THREE.Matrix4; phase: "cerrada" | "abierta" | "dentro" | "aparcado" | "saliendo"; t: number }
const interiorCache = new Map<string, Promise<{ obj: THREE.Object3D; layout: ReturnType<typeof analyzeInterior> }>>();
let garage: Placed | null = null;
const ZONE_NAME = { safehouse: "refugio", carlot: "concesionario", customshop: "taller" } as const;
function interiorFor(name: string) {
  let p = interiorCache.get(name);
  if (!p) { const it = index!.items.find(i => i.id === `int:${name}`)!; p = loadGlb(it.glb).then(obj => { const holder = new THREE.Group(); holder.add(obj); return { obj: holder, layout: analyzeInterior(holder) }; }); interiorCache.set(name, p); }
  return p;
}
let placing: Zone | null = null; // candado: una sola colocación a la vez (la función es asíncrona)
async function placeGarage(z: Zone) {
  if (placing || garage?.zone === z) return;
  placing = z;
  try { await placeGarageNow(z); } finally { placing = null; }
}
async function placeGarageNow(z: Zone) {
  const mod = garageMod(z.collection);
  const { obj, layout } = await interiorFor(mod.interior ?? INTERIOR_FOR[z.zoneType]);
  if (garage?.zone === z) return;
  if (garage) { scene.remove(garage.obj, garage.door.group, garage.spot, ...((garage as unknown as { display?: THREE.Object3D[] }).display ?? [])); }
  const info = garageInfo.find(g => g.collection === z.collection);
  const out = new THREE.Vector2(...((info?.out ?? [1, 0]) as [number, number])).normalize();
  const yawOut = Math.atan2(out.y, out.x), qOut = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), yawOut);
  const ground = info?.door?.[2] ?? z.position[2];
  const doorP = new THREE.Vector3(...((info?.door ?? z.position) as [number, number, number])).setZ(ground);
  const [doorW, doorH] = info?.doorSize ?? [6, 4];
  // Volumen interior del edificio (caja orientada con la puerta); sin edificio identificado, 16×10×5 m detrás de la puerta.
  const b = info?.building;
  // El volumen va de la puerta hacia dentro hasta la cara trasera del edificio (la caja del modelo puede incluir más cosas
  // y la puerta no siempre está en su cara), centrado lateralmente en la puerta.
  const outV3 = new THREE.Vector3(out.x, out.y, 0);
  const behind = b ? new THREE.Vector3(b.center[0] - doorP.x, b.center[1] - doorP.y, 0).dot(outV3.clone().negate()) + b.along / 2 : 16;
  const depth = Math.max(8, Math.min(behind, 40)), width = b ? Math.min(b.across, 30) : 10, height = b ? Math.max(4, Math.min(b.height, 9)) : 5;
  const innerCenter = doorP.clone().addScaledVector(outV3, -depth / 2);
  // Desde 15 cm sobre el suelo (el suelo del edificio se conserva) hasta 0,8 m bajo el tejado; 0,8 m de margen en paredes.
  const inner = new THREE.Matrix4().compose(innerCenter.clone().setZ(ground + 0.15 + (height - 0.95) / 2), qOut, new THREE.Vector3(depth / 2 - 0.6, width / 2 - 0.8, (height - 0.95) / 2));
  // Pasillo = exactamente el hueco de la puerta original (se descarta para que se vea la persiana nueva y lo de dentro)
  const corridor = new THREE.Matrix4().compose(doorP.clone().setZ(ground + doorH / 2), qOut, new THREE.Vector3(2.5, doorW / 2 + 0.15, doorH / 2 + 0.1));
  // Interior: lado abierto hacia la puerta, plaza (su origen) dentro del edificio, suelo a la altura de la calle; recortado al edificio
  const rot = yawOut - Math.atan2(layout.openDir.y, layout.openDir.x);
  const spotDist = Math.min(Math.max(depth * 0.5, 7), layout.depth, depth - 3);
  const origin = doorP.clone().sub(new THREE.Vector3(out.x, out.y, 0).multiplyScalar(spotDist)).setZ(ground - layout.floorZ);
  obj.position.copy(origin); obj.rotation.set(0, 0, rot); obj.visible = false; obj.updateMatrixWorld(true);
  // El interior se recorta con una caja que baja hasta 0,6 m bajo el suelo (para conservar su propio suelo).
  const interiorBox = new THREE.Matrix4().compose(innerCenter.clone().setZ(ground - 0.6 + (height + 0.6) / 2), qOut, new THREE.Vector3(depth / 2 - 0.4, width / 2 - 0.5, (height + 0.6) / 2));
  clipToBox(obj, interiorBox.clone().invert(), new THREE.Color(mod.tint ?? "#ffffff"));
  const meshes: THREE.Mesh[] = []; obj.traverse(o => { if ((o as THREE.Mesh).isMesh) meshes.push(o as THREE.Mesh); });
  const map = info?.doorTexture ? await new THREE.TextureLoader().loadAsync(`/${index!.disc}/textures/${info.doorTexture}.png`).then(t => { t.colorSpace = THREE.SRGBColorSpace; return t; }).catch(() => undefined) : undefined;
  const door = new RollerDoor(doorW, doorH, map);
  door.group.position.copy(doorP).addScaledVector(new THREE.Vector3(out.x, out.y, 0), 0.05); door.group.rotation.z = yawOut;
  const spot = new THREE.Mesh(new THREE.RingGeometry(2.0, 2.3, 4, 1), new THREE.MeshBasicMaterial({ color: 0x4dff9a, transparent: true, opacity: 0.8, depthWrite: false }));
  spot.position.copy(doorP).sub(new THREE.Vector3(out.x, out.y, 0).multiplyScalar(spotDist)).setZ(ground + 0.06); spot.rotation.z = yawOut + Math.PI / 4; spot.visible = false;
  scene.add(obj, door.group, spot);
  // Plaza alcanzable: se mide hasta la pared del fondo del interior (dentro del edificio) y se deja margen
  {
    const r = new THREE.Raycaster(doorP.clone().setZ(ground + 1).addScaledVector(new THREE.Vector3(out.x, out.y, 0), -1.5), new THREE.Vector3(-out.x, -out.y, 0), 0, 60);
    const innerInv = inner.clone().invert();
    const hit = r.intersectObjects(meshes, false).find(h => { const l = h.point.clone().applyMatrix4(innerInv); return Math.abs(l.x) <= 1 && Math.abs(l.y) <= 1; });
    const reach = hit ? hit.distance + 1.5 : spotDist + 3;
    const d = Math.max(5.5, Math.min(spotDist, reach - 3.2));
    spot.position.copy(doorP).sub(new THREE.Vector3(out.x, out.y, 0).multiplyScalar(d)).setZ(ground + 0.06);
  }
  // Coches de exposición del mod, colocados respecto a la plaza (x = hacia la puerta, y = izquierda)
  const display: THREE.Object3D[] = [];
  const left = new THREE.Vector3(-out.y, out.x, 0);
  for (const d of mod.display ?? []) {
    const it = index!.items.find(i => i.id === `car:${d.car}`); if (!it) continue;
    const { holder } = carHolder(await loadGlb(it.glb), carAttribs[d.car.toLowerCase()]?.tires, d.paint ?? "#20242c");
    holder.position.copy(spot.position).addScaledVector(outV3, d.offset[0]).addScaledVector(left, d.offset[1]).setZ(ground);
    holder.rotation.z = yawOut + THREE.MathUtils.degToRad(d.yaw ?? 0);
    holder.visible = false; display.push(holder); scene.add(holder);
  }
  garage = { zone: z, obj, door, spot, meshes, box: corridor, phase: "cerrada", t: 0 };
  (garage as unknown as { display: THREE.Object3D[]; name?: string }).display = display;
  (garage as unknown as { name?: string }).name = mod.name;
  (garage as unknown as { inner: THREE.Matrix4; innerInv: THREE.Matrix4 }).inner = inner;
  (garage as unknown as { innerInv: THREE.Matrix4 }).innerInv = interiorBox.clone().invert();
  (garage as unknown as { info: unknown }).info = { depth, width, height, spotDist, doorW, doorH, source: info?.source };
}
function setCutout(on: boolean) {
  if (!garage) return;
  cutout.enabled.value = on ? 1 : 0;
  // Se recorta el hueco de la puerta y el volumen interior del edificio (con margen: paredes exteriores y tejado se quedan).
  cutoutState.on = on; cutoutState.inv.copy(garage.box).invert(); cutoutState.inv2.copy((garage as unknown as { inner: THREE.Matrix4 }).inner).invert();
  cutout.worldToBox.value.copy(cutoutState.inv); cutout.worldToBox2.value.copy(cutoutState.inv2);
  garage.obj.visible = on; garage.spot.visible = on;
  for (const d of (garage as unknown as { display?: THREE.Object3D[] }).display ?? []) d.visible = on;
}
// Colisiones: se atraviesa el hueco de la puerta; del interior solo cuenta lo que queda dentro del edificio.
driver.ignore = (pt, obj) => {
  if (insideCutout(pt) && !garage?.meshes.includes(obj as THREE.Mesh)) return true; // (el suelo queda fuera del recorte: 15 cm)
  if (garage?.meshes.includes(obj as THREE.Mesh)) { const l = pt.clone().applyMatrix4((garage as unknown as { innerInv: THREE.Matrix4 }).innerInv); return Math.abs(l.x) > 1 || Math.abs(l.y) > 1 || Math.abs(l.z) > 1; }
  return false;
};
function updateGarage(dt: number) {
  const prompt = $("prompt");
  if (!driving) { prompt.hidden = true; return; }
  const p = driver.root.position;
  // Precarga y colocación del garaje más cercano (a menos de 150 m)
  const near = zones.map(z => ({ z, d: Math.hypot(z.position[0] - p.x, z.position[1] - p.y) })).sort((a, b) => a.d - b.d)[0];
  if (near && near.d < 150 && (!garage || (garage.zone !== near.z && garage.phase === "cerrada"))) placeGarage(near.z);
  if (!garage) { prompt.hidden = true; return; }
  garage.door.update(dt);
  const zp = new THREE.Vector3(...garage.zone.position);
  const gi = garageInfo.find(g => g.collection === garage!.zone.collection);
  const doorXY = gi ? new THREE.Vector3(gi.door[0], gi.door[1], 0) : zp;
  const atGate = Math.hypot(zp.x - p.x, zp.y - p.y) < garage.zone.radius + 6 || Math.hypot(doorXY.x - p.x, doorXY.y - p.y) < 12;
  // "Dentro" = ha cruzado el plano de la puerta hacia el edificio
  const info = garageInfo.find(g => g.collection === garage!.zone.collection);
  const outV = new THREE.Vector3(...((info?.out ?? [1, 0]) as [number, number]), 0);
  const doorV = new THREE.Vector3(...((info?.door ?? garage.zone.position) as [number, number, number]));
  const pastDoor = p.clone().sub(doorV).dot(outV);
  const inside = pastDoor < -2.5;
  // La puerta bloquea mientras no esté abierta del todo (y el edificio también fuera del pasillo)
  if (garage.door.open < 0.95 && pastDoor < 1.2 && pastDoor > -1.5 && driver.speed > 0) {
    const fwd = new THREE.Vector3(Math.cos(driver.yaw), Math.sin(driver.yaw), 0);
    if (fwd.dot(outV) < 0) { p.addScaledVector(outV, 1.2 - pastDoor); driver.speed = 0; }
  }
  const modName = (garage as unknown as { name?: string }).name;
  const label = modName ? modName : `${ZONE_NAME[garage.zone.zoneType]}`;
  const article = modName ? "" : "al ";
  if (garage.phase === "cerrada") {
    prompt.hidden = !(atGate && driver.kmh < 25);
    prompt.innerHTML = modName ? `<kbd>E</kbd>Entrar · ${label}` : `<kbd>E</kbd>Entrar ${article}${label}`;
  } else if (garage.phase === "abierta") {
    prompt.hidden = false; prompt.innerHTML = `Entra con el coche`;
    if (pastDoor < -4) { garage.phase = "dentro"; garage.t = 0; }
    else if (!atGate && garage.door.open >= 1) { garage.door.target = 0; garage.phase = "saliendo"; }
  } else if (garage.phase === "dentro") {
    const parked = Math.hypot(garage.spot.position.x - p.x, garage.spot.position.y - p.y) < 4 && driver.kmh < 3;
    prompt.hidden = false; prompt.innerHTML = `Aparca en la plaza`;
    if (parked) { garage.phase = "aparcado"; garage.t = 0; garage.door.target = 0; (garage.spot.material as THREE.MeshBasicMaterial).color.set(0xffb21a); }
  } else if (garage.phase === "aparcado") {
    // Vista de exposición: la cámara pasa sin cortes a girar alrededor del coche (como el garaje del juego)
    garage.t += dt;
    prompt.hidden = false; prompt.innerHTML = `${modName ? label : `En el ${label}`} · <kbd>E</kbd>Salir`;
  } else if (garage.phase === "saliendo") {
    prompt.hidden = true;
    if (pastDoor > 3 && garage.door.open <= 0.001) { setCutout(false); garage.phase = "cerrada"; }
    else if (pastDoor > 3 && garage.door.open >= 1) garage.door.target = 0; // ya fuera: se cierra detrás
  }
  // colisiones del interior mientras está abierto
  if (garage.obj.visible) for (const m of garage.meshes) if (!driver.colliders.includes(m)) driver.colliders.push(m);
}
/** Cámara de exposición alrededor del coche aparcado (transición suave desde la de persecución). */
function showcase(dt: number) {
  const c = driver.root.position, a = (garage!.t * 0.25) + driver.yaw + Math.PI * 0.75;
  const want = new THREE.Vector3(c.x + Math.cos(a) * 6.2, c.y + Math.sin(a) * 6.2, c.z + 2.1);
  const k = Math.min(1, dt * (garage!.t < 1.5 ? 2.5 : 4));
  camera.position.lerp(want, k);
  controls.target.lerp(c.clone().setZ(c.z + 0.8), k);
  camera.lookAt(controls.target);
}
function garageAction() {
  if (!garage) return;
  if (garage.phase === "cerrada" && !$("prompt").hidden) { setCutout(true); garage.door.target = 1; garage.phase = "abierta"; }
  else if (garage.phase === "dentro" || garage.phase === "aparcado") { garage.door.target = 1; garage.phase = "saliendo"; }
  else if (garage.phase === "saliendo") garage.door.target = 1;
}

// ---------- Vuelo libre ----------
const keys = new Set<string>();
addEventListener("keydown", e => {
  if ((e.target as HTMLElement).tagName === "INPUT") return;
  keys.add(e.code);
  if (driving) {
    if (e.code === "Escape") stopDriving();
    if (e.code === "KeyE") garageAction();
    if (e.code === "KeyR") { const p = driver.root.position, z = groundFromSky(p.x, p.y); if (z !== null) driver.place(new THREE.Vector3(p.x, p.y, z), driver.yaw); }
    if (["Space", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(e.code)) e.preventDefault();
    return;
  }
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
  if (driving) {
    refreshColliders(performance.now());
    const k = (a: string, b: string) => (keys.has(a) || keys.has(b) ? 1 : 0);
    const parkedNow = garage?.phase === "aparcado";
    if (!parkedNow) driver.update(dt, { throttle: k("KeyW", "ArrowUp"), brake: k("KeyS", "ArrowDown"), steer: k("KeyA", "ArrowLeft") - k("KeyD", "ArrowRight"), handbrake: keys.has("Space") });
    else driver.speed = 0; // aparcado: inmóvil (el freno con el coche parado sería marcha atrás)
    if (garage?.phase === "aparcado") showcase(dt); else driver.chase(camera, controls.target, dt);
    updateGarage(dt);
    $("kmh").textContent = String(Math.round(driver.kmh));
  } else {
    const mv = new THREE.Vector3();
    if (keys.has("KeyW")) mv.add(fwd); if (keys.has("KeyS")) mv.sub(fwd);
    if (keys.has("KeyD")) mv.add(right); if (keys.has("KeyA")) mv.sub(right);
    if (keys.has("KeyE")) mv.z += 1; if (keys.has("KeyQ")) mv.z -= 1;
    if (mv.lengthSq()) { mv.normalize().multiplyScalar(speed); camera.position.add(mv); controls.target.add(mv); }
    controls.update();
  }
  sky.position.copy(camera.position); sky.scale.setScalar(camera.far * 0.9);
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
    const zr = await fetch(`/${disc}/zones.json`); if (zr.ok) { zones = ((await zr.json()) as { zones: Zone[] }).zones; buildZones(); }
    const gr = await fetch(`/${disc}/garages.json`); if (gr.ok) garageInfo = ((await gr.json()) as { garages: GarageInfo[] }).garages;
    const cr = await fetch(`/${disc}/cars.json`); if (cr.ok) carAttribs = ((await cr.json()) as { cars: typeof carAttribs }).cars; buildBounds(); $("city-status").textContent = `${world.length} secciones · ${tiles.length} casillas`; if (!tiles.length) { btn.disabled = true; $("city-status").textContent = "Ejecuta el conversor en modo tiles"; } }
  else { btn.disabled = true; $("city-status").textContent = "Sin world.json: ejecuta el conversor en modo world"; }
  for (const it of index.items.filter(i => i.group === "Coches")) pick.append(new Option(it.label, it.label, it.label === "BMWM3GTRE46", it.label === "BMWM3GTRE46"));
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
(window as unknown as { __rockport: unknown }).__rockport = { renderer, scene, camera, controls, city, bench, frameCity, idle: () => nearLoading === 0 && pendingAdd.length === 0, slow, cutout, driver, startDriving, keys, garage: () => garage, garageAction, zones: () => zones };
