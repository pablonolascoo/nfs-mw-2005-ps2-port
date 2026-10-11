// Mundo de NFS MW PS2: tabla de secciones (L2RA.BUN, chunk 0x00034110) y escenario (STREAML2RA.BUN, chunk 0x80034100).
// Ver docs/03-mundo-rockport-ps2.md. Entradas de sección de 92 B [verificado en SLES-53559].
import { parseChunks, type Chunk } from "./bchunk";

export interface Section { index: number; name: string; number: number; fileType: number; offset: number; size: number; priority: number; centre: [number, number]; radius: number; checksum: number }
export interface SceneryInfo { name: string; hashes: number[]; radius: number }
export interface SceneryInstance { bbMin: number[]; bbMax: number[]; position: number[]; rotation: number[]; info: number }
export interface ScenerySection { sectionNumber: number; infos: SceneryInfo[]; instances: SceneryInstance[] }

export function readSectionTable(l2ra: Uint8Array): Section[] {
  const dv = new DataView(l2ra.buffer, l2ra.byteOffset, l2ra.byteLength);
  const c = parseChunks(l2ra).find(c => c.id === 0x00034110);
  if (!c) throw new Error("L2RA.BUN sin tabla de secciones 0x00034110");
  if (c.size % 92) throw new Error(`tabla de secciones de ${c.size} B no es múltiplo de 92`);
  const out: Section[] = [];
  for (let i = 0; i < c.size / 92; i++) {
    const e = c.dataOffset + i * 92;
    out.push({
      index: i, name: new TextDecoder("latin1").decode(l2ra.subarray(e, e + 8)).replace(/\0.*$/s, ""),
      number: dv.getUint32(e + 8, true), fileType: dv.getUint32(e + 16, true), offset: dv.getUint32(e + 20, true), size: dv.getUint32(e + 24, true),
      priority: dv.getUint32(e + 36, true), centre: [dv.getFloat32(e + 40, true), dv.getFloat32(e + 44, true)], radius: dv.getFloat32(e + 48, true), checksum: dv.getUint32(e + 52, true),
    });
  }
  return out;
}

const skipPad = (dv: DataView, o: number, end: number) => { while (o + 4 <= end && dv.getUint32(o, true) === 0x11111111) o += 4; return o; };

/**
 * SceneryInstance PS2 (0x40): f32 bbMin[3] @0x00, f32 bbMax[3] @0x0C, … f32 pos[3] @0x20, s16 rot[9]/8192 @0x2C, s16 info @0x3E.
 * Diferencia con PC/GC: la caja es float, no s16 [verificado: coincide con el centro de la sección].
 */
export function readScenery(buf: Uint8Array, chunks: Chunk[]): ScenerySection[] {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const out: ScenerySection[] = [];
  for (const sc of chunks.filter(c => c.id === 0x80034100)) {
    const get = (id: number) => sc.children!.find(c => c.id === id);
    const hdr = get(0x00034101), inf = get(0x00034102), ins = get(0x00034103);
    if (!hdr || !inf || !ins) continue;
    const ho = (hdr.dataOffset + 15) & ~15;
    const s: ScenerySection = { sectionNumber: dv.getInt32(ho + 0x0c, true), infos: [], instances: [] };
    for (let o = skipPad(dv, inf.dataOffset, inf.dataOffset + inf.size); o + 0x48 <= inf.dataOffset + inf.size; o += 0x48) {
      s.infos.push({ name: new TextDecoder("latin1").decode(buf.subarray(o, o + 24)).replace(/\0.*$/s, ""), hashes: [0, 1, 2, 3].map(k => dv.getUint32(o + 0x18 + k * 4, true)), radius: dv.getFloat32(o + 0x38, true) });
    }
    for (let o = skipPad(dv, (ins.dataOffset + 15) & ~15, ins.dataOffset + ins.size); o + 0x40 <= ins.dataOffset + ins.size; o += 0x40) {
      const f = (k: number) => dv.getFloat32(o + k, true);
      s.instances.push({ bbMin: [f(0), f(4), f(8)], bbMax: [f(12), f(16), f(20)], position: [f(0x20), f(0x24), f(0x28)], rotation: Array.from({ length: 9 }, (_, k) => dv.getInt16(o + 0x2c + k * 2, true) / 8192), info: dv.getInt16(o + 0x3e, true) });
    }
    out.push(s);
  }
  return out;
}

const NONE = new Set([0, 0xbe43edbb, 0x90f70174]);
/** Primer hash de modelo válido (LOD de más detalle disponible). */
export const modelHash = (i: SceneryInfo) => i.hashes.find(h => !NONE.has(h));
