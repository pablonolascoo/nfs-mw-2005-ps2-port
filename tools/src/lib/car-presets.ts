// Coches predefinidos («preset rides») y base de piezas de coche de NFS MW (PS2).
// Todo sale de GLOBAL\GLOBALB.BUN [V]:
//   0x00034600  CarTypeInfo[84]    (0xD0 B cada uno, datos alineados a 16 → 8 B de relleno 0x11) [D: CarInfo.hpp]
//   0x00034607  tabla de tipos por ranura: u32[139×2] + CarSlotTypeOverride[10] (0x10 B) [D: LoaderCarInfo]
//   0x80034602  CarPartPack: 0x34603 cabecera (60 B) · 0x34606 cadenas · 0x3460c tablas de atributos (int16)
//               · 0x34605 atributos (8 B) · 0x3460a modelos (0x18 B) · 0x3460b nombres de tipo (u32) · 0x34604 piezas (0xE B)
//   0x00030220  PresetCar[82]      (0x290 B en PS2: 0x28C + relleno de alineación del u64) [D: CarInfo.hpp, V: 53792 = 82 × 0x290]
// Cada preset guarda, por ranura (CARSLOTID 0–138), el hash del nombre de la pieza: 0 = vacía, 1 = la de serie [D: FillWithPreset].
import { parseChunks, walk, type Chunk } from "./bchunk";
import { bStringHash as H, hex8 } from "./hash";

/** CARSLOTID_* (CarPartID.h) [D]. */
export const SLOT_NAMES: string[] = (() => {
  const s = ["BASE", "DAMAGE_FRONT_WINDOW", "DAMAGE_BODY", "DAMAGE_COP_LIGHTS", "DAMAGE_COP_SPOILER", "DAMAGE_FRONT_WHEEL", "DAMAGE_LEFT_BRAKELIGHT", "DAMAGE_RIGHT_BRAKELIGHT", "DAMAGE_LEFT_HEADLIGHT", "DAMAGE_RIGHT_HEADLIGHT", "DAMAGE_HOOD", "DAMAGE_BUSHGUARD", "DAMAGE_FRONT_BUMPER", "DAMAGE_RIGHT_DOOR", "DAMAGE_RIGHT_REAR_DOOR", "DAMAGE_TRUNK", "DAMAGE_REAR_BUMPER", "DAMAGE_REAR_LEFT_WINDOW", "DAMAGE_FRONT_LEFT_WINDOW", "DAMAGE_FRONT_RIGHT_WINDOW", "DAMAGE_REAR_RIGHT_WINDOW", "DAMAGE_LEFT_DOOR", "DAMAGE_LEFT_REAR_DOOR",
    "BODY", "FRONT_BRAKE", "FRONT_LEFT_WINDOW", "FRONT_RIGHT_WINDOW", "FRONT_WINDOW", "INTERIOR", "LEFT_BRAKELIGHT", "LEFT_BRAKELIGHT_GLASS", "LEFT_HEADLIGHT", "LEFT_HEADLIGHT_GLASS", "LEFT_SIDE_MIRROR", "REAR_BRAKE", "REAR_LEFT_WINDOW", "REAR_RIGHT_WINDOW", "REAR_WINDOW", "RIGHT_BRAKELIGHT", "RIGHT_BRAKELIGHT_GLASS", "RIGHT_HEADLIGHT", "RIGHT_HEADLIGHT_GLASS", "RIGHT_SIDE_MIRROR", "DRIVER", "SPOILER", "UNIVERSAL_SPOILER_BASE",
    "DAMAGE0_FRONT", "DAMAGE0_FRONTLEFT", "DAMAGE0_FRONTRIGHT", "DAMAGE0_REAR", "DAMAGE0_REARLEFT", "DAMAGE0_REARRIGHT"];
  for (let i = 0; i < 10; i++) s.push(`ATTACHMENT${i}`);
  s.push("ROOF", "HOOD", "HEADLIGHT", "BRAKELIGHT", "FRONT_WHEEL", "REAR_WHEEL", "SPINNER", "LICENSE_PLATE", "DECAL_FRONT_WINDOW", "DECAL_REAR_WINDOW", "DECAL_LEFT_DOOR", "DECAL_RIGHT_DOOR", "DECAL_LEFT_QUARTER", "DECAL_RIGHT_QUARTER", "BASE_PAINT", "VINYL_LAYER0", "PAINT_RIM", "VINYL_COLOUR0_0", "VINYL_COLOUR0_1", "VINYL_COLOUR0_2", "VINYL_COLOUR0_3");
  for (const z of ["FRONT_WINDOW", "REAR_WINDOW", "LEFT_DOOR", "RIGHT_DOOR", "LEFT_QUARTER", "RIGHT_QUARTER"]) for (let i = 0; i < 8; i++) s.push(`DECAL_${z}_TEX${i}`);
  s.push("WINDOW_TINT", "CUSTOM_HUD", "HUD_BACKING_COLOUR", "HUD_NEEDLE_COLOUR", "HUD_CHARACTER_COLOUR", "CV", "WHEEL_MANUFACTURER", "MISC");
  return s;
})();
export const SLOT = Object.fromEntries(SLOT_NAMES.map((n, i) => [n, i])) as Record<string, number>;
export const NUM_SLOTS = 139;

/** CarPartSlotMap [D: CarInfo.cpp]: ranura → CARPARTID. */
export function partIdForSlot(slot: number): number {
  if (slot <= 65) return slot;
  if (slot <= 67) return 67;          // FRONT/REAR_WHEEL → WHEEL
  if (slot <= 75) return slot;        // SPINNER … DECAL_RIGHT_QUARTER
  if (slot === 76) return 76;         // BASE_PAINT → PAINT
  if (slot === 77) return 79;         // VINYL_LAYER0 → VINYL
  if (slot === 78) return 78;         // PAINT_RIM → RIM_PAINT
  if (slot <= 82) return 77;          // VINYL_COLOUR → VINYL_PAINT
  if (slot <= 130) return 80;         // DECAL_*_TEXn → DECAL_TEXTURE
  return [81, 82, 83, 83, 83, 84, 85, 86][slot - 131];
}

/** Nombres de atributo de pieza resueltos por bStringHash [V: los 25 hashes del disco salvo 0x311151f8]. */
const ATTR_NAMES = ["RED", "GREEN", "BLUE", "GLOSS", "TEXTURE", "NUMCOLOURS", "REMAP", "NUMREMAPCOLOURS", "BRAND_NAME", "TEXTURE_NAME", "LIGHT_MATERIAL_NAME", "CARBONFIBRE", "USEMARKER1", "USEMARKER2", "SPEECHCOLOUR", "NAME", "SPOKE_COUNT", "OUTER_RADIUS", "INNER_RADIUS", "DAMAGELEVEL", "CV", "KITNUMBER", "EXCLUDEDECAL", "SIZE", "SHAPE", "SPINNER_TEXTURE"];
const ATTR = new Map(ATTR_NAMES.map(n => [H(n), n]));
/** Atributos cuyo parámetro es un desplazamiento (×4) en la tabla de cadenas [D: GetAppliedAttributeString]. */
const STRING_ATTRS = new Set(["TEXTURE", "NAME"]);

export interface CarTypeInfo { index: number; name: string; baseModel: string; geometry: string; manufacturer: string; usage: number; skinnable: number; defaultSkin: number; defaultBasePaint: number }
export interface CarPart { index: number; nameHash: number; name: string; partId: number; upgrade: number; group: number; carType: string; carTypeHash: number; attrs: Record<string, number | string>; baseSel: number; modelTable: number; brandHash: number }
export interface ModelTable { templated: boolean; middle: string | null; names: (string | number | null)[] }
export interface PresetCar { carType: string; name: string; feKey: string; vehicleKey: string; filterBits: number; physicsLevel: number; parts: number[] }

export interface CarDb {
  types: CarTypeInfo[];
  parts: CarPart[];
  models: ModelTable[];
  presets: PresetCar[];
  typeNames: Map<number, string>;
  slotTypes: number[][];                 // por ranura: 2 hashes de tipo (0xFFFFFFFF = el propio coche)
  overrides: { carType: number; slot: number; types: [number, number] }[];
}

const cstr = (b: Uint8Array, o: number, n: number) => { let s = ""; for (let i = 0; i < n && b[o + i]; i++) s += String.fromCharCode(b[o + i]); return s; };

export function readCarDb(globalb: Uint8Array): CarDb {
  const dv = new DataView(globalb.buffer, globalb.byteOffset, globalb.byteLength);
  const all = [...walk(parseChunks(globalb))].map(([c]) => c);
  const ch = (id: number): Chunk => { const c = all.find(x => x.id === id); if (!c) throw new Error(`GLOBALB sin chunk ${hex8(id)}`); return c; };

  // CarTypeInfo (alineado a 16: se salta el relleno 0x11)
  const cti = ch(0x00034600);
  let o = cti.dataOffset; while (globalb[o] === 0x11 && o < cti.dataOffset + 16) o++;
  const types: CarTypeInfo[] = [];
  for (let i = 0; o + 0xd0 <= cti.dataOffset + cti.size; i++, o += 0xd0) {
    types.push({ index: i, name: cstr(globalb, o, 16), baseModel: cstr(globalb, o + 0x10, 16), geometry: cstr(globalb, o + 0x20, 32), manufacturer: cstr(globalb, o + 0x40, 16),
      usage: dv.getInt32(o + 0x94, true), defaultSkin: dv.getInt8(o + 0xc6), skinnable: dv.getInt8(o + 0xc7), defaultBasePaint: dv.getUint32(o + 0xcc, true) });
  }

  // Tabla de tipos por ranura
  const st = ch(0x00034607);
  const slotTypes: number[][] = [];
  for (let s = 0; s < NUM_SLOTS; s++) slotTypes.push([dv.getUint32(st.dataOffset + s * 8, true), dv.getUint32(st.dataOffset + s * 8 + 4, true)]);
  const overrides: CarDb["overrides"] = [];
  for (let p = st.dataOffset + 280 * 4 - 8; p + 16 <= st.dataOffset + st.size; p += 16)
    overrides.push({ carType: dv.getUint32(p, true), slot: dv.getUint32(p + 4, true), types: [dv.getUint32(p + 8, true), dv.getUint32(p + 12, true)] });

  // CarPartPack
  const hdr = ch(0x00034603).dataOffset;
  const numParts = dv.getUint32(hdr + 0x38, true), numAttrs = dv.getUint32(hdr + 0x20, true), numTypes = dv.getUint32(hdr + 0x28, true);
  const strs = ch(0x00034606), mt = ch(0x0003460a), atabs = ch(0x0003460c), attrs = ch(0x00034605), tn = ch(0x0003460b), pt = ch(0x00034604);
  const str = (off4: number) => cstr(globalb, strs.dataOffset + off4 * 4, 64);
  const typeHashes: number[] = [];
  for (let i = 0; i < numTypes; i++) typeHashes.push(dv.getUint32(tn.dataOffset + i * 4, true));
  const typeNames = new Map<number, string>();
  for (const t of types) { typeNames.set(H(t.name), t.name); typeNames.set(H(t.baseModel), t.baseModel); }
  for (const n of ["UNIVERSAL", "GLOBAL", "WHEELS", "SPOILER", "ROOF", "BRAKES", "DECALS", "VINYLS", "PAINTS", "HUD", "CV", "MISC", "TIRES"]) typeNames.set(H(n), n);
  const parts: CarPart[] = [];
  for (let i = 0; i < numParts; i++) {
    const p = pt.dataOffset + i * 14;
    const nameHash = ((dv.getUint16(p + 2, true) << 16) | dv.getUint16(p, true)) >>> 0;
    const gu = globalb[p + 5], typeIdx = globalb[p + 7], nameOff = dv.getUint16(p + 8, true), atOff = dv.getUint16(p + 10, true);
    const a: Record<string, number | string> = {};
    if (atOff !== 0xffff) {
      const t = atabs.dataOffset + atOff * 2, n = dv.getInt16(t, true);
      for (let k = 0; k < n; k++) {
        const ai = dv.getInt16(t + 2 + k * 2, true);
        if (ai < 0 || ai >= numAttrs) continue;
        const ka = dv.getUint32(attrs.dataOffset + ai * 8, true), v = dv.getUint32(attrs.dataOffset + ai * 8 + 4, true);
        const kn = ATTR.get(ka) ?? hex8(ka);
        if (kn in a) continue; // GetFirstAppliedAttribute: gana el primero
        a[kn] = STRING_ATTRS.has(kn) ? str(v) : (["RED", "GREEN", "BLUE", "GLOSS", "NUMCOLOURS", "REMAP", "NUMREMAPCOLOURS", "SPOKE_COUNT", "OUTER_RADIUS", "INNER_RADIUS", "DAMAGELEVEL", "KITNUMBER", "SIZE", "SHAPE", "USEMARKER1", "USEMARKER2", "CARBONFIBRE", "EXCLUDEDECAL"].includes(kn) ? v | 0 : v >>> 0);
      }
    }
    const th = typeHashes[typeIdx] ?? 0;
    parts.push({ index: i, nameHash, name: nameOff === 0xffff ? "" : str(nameOff), partId: globalb[p + 4], upgrade: (gu >> 5) & 7, group: gu & 0x1f, carTypeHash: th, carType: typeNames.get(th) ?? hex8(th), attrs: a,
      baseSel: dv.getInt8(p + 6), modelTable: dv.getUint16(p + 12, true), brandHash: typeof a.BRAND_NAME === "number" ? a.BRAND_NAME : 0 });
  }
  // Tablas de modelos (CarPartModelTable, 0x18 B) [D]: con TemplatedNameHashes, cada nombre es un desplazamiento (×4) en las cadenas.
  const models: ModelTable[] = [];
  for (let q = mt.dataOffset; q + 0x18 <= mt.dataOffset + mt.size; q += 0x18) {
    const templated = globalb[q] !== 0, mid = dv.getUint16(q + 2, true);
    const names: (string | number | null)[] = [];
    for (let l = 0; l < 5; l++) { const v = dv.getUint32(q + 4 + l * 4, true); names.push(v === 0xffffffff ? null : templated ? str(v) : v); }
    models.push({ templated, middle: mid === 0xffff ? null : str(mid), names });
  }

  // Presets
  const pc = ch(0x00030220);
  const presets: PresetCar[] = [];
  const u64 = (q: number) => hex8(dv.getUint32(q + 4, true)) + hex8(dv.getUint32(q, true));
  for (let q = pc.dataOffset; q + 0x28c <= pc.dataOffset + pc.size; q += 0x290) {
    const ph: number[] = [];
    for (let s = 0; s < NUM_SLOTS; s++) ph.push(dv.getUint32(q + 0x60 + s * 4, true));
    presets.push({ carType: cstr(globalb, q + 8, 32), name: cstr(globalb, q + 0x28, 32), feKey: u64(q + 0x48), vehicleKey: u64(q + 0x50), filterBits: dv.getUint32(q + 0x58, true), physicsLevel: dv.getInt32(q + 0x5c, true), parts: ph });
  }
  return { types, parts, models, presets, typeNames, slotTypes, overrides };
}

/** GetTypesFromSlot [D]: los dos tipos de pieza válidos para una ranura de un coche. */
export function typesForSlot(db: CarDb, slot: number, carTypeName: string): number[] {
  const ct = H(carTypeName);
  const ov = db.overrides.find(o => o.carType === ct && o.slot === slot);
  if (ov) return ov.types;
  return db.slotTypes[slot].map(t => (t === 0xffffffff ? ct : t));
}

/** CarPartDatabase::NewGetCarPart [D] (primer resultado). nameHash 0 = cualquiera. */
const partIndex = new WeakMap<CarDb, Map<string, CarPart[]>>();
export function findPart(db: CarDb, carTypeName: string, slot: number, nameHash: number, upgrade = -1): CarPart | undefined {
  let idx = partIndex.get(db);
  if (!idx) { idx = new Map(); for (const p of db.parts) { const k = `${p.partId}|${p.carTypeHash}`; (idx.get(k) ?? idx.set(k, []).get(k)!).push(p); } partIndex.set(db, idx); }
  const pid = partIdForSlot(slot);
  for (const t of typesForSlot(db, slot, carTypeName)) {
    if (!t) continue;
    const p = idx.get(`${pid}|${t}`)?.find(p => (nameHash === 0 || p.nameHash === nameHash) && (upgrade === -1 || p.upgrade === upgrade));
    if (p) return p;
  }
}

export const rgbHex = (p?: CarPart) => p && "RED" in p.attrs ? [p.attrs.RED, p.attrs.GREEN, p.attrs.BLUE].map(v => (+v & 255).toString(16).padStart(2, "0")).join("") : undefined;

/** CarPart::GetModelNameHash(0, lod) [D]: hash del nombre del sólido para LOD A–E (0 = sin modelo). */
export function modelNameHash(db: CarDb, part: CarPart, lod: number): number {
  if (part.modelTable === 0xffff) return 0;
  const t = db.models[part.modelTable];
  const n = t?.names[lod];
  if (n == null) return 0;
  if (!t.templated) return n as number;
  let h = part.baseSel === 0 ? 0xffffffff : part.baseSel === 1 ? part.carTypeHash : part.brandHash;
  if (t.middle != null) h = H(t.middle, h);
  h = H(n as string, h);
  return H(`_${"ABCDE"[lod]}`, h);
}
