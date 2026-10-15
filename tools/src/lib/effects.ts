// Efectos del mundo de NFS MW PS2: emisores de partículas, objetos rompibles, disparadores, destellos, hoja del helicóptero,
// texturas animadas y jerarquías de modelos. Ver docs/es/24-efectos-luces-y-mundo.md.
// Etiquetas: [V] verificado en bytes de SLES-53559 (tamaño = cabecera + n × struct, posiciones dentro de Rockport),
// [D] decomp (symbols/PS2/PS2_types.nothpp, Ecstasy/EmitterSystem.*, World/*), [I] inferido, [H] hipótesis.
import type { Chunk } from "./bchunk";
import { attribHash, type AttribDatabase, type CollectionInfo, type Value } from "./vlt";

const PAD = 0x11111111;
const dvOf = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);
/** Salta el relleno 0x11111111 que precede a los datos alineados a 16 (GetAlignedData(16)) [V]. */
export function skipPad(dv: DataView, o: number, end: number) { while (o + 4 <= end && dv.getUint32(o, true) === PAD) o += 4; return o; }
const r3 = (x: number) => Math.round(x * 1000) / 1000;
const mat16 = (dv: DataView, o: number) => Array.from({ length: 16 }, (_, i) => r3(dv.getFloat32(o + i * 4, true)));
const cstr = (b: Uint8Array, o: number, n: number) => { let s = ""; for (let i = 0; i < n && b[o + i]; i++) s += String.fromCharCode(b[o + i]); return s; };
const h8 = (n: number) => "0x" + (n >>> 0).toString(16).padStart(8, "0");

// ───────────────────────────── 0x0003BC00 EmitterLibrary (emisores colocados en el mundo) ─────────────────────────────
/** WorldFXTrigger (0x30) [D: EmitterSystem.h]: bTNode 8 B · mLib · f32 radio @0x0C · bVector3 pos @0x10 (+w) ·
 *  f32 reinicio @0x20 · u16 probabilidad @0x24 (0xFFFF = siempre) · u8 estado · u8 flags · f32 fin · pad [V]. */
export interface FxTrigger { radius: number; pos: number[]; resetTime: number; probability: number; state: number; flags: number }
/** EmitterLibrary (0x50) [D]: u32 GroupKey (clave Attrib de un `emittergroup`) · pad · u16 sección · u16 nº disparadores ·
 *  mGroup · bMatrix4 LocalWorld @0x10 (filas; fila 3 = posición en metros del mundo, Z arriba) [V]. */
export interface EmitterLibrary { groupKey: number; section: number; matrix: number[]; triggers: FxTrigger[] }
export interface EmitterLibraryPack { version: number; section: number; libraries: EmitterLibrary[] }

/** EmitterLibraryHeader (0x10): {EndianSwapped, Version, NumEmitterLibraries, SectionNumber}, luego por biblioteca
 *  EmitterLibrary + mNumTriggers × WorldFXTrigger [D: EmitterLibraryHeader::GetLibrary][V: suma exacta del chunk]. */
export function readEmitterLibraryPack(buf: Uint8Array, c: Chunk): EmitterLibraryPack {
  const dv = dvOf(buf), end = c.dataOffset + c.size;
  let o = skipPad(dv, c.dataOffset, end);
  const version = dv.getInt32(o + 4, true), n = dv.getInt32(o + 8, true), section = dv.getInt32(o + 12, true);
  o += 16;
  const libraries: EmitterLibrary[] = [];
  for (let i = 0; i < n; i++) {
    if (o + 0x50 > end) throw new Error(`EmitterLibrary ${i}/${n} se sale del chunk`);
    const nt = dv.getUint16(o + 10, true);
    const lib: EmitterLibrary = { groupKey: dv.getUint32(o, true), section: dv.getUint16(o + 8, true), matrix: mat16(dv, o + 0x10), triggers: [] };
    o += 0x50;
    for (let k = 0; k < nt; k++, o += 0x30) lib.triggers.push({
      radius: r3(dv.getFloat32(o + 0x0c, true)), pos: [0, 4, 8].map(j => r3(dv.getFloat32(o + 0x10 + j, true))),
      resetTime: r3(dv.getFloat32(o + 0x20, true)), probability: dv.getUint16(o + 0x24, true), state: buf[o + 0x26], flags: buf[o + 0x27],
    });
    libraries.push(lib);
  }
  if (o > end || end - o >= 16) throw new Error(`EmitterLibraryPack: ${end - o} B sin explicar`);
  return { version, section, libraries };
}

// ───────────────────────────── 0x00034027 SmokeableSpawnerPack (objetos rompibles) ─────────────────────────────
/** SmokeableSpawner (0x40) [D: Physics/SmokeableInfo.hpp]: Quaternion @0x00 · Vector4 pos @0x10 (espacio de simulación:
 *  X_mundo = z, Y_mundo = −x, Z_mundo = y [V: coincide con su instancia de escenario]) · UCrc32 modelo/colisión/atributos
 *  (attribHash, clase VLT `smackable`) · nº de SceneryOverrideInfo · id único · ExcludeFlags [V]. */
export interface SmokeableSpawner { quat: number[]; simPos: number[]; model: number; collision: number; attributes: number; overrideInfo: number; uniqueId: number; excludeFlags: number }
export interface SmokeableSpawnerPack { section: number; firstId: number; spawners: SmokeableSpawner[] }

export function readSmokeableSpawnerPack(buf: Uint8Array, c: Chunk): SmokeableSpawnerPack {
  const dv = dvOf(buf), end = c.dataOffset + c.size;
  const o = skipPad(dv, c.dataOffset, end);
  const n = dv.getInt16(o + 0x0c, true);
  if (o + 0x10 + n * 0x40 !== end) throw new Error(`SmokeableSpawnerPack: ${n} × 0x40 no llena el chunk`);
  const spawners: SmokeableSpawner[] = [];
  for (let k = 0; k < n; k++) {
    const p = o + 0x10 + k * 0x40;
    spawners.push({
      quat: [0, 4, 8, 12].map(j => +dv.getFloat32(p + j, true).toFixed(5)), simPos: [0, 4, 8].map(j => r3(dv.getFloat32(p + 0x10 + j, true))),
      model: dv.getUint32(p + 0x20, true), collision: dv.getUint32(p + 0x24, true), attributes: dv.getUint32(p + 0x28, true),
      overrideInfo: dv.getUint32(p + 0x2c, true), uniqueId: dv.getUint32(p + 0x30, true), excludeFlags: dv.getUint32(p + 0x34, true),
    });
  }
  return { section: dv.getInt16(o + 8, true), firstId: dv.getInt16(o + 0x0a, true), spawners };
}

/** Espacio de simulación (Y arriba) → mundo (Z arriba): X = z, Y = −x, Z = y (la misma regla que las carreteras) [V]. */
export const simToWorld = (p: number[]) => [p[2], -p[0], p[1]];
/** Rumbo en el mundo (grados, de +X hacia +Y) de un cuaternión de simulación que gira alrededor de su eje Y [V: y=w≠0, x=z=0]. */
export function simQuatToWorldYaw(q: number[]) {
  const [x, y, z, w] = q;
  // columna X del giro en simulación → mundo
  const fx = [1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)];
  const f = simToWorld(fx);
  return r3((((Math.atan2(f[1], f[0]) * 180) / Math.PI) % 360 + 360) % 360);
}

// ───────────────────────────── 0x80036000 EventTriggerPack (disparadores del mundo) ─────────────────────────────
/** EVENT_ID [D: PS2_types]: el byte alto es el «stream» (1 mundo, 2 policía, 4 sirena). */
export const EVENT_IDS: Record<number, string> = {
  0x10003: "CAR_ON_FERN", 0x10005: "VIEW_DRIVING_LINE", 0x10006: "ACTIVATE_TRAIN", 0x10007: "SOUND", 0x10008: "GUIDE_ARROW", 0x10009: "ACTIVATE_PLANE",
  0x20000: "INITIATE_PURSUIT", 0x20001: "CALL_FOR_BACKUP", 0x20002: "CALL_FOR_ROADBLOCK", 0x20003: "STRATEGY_INITIATE", 0x20004: "COLLISION",
  0x20005: "ANNOUNCE_ARREST", 0x20006: "STRATEGY_OUTCOME", 0x20007: "ROADBLOCK_UPDATE", 0x20008: "CANCEL_PURSUIT", 0x40000: "START_SIREN", 0x40001: "STOP_SIREN",
};
/** EventTrigger (0x20) [D: World/EventManager.hpp]: NameHash · EventID · Parameter · TrackDirectionMask · pos[3] · radio [V]. */
export interface EventTrigger { nameHash: number; eventId: number; parameter: number; directionMask: number; pos: number[]; radius: number }
export interface EventTriggerPack { version: number; section: number; triggers: EventTrigger[]; treeNodes: number }

/** 0x00036001 cabecera (bTNode, Version 2, sección, nº, swapped, punteros; 0x20 B) · 0x00036002 vAABBTree (0x10 + n × vAABB 0x30)
 *  · 0x00036003 EventTrigger[] [D: LoaderEventManager][V]. */
export function readEventTriggerPack(buf: Uint8Array, c: Chunk): EventTriggerPack {
  const dv = dvOf(buf);
  const kid = (id: number) => c.children?.find(k => k.id === id);
  const h = kid(0x00036001), t = kid(0x00036002), e = kid(0x00036003);
  if (!h) throw new Error("EventTriggerPack sin cabecera 0x00036001");
  const ho = skipPad(dv, h.dataOffset, h.dataOffset + h.size);
  const pack: EventTriggerPack = { version: dv.getInt32(ho + 8, true), section: dv.getInt32(ho + 12, true), triggers: [], treeNodes: 0 };
  const n = dv.getInt32(ho + 16, true);
  if (t) { const to = skipPad(dv, t.dataOffset, t.dataOffset + t.size); pack.treeNodes = dv.getInt16(to + 8, true); if (to + 0x10 + pack.treeNodes * 0x30 !== t.dataOffset + t.size) throw new Error("vAABBTree: tamaño inesperado"); }
  if (e) {
    const eo = skipPad(dv, e.dataOffset, e.dataOffset + e.size);
    if ((e.dataOffset + e.size - eo) !== n * 0x20) throw new Error(`EventTrigger: ${n} × 0x20 no llena el chunk`);
    for (let k = 0; k < n; k++) {
      const p = eo + k * 0x20;
      pack.triggers.push({ nameHash: dv.getUint32(p, true), eventId: dv.getUint32(p + 4, true), parameter: dv.getUint32(p + 8, true), directionMask: dv.getInt32(p + 12, true),
        pos: [16, 20, 24].map(j => r3(dv.getFloat32(p + j, true))), radius: r3(dv.getFloat32(p + 28, true)) });
    }
  }
  return pack;
}

// ───────────────────────────── 0x00034159 HeliSheet (altura de vuelo del helicóptero) ─────────────────────────────
/** HeliSection (0x18): bTNode · SectionNumber · NumPolys · EndianSwapped · PolyTable; luego HeliPoly[] de 18 B:
 *  s16 X[3], Y[3], Z[3]; X,Y × 0.25 m, Z × 0.0625 m [D: World/HeliSheet.cpp][V: 0x18 + n × 18 (+relleno a 4)]. */
export interface HeliSection { section: number; polys: Int16Array }
export function readHeliSection(buf: Uint8Array, c: Chunk): HeliSection {
  const dv = dvOf(buf), end = c.dataOffset + c.size;
  const o = skipPad(dv, c.dataOffset, end);
  const n = dv.getInt32(o + 0x0c, true);
  const rest = end - (o + 0x18 + n * 18);
  if (rest < 0 || rest > 3) throw new Error(`HeliSection: ${n} × 18 B no cuadra (${rest})`);
  const polys = new Int16Array(n * 9);
  for (let k = 0; k < n * 9; k++) polys[k] = dv.getInt16(o + 0x18 + k * 2, true);
  return { section: dv.getInt32(o + 8, true), polys };
}

// ───────────────────────────── Marcadores de sólidos (0x0013401A) → destellos del mundo ─────────────────────────────
/** eLightFlareType [D: PS2_types]. En el escenario, tipo = iParam0 del marcador + ELF_CATSEYE_ORANGE [D: Scenery.cpp]. */
export const FLARE_TYPES = ["CAR_HEADLIGHT", "CAR_BRAKELIGHT", "CAR_TRAFFIC_BRAKELIGHT", "CAR_REVERSELIGHT", "CAR_FOGLIGHT", "CAR_COPLIGHTRED",
  "CAR_COPLIGHTBLUE", "CAR_COPLIGHTWHITE", "CAR_COPHEADLIGHTRIGHT", "CAR_COPHEADLIGHTLEFT", "CAR_COPLIGHTBRIGHTRED", "CAR_COPLIGHTBRIGHTBLUE",
  "CAR_COPLIGHTORANGE", "LAMPPOST", "CATSEYE_ORANGE", "CATSEYE_RED", "CATSEYE_BLUE", "BLINKING_AMBER", "BLINKING_RED", "BLINKING_GREEN", "HAND_FLARE", "SUN_FLARE"];
export interface SolidMarkers { name: string; nameHash: number; pivot: number[]; markers: { nameHash: number; iParam0: number; fParam0: number; fParam1: number; pos: number[] }[] }
/** Lectura ligera de un sólido 0x80134010: solo cabecera eSolid (nombre @0xA0, hash @0x10, PivotMatrix @0x40) y ePositionMarker
 *  (0x50: NameHash, iParam0, fParam0, fParam1, bMatrix4) [D: EcstasyData][V]. */
export function readSolidMarkers(buf: Uint8Array, c: Chunk): SolidMarkers | undefined {
  const mk = c.children?.find(k => k.id === 0x0013401a), hdr = c.children?.find(k => k.id === 0x00134011);
  if (!mk || !hdr) return;
  const dv = dvOf(buf);
  const h = skipPad(dv, hdr.dataOffset, hdr.dataOffset + hdr.size);
  const out: SolidMarkers = { name: cstr(buf, h + 0xa0, 64), nameHash: dv.getUint32(h + 0x10, true), pivot: [0x70, 0x74, 0x78].map(j => dv.getFloat32(h + j, true)), markers: [] };
  const end = mk.dataOffset + mk.size;
  const o0 = skipPad(dv, mk.dataOffset, end);
  if ((end - o0) % 0x50) throw new Error(`${out.name}: marcadores de ${end - o0} B no múltiplo de 0x50`);
  for (let o = o0; o + 0x50 <= end; o += 0x50) out.markers.push({ nameHash: dv.getUint32(o, true), iParam0: dv.getInt32(o + 4, true), fParam0: dv.getFloat32(o + 8, true), fParam1: dv.getFloat32(o + 12, true),
    pos: [0x30, 0x34, 0x38].map(j => dv.getFloat32(o + 0x10 + j, true)) }); // fila 3 de la matriz [V]
  return out;
}

// ───────────────────────────── 0xB0300100 TextureAnimPack (texturas animadas) ─────────────────────────────
/** 0x30300101 cabecera (0x10) · 0x30300102 TextureAnim[] (0x34: Name[24], NameHash, NumFrames, FPS, TimeBase…) ·
 *  0x30300103 TextureAnimEntry[] (0x10: NameHash de cada fotograma) [D: PS2_types TextureAnim*][V]. */
export interface TextureAnim { name: string; nameHash: number; fps: number; timeBase: number; frames: number[] }
export function readTextureAnimPack(buf: Uint8Array, c: Chunk): TextureAnim[] {
  const dv = dvOf(buf);
  const a = c.children?.find(k => k.id === 0x30300102), e = c.children?.find(k => k.id === 0x30300103);
  if (!a || !e) return [];
  if (a.size % 0x34 || e.size % 0x10) throw new Error("TextureAnimPack: tamaños no múltiplos de su struct");
  const frames = Array.from({ length: e.size / 0x10 }, (_, i) => dv.getUint32(e.dataOffset + i * 0x10, true));
  const out: TextureAnim[] = [];
  let f = 0;
  for (let o = a.dataOffset; o < a.dataOffset + a.size; o += 0x34) {
    const n = dv.getInt32(o + 0x1c, true);
    out.push({ name: cstr(buf, o, 24), nameHash: dv.getUint32(o + 0x18, true), fps: dv.getInt32(o + 0x20, true), timeBase: dv.getInt32(o + 0x24, true), frames: frames.slice(f, f + n) });
    f += n;
  }
  if (f !== frames.length) throw new Error(`TextureAnimPack: ${f} fotogramas usados de ${frames.length}`);
  return out;
}

/** Nombres de textura de los TPK de un búfer sin decodificar píxeles: TextureInfo (0x7C) del chunk 0x33310004, nombre @0x0C
 *  (24 B, truncado), hash @0x24 [V: tex-ps2.ts]. */
export function textureNames(buf: Uint8Array, chunks: Chunk[], into = new Map<number, string>()) {
  const dv = dvOf(buf);
  const visit = (cs: Chunk[]) => { for (const c of cs) { if (c.children) visit(c.children); else if (c.id === 0x33310004) for (let o = c.dataOffset; o + 0x7c <= c.dataOffset + c.size; o += 0x7c) into.set(dv.getUint32(o + 0x24, true), cstr(buf, o + 0x0c, 24)); } };
  visit(chunks);
  return into;
}

// ───────────────────────────── 0x0003410C ModelHierarchy (modelos con piezas, p. ej. rompibles) ─────────────────────────────
/** ModelHeirarchy (8: NameHash, u8 nº nodos, u8 flags) + Node[] (0x10: UCrc32 nombre, u32 hash de modelo (bStringHash del
 *  sólido), eModel*, u8 flags, padre, nº hijos, primer hijo) [D: PS2_types][V: 8 + n × 0x10]. */
export interface ModelHierarchy { nameHash: number; flags: number; nodes: { name: number; model: number; flags: number; parent: number; numChildren: number; childIndex: number }[] }
export function readModelHierarchy(buf: Uint8Array, c: Chunk): ModelHierarchy {
  const dv = dvOf(buf), o = c.dataOffset, n = buf[o + 4];
  if (8 + n * 16 !== c.size) throw new Error(`ModelHierarchy: ${n} nodos no llenan ${c.size} B`);
  return { nameHash: dv.getUint32(o, true), flags: buf[o + 5], nodes: Array.from({ length: n }, (_, i) => { const p = o + 8 + i * 16; return { name: dv.getUint32(p, true), model: dv.getUint32(p + 4, true), flags: buf[p + 12], parent: buf[p + 13], numChildren: buf[p + 14], childIndex: buf[p + 15] }; }) };
}

// ───────────────────────────── Definiciones de efectos (GLOBAL\ATTRIBUTES.BIN) ─────────────────────────────
/** eTEG_ParticleTextures [D]: el valor del enum es bStringHash del nombre de la textura del pack «PARTICLE» de INGAMEB.BUN [V]. */
export const PARTICLE_TEXTURES = ["FX_BEAN_ADDITIVE", "FX_BEAN_BLEND", "FX_DEBRIS02_BLEND", "FX_FIRE01_ADDITIVE", "FX_FIRE01_BLEND", "FX_FIRE02_ADDITIVE",
  "FX_FIRE02_BLEND", "FX_FIRE03_ADDITIVE", "FX_GLOW01_ADDITIVE", "FX_GLOW02_ADDITIVE", "FX_LEAF01_BLEND", "FX_SMK01_BLEND", "FX_SMK02_BLEND", "FX_SMK03_BLEND",
  "FX_SMK04_ADDITIVE", "FX_SMK04_BLEND", "FX_SMK05_BLEND", "FX_SMK06_BLEND", "FX_SPARK01_ADDITIVE", "FX_SPARK02_ADDITIVE", "FX_SPARK03_ADDITIVE",
  "FX_SPARK04_ADDITIVE", "FX_SPARK05_ADDITIVE", "FX_WATER01_BLEND", "FX_WATER02_BLEND", "FX_WATER03_BLEND", "FX_RINGWAVEA", "FX_SPARK01_ADDITIVE_ANIM",
  "FX_BIRD01_BLEND_ANIM", "FX_LEAF01_BLEND_ANIM", "FX_HIDE_CAR_ICON", "FX_MILESTONE_SPEEDTRAP", "FX_MILESTONE_TOLLBOOTH", "FX_MODE_ICON_CIRCUIT",
  "FX_MODE_ICON_DRAG", "FX_MODE_ICON_LAP_KNOCKOUT", "FX_MODE_ICON_SPRINT", "FX_RIVAL_RACE", "FX_GRASS01_BLEND_ANIM", "FX_DEBRIS01_BLEND_ANIM",
  "FX_WORLD_CARLOT", "FX_WORLD_PURSUITBREAKER", "FX_WORLD_SAFEHOUSE", "FX_WORLD_CHOP_SHOP", "FX_MARKER_BG", "FX_GLASS01_BLEND_ANIM"];

type Raw = { type: string; raw: string[] };
const isRaw = (v: Value): v is Raw & Value => !!v && typeof v === "object" && !Array.isArray(v) && typeof (v as any).type === "string" && Array.isArray((v as any).raw);
const u32 = (s: string) => parseInt(s, 16) >>> 0;
const f32 = (s: string) => { const b = new DataView(new ArrayBuffer(4)); b.setUint32(0, u32(s)); return r3(b.getFloat32(0)); };

/** Biblioteca de efectos del juego: emittergroup → emitterdata (con su textura de partícula), effects (efecto por nombre),
 *  efectos de neumático por superficie (simsurface: TireEffectRecord) y reacciones de los rompibles (smackable) [V][D]. */
export function buildEffectLibrary(db: AttribDatabase, texNames: Map<number, string>) {
  const byClass = (cls: string) => [...db.collections.values()].filter(c => db.names.name(c.classKey) === cls);
  const nameOf = new Map<number, string>();
  for (const c of db.collections.values()) nameOf.set(c.key >>> 0, db.collectionName(c));
  const key = (k: number) => (k ? nameOf.get(k >>> 0) ?? db.names.get(k >>> 0) ?? h8(k) : null);
  // RefSpec dentro de un registro crudo: {u32 clase, u32 colección, puntero} [D: Attrib::RefSpec 0xC]
  const ref = (raw: string[], i: number) => ({ class: key(u32(raw[i])), collection: key(u32(raw[i + 1])) });
  const decodeRecord = (v: Raw) => {
    switch (v.type) {
      case "ParticleTextureRecord": { const h = u32(v.raw[0]); return { texture: texNames.get(h) ?? h8(h), index: u32(v.raw[1]) }; }
      case "ParticleAnimationInfo": { const w = u32(v.raw[1]); return { animType: u32(v.raw[0]), fps: w & 0xff, randomStartFrame: (w >> 8) & 0xff }; }
      case "TireEffectRecord": return { emitter: ref(v.raw, 0).collection, minSpeed: f32(v.raw[3]), maxSpeed: f32(v.raw[4]) };
      case "EffectLinkageRecord": return { surface: ref(v.raw, 0).collection, effect: ref(v.raw, 3).collection, minSpeed: f32(v.raw[6]), maxSpeed: f32(v.raw[7]) };
      case "EmitterDataRecord": return { emitter: ref(v.raw, 0).collection, minIntensity: f32(v.raw[3]), maxIntensity: f32(v.raw[4]) };
      default: return v;
    }
  };
  const clean = (v: Value): Value => {
    if (isRaw(v)) return decodeRecord(v as unknown as Raw) as unknown as Value;
    if (Array.isArray(v)) return v.map(clean);
    if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, clean(x)]));
    return v;
  };
  const dump = (cls: string, pick?: (name: string, v: Record<string, Value>) => Record<string, Value>) => {
    const out: Record<string, Value> = {};
    for (const c of byClass(cls)) { const n = db.collectionName(c); const v = clean(db.resolvedValues(c)) as Record<string, Value>; delete v.CollectionName; out[n] = pick ? pick(n, v) : v; }
    return out;
  };
  const emitterGroups = dump("emittergroup", (_, v) => ({ ...v, Emitters: ((v.Emitters as any[]) ?? []).map(e => e?.collection ?? null) }));
  const emitterData = dump("emitterdata");
  const effects = dump("effects", (_, v) => ({ emittergroup: (v.emittergroup as any)?.collection ?? null, visualCullDist: v.VisualCullDist ?? null, emitterQuadratic: v.EmitterQuadratic ?? null }));
  const TIRE = ["TireSlideEffects", "TireSlipEffects", "TireDriveEffects"];
  const tireEffects = dump("simsurface", (_, v) => Object.fromEntries(TIRE.filter(k => v[k]).map(k => [k, v[k]])));
  const smackables = dump("smackable", (_, v) => Object.fromEntries(Object.entries(v).filter(([k]) => !/^Aud|^0x/.test(k))));
  const fuelcell = { effect: dump("fuelcell_effect"), emitter: dump("fuelcell_emitter"), uv: dump("emitteruv") };
  return { emitterGroups, emitterData, effects, tireEffects, smackables, fuelcell, collectionName: key };
}

/** Clave Attrib de un nombre (UCrc32 de los rompibles y GroupKey de los emisores usan la misma función) [V]. */
export const attribKey = attribHash;
export type { CollectionInfo };
