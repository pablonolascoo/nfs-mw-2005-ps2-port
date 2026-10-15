// Lector de sólidos (geometría) de NFS MW PS2. Ver docs/02-formato-solidos-ps2.md.
// Estructura de chunks y structs: tipos de depuración de la decompilación (symbols/PS2) [verificado].
// Empaquetado VIF de las tiras: deducido de los datos reales de SLES-53559 [verificado empíricamente].
import { parseChunks, type Chunk } from "./bchunk";
import { parseVif, unpackValues, type Unpack } from "./vif";

export interface Strip { nv: number; np: number; texture: number; lightMaterial: number; flags: number; positions: number[][]; uvs: number[][]; normals: number[][]; colors?: number[][]; adc: boolean[] }
/** ePositionMarker (0x50 B): NameHash, iParam0, fParam0, fParam1, bMatrix4 (filas; v3 = traslación) [D: EcstasyData.hpp]. */
export interface PositionMarker { nameHash: number; iParam0: number; fParam0: number; fParam1: number; matrix: number[] }
export interface Solid { name: string; nameHash: number; markers: PositionMarker[]; numPolys: number; numVerts: number; aabbMin: number[]; aabbMax: number[]; pivot: number[]; textureHashes: number[]; lightMaterialHashes: number[]; strips: Strip[]; warnings: string[] }

const PAD = 0x11111111;
const f32 = (dv: DataView, o: number) => dv.getFloat32(o, true);

function skipPad(dv: DataView, o: number, end: number) { while (o + 4 <= end && dv.getUint32(o, true) === PAD) o += 4; return o; }
function align(o: number, a: number) { return (o + a - 1) & ~(a - 1); }

export function readSolidList(buf: Uint8Array): Solid[] {
  const top = parseChunks(buf);
  const pack = top.find(c => c.id === 0x80134000);
  if (!pack) throw new Error("No hay chunk 0x80134000 (lista de sólidos)");
  return pack.children!.filter(c => c.id === 0x80134010).map(c => readSolid(buf, c));
}

export function readSolidListsDeep(buf: Uint8Array, chunks: Chunk[]): Solid[] {
  const out: Solid[] = [];
  for (const c of chunks) {
    if (c.id === 0x80134010) out.push(readSolid(buf, c));
    else if (c.children) out.push(...readSolidListsDeep(buf, c.children));
  }
  return out;
}

function readSolid(buf: Uint8Array, c: Chunk): Solid {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const kids = c.children!;
  const hdr = kids.find(k => k.id === 0x00134011);
  if (!hdr) throw new Error(`Sólido @${c.offset} sin cabecera 0x00134011`);
  const h = align(hdr.dataOffset, 16); // eSolid se alinea a 16 dentro del chunk
  const nameBytes = buf.subarray(h + 0xa0, Math.min(h + 0xe0, hdr.dataOffset + hdr.size));
  const nul = nameBytes.indexOf(0);
  const solid: Solid = {
    name: new TextDecoder("latin1").decode(nameBytes.subarray(0, nul < 0 ? nameBytes.length : nul)),
    nameHash: dv.getUint32(h + 0x10, true),
    numPolys: dv.getInt16(h + 0x14, true), numVerts: dv.getInt16(h + 0x16, true),
    aabbMin: [f32(dv, h + 0x20), f32(dv, h + 0x24), f32(dv, h + 0x28)],
    aabbMax: [f32(dv, h + 0x30), f32(dv, h + 0x34), f32(dv, h + 0x38)],
    pivot: Array.from({ length: 16 }, (_, i) => f32(dv, h + 0x40 + i * 4)),
    textureHashes: [], lightMaterialHashes: [], strips: [], warnings: [], markers: [],
  };
  const readHashTable = (id: number) => {
    const t = kids.find(k => k.id === id); if (!t) return [];
    const out: number[] = []; const s = skipPad(dv, t.dataOffset, t.dataOffset + t.size);
    for (let o = s; o + 8 <= t.dataOffset + t.size; o += 8) out.push(dv.getUint32(o, true));
    return out;
  };
  solid.textureHashes = readHashTable(0x00134012);
  solid.lightMaterialHashes = readHashTable(0x00134013);
  // Marcadores de posición (chunk 0x0013401A, BCHUNK_SOLID_MARKERS): dónde van alerón, toma de techo, frenos, luces… [D][V]
  const mk = kids.find(k => k.id === 0x0013401a);
  if (mk) for (let o = align(mk.dataOffset, 16); o + 0x50 <= mk.dataOffset + mk.size; o += 0x50) {
    if (dv.getUint32(o, true) === PAD) { o -= 0x4c; continue; }
    solid.markers.push({ nameHash: dv.getUint32(o, true), iParam0: dv.getInt32(o + 4, true), fParam0: f32(dv, o + 8), fParam1: f32(dv, o + 12), matrix: Array.from({ length: 16 }, (_, i) => f32(dv, o + 0x10 + i * 4)) });
  }
  const plat = kids.find(k => k.id === 0x80134100);
  if (!plat) { solid.warnings.push("sin chunk de plataforma 0x80134100"); return solid; }
  const tbl = plat.children!.find(k => k.id === 0x00134a01), dat = plat.children!.find(k => k.id === 0x00134a02);
  if (!tbl || !dat) { solid.warnings.push("sin tabla o datos de tiras PS2"); return solid; }
  const to = skipPad(dv, tbl.dataOffset, tbl.dataOffset + tbl.size);
  const base = skipPad(dv, dat.dataOffset, dat.dataOffset + dat.size);
  const nStrips = Math.floor((tbl.dataOffset + tbl.size - to) / 16);
  for (let i = 0; i < nStrips; i++) {
    const e = to + i * 16;
    const qoff = dv.getUint16(e + 8, true), qsz = buf[e + 12];
    const start = base + qoff * 16, end = start + qsz * 16;
    if (end > dat.dataOffset + dat.size) { solid.warnings.push(`tira ${i} se sale de 0x00134a02`); continue; }
    try {
      solid.strips.push(decodeStrip(buf, start, end, { nv: buf[e + 2], np: buf[e + 3], flags: dv.getUint16(e, true), texture: dv.getInt8(e + 14), lightMaterial: dv.getInt8(e + 15) }));
    } catch (err) { solid.warnings.push(`tira ${i}: ${(err as Error).message}`); }
  }
  return solid;
}

/**
 * Paquete VIF de una tira (direcciones VU en qwords):
 *  0  V4-8   [numVerts, packs, 23, ?]       · 1 V4-32 [máscaraADC0, escala(0.0002), máscaraADC2, máscaraADC3]
 *  2  V3-32  AABB min/max                    · 4 V4-32 cono de normales
 *  5  V4-16  XYZ en SoA: por grupo de 4 vértices, filas x[4], y[4], z[4]; luego vértices sueltos V{m}-16 ×3
 *  29 V4-16  ST: por fila (s0, t0, t1, s1) → 2 vértices/fila
 *  45 V4-8u  RGBA por vértice (solo escenario; 128 = 1.0)
 *  77 V4-8   normales SoA igual que XYZ (int8 / 127)
 * Posición = entero × escala + desplazamiento entero por eje (se deduce de la AABB: ver docs); con XYZ en V4-32, metros directos.
 */
function decodeStrip(buf: Uint8Array, start: number, end: number, e: { nv: number; np: number; flags: number; texture: number; lightMaterial: number }): Strip {
  const cur: Record<number, Unpack> = {};
  for (const it of parseVif(buf, start, end)) if (it.kind === "unpack") cur[it.addr] = it;
  if (!cur[0] || !cur[1] || !cur[2] || !cur[5]) throw new Error("faltan bloques VIF básicos (0,1,2,5)");
  const [nv, packs] = unpackValues(cur[0])[0];
  if (nv !== e.nv) throw new Error(`numVerts VIF ${nv} ≠ tabla ${e.nv}`);
  const slop = nv - packs * 4;
  const hdrDv = new DataView(cur[1].data.buffer, cur[1].data.byteOffset, 16);
  const scale = hdrDv.getFloat32(4, true);
  const w = [hdrDv.getUint32(0, true), hdrDv.getUint32(8, true), hdrDv.getUint32(12, true)];
  const [bbMin] = unpackValues(cur[2]);

  const soa = (u: Unpack | undefined, rowsPerPack: number, tail: Unpack | undefined) => {
    const out: number[][] = [];
    if (!u) return out;
    const r = unpackValues(u);
    for (let p = 0; p < packs; p++) for (let l = 0; l < 4; l++) out.push(Array.from({ length: rowsPerPack }, (_, a) => r[p * rowsPerPack + a][l]));
    if (slop > 0) {
      const t = tail ? unpackValues(tail) : r.slice(packs * rowsPerPack);
      for (let l = 0; l < slop; l++) out.push(Array.from({ length: rowsPerPack }, (_, a) => t[a][l]));
    }
    return out;
  };
  const rawPos = soa(cur[5], 3, cur[5 + packs * 3]);
  if (rawPos.length < nv) throw new Error(`posiciones insuficientes (${rawPos.length}/${nv})`);
  // Con XYZ en V4-32 (floats; cabecera [nv, packs, 9, …]) las posiciones ya vienen en metros: sin escala ni desplazamiento.
  // Lo usan las piezas grandes (> ±128 m con int16/256), p. ej. la cúpula del cielo BACKDROP_CURRGEN de los garajes [V].
  const floatPos = cur[5].bits === 32;
  const off = floatPos ? [0, 0, 0] : [0, 1, 2].map(a => Math.round(bbMin[a] - Math.min(...rawPos.slice(0, nv).map(v => v[a])) * scale));
  const positions = rawPos.slice(0, nv).map(v => v.map((x, a) => (floatPos ? x : x * scale + off[a])));

  const uvs: number[][] = [];
  if (cur[29]) {
    const rows = [...unpackValues(cur[29]), ...(cur[29 + packs * 2] && cur[29 + packs * 2] !== cur[29] ? unpackValues(cur[29 + packs * 2]) : [])];
    for (const r of rows) { uvs.push([r[0] / 4096, r[1] / 4096]); uvs.push([r[3] / 4096, r[2] / 4096]); }
  }
  // 45 V4-8 sin signo: RGBA por vértice (iluminación horneada del escenario). 128 = 1.0 como en el GS.
  const colors = cur[45] ? unpackValues(cur[45]).slice(0, nv).map(c => c.map(x => x / 128)) : undefined;
  const normals = soa(cur[77], 3, undefined).slice(0, nv).map(n => { const l = Math.hypot(n[0], n[1], n[2]) || 1; return [n[0] / l, n[1] / l, n[2] / l]; });

  const bit = (k: number): number => {
    const F = packs === 7 ? w[1] : packs === 3 ? w[2] : w[0];
    if (k <= 14) return (F >>> (14 - k)) & 1;
    if (packs === 3) return 0;
    if (packs === 7) {
      if (k !== 15) return (w[2] >>> (33 - k)) & 1;
      const f13 = (w[1] >>> 1) & 1, f14 = w[1] & 1, f16 = (w[2] >>> 17) & 1, f17 = (w[2] >>> 16) & 1;
      return (f14 && !f13) || (f16 && !f17) ? 1 : 0;
    }
    return (w[2] >>> (4 * packs + 5 - k)) & 1;
  };
  const adc = Array.from({ length: nv }, (_, k) => bit(k) === 1);
  const kills = adc.slice(2).filter(Boolean).length;
  if (nv - 2 - kills !== e.np) throw new Error(`triángulos ${nv - 2 - kills} ≠ tabla ${e.np}`);
  return { nv, np: e.np, texture: e.texture, lightMaterial: e.lightMaterial, flags: e.flags, positions, uvs: uvs.slice(0, nv), normals, colors, adc };
}

/** Triángulos de una tira con ADC (orden alterno para mantener el sentido). */
export function stripTriangles(s: Strip): [number, number, number][] {
  const tris: [number, number, number][] = [];
  let runStart = 0;
  for (let k = 0; k < s.nv; k++) {
    if (s.adc[k]) { if (k >= 1 && s.adc[k - 1] === false) runStart = k; else if (k === 0) runStart = 0; continue; }
    if (k < 2) continue;
    const par = (k - runStart) & 1;
    tris.push(par ? [k - 1, k - 2, k] : [k - 2, k - 1, k]);
  }
  return tris;
}
