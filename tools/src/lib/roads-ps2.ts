// Red de carreteras y colisión de Rockport (NFS MW PS2). Ver docs/es/09-red-de-carreteras.md.
//
// Chunks:
//  - 0x0003B800 en L2RA.BUN  = BCHUNK_UPPLE_UWORLD / BCHUNK_CARP_WGRID: un árbol UGroup serializado ("CARP") con
//      · grupo 'CDat': rejilla espacial WGrid ('CGrd') y sus celdas ('CGcn')         [decomp WGrid::Init]
//      · grupo 'Map ': vacío en SLES-53559                                              [V]
//      · grupo 'RNgp': red de carreteras ('RNhd' cabecera, 'RNpf' perfiles, 'RNnd' nodos,
//                      'RNsg' segmentos, 'RNrd' carreteras)                             [decomp WRoadNetwork::Init]
//  - 0x0003B801 en cada sección de STREAML2RA.BUN = BCHUNK_CARP_WCOLLISIONPACK: colisión de la sección.
//      bChunkCarpHeader (16 B) + árbol UGroup "CARP" → grupo 'Arti' con 'ci' (instancias),
//      'ca'+índice (artículos: tiras de triángulos + barreras) y 'Name'.                [decomp WCollisionPack]
//
// Espacio de coordenadas: todo lo de este archivo viene en espacio "Bond"/simulación (Y arriba).
// Paso a mundo (Z arriba, el del render y del resto de herramientas): X = z, Y = -x, Z = y  [decomp bConvertFromBond].
import { parseChunks, walk } from "./bchunk";

// ───────────────────────────── UGroup (serialización CARP) ─────────────────────────────

/** Etiqueta de 4 caracteres: el u32 se lee como texto big-endian ('RN'<<16 | 'gp' → "RNgp"). Índices: tipo de 2 letras + u16. */
export function tagName(tag: number): string {
  const c = [24, 16, 8, 0].map(s => (tag >>> s) & 0xff);
  if (c.every(b => b >= 0x20 && b < 0x7f)) return String.fromCharCode(...c);
  if (c[0] >= 0x20 && c[0] < 0x7f && c[1] >= 0x20 && c[1] < 0x7f) return `${String.fromCharCode(c[0], c[1])}#${tag & 0xffff}`;
  return `0x${(tag >>> 0).toString(16).padStart(8, "0")}`;
}

export interface UData { tag: number; name: string; indexed: boolean; size: number; count: number; offset: number /* absoluto en el buffer */ }
export interface UGroupNode { tag: number; name: string; groups: UGroupNode[]; data: UData[] }

/**
 * Registro de 16 B, igual para grupos y datos [decomp UGroup.hpp; offsets verificados en SLES-53559]:
 *   u32 tag · u32 bits · u32 count · u32 offset
 *  Grupo: bits = indexed:1 embedded:1 allocated:1 dataSorted:1 groupSorted:1 groupCount:27; count = nº de datos;
 *         offset en unidades de 16 B desde el propio registro → hijos: groupCount grupos y luego count datos.
 *  Dato:  bits = indexed:1 embedded:1 allocated:1 section:5 size:24 (bytes totales); count = nº de elementos;
 *         offset en bytes desde el propio registro.
 */
export function parseUGroup(buf: Uint8Array, at: number): UGroupNode {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const rec = (o: number) => ({ tag: dv.getUint32(o, true), bits: dv.getUint32(o + 4, true), count: dv.getUint32(o + 8, true), off: dv.getUint32(o + 12, true) });
  const group = (o: number, depth: number): UGroupNode => {
    if (depth > 16 || o + 16 > buf.length) throw new Error(`UGroup fuera de rango @${o}`);
    const r = rec(o), nGroups = r.bits >>> 5, base = o + r.off * 16;
    const node: UGroupNode = { tag: r.tag, name: tagName(r.tag), groups: [], data: [] };
    for (let i = 0; i < nGroups; i++) node.groups.push(group(base + i * 16, depth + 1));
    for (let i = 0; i < r.count; i++) {
      const p = base + (nGroups + i) * 16, d = rec(p);
      node.data.push({ tag: d.tag, name: tagName(d.tag), indexed: (d.bits & 1) !== 0, size: d.bits >>> 8, count: d.count, offset: p + d.off });
    }
    return node;
  };
  return group(at, 0);
}

const findGroup = (g: UGroupNode, name: string) => g.groups.find(x => x.name === name);
const findData = (g: UGroupNode, name: string) => g.data.find(x => x.name === name);

/** Los datos del chunk empiezan alineados a 16 B (bChunk::GetAlignedData(16)); el hueco se rellena con 0x11. [V] */
function alignedStart(buf: Uint8Array, dataOffset: number, end: number) {
  let o = dataOffset;
  while (o < end && (o & 15) !== 0 && buf[o] === 0x11) o++;
  return o;
}

/** Bond (Y arriba) → mundo (Z arriba). [decomp bConvertFromBond] */
export const bondToWorld = (v: number[]): [number, number, number] => [v[2], -v[0], v[1]];

// ───────────────────────────── Red de carreteras ('RNgp') ─────────────────────────────

/** Bits de WRoadSegment::fFlags. [decomp WRoadElem.h] */
export const SEGMENT_FLAGS: [number, string][] = [
  [1 << 0, "decision"], [1 << 1, "noTraffic"], [1 << 2, "raceRouteForward"], [1 << 3, "intersection"],
  [1 << 4, "entrance"], [1 << 5, "copsXorTraffic"], [1 << 6, "oneWay"], [1 << 7, "shortcut"],
  [1 << 8, "curved"], [1 << 9, "endInverted"], [1 << 10, "startInverted"], [1 << 11, "chopperStayLow"],
  [1 << 12, "crossesBarrier"], [1 << 13, "crossesDriveThroughBarrier"], [1 << 14, "laneMap"], [1 << 15, "inRace"],
];
export const flagNames = (f: number) => SEGMENT_FLAGS.filter(([b]) => f & b).map(([, n]) => n);

export interface RoadNetworkInfo { numProfiles: number; numNodes: number; numSegments: number; numIntersections: number; numRoads: number; numJunctions: number }
/** Carril/zona de un perfil: tipo (4 bits), ancho y desplazamiento lateral en metros (14 bits con signo ×100/8191). */
export interface RoadLane { type: number; width: number; offset: number; raw: number }
/** WRoadProfile (0x40): sección transversal de la calzada. middleZone separa carriles "hacia atrás" (<middle) y "hacia delante". */
export interface RoadProfile { index: number; numZones: number; middleZone: number; lanes: RoadLane[] }
/** WRoadNode (0x20). position en mundo (Z arriba); bond = valor crudo del disco. */
export interface RoadNode { index: number; storedIndex: number; position: [number, number, number]; bond: number[]; profile: number; segments: number[] }
/** WRoadSegment (0x16). Curva Bézier cúbica [inicio, inicio+startControl, fin+endControl, fin] si flag "curved" [H sobre el orden]. */
export interface RoadSegment {
  index: number; storedIndex: number; nodes: [number, number]; length: number; road: number; flags: number; flagNames: string[];
  startControl: [number, number, number]; endControl: [number, number, number]; // mundo, relativos al nodo
  raw: { nLength: number; startHandleLength: number; endHandleLength: number; startHandle: number[]; endHandle: number[] };
}
/** WRoad (8 B): agrupa segmentos de la misma calle. Escalas de nLength/nScale sin confirmar. */
export interface Road { index: number; nScale: number; scale: number; nLength: number; shortcut: number; minWidth: number; speechId: number }
export interface GridInfo { minBond: number[]; edgeSize: number; rows: number; cols: number; cells: GridCell[] }
/** WGridNode: celda de la rejilla con índices a instancias de colisión (sección<<16|índice), triggers, objetos y segmentos. */
export interface GridCell { index: number; row: number; col: number; instances: number[]; triggers: number[]; objects: number[]; roadSegments: number[] }

export interface RoadNetwork {
  info: RoadNetworkInfo; tree: UGroupNode;
  profiles: RoadProfile[]; nodes: RoadNode[]; segments: RoadSegment[]; roads: Road[]; grid: GridInfo | null;
}

/** Busca el chunk 0x0003B800 en L2RA.BUN y devuelve el árbol CARP ya parseado. */
export function readCarpWorld(l2ra: Uint8Array): { tree: UGroupNode; buf: Uint8Array } {
  const c = [...walk(parseChunks(l2ra))].map(([c]) => c).find(c => c.id === 0x0003b800);
  if (!c) throw new Error("L2RA.BUN sin chunk 0x0003B800 (UWorld/CARP)");
  const at = alignedStart(l2ra, c.dataOffset, c.dataOffset + c.size);
  const buf = l2ra.subarray(at, c.dataOffset + c.size);
  return { tree: parseUGroup(buf, 0), buf };
}

const s14 = (bits: number, off: number) => ((bits << (32 - off - 14)) >> (32 - 14));

export function readRoadNetwork(l2ra: Uint8Array): RoadNetwork {
  const { tree, buf } = readCarpWorld(l2ra);
  if (tree.name !== "CARP") throw new Error(`raíz ${tree.name}, se esperaba CARP`);
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const rn = findGroup(tree, "RNgp");
  if (!rn) throw new Error("sin grupo RNgp");
  const need = (n: string, stride: number) => {
    const d = findData(rn, n); if (!d) throw new Error(`sin ${n}`);
    if (d.size !== d.count * stride) throw new Error(`${n}: ${d.size} B ≠ ${d.count}×${stride}`);
    return d;
  };
  const hd = need("RNhd", 14), u16 = (o: number) => dv.getUint16(o, true);
  const info: RoadNetworkInfo = {
    numProfiles: u16(hd.offset), numNodes: u16(hd.offset + 2), numSegments: u16(hd.offset + 4),
    numIntersections: u16(hd.offset + 6), numRoads: u16(hd.offset + 8), numJunctions: u16(hd.offset + 10),
  };

  const pf = need("RNpf", 0x40), profiles: RoadProfile[] = [];
  for (let i = 0; i < pf.count; i++) {
    const o = pf.offset + i * 0x40, numZones = buf[o], lanes: RoadLane[] = [];
    for (let k = 0; k < Math.min(numZones, 15); k++) {
      const b = dv.getUint32(o + 4 + k * 4, true);
      lanes.push({ type: b & 15, width: s14(b, 4) * (100 / 8191), offset: s14(b, 18) * (100 / 8191), raw: b >>> 0 });
    }
    profiles.push({ index: i, numZones, middleZone: buf[o + 1], lanes });
  }

  const nd = need("RNnd", 0x20), nodes: RoadNode[] = [];
  for (let i = 0; i < nd.count; i++) {
    const o = nd.offset + i * 0x20, bond = [0, 4, 8].map(k => dv.getFloat32(o + k, true));
    const n = buf[o + 0x10], segments: number[] = [];
    for (let k = 0; k < Math.min(n, 7); k++) segments.push(u16(o + 0x12 + k * 2));
    nodes.push({ index: i, storedIndex: dv.getInt16(o + 0xc, true), position: bondToWorld(bond), bond, profile: dv.getInt16(o + 0xe, true), segments });
  }

  const sg = need("RNsg", 0x16), segments: RoadSegment[] = [];
  const i8 = (o: number) => dv.getInt8(o);
  for (let i = 0; i < sg.count; i++) {
    const o = sg.offset + i * 0x16;
    const nLength = u16(o + 4), flags = u16(o + 0xa), endLen = u16(o + 0xc), startLen = u16(o + 0xe);
    const endH = [i8(o + 0x10), i8(o + 0x11), i8(o + 0x12)], startH = [i8(o + 0x13), i8(o + 0x14), i8(o + 0x15)];
    const k = 500 / (127 * 65535); // WRoadSegment::GetStartControl / GetEndControl
    segments.push({
      index: i, storedIndex: dv.getInt16(o + 8, true), nodes: [u16(o), u16(o + 2)], length: nLength * (1000 / 65535),
      road: dv.getInt16(o + 6, true), flags, flagNames: flagNames(flags),
      startControl: bondToWorld(startH.map(v => v * startLen * k)), endControl: bondToWorld(endH.map(v => v * endLen * k)),
      raw: { nLength, startHandleLength: startLen, endHandleLength: endLen, startHandle: startH, endHandle: endH },
    });
  }

  const rd = findData(rn, "RNrd"), roads: Road[] = [];
  if (rd) for (let i = 0; i < rd.count; i++) {
    const o = rd.offset + i * 8, nScale = u16(o);
    roads.push({ index: i, nScale, scale: (nScale << 8) / 65536, nLength: u16(o + 2), shortcut: buf[o + 4], minWidth: buf[o + 5], speechId: u16(o + 6) });
  }

  return { info, tree, profiles, nodes, segments, roads, grid: readGrid(tree, buf) };
}

/** Rejilla WGrid ('CDat'/'CGrd' + celdas 'CGcn'). Celda: u32 dyn(0) · u16 nodeInd · u16 pad · u8 counts[4] · u16 offsets[4] · u32 elems[]. */
function readGrid(tree: UGroupNode, buf: Uint8Array): GridInfo | null {
  const cd = findGroup(tree, "CDat"); if (!cd) return null;
  const grd = findData(cd, "CGrd"), cn = findData(cd, "CGcn"); if (!grd) return null;
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength), g = grd.offset;
  const minBond = [0, 4, 8].map(k => dv.getFloat32(g + k, true)), edgeSize = dv.getFloat32(g + 16, true);
  const rows = dv.getUint32(g + 0x18, true), cols = dv.getUint32(g + 0x1c, true), cells: GridCell[] = [];
  if (cn) {
    let o = cn.offset;
    for (let i = 0; i < cn.count; i++) {
      const idx = dv.getUint16(o + 4, true), counts = [0, 1, 2, 3].map(k => buf[o + 8 + k]), offs = [0, 1, 2, 3].map(k => dv.getUint16(o + 12 + k * 2, true));
      const list = (t: number) => Array.from({ length: counts[t] }, (_, k) => dv.getUint32(o + 0x14 + offs[t] + k * 4, true));
      cells.push({ index: idx, row: Math.floor(idx / cols), col: idx % cols, instances: list(0), triggers: list(1), objects: list(2), roadSegments: list(3) });
      o += 0x14 + 4 * counts.reduce((a, b) => a + b, 0); // WGridNode::TotalSize [V: encadena las 2779 celdas sin hueco]
    }
  }
  return { minBond, edgeSize, rows, cols, cells };
}

/** Punto de un segmento en t∈[0,1] (mundo). Recto si no tiene flag "curved"; si no, Bézier cúbica [H: orden de puntos de control]. */
export function segmentPoint(net: RoadNetwork, s: RoadSegment, t: number): [number, number, number] {
  const a = net.nodes[s.nodes[0]].position, b = net.nodes[s.nodes[1]].position;
  if (!(s.flags & (1 << 8))) return [0, 1, 2].map(k => a[k] + (b[k] - a[k]) * t) as [number, number, number];
  const p1 = a.map((v, k) => v + s.startControl[k]), p2 = b.map((v, k) => v + s.endControl[k]), u = 1 - t;
  return [0, 1, 2].map(k => u * u * u * a[k] + 3 * u * u * t * p1[k] + 3 * u * t * t * p2[k] + t * t * t * b[k]) as [number, number, number];
}

// ───────────────────────────── Colisión por sección (0x0003B801) ─────────────────────────────

/** Instancia de colisión (0x40, CARP::CollisionInstance). Matriz guardada en espacio Bond; position = CalcPosition() pasada a mundo. */
export interface CollisionInstance {
  index: number; flags: number; height: number; groupNumber: number; article: number;
  row0: number[]; row2: number[]; posRadius: number[]; width: number; length: number; radius: number;
  position: [number, number, number];
}
export interface CollisionBarrier { a: [number, number, number]; b: [number, number, number]; surface: number; invXZLength: number }
export interface CollisionStrip { centre: number[]; radius: number; flags: number; verts: { p: [number, number, number]; surface: number }[] }
/** WCollisionArticle: tiras de triángulos (suelo/calzada, vértices s16/128 relativos a una esfera) + barreras (muros 2D con altura). Coordenadas locales Bond. */
export interface CollisionArticle { index: number; numStrips: number; numEdges: number; numSurfaces: number; flags: number; strips: CollisionStrip[]; barriers: CollisionBarrier[]; surfaceHashes: number[] }
export interface CollisionPack { carpSize: number; sectionNumber: number; flags: number; name: string; tree: UGroupNode; instances: CollisionInstance[]; articles: Map<number, CollisionArticle> }

/** Lee un chunk 0x0003B801 (datos del chunk, incluido el relleno 0x11). */
export function readCollisionPack(buf: Uint8Array, dataOffset = 0, end = buf.length): CollisionPack {
  const at = alignedStart(buf, dataOffset, end);
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const carpSize = dv.getInt32(at, true), sectionNumber = dv.getInt32(at + 4, true), flags = dv.getInt32(at + 8, true);
  const body = buf.subarray(at + 16, end), bdv = new DataView(body.buffer, body.byteOffset, body.byteLength);
  const tree = parseUGroup(body, 0), arti = findGroup(tree, "Arti");
  if (!arti) throw new Error("pack sin grupo Arti");
  const f = (o: number) => bdv.getFloat32(o, true), u16 = (o: number) => bdv.getUint16(o, true);
  const nm = findData(arti, "Name");
  const name = nm ? new TextDecoder("latin1").decode(body.subarray(nm.offset, nm.offset + nm.size)).replace(/\0.*$/s, "") : "";

  const instances: CollisionInstance[] = [], ci = arti.data.find(d => d.name === "ci#0");
  if (ci) for (let i = 0; i < ci.count; i++) {
    const o = ci.offset + i * 0x40, row0 = [0, 4, 8].map(k => f(o + k)), row2 = [0, 4, 8].map(k => f(o + 0x20 + k)), P = [0, 4, 8].map(k => f(o + 0x30 + k));
    const fl = u16(o + 0x12), dot = (r: number[]) => -(P[0] * r[0] + P[1] * r[1] + P[2] * r[2]);
    let y = -P[1];
    if (fl & 3) { const up = [row2[1] * row0[2] - row2[2] * row0[1], row2[2] * row0[0] - row2[0] * row0[2], row2[0] * row0[1] - row2[1] * row0[0]]; y = dot(up); }
    instances.push({
      index: i, flags: fl, height: f(o + 0x14), groupNumber: u16(o + 0x18), article: u16(o + 0x1a),
      row0, row2, posRadius: [...P, f(o + 0x3c)], width: f(o + 0xc), length: f(o + 0x2c), radius: f(o + 0x3c),
      position: bondToWorld([dot(row0), y, dot(row2)]),
    });
  }

  const articles = new Map<number, CollisionArticle>();
  for (const d of arti.data) {
    if (!d.name.startsWith("ca#")) continue;
    const idx = d.tag & 0xffff, o = d.offset;
    const numStrips = u16(o), stripsSize = u16(o + 2), numEdges = u16(o + 4), edgesSize = u16(o + 6), numSurfaces = body[o + 9];
    const strips: CollisionStrip[] = [], barriers: CollisionBarrier[] = [], surfaceHashes: number[] = [];
    // Bloque de tiras: numStrips esferas WCollisionStripSphere (f32 pos[3], u16 radio, u16 fOffset) y luego los vértices.
    // Offset() = fOffset + 0x10 contado desde el inicio del artículo (= fOffset desde la 1.ª esfera) [D + V: la 1.ª tira
    // empieza justo tras las esferas y cada tira acaba donde empieza la siguiente].
    // Vértice WCollisionPackedVert (8 B): s16 x,y,z (/128, relativos a la esfera) + u16 superficie; el campo superficie
    // del vértice 0 es nº de vértices y el del vértice 1 son flags (1 = mira arriba, 2 = desconocido). [decomp WCollisionStrip]
    const s0 = o + 16;
    for (let k = 0; k < numStrips; k++) {
      const so = s0 + k * 16, st: CollisionStrip = { centre: [f(so), f(so + 4), f(so + 8)], radius: u16(so + 12), flags: 0, verts: [] };
      strips.push(st);
      const vstart = o + u16(so + 14) + 0x10;
      if (vstart + 16 > o + 16 + stripsSize) continue;
      const n = u16(vstart + 6);
      st.flags = u16(vstart + 14);
      if (n < 3 || vstart + n * 8 > o + 16 + stripsSize) continue;
      for (let v = 0; v < n; v++) {
        const vo = vstart + v * 8;
        st.verts.push({ p: [bdv.getInt16(vo, true) / 128 + st.centre[0], bdv.getInt16(vo + 2, true) / 128 + st.centre[1], bdv.getInt16(vo + 4, true) / 128 + st.centre[2]], surface: v < 2 ? -1 : u16(vo + 6) });
      }
    }
    const e0 = o + 16 + stripsSize;
    for (let k = 0; k < numEdges; k++) {
      const eo = e0 + k * 32;
      barriers.push({ a: [f(eo), f(eo + 4), f(eo + 8)], b: [f(eo + 16), f(eo + 20), f(eo + 24)], surface: bdv.getUint32(eo + 12, true), invXZLength: f(eo + 28) });
    }
    const h0 = e0 + edgesSize;
    for (let k = 0; k < numSurfaces; k++) surfaceHashes.push(bdv.getUint32(h0 + k * 4, true));
    articles.set(idx, { index: idx, numStrips, numEdges, numSurfaces, flags: bdv.getInt16(o + 14, true), strips, barriers, surfaceHashes });
  }
  return { carpSize, sectionNumber, flags, name, tree, instances, articles };
}

/** Transforma un punto local Bond de un artículo a mundo (Z arriba) con la matriz inversa guardada en la instancia. [D: validado contra la red de carreteras] */
export function instanceToWorld(inst: CollisionInstance, p: number[]): [number, number, number] {
  const r0 = inst.row0, r2 = inst.row2, P = inst.posRadius;
  const r1 = inst.flags & 3 ? [r2[1] * r0[2] - r2[2] * r0[1], r2[2] * r0[0] - r2[0] * r0[2], r2[0] * r0[1] - r2[1] * r0[0]] : [0, 1, 0];
  // local = R·world + P  ⇒  world = Rᵀ·(local − P)
  const q = [p[0] - P[0], p[1] - P[1], p[2] - P[2]];
  return bondToWorld([0, 1, 2].map(k => r0[k] * q[0] + r1[k] * q[1] + r2[k] * q[2]));
}
