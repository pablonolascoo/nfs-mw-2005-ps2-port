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
  setModel(model: THREE.Object3D, tires?: number[][], paint?: string) {
    this.body.clear();
    const { holder, size } = carHolder(model, tires, paint);
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

/**
 * Monta las cuatro ruedas: el modelo trae una sola (pieza *_TIRE_*); el juego las coloca con TireOffsets
 * (x, y, z, radio) de GLOBAL\ATTRIBUTES.BIN [D: CarRender.cpp]. Las del lado contrario se reflejan.
 */
export function mountWheels(model: THREE.Object3D, tires?: number[][]): THREE.Object3D {
  if (!tires) return model;
  model.updateMatrixWorld(true); // el modelo aún no tiene padre: su espacio de mundo = coordenadas del coche
  let tire: THREE.Object3D | null = null;
  model.traverse(o => { if (!tire && /_TIRE_[A-Z]$/i.test(o.name)) tire = o; });
  if (!tire) return model;
  const t = tire as THREE.Object3D;
  const tireBox = new THREE.Box3().setFromObject(t);
  const c = tireBox.getCenter(new THREE.Vector3());
  const assembly = new THREE.Group();
  assembly.add(model);
  t.visible = false;
  for (const [x, y, z] of tires) {
    const pivot = new THREE.Group();
    t.traverse(o => {
      const m = o as THREE.Mesh; if (!m.isMesh) return;
      const part = new THREE.Mesh(m.geometry, m.material);
      part.applyMatrix4(m.matrixWorld); part.position.sub(c); // pieza centrada en el eje de la rueda
      pivot.add(part);
    });
    // CarRender.cpp (WheelPivotTranslationAmount = 0.5): la cara exterior de la llanta queda en |y| = TireOffsets.y
    // y la goma se extiende hacia dentro el ancho de la pieza.
    const halfW = (tireBox.max.y - tireBox.min.y) / 2;
    pivot.position.set(x, Math.sign(y) * (Math.abs(y) - halfW), z === 0 ? c.z : z);
    if (Math.sign(y) !== Math.sign(c.y || 1)) pivot.scale.y = -1; // lado contrario: espejo
    assembly.add(pivot);
  }
  assembly.userData.tireCenter = c.toArray();
  return assembly;
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

/** Envuelve un coche del juego: centrado, apoyado en z = 0 y con el morro hacia +X (deducido de los faros). */
export function carHolder(model0: THREE.Object3D, tires?: number[][], paint?: string) {
  if (paint) paintCar(model0, paint);
  const model = mountWheels(model0, tires);
  const box = new THREE.Box3().setFromObject(model);
  const size = box.getSize(new THREE.Vector3()), c = box.getCenter(new THREE.Vector3());
  let front = 1;
  model.traverse(o => { if (/HEADLIGHT/i.test(o.name)) { const b = new THREE.Box3().setFromObject(o); front = b.getCenter(new THREE.Vector3()).x >= c.x ? 1 : -1; } });
  const holder = new THREE.Group();
  model.position.set(-c.x, -c.y, -box.min.z);
  holder.add(model);
  holder.rotation.z = front > 0 ? 0 : Math.PI;
  const outer = new THREE.Group(); outer.add(holder);
  return { holder: outer, size };
}
