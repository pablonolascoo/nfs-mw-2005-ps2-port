// Conducción arcade sobre el Rockport real: suelo y choques por rayos contra la geometría de las casillas cercanas.
// No es la física del juego (eso vendrá de la decomp: zPhysics/zDynamics); es un prototipo para recorrer la ciudad y probar ideas.
import * as THREE from "three/webgpu";
import { MeshBVH, acceleratedRaycast } from "three-mesh-bvh";

THREE.Mesh.prototype.raycast = acceleratedRaycast;

export interface DriveInput { throttle: number; brake: number; steer: number; handbrake: boolean }

const UP = new THREE.Vector3(0, 0, 1);
const KMH = 3.6;

export class Driver {
  readonly root = new THREE.Group();       // posición y orientación del coche (X = adelante, Z = arriba)
  readonly body = new THREE.Group();       // modelo, con inclinación según el suelo
  speed = 0;                                // m/s, + hacia delante
  yaw = 0;
  private vz = 0;
  private grounded = false;
  private ray = new THREE.Raycaster();
  colliders: THREE.Mesh[] = [];
  /** Puntos a ignorar (p. ej. el edificio vaciado por el garaje). */
  ignore: (p: THREE.Vector3, obj: THREE.Object3D) => boolean = () => false;
  private firstValid(hits: THREE.Intersection[]) { return hits.find(h => !this.ignore(h.point, h.object)); }
  halfLength = 2.2; halfWidth = 0.9;

  constructor() { this.root.add(this.body); }

  /** Coloca el modelo: lo centra, lo apoya en z = 0 y lo gira para que su morro mire a +X. */
  setModel(model: THREE.Object3D, attr?: CarAttribs, paint?: string, cfg?: CarConfig) {
    this.body.clear();
    const { holder, size } = carHolder(model, attr, paint, cfg);
    this.body.add(holder);
    this.halfLength = Math.max(size.x, size.y) / 2; this.halfWidth = Math.min(size.x, size.y) / 2;
  }

  place(p: THREE.Vector3, yawRad: number) { this.root.position.copy(p); this.yaw = yawRad; this.speed = 0; this.vz = 0; this.snapToGround(true); }

  /** Altura del suelo bajo un punto (o null si no hay geometría cargada). */
  groundAt(x: number, y: number, fromZ: number): { z: number; n: THREE.Vector3 } | null {
    this.ray.set(new THREE.Vector3(x, y, fromZ + 3), new THREE.Vector3(0, 0, -1));
    this.ray.far = 30;
    const hit = this.firstValid(this.ray.intersectObjects(this.colliders, false));
    if (!hit) return null;
    const n = hit.face ? hit.face.normal.clone().transformDirection(hit.object.matrixWorld) : UP.clone();
    if (n.z < 0) n.negate();
    return { z: hit.point.z, n };
  }

  private snapToGround(force = false) {
    const p = this.root.position, g = this.groundAt(p.x, p.y, p.z);
    if (g && (force || p.z <= g.z + 0.05)) { p.z = g.z; this.vz = 0; this.grounded = true; }
  }

  update(dt: number, inp: DriveInput) {
    const fwd = new THREE.Vector3(Math.cos(this.yaw), Math.sin(this.yaw), 0);
    // Motor, freno, marcha atrás y rozamiento (valores de prueba: 0-100 en ~5 s, 270 km/h de punta)
    const MAX = 75, ACC = 9.5, BRAKE = 26, DRAG = 0.0009, ROLL = 0.6;
    if (inp.throttle > 0) this.speed += ACC * inp.throttle * (1 - Math.max(0, this.speed) / MAX) * dt;
    if (inp.brake > 0) this.speed -= (this.speed > 0.5 ? BRAKE : ACC * 0.6) * inp.brake * dt;
    this.speed -= Math.sign(this.speed) * (ROLL + DRAG * this.speed * this.speed) * dt;
    if (inp.handbrake) this.speed *= Math.pow(0.35, dt);
    if (Math.abs(this.speed) < 0.05 && !inp.throttle && !inp.brake) this.speed = 0;
    this.speed = Math.max(-15, Math.min(MAX, this.speed));
    // Dirección: más ángulo a baja velocidad, menos a alta; con freno de mano gira más
    const steerRate = (1.9 / (1 + Math.abs(this.speed) / 22)) * (inp.handbrake ? 1.6 : 1);
    this.yaw += inp.steer * steerRate * dt * Math.sign(this.speed || 1) * Math.min(1, Math.abs(this.speed) / 3);

    // Choque frontal: rayo a la altura del paragolpes en la dirección de marcha
    const p = this.root.position;
    const step = this.speed * dt;
    if (Math.abs(step) > 0) {
      const dir = fwd.clone().multiplyScalar(Math.sign(step));
      this.ray.set(new THREE.Vector3(p.x, p.y, p.z + 0.7), dir); this.ray.far = this.halfLength + Math.abs(step) + 0.2;
      const hit = this.firstValid(this.ray.intersectObjects(this.colliders, false));
      const wallish = hit?.face && Math.abs(hit.face.normal.clone().transformDirection(hit.object.matrixWorld).z) < 0.6;
      if (hit && wallish) { this.speed *= -0.25; } else p.addScaledVector(fwd, step);
    }
    // Gravedad y suelo
    const g = this.groundAt(p.x, p.y, p.z);
    if (g && p.z - g.z < 0.6 && this.vz <= 0) { p.z = g.z; this.vz = 0; this.grounded = true; }
    else { this.vz -= 9.8 * dt; p.z += this.vz * dt; this.grounded = false; if (g && p.z < g.z) { p.z = g.z; this.vz = 0; } }
    this.root.rotation.set(0, 0, this.yaw);
    // Inclinación según el suelo bajo las cuatro esquinas
    if (this.grounded) {
      const c = Math.cos(this.yaw), s = Math.sin(this.yaw), L = this.halfLength * 0.8, W = this.halfWidth * 0.8;
      const h = (dx: number, dy: number) => this.groundAt(p.x + c * dx - s * dy, p.y + s * dx + c * dy, p.z)?.z ?? p.z;
      const zf = (h(L, W) + h(L, -W)) / 2, zb = (h(-L, W) + h(-L, -W)) / 2, zl = (h(L, W) + h(-L, W)) / 2, zr = (h(L, -W) + h(-L, -W)) / 2;
      const pitch = Math.atan2(zf - zb, 2 * L), roll = Math.atan2(zl - zr, 2 * W);
      this.body.rotation.y = THREE.MathUtils.lerp(this.body.rotation.y, -pitch, Math.min(1, dt * 10));
      this.body.rotation.x = THREE.MathUtils.lerp(this.body.rotation.x, roll, Math.min(1, dt * 10));
    }
  }

  get kmh() { return Math.abs(this.speed) * KMH; }

  /** Cámara de persecución suave. */
  chase(camera: THREE.PerspectiveCamera, target: THREE.Vector3, dt: number) {
    const fwd = new THREE.Vector3(Math.cos(this.yaw), Math.sin(this.yaw), 0);
    const back = 6.5 + this.kmh / 60, high = 2.3 + this.kmh / 160;
    const want = this.root.position.clone().addScaledVector(fwd, -back).add(new THREE.Vector3(0, 0, high));
    camera.position.lerp(want, Math.min(1, dt * 6));
    target.lerp(this.root.position.clone().addScaledVector(fwd, 3).add(new THREE.Vector3(0, 0, 1.1)), Math.min(1, dt * 10));
    camera.lookAt(target);
  }
}

/** Prepara una malla como colisionador (BVH una sola vez). */
export function makeCollider(m: THREE.Mesh) {
  const g = m.geometry as THREE.BufferGeometry & { boundsTree?: MeshBVH };
  if (!g.boundsTree) g.boundsTree = new MeshBVH(g, { maxLeafTris: 12 });
  return m;
}

/** Atributos de coche de cars.json (tools/src/cli/car-attribs.ts): clase ecar + RIM_SIZE de la clase tires. */
export interface CarAttribs { tires: number[][]; spokes?: number; skidWidth?: number[]; kitWidthScale?: number[][]; kitOffsetFront?: number[]; kitOffsetRear?: number[]; camber?: [number, number]; feCompression?: number[]; rimSize?: number[] }
/** Configuración de tuneo: kit de carrocería, capó, llantas, alerón y toma de techo (null/undefined = de serie). */
export interface CarConfig { kit?: number; hood?: number | null; rim?: string | null; spoiler?: string | null; roof?: string | null }
type Pieza = { slot: string; kit?: number; style?: number; stock: boolean; kind: string; variant?: string };
const pieza = (o: THREE.Object3D) => o.userData?.pieza as Pieza | undefined;

/** Packs comunes de tuneo ya cargados (WHEELS, SPOILER, ROOF…): los registra main.ts. */
export const tuningPacks = new Map<string, THREE.Object3D>();
function findTuningPart(variant: string): THREE.Object3D | null {
  let hit: THREE.Object3D | null = null;
  for (const pack of tuningPacks.values()) pack.traverse(o => { if (!hit && o.name.replace(/_[A-E]$/, "") === variant && pieza(o)) hit = o; });
  return hit;
}

/**
 * Elige qué piezas se ven, como RideInfo + CarRenderInfo [D: CarInfo.cpp SetStockParts, CarRender.cpp UpdateCarParts]:
 * una pieza por ranura. El kit pedido sustituye al KIT00 solo en las ranuras que trae (en MW un kit es sobre todo el BODY);
 * capó STYLEnn en lugar del KITnn_HOOD; sin daños ni zonas de vinilo; UNIVERSAL_SPOILER_BASE solo con alerón de tuneo.
 */
export function applyCarConfig(model: THREE.Object3D, cfg: CarConfig = {}) {
  const kitsBySlot = new Map<string, Set<number>>();
  model.traverse(o => { const p = pieza(o); if (p?.kit !== undefined) (kitsBySlot.get(p.slot) ?? kitsBySlot.set(p.slot, new Set()).get(p.slot)!).add(p.kit); });
  const hoodStyle = cfg.hood ?? null;
  let hasStyleHood = false; model.traverse(o => { const p = pieza(o); if (p?.kind === "capo" && p.style === hoodStyle) hasStyleHood = true; });
  // Si una ranura tiene pieza normal y panel DAMAGE0 (intacto), manda la normal: así no se duplican.
  const normal = new Set<string>(); model.traverse(o => { const p = pieza(o); if (p && p.kit !== undefined && p.variant !== "DAMAGE0" && p.kind !== "dano") normal.add(`${p.slot}|${p.kit}`); });
  const kitFor = (slot: string) => { const k = cfg.kit ?? 0, set = kitsBySlot.get(slot); return set?.has(k) ? k : 0; };
  model.traverse(o => {
    const p = pieza(o); if (!p) return;
    let v = p.stock;
    if (p.kind === "dano" || p.kind === "calcomania") v = false;
    else if (p.kit !== undefined) v = p.kit === kitFor(p.slot);
    else if (p.kind === "capo") v = hasStyleHood && p.style === hoodStyle;
    if (p.variant === "DAMAGE0" && normal.has(`${p.slot}|${p.kit}`)) v = false;
    if (p.slot === "HOOD" && p.kind !== "capo" && hasStyleHood) v = false;
    if (p.slot === "UNIVERSAL_SPOILER_BASE") v = !!cfg.spoiler && p.kit === kitFor(p.slot);
    if (p.slot === "SPOILER" && p.kind !== "aleron" && cfg.spoiler) v = false;
    o.visible = v;
  });
}

/** Matriz del juego (filas, v3 = traslación) → Matrix4 de three: el mismo orden de 16 números. */
const gameMatrix = (m: number[]) => new THREE.Matrix4().fromArray(m);
function marker(model: THREE.Object3D, name: string): THREE.Matrix4 | null {
  let out: THREE.Matrix4 | null = null;
  model.traverse(o => { const ms = o.userData?.marcadores as { nombre: string; matriz: number[] }[] | undefined; const p = pieza(o); if (!out && ms && p?.slot === "BASE") { const m = ms.find(x => x.nombre === name); if (m) out = gameMatrix(m.matriz); } });
  return out;
}

/** Actualiza las matrices desde la raíz (las piezas de los packs de tuneo no tienen padre en la escena). */
function updateFromRoot(o: THREE.Object3D) { let r = o; while (r.parent) r = r.parent; r.updateMatrixWorld(true); }

/** Copia las mallas de una pieza (en coordenadas del coche) bajo un grupo nuevo con la matriz dada. */
function instancePart(part: THREE.Object3D, matrix: THREE.Matrix4) {
  const g = new THREE.Group(); g.matrixAutoUpdate = false; g.matrix.copy(matrix);
  updateFromRoot(part);
  part.traverse(o => { const m = o as THREE.Mesh; if (!m.isMesh) return; const c = new THREE.Mesh(m.geometry, m.material); c.matrixAutoUpdate = false; c.matrix.copy(m.matrixWorld); c.name = m.name || part.name; g.add(c); });
  return g;
}

/**
 * Monta las cuatro ruedas y los frenos como CarRenderInfo::Render [D: CarRender.cpp 1855-1999 y 3330-3460]:
 *  - Modelo de rueda = pieza FRONT_TIRE (o una llanta de tuneo de WHEELS: es la rueda entera, no una textura). La cara de
 *    la llanta está en y = 0 del modelo y TIRE_BACK (la tapa trasera) en y = ancho [V: BMW M3 GTR].
 *  - Escala: radio TireOffsets.w / radio del modelo; ancho TireSkidWidth × TireSkidWidthKitScale / ancho del modelo.
 *  - pivot (y −= ancho/2) · giro izquierdo (Z 180°, o espejo si WheelSpokeCount & 0x80) · caída (X, CamberFront/Rear × 7°)
 *    · eje (x, ±(|y| + ancho/2) hacia fuera, z = TireOffsets.z + FECompressions − caída × 0,03). La cara queda en |y|.
 *  - Frenos: marcador FRONT_BRAKE/REAR_BRAKE de la rueda (solo su y), espejo en el lado izquierdo, sin escala de radio.
 */
export function mountWheels(model: THREE.Object3D, attr?: CarAttribs, cfg: CarConfig = {}): THREE.Object3D {
  if (!attr?.tires) return model;
  model.updateMatrixWorld(true); // aún sin padre: espacio de mundo = coordenadas del coche
  const find = (re: RegExp) => { let hit: THREE.Object3D | null = null; model.traverse(o => { if (!hit && o.visible !== false && re.test(o.name) && pieza(o)) hit = o; }); return hit as THREE.Object3D | null; };
  const kit = cfg.kit ?? 0;
  const stockFront = find(/_FRONT_TIRE(_[A-E])?$/), stockRear = find(/_REAR_TIRE(_[A-E])?$/) ?? stockFront;
  const brakeF = find(/_FRONT_BRAKE(_[A-E])?$/), brakeR = find(/_REAR_BRAKE(_[A-E])?$/) ?? brakeF;
  let rim: THREE.Object3D | null = null;
  if (cfg.rim) {
    const want = Math.round(attr.rimSize?.[0] ?? 18), sizes = [want, 18, 17, 19, 20];
    for (const sz of sizes) { rim = findTuningPart(`${cfg.rim}_${Math.min(20, Math.max(17, sz))}_25`); if (rim) break; }
  }
  const front = rim ?? stockFront, rear = rim ?? stockRear;
  if (!front) return model;
  for (const o of [stockFront, stockRear, brakeF, brakeR]) if (o) o.visible = false;
  const boxOf = (o: THREE.Object3D) => { updateFromRoot(o); const b = new THREE.Box3(); o.traverse(x => { const m = x as THREE.Mesh; if (m.isMesh) { m.geometry.computeBoundingBox(); b.union(m.geometry.boundingBox!.clone().applyMatrix4(m.matrixWorld)); } }); return b; };
  const markerY = (wheel: THREE.Object3D, name: string) => (wheel.userData?.marcadores as { nombre: string; matriz: number[] }[] | undefined)?.find(m => m.nombre === name)?.matriz[13] ?? 0;
  const assembly = new THREE.Group();
  assembly.add(model);
  attr.tires.forEach(([x, y, z, radius], i) => {
    const isFront = i <= 1, left = i === 0 || i === 3, wheel = isFront ? front : rear!;
    const box = boxOf(wheel), W = box.max.y - box.min.y, R = (box.max.x - box.min.x) / 2;
    const ks = attr.kitWidthScale?.[kit]?.[isFront ? 0 : 1] || 1;
    const desired = (attr.skidWidth?.[i] ?? 0) * ks;
    const sw = desired > 0 && W > 0 ? desired / W : 1, sr = radius > 0 && R > 0 ? radius / R : 1;
    const pivotY = W * sw * 0.5;
    let yoff = -y; const kOff = ((isFront ? attr.kitOffsetFront : attr.kitOffsetRear)?.[kit] ?? 0) * 0.001;
    yoff += yoff <= 0 ? -kOff : kOff;
    const axleY = yoff < 0 ? -(yoff + pivotY) : pivotY - yoff;
    const camber = (attr.camber?.[isFront ? 0 : 1] ?? 0);
    const ang = THREE.MathUtils.degToRad(camber * 7) * (i === 0 || i === 3 ? 1 : -1);
    const wz = z + (attr.feCompression?.[isFront ? 0 : 1] ?? 0) - camber * 0.03;
    const C = new THREE.Matrix4().makeTranslation(x, axleY, wz).multiply(new THREE.Matrix4().makeRotationX(ang));
    const mirrorLeft = ((attr.spokes ?? 0) & 0x80) !== 0;
    const F = left ? (mirrorLeft ? new THREE.Matrix4().makeScale(1, -1, 1) : new THREE.Matrix4().makeRotationZ(Math.PI)) : new THREE.Matrix4();
    const P = new THREE.Matrix4().makeTranslation(0, -pivotY, 0).multiply(new THREE.Matrix4().makeScale(sr, sw, sr));
    const w = instancePart(wheel, C.clone().multiply(F).multiply(P)); w.name = `rueda ${i}`;
    assembly.add(w);
    const brake = isFront ? brakeF : brakeR;
    if (brake) {
      const my = markerY(wheel, isFront ? "FRONT_BRAKE" : "REAR_BRAKE");
      const Pb = new THREE.Matrix4().makeTranslation(0, my * sw - pivotY, 0);
      const Fb = left ? new THREE.Matrix4().makeScale(1, -1, 1) : new THREE.Matrix4();
      const b = instancePart(brake, C.clone().multiply(Fb).multiply(Pb)); b.name = `freno ${i}`;
      assembly.add(b);
    }
  });
  return assembly;
}

/** Alerón y toma de techo de tuneo en los marcadores SPOILER / ROOF_SCOOP de la pieza BASE [D: CarRender.cpp 3262-3316]. */
function mountAddons(model: THREE.Object3D, assembly: THREE.Object3D, cfg: CarConfig) {
  for (const [variant, mk] of [[cfg.spoiler, "SPOILER"], [cfg.roof, "ROOF_SCOOP"]] as const) {
    if (!variant) continue;
    const part = findTuningPart(variant), m = marker(model, mk);
    if (!part || !m) continue;
    const g = instancePart(part, m); g.name = variant; assembly.add(g);
  }
}

/** Pinta la carrocería: materiales con extras.role = "pintura" (sustitutos de <COCHE>_SKIN1, ver tools/src/lib/car-textures.ts). */
export function paintCar(model: THREE.Object3D, color: string) {
  const done = new Map<THREE.Material, THREE.Material>();
  model.traverse(o => {
    const m = o as THREE.Mesh; if (!m.isMesh) return;
    const swap = (mat: THREE.Material) => {
      if (mat.userData?.role !== "pintura") return mat;
      let c = done.get(mat);
      if (!c) { const n = mat.clone() as THREE.MeshStandardMaterial; n.color.set(color); n.roughness = 0.32; n.metalness = 0.45; c = n; done.set(mat, n); }
      return c;
    };
    m.material = Array.isArray(m.material) ? m.material.map(swap) : swap(m.material);
  });
}

/** Envuelve un coche del juego: piezas según la configuración, ruedas, centrado, apoyado en z = 0 y morro hacia +X. */
export function carHolder(model0: THREE.Object3D, attr?: CarAttribs, paint?: string, cfg: CarConfig = {}) {
  applyCarConfig(model0, cfg);
  const model = mountWheels(model0, attr, cfg);
  mountAddons(model0, model, cfg);
  if (paint) paintCar(model, paint);
  const box = new THREE.Box3();
  model.updateMatrixWorld(true);
  model.traverse(o => { const m = o as THREE.Mesh; if (!m.isMesh) return; let v = true; for (let p: THREE.Object3D | null = m; p; p = p.parent) if (!p.visible) { v = false; break; } if (v) { m.geometry.computeBoundingBox(); box.union(m.geometry.boundingBox!.clone().applyMatrix4(m.matrixWorld)); } });
  const size = box.getSize(new THREE.Vector3()), c = box.getCenter(new THREE.Vector3());
  let front = 1;
  model0.traverse(o => { if (/HEADLIGHT/i.test(o.name) && o.visible) { const b = new THREE.Box3().setFromObject(o); front = b.getCenter(new THREE.Vector3()).x >= c.x ? 1 : -1; } });
  const holder = new THREE.Group();
  model.position.set(-c.x, -c.y, -box.min.z);
  holder.add(model);
  holder.rotation.z = front > 0 ? 0 : Math.PI;
  const outer = new THREE.Group(); outer.add(holder);
  return { holder: outer, size };
}
