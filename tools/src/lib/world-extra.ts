// Datos del mundo de NFS MW PS2 fuera de la geometría: regiones de clima y bloom (Weatherman), mapas de parámetros (sonido
// ambiente, reverberación, lluvia, nubes), marcadores de pista, cajas de objetos, animaciones del mundo, TrackInfo,
// perímetros «trough», visibilidad por sección y paquetes de streaming. Ver docs/es/24-efectos-luces-y-mundo.md.
// Etiquetas: [V] verificado en bytes de SLES-53559, [D] decomp, [I] inferido, [H] hipótesis.
import type { Chunk } from "./bchunk";
import { skipPad } from "./effects";

const dvOf = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);
const r3 = (x: number) => Math.round(x * 1000) / 1000;
const cstr = (b: Uint8Array, o: number, n: number) => { let s = ""; for (let i = 0; i < n && b[o + i]; i++) s += String.fromCharCode(b[o + i]); return s; };
const mat16 = (dv: DataView, o: number) => Array.from({ length: 16 }, (_, i) => r3(dv.getFloat32(o + i * 4, true)));
const vec = (dv: DataView, o: number, n: number) => Array.from({ length: n }, (_, i) => r3(dv.getFloat32(o + i * 4, true)));
function exact(what: string, got: number, want: number) { if (got !== want) throw new Error(`${what}: ${got} B, se esperaban ${want}`); }

// ───────────────────────────── 0x00034250 Weatherman: GenericRegion ─────────────────────────────
export const REGION_TYPES = ["RAIN", "FOG", "SNOW", "WIND", "CLEAR", "TUNNEL", "HORIZON_COLOUR", "FOG_VOLUME", "BLOOM"];
/** WeatherRegionPack (0x10: bTNode, Version, NumRegions) + GenericRegion[] (0xA4) [D: World/WeatherMan.hpp][V: 0x10 + 61 × 0xA4]. */
export function readWeatherRegions(buf: Uint8Array, c: Chunk) {
  const dv = dvOf(buf), end = c.dataOffset + c.size;
  const o = skipPad(dv, c.dataOffset, end);
  const version = dv.getInt32(o + 8, true), n = dv.getInt32(o + 12, true);
  exact("WeatherRegionPack", end - o, 0x10 + n * 0xa4);
  const regions = Array.from({ length: n }, (_, i) => {
    const p = o + 0x10 + i * 0xa4, f = (k: number) => r3(dv.getFloat32(p + k, true));
    const type = dv.getInt32(p + 0x48, true);
    return { name: cstr(buf, p + 8, 32), group: cstr(buf, p + 0x28, 32), type: REGION_TYPES[type] ?? type, fogColour: "0x" + dv.getUint32(p + 0x4c, true).toString(16).padStart(8, "0"),
      fogStart: f(0x50), parameter1: f(0x54), pos: [f(0x58), f(0x5c), f(0x60)], radius: f(0x64), intensity: f(0x68), farFalloffStart: f(0x6c),
      fogFalloff: f(0x70), fogFalloffX: f(0x74), fogFalloffY: f(0x78), screenPos: [f(0x7c), f(0x80)], nameHash: dv.getUint32(p + 0x84, true),
      shape: dv.getInt32(p + 0x8c, true), blend: dv.getInt32(p + 0x90, true), modifier: f(0x94), flags: dv.getUint32(p + 0x98, true), effect: f(0x9c), dynamic: dv.getInt32(p + 0xa0, true) };
  });
  return { version, regions };
}

// ───────────────────────────── 0x8003B600 ParameterMaps ─────────────────────────────
/** Capa (0x8003B601): 0x0003B602 cabecera (0x24: NameHash, Left, Top, Right, Bottom, nº nodos, nº conjuntos, tamaño conjunto,
 *  nº campos) · B603 tipos de campo (0 float, 1 int) · B604 offsets · B605 conjuntos · B607 árbol cuaternario u8 (4 B/nodo) o
 *  B608 u16 (8 B/nodo): hoja si hijo0 = 0, dato = hijo1 (índice de conjunto) [D: World/ParameterMaps.cpp][V: tamaños exactos].
 *  Sin relleno: los datos empiezan justo tras la cabecera del chunk [V]. */
export interface ParameterLayer { nameHash: number; name?: string; rect: number[]; fieldTypes: number[]; fieldOffsets: number[]; setSize: number; sets: number[][]; quadBits: 8 | 16 | 0; quads: number[] }
export function readParameterMaps(buf: Uint8Array, c: Chunk, names: Map<number, string>): ParameterLayer[] {
  const dv = dvOf(buf);
  const out: ParameterLayer[] = [];
  for (const L of c.children?.filter(k => k.id === 0x8003b601) ?? []) {
    const get = (id: number) => L.children!.find(k => k.id === id);
    const h = get(0x0003b602); if (!h) continue;
    const o = h.dataOffset, nh = dv.getUint32(o, true);
    const nQuad = dv.getInt32(o + 0x14, true), nSets = dv.getInt32(o + 0x18, true), setSize = dv.getInt32(o + 0x1c, true), nFields = dv.getInt32(o + 0x20, true);
    const ints = (k: Chunk | undefined, n: number) => { if (!k) return []; exact("ParameterMap campos", k.size, n * 4); return Array.from({ length: n }, (_, i) => dv.getInt32(k.dataOffset + i * 4, true)); };
    const types = ints(get(0x0003b603), nFields), offs = ints(get(0x0003b604), nFields);
    const d = get(0x0003b605);
    const sets: number[][] = [];
    if (d) {
      exact("ParameterMap datos", d.size, nSets * setSize);
      for (let s = 0; s < nSets; s++) sets.push(types.map((t, f) => { const p = d.dataOffset + s * setSize + offs[f]; return t === 0 ? r3(dv.getFloat32(p, true)) : dv.getInt32(p, true); }));
    }
    const q8 = get(0x0003b607), q16 = get(0x0003b608);
    const quads: number[] = [];
    if (q8) { exact("ParameterMap quad8", q8.size, nQuad * 4); for (let i = 0; i < nQuad * 4; i++) quads.push(buf[q8.dataOffset + i]); }
    else if (q16) { exact("ParameterMap quad16", q16.size, nQuad * 8); for (let i = 0; i < nQuad * 4; i++) quads.push(dv.getUint16(q16.dataOffset + i * 2, true)); }
    out.push({ nameHash: nh, name: names.get(nh), rect: vec(dv, o + 4, 4), fieldTypes: types, fieldOffsets: offs, setSize, sets, quadBits: q8 ? 8 : q16 ? 16 : 0, quads });
  }
  return out;
}
/** Consulta como ParameterMapLayer::GetParameterSetIndexFromQuadData* [D]: devuelve el índice de conjunto en (x, y). */
export function parameterSetAt(l: ParameterLayer, x: number, y: number) {
  if (!l.quads.length) return 0; // una sola zona: sin árbol [V: capas de 1 conjunto]
  let [left, top, right, bottom] = l.rect, i = 0;
  for (let guard = 0; guard < 64; guard++) {
    const q = l.quads.slice(i * 4, i * 4 + 4);
    if (q[0] === 0) return q[1];
    const cx = (left + right) / 2, cy = (top + bottom) / 2;
    if (x < cx) { right = cx; if (y < cy) { bottom = cy; i = q[0]; } else { top = cy; i = q[1]; } }
    else { left = cx; if (y < cy) { bottom = cy; i = q[2]; } else { top = cy; i = q[3]; } }
  }
  return -1;
}

// ───────────────────────────── 0x00034146 TrackPositionMarker ─────────────────────────────
/** TrackPositionMarker (0x30): bTNode · NameHash · Param · bVector3 pos @0x10 · bAngle @0x20 · TrackNumber @0x24 [D][V: 328 × 0x30]. */
export function readTrackPositionMarkers(buf: Uint8Array, c: Chunk) {
  const dv = dvOf(buf), end = c.dataOffset + c.size, o = skipPad(dv, c.dataOffset, end);
  if ((end - o) % 0x30) throw new Error("TrackPositionMarkers: tamaño no múltiplo de 0x30");
  return Array.from({ length: (end - o) / 0x30 }, (_, i) => { const p = o + i * 0x30; return { nameHash: dv.getUint32(p + 8, true), param: dv.getInt32(p + 12, true), pos: vec(dv, p + 0x10, 3), angle: r3(dv.getUint16(p + 0x20, true) * 360 / 65536), track: dv.getInt32(p + 0x24, true) }; });
}

// ───────────────────────────── 0x00034191 TrackOBB ─────────────────────────────
/** TrackOBB (0x60): TypeNameHash · pad[3] · bMatrix4 @0x10 · bVector3 Dims @0x50 [D: World/Track.hpp][V]. */
export function readTrackOBBs(buf: Uint8Array, c: Chunk) {
  const dv = dvOf(buf);
  if (c.size % 0x60) throw new Error("TrackOBB: tamaño no múltiplo de 0x60");
  return Array.from({ length: c.size / 0x60 }, (_, i) => { const p = c.dataOffset + i * 0x60; return { typeHash: dv.getUint32(p, true), matrix: mat16(dv, p + 0x10), dims: vec(dv, p + 0x50, 3) }; });
}

// ───────────────────────────── WorldAnim 0x00037080/90/110/150 ─────────────────────────────
/** 0x37080 WorldAnimEntityInfo[] (0x70) · 0x37110 WorldAnimEntityTreeMarker (0x50) · 0x37090 WorldAnimInstance[] (0xA0) ·
 *  0x37150 WorldAnimInstanceEntryInfo[] (0x10) [D: Animation/AnimEntity_WorldEntity.cpp, PS2_types][V: tamaños exactos].
 *  Las curvas son EAGL (0x00E34010), que lee el paso de NIS. */
export function readWorldAnim(buf: Uint8Array, chunks: Chunk[]) {
  const dv = dvOf(buf);
  const arr = (c: Chunk, sz: number) => { const o = skipPad(dv, c.dataOffset, c.dataOffset + c.size); if ((c.dataOffset + c.size - o) % sz) throw new Error(`WorldAnim ${c.id.toString(16)}: no múltiplo de ${sz}`); return Array.from({ length: (c.dataOffset + c.size - o) / sz }, (_, i) => o + i * sz); };
  const trees: { treeHash: number; entities: unknown[]; namedRanges: { name: number; range: number }[] }[] = [];
  let pending: unknown[] = [];
  const instances: unknown[] = [], controls: unknown[] = [];
  for (const c of chunks) {
    if (c.id === 0x00037080) for (const p of arr(c, 0x70)) pending.push({ type: dv.getUint32(p, true), instance: dv.getUint32(p + 4, true), parentInstance: dv.getUint32(p + 8, true),
      model: dv.getUint32(p + 0x0c, true), lodB: dv.getUint32(p + 0x10, true), lodZ: dv.getUint32(p + 0x14, true), animTree: dv.getUint32(p + 0x20, true), anim: dv.getUint32(p + 0x24, true),
      contentFlags: buf[p + 0x28], parentIndex: dv.getInt8(p + 0x29), localMatrix: mat16(dv, p + 0x30) });
    else if (c.id === 0x00037110) { const p = arr(c, 0x50)[0]; trees.push({ treeHash: dv.getUint32(p, true), entities: pending, namedRanges: [0, 1, 2, 3].map(k => ({ name: dv.getUint32(p + 0x10 + k * 16, true), range: dv.getUint32(p + 0x14 + k * 16, true) })).filter(r => r.name) }); pending = []; }
    else if (c.id === 0x00037090) for (const p of arr(c, 0xa0)) instances.push({ id: dv.getUint32(p, true), animTree: dv.getUint32(p + 4, true), section: dv.getInt32(p + 8, true),
      playFlags: dv.getUint32(p + 0x0c, true), speed: r3(dv.getFloat32(p + 0x10, true)), masterDelay: r3(dv.getFloat32(p + 0x14, true)), loopDelay: r3(dv.getFloat32(p + 0x18, true)),
      range: [dv.getUint16(p + 0x1c, true), dv.getUint16(p + 0x1e, true)], startTrigger: dv.getUint32(p + 0x20, true), stopTrigger: dv.getUint32(p + 0x24, true),
      namedRange: dv.getUint32(p + 0x30, true), eventTrack: dv.getUint32(p + 0x34, true), track: dv.getUint32(p + 0x38, true), trackDir: dv.getInt16(p + 0x3c, true),
      matrix: mat16(dv, p + 0x40), bboxMin: vec(dv, p + 0x80, 3), bboxMax: vec(dv, p + 0x90, 3) });
    else if (c.id === 0x00037150) for (const p of arr(c, 0x10)) controls.push({ id: dv.getUint32(p, true), animTree: dv.getUint32(p + 4, true), section: dv.getUint32(p + 8, true), evalTime: r3(dv.getFloat32(p + 12, true)) });
  }
  return { trees, instances, controls };
}

// ───────────────────────────── 0x00034201 TrackInfo (GLOBALB.BUN) ─────────────────────────────
/** TrackInfo (0x120) [D: PS2_types TrackInfo][V: 18 × 0x120 = 5184]. */
export function readTrackInfos(buf: Uint8Array, c: Chunk) {
  const dv = dvOf(buf), o0 = skipPad(dv, c.dataOffset, c.dataOffset + c.size);
  if ((c.dataOffset + c.size - o0) % 0x120) throw new Error("TrackInfo: no múltiplo de 0x120");
  const LOC = ["UPPER_CLASS", "CITY_CORE", "SUBURBAN_HILLS", "INDUSTRIAL_PARK", "AIRPORT", "MODE_SPECIFIC"];
  return Array.from({ length: (c.dataOffset + c.size - o0) / 0x120 }, (_, i) => {
    const p = o0 + i * 0x120, f = (k: number) => r3(dv.getFloat32(p + k, true)), ang = (k: number) => r3(dv.getUint16(p + k, true) * 360 / 65536);
    return { name: cstr(buf, p, 32), trackDirectory: cstr(buf, p + 0x20, 32), region: cstr(buf, p + 0x40, 8), regionDirectory: cstr(buf, p + 0x48, 32),
      locationNumber: dv.getInt32(p + 0x68, true), locationDirectory: cstr(buf, p + 0x6c, 16), location: LOC[dv.getInt32(p + 0x7c, true)] ?? dv.getInt32(p + 0x7c, true),
      driftType: dv.getInt32(p + 0x80, true), isValid: buf[p + 0x84], point2point: buf[p + 0x85], reverseExists: buf[p + 0x86], performanceTuning: buf[p + 0x88],
      trackNumber: dv.getInt16(p + 0x8a, true), sameAs: dv.getInt16(p + 0x8c, true), sunInfoHash: dv.getUint32(p + 0x90, true), usageFlags: dv.getUint32(p + 0x94, true),
      trackLength: dv.getUint32(p + 0x98, true), timeToBeat: [f(0x9c), f(0xa0)], mapUpperLeft: [f(0xac), f(0xb0)], mapWidthMetres: f(0xb4), mapRotation: ang(0xb8),
      mapStartLineAngle: ang(0xba), mapFinishLineAngle: ang(0xbc), mapZoomFactor: f(0xc0), difficulty: [dv.getInt32(p + 0xc4, true), dv.getInt32(p + 0xc8, true)],
      shortcutDelaySeconds: dv.getInt16(p + 0xdc, true), maxTrafficCars: Array.from({ length: 8 }, (_, k) => dv.getInt8(p + 0xe4 + k)),
      trafficOncomingFraction: [0, 1, 2, 3].map(k => f(0x100 + k * 4)), mapZoomTopLeft: [f(0x110), f(0x114)], mapZoomWidth: f(0x118), mapStartZoomed: buf[p + 0x11c] };
  });
}

// ───────────────────────────── 0x00034190 «Trough» (TRACKS\L2RA\TROUGHBOUNDARY.BIN) ─────────────────────────────
/** Polígono con nombre [V: 8 + 80 + 4 + 2 + 2 + 16 + 4 + n × 8 = tamaño del chunk en los 563]: u32 ×2 a cero · char Name[80] ·
 *  u32 tipo · u16 a · u16 b · bVector2 caja mín/máx · u32 n · bVector2 puntos[n]. Struct en los tipos de PS2 de la decomp
 *  [D: symbols/PS2/PS2_types.nothpp «struct TroughBoundary» 0x10074]: +0x08 Name[80] · +0x58 s8 TypeRegularTrough · +0x59 s8 TypeTroughHole ·
 *  +0x5A s8 TypeAntiTrough · +0x5B pad (→ `type` u32: 0x1 normal, 0x100 agujero, 0x10000 anti) · +0x5C s16 TroughNumber (`a`) ·
 *  +0x5E s16 ParentTroughNumber (`b`) · +0x60/+0x68 BBox · +0x70 NumPoints · +0x74 Points[]. 484 normales + 79 agujeros [V].
 *  Nombres TRN_* y TROUGH_* por zonas (carreteras, terreno, atajos) [I]; uso exacto (¿límite fuera del mapa / reinicio?) [H]. */
export function readTrough(buf: Uint8Array, c: Chunk) {
  const dv = dvOf(buf), o = c.dataOffset, n = dv.getUint32(o + 0x70, true);
  exact("Trough", c.size, 0x74 + n * 8);
  return { name: cstr(buf, o + 8, 80), type: dv.getUint32(o + 0x58, true), a: dv.getUint16(o + 0x5c, true), b: dv.getUint16(o + 0x5e, true),
    bboxMin: vec(dv, o + 0x60, 2), bboxMax: vec(dv, o + 0x68, 2), points: Array.from({ length: n }, (_, i) => vec(dv, o + 0x74 + i * 8, 2)) };
}

// ───────────────────────────── Visibilidad y streaming (L2RA.BUN) ─────────────────────────────
/** 0x80034150 VisibleSectionManager [D: PS2_types, World/VisibleSection.hpp][V: tamaños sumados exactos]:
 *  0x34151 VisibleSectionManagerInfo (LODOffset + DrivableSectionsInRegion {n, s16[400]}) ·
 *  0x34152 VisibleSectionBoundary (0x24 + NumPoints × 8, en disco de tamaño variable) ·
 *  0x34153 DrivableScenerySection (0x12 + MaxVisibleSections × 2, alineado a 4 [V]; las NumVisible primeras son válidas: lista de secciones visibles desde cada sección conducible) ·
 *  0x34155 LoadingSection (0x4C) · 0x34158 VisibleSectionOverlay (0x34 + NumEntries × 6). */
export function readVisibility(buf: Uint8Array, mgr: Chunk) {
  const dv = dvOf(buf);
  const out = { lodOffset: 0, drivableInRegion: [] as number[], boundaries: [] as unknown[], drivable: [] as unknown[], loading: [] as unknown[], overlays: [] as unknown[] };
  for (const c of mgr.children ?? []) {
    const end = c.dataOffset + c.size;
    if (c.id === 0x00034151) { out.lodOffset = dv.getInt32(c.dataOffset, true); const n = dv.getInt32(c.dataOffset + 4, true); out.drivableInRegion = Array.from({ length: n }, (_, i) => dv.getInt16(c.dataOffset + 8 + i * 2, true)); }
    else if (c.id === 0x00034152) for (let o = c.dataOffset; o < end;) {
      const n = dv.getInt8(o + 0x0a);
      out.boundaries.push({ section: dv.getInt16(o + 8, true), panorama: dv.getInt8(o + 0x0b), bboxMin: vec(dv, o + 0x0c, 2), bboxMax: vec(dv, o + 0x14, 2), centre: vec(dv, o + 0x1c, 2), points: Array.from({ length: n }, (_, i) => vec(dv, o + 0x24 + i * 8, 2)) });
      o += 0x24 + n * 8; if (o > end) throw new Error("VisibleSectionBoundary se sale del chunk");
    }
    else if (c.id === 0x00034153) for (let o = c.dataOffset; o < end;) {
      const n = dv.getInt16(o + 0x10, true);
      out.drivable.push({ section: dv.getInt16(o + 0x0c, true), mostVisible: dv.getInt8(o + 0x0e), maxVisible: dv.getInt8(o + 0x0f), visible: Array.from({ length: n }, (_, i) => dv.getInt16(o + 0x12 + i * 2, true)) });
      o += (0x12 + Math.max(n, dv.getInt8(o + 0x0f)) * 2 + 3) & ~3; if (o > end) throw new Error("DrivableScenerySection se sale del chunk");
    }
    else if (c.id === 0x00034155) { exact("LoadingSection", c.size % 0x4c, 0); for (let o = c.dataOffset; o < end; o += 0x4c) { const nd = dv.getInt16(o + 0x18, true), ne = dv.getInt16(o + 0x3a, true);
      out.loading.push({ name: cstr(buf, o + 8, 15), isDefault: buf[o + 0x17], drivable: Array.from({ length: nd }, (_, i) => dv.getInt16(o + 0x1a + i * 2, true)), extra: Array.from({ length: ne }, (_, i) => dv.getInt16(o + 0x3c + i * 2, true)) }); } }
    else if (c.id === 0x00034158) { const n = dv.getInt32(c.dataOffset + 0x30, true); exact("VisibleSectionOverlay", c.size, 0x34 + n * 6);
      out.overlays.push({ name: cstr(buf, c.dataOffset + 8, 40), entries: Array.from({ length: n }, (_, i) => { const p = c.dataOffset + 0x34 + i * 6; return [dv.getInt8(p), dv.getInt16(p + 2, true), dv.getInt16(p + 4, true)]; }) }); }
  }
  return out;
}
/** 0x00034113 DiscBundleSection (0x14 + NumMembers × 8: FileOffset, FileSize, Name[11], n, {s16 sección, s16 offset/2048?, ptr}) [D][V]. */
export function readDiscBundles(buf: Uint8Array, c: Chunk) {
  const dv = dvOf(buf), end = c.dataOffset + c.size, out: unknown[] = [];
  for (let o = c.dataOffset; o < end;) {
    const n = dv.getInt8(o + 0x13);
    out.push({ fileOffset: dv.getInt32(o, true), fileSize: dv.getInt32(o + 4, true), name: cstr(buf, o + 8, 11), members: Array.from({ length: n }, (_, i) => [dv.getInt16(o + 0x14 + i * 8, true), dv.getInt16(o + 0x16 + i * 8, true)]) });
    o += 0x14 + n * 8; if (o > end) throw new Error("DiscBundleSection se sale del chunk");
  }
  return out;
}
