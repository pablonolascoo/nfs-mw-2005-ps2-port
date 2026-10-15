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
/** Configuración de tuneo: kit de carrocería, capó, llantas, alerón y toma de techo (null/undefined = de serie).
 *  `preset`: coche predefinido del juego (presets.json, tools/src/cli/presets.ts): manda sobre todo lo demás. */
export interface CarConfig { kit?: number; hood?: number | null; rim?: string | null; spoiler?: string | null; roof?: string | null; preset?: CarPreset | null }
type PresetColour = { name: string; rgb: string; gloss: number; finish: string; material?: string };
/** Preset del juego (presets.json): sólidos exactos por ranura, pintura, vinilo, llanta y cristales [V: GLOBALB.BUN PresetCar]. */
export interface CarPreset {
  name: string; car: string; base: string; blacklist: number | null; kit: number;
  solids: { slot: string; part: string; glb: string; node: string }[];
  paint: PresetColour | null;
  vinyl: { name: string; texture: string; image: string | null; mask: string | null; remap: number; colours: (PresetColour | null)[] } | null;
  rim: { name: string; texture: string | null; innerMask: string | null } | null;
  rimPaint: PresetColour | null;
  windowTint: { name: string; rgb: string; opacity: number } | null;
}
/** Packs de tuneo que necesita un preset (WHEELS, SPOILER*, ROOF). */
export const presetPacks = (p: CarPreset) => [...new Set(p.solids.filter(s => s.glb !== p.car).map(s => s.glb))];
const presetFor = (model: THREE.Object3D, cfg: CarConfig) => {
  const p = cfg.preset; if (!p) return null;
  let ok = false; model.traverse(o => { if (!ok && pieza(o) && o.name.startsWith(p.car + "_")) ok = true; });
  return ok ? p : null;
};
type Pieza = { slot: string; kit?: number; style?: number; stock: boolean; kind: string; variant?: string };
const pieza = (o: THREE.Object3D) => o.userData?.pieza as Pieza | undefined;

/** Packs comunes de tuneo ya cargados (WHEELS, SPOILER, ROOF…): los registra main.ts. */
export const tuningPacks = new Map<string, THREE.Object3D>();
function findTuningPart(variant: string, exact = false): THREE.Object3D | null {
  let hit: THREE.Object3D | null = null;
  for (const pack of tuningPacks.values()) pack.traverse(o => { if (!hit && (exact ? o.name === variant : o.name.replace(/_[A-E]$/, "") === variant) && pieza(o)) hit = o; });
  return hit;
}

/**
 * Elige qué piezas se ven, como RideInfo + CarRenderInfo [D: CarInfo.cpp SetStockParts, CarRender.cpp UpdateCarParts]:
 * una pieza por ranura. El kit pedido sustituye al KIT00 solo en las ranuras que trae (en MW un kit es sobre todo el BODY);
 * capó STYLEnn en lugar del KITnn_HOOD; sin daños ni zonas de vinilo; UNIVERSAL_SPOILER_BASE solo con alerón de tuneo.
 */
export function applyCarConfig(model: THREE.Object3D, cfg: CarConfig = {}) {
  const preset = presetFor(model, cfg);
  if (preset) {
    // Preset: exactamente sus sólidos; sin zonas de calcomanía; base de alerón solo con alerón de tuneo [D: CarRender.cpp 1894].
    const tunedSpoiler = preset.solids.some(s => s.slot === "SPOILER" && s.glb !== preset.car);
    const want = new Set(preset.solids.filter(s => s.glb === preset.car && !s.slot.startsWith("DECAL_") && (s.slot !== "UNIVERSAL_SPOILER_BASE" || tunedSpoiler)).map(s => s.node));
    // Sólidos rotos del disco (CAYMANS_KIT00_REAR_*_WINDOW, a 9 m) fuera, igual que Car.swift [V].
    const sane = (o: THREE.Object3D) => { const b = new THREE.Box3().setFromObject(o); return b.isEmpty() || (Math.abs(b.max.y) < 4 && Math.abs(b.min.y) < 4 && b.min.z > -3); };
    model.traverse(o => { if (pieza(o)) o.visible = want.has(o.name); });
    model.updateMatrixWorld(true);
    model.traverse(o => { if (pieza(o) && o.visible && !sane(o)) o.visible = false; });
    return;
  }
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
  const preset = presetFor(model, cfg);
  const kit = preset?.kit ?? cfg.kit ?? 0;
  const stockFront = find(/_FRONT_TIRE(_[A-E])?$/), stockRear = find(/_REAR_TIRE(_[A-E])?$/) ?? stockFront;
  const brakeF = find(/_FRONT_BRAKE(_[A-E])?$/), brakeR = find(/_REAR_BRAKE(_[A-E])?$/) ?? brakeF;
  let rim: THREE.Object3D | null = null;
  if (cfg.rim) {
    const want = Math.round(attr.rimSize?.[0] ?? 18), sizes = [want, 18, 17, 19, 20];
    for (const sz of sizes) { rim = findTuningPart(`${cfg.rim}_${Math.min(20, Math.max(17, sz))}_25`); if (rim) break; }
  }
  if (preset) {
    // Rueda del preset: la de serie o una llanta de tuneo de WHEELS (rueda entera) [D: CarRender.cpp]
    const s = preset.solids.find(x => x.slot === "FRONT_WHEEL");
    if (s) { if (s.glb === preset.car) { let hit: THREE.Object3D | null = null; model.traverse(o => { if (!hit && o.name === s.node) hit = o; }); rim = hit; } else rim = findTuningPart(s.node, true); }
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
  const preset = presetFor(model, cfg);
  const pack = (slot: string) => preset?.solids.find(s => s.slot === slot && s.glb !== preset.car)?.node ?? null;
  const list = preset ? [[pack("SPOILER"), "SPOILER"], [pack("ROOF"), "ROOF_SCOOP"]] as const : [[cfg.spoiler, "SPOILER"], [cfg.roof, "ROOF_SCOOP"]] as const;
  for (const [variant, mk] of list) {
    if (!variant) continue;
    const part = findTuningPart(variant, !!preset), m = marker(model, mk);
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
  const preset = presetFor(model0, cfg);
  if (preset) skinCar(model, preset); else if (paint) paintCar(model, paint);
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

/** Carpeta de datos del disco (/<ID>/) para leer los PNG de vinyls/: la fija main.ts. */
export const presetData = { base: "" };
const loadImage = (url: string) => new Promise<HTMLImageElement>((ok, ko) => { const i = new Image(); i.onload = () => ok(i); i.onerror = ko; i.src = url; });
/** Píxeles de un PNG reescalado a w×h con filtrado bilineal del navegador. */
async function pixels(url: string, w: number, h: number) {
  const img = await loadImage(url);
  const c = document.createElement("canvas"); c.width = w; c.height = h;
  const g = c.getContext("2d", { willReadFrequently: true })!; g.imageSmoothingEnabled = true; g.imageSmoothingQuality = "high";
  g.drawImage(img, 0, 0, w, h);
  return g.getImageData(0, 0, w, h).data;
}
const skinCache = new Map<string, THREE.Texture>();
/**
 * Piel compuesta como CarSkin.cpp [D] (misma regla que native-engine/Sources/Rockport/CarSkin.swift): base = pintura (alfa = GLOSS);
 * m = R de la máscara del vinilo; m ≥ 128 → vinilo, 0 < m < 128 → mezcla m/128. Al doble de la resolución del PS2 (512 → 1024).
 */
export function presetSkin(p: CarPreset): THREE.Texture {
  const hit = skinCache.get(p.name); if (hit) return hit;
  const W = 1024, H = 1024, canvas = document.createElement("canvas"); canvas.width = W; canvas.height = H;
  const g = canvas.getContext("2d")!;
  g.fillStyle = `#${p.paint?.rgb ?? "b7b7b7"}`; g.fillRect(0, 0, W, H);
  const tex = new THREE.CanvasTexture(canvas); tex.colorSpace = THREE.SRGBColorSpace; tex.flipY = false; tex.anisotropy = 8;
  skinCache.set(p.name, tex);
  const v = p.vinyl;
  if (v?.image && v.mask) Promise.all([pixels(`${presetData.base}${v.image}`, W, H), pixels(`${presetData.base}${v.mask}`, W, H)]).then(([img, mask]) => {
    const out = g.getImageData(0, 0, W, H), d = out.data;
    for (let i = 0; i < d.length; i += 4) {
      const m = mask[i]; if (m === 0) continue;
      const k = Math.min(1, m / 128);
      for (let c = 0; c < 3; c++) d[i + c] = Math.round(img[i + c] * k + d[i + c] * (1 - k));
    }
    g.putImageData(out, 0, 0); tex.needsUpdate = true;
  }).catch(e => console.warn("vinilo", p.name, e));
  return tex;
}

/** Viste el coche con el preset: piel compuesta en los materiales "pintura" (SKIN1, SPOILER_SKIN1, ROOF_SKIN), acabado y cristales. */
export function skinCar(model: THREE.Object3D, p: CarPreset) {
  const map = presetSkin(p);
  const finish = p.paint?.finish === "METAL" ? [0.6, 0.3] : p.paint?.finish === "PEARL" ? [0.4, 0.22] : [0.12, 0.24];
  const tint = p.windowTint && !/^STOCK/i.test(p.windowTint.name) ? p.windowTint : null;
  const done = new Map<THREE.Material, THREE.Material>();
  model.traverse(o => {
    const m = o as THREE.Mesh; if (!m.isMesh) return;
    const swap = (mat: THREE.Material) => {
      const c0 = done.get(mat); if (c0) return c0;
      let c = mat;
      if (mat.userData?.role === "pintura") {
        const n = mat.clone() as THREE.MeshStandardMaterial; n.map = map; n.color.set(0xffffff); n.metalness = finish[0]; n.roughness = finish[1]; c = n;
      } else if (tint && /^WINDOW_(?!MASK)|^REAR_DEFROSTER/.test(mat.name)) {
        // Tintado [I]: el juego cambia el material de luz (WINDSHIELD_TINT_*); aquí se tiñe y oscurece el cristal.
        const n = mat.clone() as THREE.MeshStandardMaterial; const t = new THREE.Color(`#${tint.rgb}`); const mx = Math.max(t.r, t.g, t.b, 0.001);
        n.color.multiply(new THREE.Color(1, 1, 1).lerp(new THREE.Color(t.r / mx * 0.55, t.g / mx * 0.55, t.b / mx * 0.55), tint.opacity)); c = n;
      }
      done.set(mat, c); return c;
    };
    m.material = Array.isArray(m.material) ? m.material.map(swap) : swap(m.material);
  });
}
