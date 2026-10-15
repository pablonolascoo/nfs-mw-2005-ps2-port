// Garajes sin pantallas de carga: el interior del menú (FRONTEND\PLATFORMS\*.BIN) se coloca de verdad en el mundo,
// detrás de la zona del juego (menu_gate_*), con una puerta enrollable y un recorte que vacía el edificio.
// En el juego original la zona llama a EQuitToFE(GARAGETYPE_*) y sale del mundo; esto es una ampliación propia.
import * as THREE from "three/webgpu";
import { MeshBVH } from "three-mesh-bvh";
import { uniform, positionWorld, Discard, If, vec4, Fn, texture as tslTexture, uv } from "three/tsl";

export interface Zone { collection: string; zoneType: "safehouse" | "carlot" | "customshop"; position: [number, number, number]; radius: number; respawn?: { position: [number, number, number]; rotation: number } }
export const INTERIOR_FOR: Record<Zone["zoneType"], string> = { safehouse: "CAREER_SAFEHOUSE", carlot: "CAR_LOT", customshop: "CUSTOMIZATION_SHOP" };

/** Recorte global: los materiales del mundo descartan lo que cae dentro de esta caja (en coordenadas de la caja). */
export const cutout = { enabled: uniform(0), worldToBox: uniform(new THREE.Matrix4()), worldToBox2: uniform(new THREE.Matrix4()) };
export function applyCutout(mat: THREE.NodeMaterial) {
  const prev = mat.colorNode!;
  mat.colorNode = Fn(() => {
    const a = cutout.worldToBox.mul(vec4(positionWorld, 1)), b = cutout.worldToBox2.mul(vec4(positionWorld, 1));
    const inA = a.x.abs().lessThan(1).and(a.y.abs().lessThan(1)).and(a.z.abs().lessThan(1));
    const inB = b.x.abs().lessThan(1).and(b.y.abs().lessThan(1)).and(b.z.abs().lessThan(1));
    If(cutout.enabled.greaterThan(0.5).and(inA.or(inB)), () => { Discard(); });
    return prev;
  })();
}
/** ¿Está un punto dentro del recorte? (para ignorar colisiones del edificio original). */
export const cutoutState = { on: false, inv: new THREE.Matrix4(), inv2: new THREE.Matrix4() };
const inBox = (p: THREE.Vector3, inv: THREE.Matrix4) => { const l = p.clone().applyMatrix4(inv); return Math.abs(l.x) < 1 && Math.abs(l.y) < 1 && Math.abs(l.z) < 1; };
export function insideCutout(p: THREE.Vector3) { return cutoutState.on && (inBox(p, cutoutState.inv) || inBox(p, cutoutState.inv2)); }
/** Garaje calculado por tools/src/cli/garages.ts. */
export interface GarageInfo { collection: string; zoneType: Zone["zoneType"]; zone: number[]; radius: number; building: { name: string; center: number[]; along: number; across: number; height: number; floor: number } | null; out: number[]; door: number[]; doorSize?: [number, number]; doorTexture?: string; source: string }
/** Planos que dejan solo lo que queda dentro de una caja (para que el interior no asome fuera del edificio). */
export function boxClipPlanes(M: THREE.Matrix4) {
  const c = new THREE.Vector3(), q = new THREE.Quaternion(), s = new THREE.Vector3(); M.decompose(c, q, s);
  const axes = [new THREE.Vector3(1, 0, 0), new THREE.Vector3(0, 1, 0), new THREE.Vector3(0, 0, 1)].map(a => a.applyQuaternion(q));
  const planes: THREE.Plane[] = [];
  axes.forEach((a, i) => { const h = [s.x, s.y, s.z][i]; planes.push(new THREE.Plane(a.clone().negate(), a.dot(c) + h), new THREE.Plane(a.clone(), -a.dot(c) + h)); });
  return planes;
}

/** Quita el fondo del frontend que no cabe dentro de un edificio: la cúpula del cielo (…_SKY) y la caja exterior del refugio
 *  (CRIB1_OFFICE_TEXTURE), ambas del sólido BACKDROP_CURRGEN. Desde que el conversor lee bien las posiciones en float (V4-32)
 *  esas piezas miden cientos de metros y estropeaban el análisis por rayos (doc 07 §2). */
export function stripBackdrop(obj: THREE.Object3D) {
  const drop: THREE.Object3D[] = [];
  obj.traverse(o => {
    const m = o as THREE.Mesh; if (!m.isMesh) return;
    let inBackdrop = false; for (let q: THREE.Object3D | null = m; q; q = q.parent) if (q.name === "BACKDROP_CURRGEN") inBackdrop = true;
    const mat = (Array.isArray(m.material) ? m.material[0] : m.material) as THREE.Material;
    if (inBackdrop && /_SKY$|MIDDAYSKY|OFFICE_TEXTURE/i.test(mat?.name ?? "")) drop.push(m);
  });
  for (const d of drop) d.removeFromParent();
}

interface Layout { floorZ: number; openDir: THREE.Vector2; depth: number; halfWidth: number; height: number }

/** Analiza el interior con rayos: altura del suelo bajo el origen y lado abierto (entrada). */
export function analyzeInterior(obj: THREE.Object3D): Layout {
  obj.updateMatrixWorld(true);
  const meshes: THREE.Mesh[] = [];
  obj.traverse(o => { const m = o as THREE.Mesh; if (m.isMesh) { const g = m.geometry as THREE.BufferGeometry & { boundsTree?: MeshBVH }; g.boundsTree ??= new MeshBVH(g); meshes.push(m); } });
  const ray = new THREE.Raycaster(); ray.firstHitOnly = true;
  ray.set(new THREE.Vector3(0, 0, 4), new THREE.Vector3(0, 0, -1)); ray.far = 20;
  const floorZ = ray.intersectObjects(meshes, false)[0]?.point.z ?? 0;
  let best = { d: -1, dir: new THREE.Vector2(1, 0) };
  const dists: number[] = [];
  for (let i = 0; i < 16; i++) {
    const a = (i / 16) * Math.PI * 2, dir = new THREE.Vector3(Math.cos(a), Math.sin(a), 0);
    ray.set(new THREE.Vector3(0, 0, floorZ + 1.2), dir); ray.far = 200;
    const d = ray.intersectObjects(meshes, false)[0]?.distance ?? 200;
    dists.push(d);
    if (d > best.d) best = { d, dir: new THREE.Vector2(dir.x, dir.y) };
  }
  const box = new THREE.Box3().setFromObject(obj), size = box.getSize(new THREE.Vector3());
  // profundidad: distancia del origen al borde de la caja en la dirección abierta
  const depth = Math.min(Math.abs((best.dir.x > 0 ? box.max.x : box.min.x) / (best.dir.x || 1e-6)), Math.abs((best.dir.y > 0 ? box.max.y : box.min.y) / (best.dir.y || 1e-6)));
  return { floorZ, openDir: best.dir, depth: Math.min(depth, 25), halfWidth: Math.min(size.x, size.y) / 2, height: Math.min(size.z, 8) };
}

/** Puerta enrollable: listones con la textura original de la puerta (cada listón muestra su franja de la imagen). */
export class RollerDoor {
  readonly group = new THREE.Group();
  private slats: THREE.Mesh[] = [];
  private slatH: number;
  open = 0; target = 0;
  constructor(width: number, private height: number, map?: THREE.Texture) {
    const n = Math.max(6, Math.round(height / 0.3)); this.slatH = height / n;
    const mat = new THREE.MeshBasicNodeMaterial({ color: map ? 0xffffff : 0x6f7468, map, side: THREE.DoubleSide, name: "puerta enrollable" });
    for (let i = 0; i < n; i++) {
      const g = new THREE.PlaneGeometry(width, this.slatH * 0.96);
      const uv = g.getAttribute("uv") as THREE.BufferAttribute;
      for (let k = 0; k < uv.count; k++) uv.setY(k, (i + uv.getY(k)) / n);
      const s = new THREE.Mesh(g, mat);
      s.setRotationFromMatrix(new THREE.Matrix4().makeBasis(new THREE.Vector3(0, 1, 0), new THREE.Vector3(0, 0, 1), new THREE.Vector3(1, 0, 0))); // plano vertical mirando a +X (fuera)
      s.position.set(0.02, 0, (i + 0.5) * this.slatH);
      this.slats.push(s); this.group.add(s);
    }
    const box = new THREE.Mesh(new THREE.BoxGeometry(0.5, width + 0.3, 0.45), new THREE.MeshBasicNodeMaterial({ color: 0x2b2d28 }));
    box.position.set(0.1, 0, height + 0.2); this.group.add(box);
  }
  update(dt: number) {
    this.open += Math.sign(this.target - this.open) * Math.min(Math.abs(this.target - this.open), dt / 1.4);
    const e = this.open < 0.5 ? 4 * this.open ** 3 : 1 - (-2 * this.open + 2) ** 3 / 2; // aceleración suave
    const lift = e * this.height;
    this.slats.forEach((s, i) => { const z = (i + 0.5) * this.slatH + lift; s.visible = z < this.height; s.position.z = Math.min(z, this.height); });
  }
}

/** Sustituye los materiales del interior por unos que solo se ven dentro de la caja del edificio. */
export function clipToBox(obj: THREE.Object3D, worldToBox: THREE.Matrix4, tint = new THREE.Color(1, 1, 1)) {
  const m = uniform(worldToBox.clone());
  obj.traverse(o => {
    const mesh = o as THREE.Mesh; if (!mesh.isMesh) return;
    // Siempre se parte del material original (el interior se reutiliza entre garajes: no acumular tonos)
    mesh.userData.origMat ??= mesh.material;
    const src = mesh.userData.origMat as THREE.MeshStandardMaterial;
    const mat = new THREE.MeshBasicNodeMaterial({ map: src.map ?? null, color: src.color ?? new THREE.Color(1, 1, 1), side: THREE.DoubleSide, transparent: src.transparent, alphaTest: src.alphaTest, name: src.name });
    const col = (src.color ?? new THREE.Color(1, 1, 1)).clone().multiply(tint);
    const base = src.map ? tslTexture(src.map, uv()).mul(vec4(col.r, col.g, col.b, 1)) : vec4(col.r, col.g, col.b, 1);
    mat.colorNode = Fn(() => {
      const l = m.mul(vec4(positionWorld, 1));
      If(l.x.abs().greaterThan(1).or(l.y.abs().greaterThan(1)).or(l.z.abs().greaterThan(1)), () => { Discard(); });
      return base;
    })();
    if (src.alphaTest) mat.opacityNode = base.a;
    mesh.material = mat;
  });
  return m;
}

/** Mods: datos propios que se aplican encima de lo extraído de la ISO (ver mods/README.md). */
export interface GarageMod { name?: string; interior?: string; tint?: string; display?: { car: string; offset: [number, number]; yaw?: number; paint?: string }[] }
export interface ModManifest { id: string; name: string; version: string; author?: string; description?: string; garages?: Record<string, GarageMod> }
const modFiles = import.meta.glob("../../mods/*/mod.json", { eager: true, import: "default" }) as Record<string, ModManifest>;
export const mods: ModManifest[] = Object.keys(modFiles).sort().map(k => modFiles[k]);
/** Ajustes del garaje combinando todos los mods (el último gana). */
export function garageMod(collection: string): GarageMod {
  const key = collection.split("/").pop()!;
  return mods.reduce<GarageMod>((acc, m) => ({ ...acc, ...(m.garages?.[key] ?? {}) }), {});
}
