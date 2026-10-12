// Atributos de física de cada vehículo (GLOBAL\ATTRIBUTES.BIN) para el modelo de conducción del juego.
// En el juego, cada comportamiento lee su clase con BehaviorSpecsPtr<T>(this, 0): la colección del índice 0 del array
// RefSpec del pvehicle (pvehicle.engine[0], pvehicle.tires[0]…) [D: Physics/Behavior.h LookupKey]. Las demás
// entradas del array son niveles de mejora. Todo con herencia por padre (resolvedValues).
// Uso: bun src/cli/physics-attribs.ts <iso> <ID> → map-data/<ID>/physics.json
import { GameDisc } from "../lib/zdir";
import { AttribDatabase, Vault, parseVpak, type Value } from "../lib/vlt";
import { loadAttribNames } from "../lib/attrib-names";
import { outDir } from "../lib/paths";

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/physics-attribs.ts <iso> <ID>"); process.exit(1); }
const d = await GameDisc.open(iso);
const db = new AttribDatabase();
await loadAttribNames(db);
for (const e of parseVpak(await d.readEntry(d.find("GLOBAL\\ATTRIBUTES.BIN")!))) db.addVault(new Vault(e.name, e.vlt, e.bin));

const f32 = (w: Value) => { const b = new DataView(new ArrayBuffer(4)); b.setUint32(0, parseInt(String(w), 16) >>> 0); return +b.getFloat32(0).toPrecision(7); };
// Estructuras de floats que el lector deja en crudo: AxlePair {Front, Rear}, CarBodyMotion {3 floats} [D: AttribSys].
const FLOAT_STRUCTS = new Set(["AxlePair", "CarBodyMotion"]);
type Out = Record<string, unknown>;
function clean(vals: Record<string, Value>): Out {
  const out: Out = {};
  for (const [k, v] of Object.entries(vals)) {
    if (k === "CollectionName") continue;
    if (v && typeof v === "object" && !Array.isArray(v) && "type" in v) {
      const o = v as { type: string; raw: Value[] };
      if (FLOAT_STRUCTS.has(o.type)) out[k] = o.raw.map(f32);
      continue; // otros registros (efectos, sonido): no son física
    }
    if (Array.isArray(v) && v.some(x => x && typeof x === "object" && !Array.isArray(x))) continue;
    out[k] = v;
  }
  return out;
}

const byClass = new Map<string, Map<string, ReturnType<typeof db.resolvedValues>>>();
for (const c of db.collections.values()) {
  const cn = db.names.name(c.classKey);
  if (!byClass.has(cn)) byClass.set(cn, new Map());
  byClass.get(cn)!.set(db.collectionName(c), db.resolvedValues(c));
}
const get = (cls: string, name: string | null | undefined) => (name ? byClass.get(cls)?.get(name) : undefined);
const refName = (v: Value): string | null => (v && typeof v === "object" && !Array.isArray(v) && "collection" in v ? (v.collection as string | null) : null);
const refs = (v: Value): string[] => (Array.isArray(v) ? v.map(refName) : [refName(v)]).map(n => n ?? "default");

// Clases que lee la física de un coche [D: SuspensionRacer, EngineRacer, Chassis, RigidBody].
const PHYS = ["chassis", "tires", "engine", "transmission", "brakes", "induction", "nos"] as const;
const vehicles: Record<string, Out> = {};
for (const [name, pv] of byClass.get("pvehicle") ?? []) {
  const v: Out = {
    model: pv.MODEL ?? "", class: pv.CLASS ?? null, mass: pv.MASS, tensorScale: pv.TENSOR_SCALE, playerUsable: pv.PlayerUsable ?? false,
    behaviors: Object.fromEntries(Object.entries(pv).filter(([k]) => k.startsWith("BEHAVIOR_MECHANIC_")).map(([k, x]) => [k.slice(18).toLowerCase(), x])),
  };
  const upgrades: Out = {};
  for (const cls of PHYS) {
    const list = refs(pv[cls] ?? null);
    upgrades[cls] = list;
    const vals = get(cls, list[0]);
    v[cls] = vals ? { collection: list[0], ...clean(vals) } : null;
  }
  const rb = refName(pv.rigidbodyspecs ?? null);
  const rbv = get("rigidbodyspecs", rb);
  v.rigidbody = rbv ? { collection: rb, ...clean(rbv) } : null;
  v.upgrades = upgrades;
  // Cámaras de persecución del coche: clase ecar → CameraInfo_* (RefSpec a camerainfo) [V]
  const ecar = get("ecar", name);
  if (ecar) {
    const cams: Out = {};
    for (const [k, x] of Object.entries(ecar)) {
      if (!k.startsWith("CameraInfo_")) continue;
      const cv = get("camerainfo", refName(x));
      if (cv) cams[k.slice(11).toLowerCase()] = { collection: refName(x), ...clean(cv) };
    }
    v.cameras = cams;
    v.ecar = { SteerSpeed: ecar.SteerSpeed, MaxTireSteer: ecar.MaxTireSteer, BodyRoll: clean({ x: ecar.BodyRoll ?? null }).x, BodyDive: clean({ x: ecar.BodyDive ?? null }).x, BodySquat: clean({ x: ecar.BodySquat ?? null }).x };
  }
  vehicles[name] = v;
}

// Mando: clase controller, colección "drive". ControllerDataRecord = {StringKey mDeviceID, u32 mUpdateType,
// f32 mLowerDZ, f32 mUpperDZ} [D: Misc/MWAttribUserTypes.h]. Un registro por dispositivo/eje que dispara la acción.
const controller: Out = {};
for (const [k, x] of Object.entries(get("controller", "drive") ?? {})) {
  if (!Array.isArray(x)) continue;
  const recs = x.filter(r => r && typeof r === "object" && !Array.isArray(r) && (r as { type?: string }).type === "ControllerDataRecord") as { raw: Value[] }[];
  if (recs.length) controller[k] = recs.map(r => ({ device: r.raw[2], updateType: parseInt(String(r.raw[4]), 16), lowerDZ: f32(r.raw[5]), upperDZ: f32(r.raw[6]) }));
}
// Superficie por defecto (la colisión exportada no guarda el material) [V: simsurface/default]
const surf = get("simsurface", "default");
const surface = surf ? { GROUND_FRICTION: surf.GROUND_FRICTION, LATERAL_GRIP: surf.LATERAL_GRIP, DRIVE_GRIP: surf.DRIVE_GRIP, ROLLING_RESISTANCE: surf.ROLLING_RESISTANCE, WORLD_FRICTION: surf.WORLD_FRICTION } : null;

const out = {
  disc: id,
  source: "GLOBAL\\ATTRIBUTES.BIN · pvehicle → chassis/tires/engine/transmission/brakes/induction/nos (índice 0) + rigidbodyspecs + camerainfo",
  note: "AxlePair = [delante, detrás]. Unidades del juego: RIDE_HEIGHT/TRAVEL/SHOCK_VALVING en pulgadas, SPRING/SHOCK/SWAYBAR en lb/in, BRAKES/EBRAKE y TORQUE en ft·lb, SECTION_WIDTH en mm, RIM_SIZE en pulgadas [D: SuspensionRacer.cpp, ConversionUtil.hpp]",
  vehicles, controller, surface,
};
const dest = `${outDir(id)}/physics.json`;
await Bun.write(dest, JSON.stringify(out));
const bmw = vehicles["bmwm3gtre46"] as { mass?: number; engine?: { TORQUE?: number[] } } | undefined;
console.log(`physics.json: ${Object.keys(vehicles).length} vehículos · mando ${Object.keys(controller).length} acciones · bmwm3gtre46 ${bmw?.mass} kg, par ${JSON.stringify(bmw?.engine?.TORQUE)}`);
