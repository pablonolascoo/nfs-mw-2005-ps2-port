import "@phosphor-icons/web/regular";
import "./style.css";
import * as THREE from "three/webgpu";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";

// Contrato de datos: map-data/<disco>/index.json (lo genera tools/src/cli/convert.ts).
interface Item { id: string; group: string; label: string; glb: string; tris: number; verts: number; source: string }
interface Index { disc: string; generated: string; upAxis: "Z"; items: Item[] }

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const stage = $("stage");

const renderer = new THREE.WebGPURenderer({ antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
stage.prepend(renderer.domElement);
await renderer.init();
$("backend").textContent = (renderer.backend as { isWebGPUBackend?: boolean }).isWebGPUBackend ? "WebGPU · Metal" : "WebGL 2";

// Decisión de diseño: el mundo del juego se trata como Z-arriba (hipótesis a validar con L2RA).
THREE.Object3D.DEFAULT_UP.set(0, 0, 1);
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0a0b09);
scene.fog = new THREE.Fog(0x0a0b09, 400, 4000);
const camera = new THREE.PerspectiveCamera(55, 1, 0.05, 20000);
camera.up.set(0, 0, 1);
camera.position.set(6, -6, 4);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;

scene.add(new THREE.HemisphereLight(0xdfe8ff, 0x2a2416, 1.4));
const sun = new THREE.DirectionalLight(0xffe2b0, 2.2);
sun.position.set(30, -20, 50);
scene.add(sun);
const grid = new THREE.GridHelper(200, 200, 0x3a3020, 0x1a1d16);
grid.rotation.x = Math.PI / 2;
scene.add(grid);

const content = new THREE.Group();
scene.add(content);
const loader = new GLTFLoader();
let index: Index | null = null;
let current: Item | null = null;
let selected: THREE.Mesh | null = null;
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
    for (const it of items) {
      const li = document.createElement("li");
      const b = document.createElement("button");
      b.innerHTML = `<span>${it.label}</span><small>${(it.tris / 1000).toFixed(1)}k</small>`;
      b.setAttribute("aria-current", String(current?.id === it.id));
      b.onclick = () => load(it);
      li.append(b);
      tree.append(li);
    }
  }
}
$<HTMLInputElement>("filter").addEventListener("input", e => renderTree((e.target as HTMLInputElement).value));

async function load(it: Item) {
  current = it;
  renderTree($<HTMLInputElement>("filter").value);
  select(null);
  content.clear();
  const gltf = await loader.loadAsync(`/${index!.disc}/${it.glb}`);
  // El GLB es Y-arriba (estándar glTF); el visor trabaja en coordenadas del juego (Z-arriba).
  gltf.scene.rotation.x = Math.PI / 2;
  content.add(gltf.scene);
  let tris = 0;
  gltf.scene.traverse(o => { const m = o as THREE.Mesh; if (m.isMesh) tris += (m.geometry.index?.count ?? m.geometry.attributes.position.count) / 3; });
  $("tri-count").textContent = Math.round(tris).toLocaleString("es-ES");
  frame(gltf.scene);
}

function frame(obj: THREE.Object3D) {
  const box = new THREE.Box3().setFromObject(obj);
  if (box.isEmpty()) return;
  const c = box.getCenter(new THREE.Vector3()), r = box.getSize(new THREE.Vector3()).length() * 0.9 || 1;
  controls.target.copy(c);
  camera.position.copy(c).add(new THREE.Vector3(r, -r, r * 0.6));
  camera.near = r / 500; camera.far = r * 200; camera.updateProjectionMatrix();
}

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
  const hit = ray.intersectObject(content, true)[0];
  select((hit?.object as THREE.Mesh) ?? null, hit?.point);
});

function select(m: THREE.Mesh | null, point?: THREE.Vector3) {
  selected = m;
  selBox.visible = !!m;
  const dl = $("inspector");
  if (!m) { dl.innerHTML = `<dt>Selección</dt><dd class="muted">Haz clic en una pieza</dd>`; return; }
  selBox.setFromObject(m);
  const ex = (m.userData ?? {}) as Record<string, unknown>;
  const g = m.geometry;
  const rows: [string, string][] = [
    ["Pieza", `<span class="hl">${m.name || "—"}</span>`],
    ["Vértices", g.attributes.position.count.toLocaleString("es-ES")],
    ["Triángulos", Math.round((g.index?.count ?? g.attributes.position.count) / 3).toLocaleString("es-ES")],
    ["Material", (m.material as THREE.Material).name || "—"],
    ...Object.entries(ex).map(([k, v]) => [k, String(v)] as [string, string]),
  ];
  if (point) rows.push(["Punto", `${point.x.toFixed(2)}, ${point.y.toFixed(2)}, ${point.z.toFixed(2)}`]);
  dl.innerHTML = rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("");
}

// ---------- Marcadores (anotaciones de diseño) ----------
const markers: { id: number; source: string | null; pos: [number, number, number]; note: string }[] = [];
function addMarker() {
  const p = controls.target.clone();
  const m = { id: markers.length + 1, source: current?.id ?? null, pos: [+p.x.toFixed(2), +p.y.toFixed(2), +p.z.toFixed(2)] as [number, number, number], note: "" };
  markers.push(m);
  const pin = new THREE.Mesh(new THREE.ConeGeometry(0.15, 0.5, 4), new THREE.MeshBasicMaterial({ color: 0xffb21a }));
  pin.rotation.x = -Math.PI / 2; pin.position.copy(p).add(new THREE.Vector3(0, 0, 0.25));
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
  if (e.code === "KeyF") frame(selected ?? content);
});
addEventListener("keyup", e => keys.delete(e.code));
const clock = new THREE.Clock();
let frames = 0, acc = 0;
renderer.setAnimationLoop(() => {
  const dt = Math.min(clock.getDelta(), 0.1);
  const speed = (keys.has("ShiftLeft") ? 60 : 12) * dt * Math.max(1, camera.position.distanceTo(controls.target) / 20);
  const fwd = new THREE.Vector3().subVectors(controls.target, camera.position).setZ(0).normalize();
  const right = new THREE.Vector3().crossVectors(fwd, camera.up).normalize();
  const mv = new THREE.Vector3();
  if (keys.has("KeyW")) mv.add(fwd); if (keys.has("KeyS")) mv.sub(fwd);
  if (keys.has("KeyD")) mv.add(right); if (keys.has("KeyA")) mv.sub(right);
  if (keys.has("KeyE")) mv.z += 1; if (keys.has("KeyQ")) mv.z -= 1;
  if (mv.lengthSq()) { mv.normalize().multiplyScalar(speed); camera.position.add(mv); controls.target.add(mv); }
  controls.update();
  const t = controls.target;
  $("cx").textContent = t.x.toFixed(1); $("cy").textContent = t.y.toFixed(1); $("cz").textContent = t.z.toFixed(1);
  if ((acc += dt) > 0.5) { $("fps").textContent = String(Math.round(frames / acc)); frames = 0; acc = 0; }
  frames++;
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
  renderTree();
  if (index.items[0]) await load(index.items[0]);
} catch {
  $("disc-tag").textContent = disc;
}
resize();
