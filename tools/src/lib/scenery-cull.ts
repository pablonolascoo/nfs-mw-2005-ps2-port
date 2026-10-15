// Ocultación del escenario por sección (STREAML2RA.BUN, dentro de cada 0x80034100) [D: World/Scenery.cpp/.hpp][V: SLES-53559].
//
// 0x00034105 SceneryTreeNode[] (0x24 B): f32 BBoxMin[3], BBoxMax[3] · s16 NumChildren · s16 ChildCodes[5]
//   ChildCode ≥ 0 → instancia de escenario (dibujar); < 0 → nodo −ChildCode (bajar). El nodo 0 es la raíz [D: TreeCull].
//   [V] 1 476 secciones: 137 503 códigos válidos, las 110 954 instancias se alcanzan una vez desde la raíz y todas caben en la
//   caja de su nodo. (Los tipos de PS2 de la decomp dan una caja de s16 de 0xC B, pero en el disco es de floats: 0x24 por nodo.)
// 0x00034107 tPrecullerInfo[] (0x80 B): VisibilityBits[128] = 1 024 bits. Bit n a 1 → la instancia NO se ve si la cámara está
//   en la celda n = ((int)x >> 5 & 31) + ((int)y & 0x3E0): rejilla de 32 × 32 celdas de 32 m que se repite cada 1 024 m
//   [D: GetPrecullerSectionNumber]. Solo se usa por encima de 40 mph y si el guion «booboo» no lo quita en esa celda
//   (TRACKS\PRECULLERBOOBOOSCRIPT.HOO, rejilla de 128 × 128 celdas de 32 m) [D].
//   Cada instancia apunta a su tabla con s16 PrecullerInfoIndex en +0x1C (+0x1E = s16 LightingContextNumber, −1) [V: el índice
//   máximo = nº de tablas − 1 en las 1 476 secciones]. Media: 8,1 % de bits a 1 [V].
// 0x00034106 SceneryOverrideInfoHookup[] (4 B): u16 OverrideInfoNumber · u16 InstanceNumber [D][V: 18 902/18 902 instancias válidas].
import { type Chunk } from "./bchunk";

const PAD = 0x11111111;
const start = (dv: DataView, c: Chunk) => { let o = c.dataOffset; while (o + 4 <= c.dataOffset + c.size && dv.getUint32(o, true) === PAD) o += 4; return o; };

export interface TreeNode { bbMin: number[]; bbMax: number[]; children: number[] }
export interface SectionCulling { tree: TreeNode[]; preculler: Uint8Array[]; instancePreculler: number[]; overrideHooks: { override: number; instance: number }[] }

export const precullerCell = (x: number, y: number) => ((Math.trunc(x) >>> 5) & 31) + (Math.trunc(y) & 0x3e0);
export const isPrecullVisible = (bits: Uint8Array, cell: number) => (bits[cell >> 3] & (1 << (cell & 7))) === 0;

/** `section` = chunk 0x80034100 con hijos. */
export function readSectionCulling(buf: Uint8Array, section: Chunk): SectionCulling {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const get = (id: number) => section.children?.find(c => c.id === id);
  const out: SectionCulling = { tree: [], preculler: [], instancePreculler: [], overrideHooks: [] };
  const tn = get(0x00034105), pi = get(0x00034107), ins = get(0x00034103), hk = get(0x00034106);
  if (tn) for (let o = start(dv, tn); o + 0x24 <= tn.dataOffset + tn.size; o += 0x24) {
    const f = (k: number) => dv.getFloat32(o + k * 4, true), n = dv.getInt16(o + 0x18, true);
    out.tree.push({ bbMin: [f(0), f(1), f(2)], bbMax: [f(3), f(4), f(5)], children: Array.from({ length: Math.min(n, 5) }, (_, j) => dv.getInt16(o + 0x1a + j * 2, true)) });
  }
  if (pi) for (let o = start(dv, pi); o + 0x80 <= pi.dataOffset + pi.size; o += 0x80) out.preculler.push(buf.slice(o, o + 0x80));
  if (ins) for (let o = start(dv, ins); o + 0x40 <= ins.dataOffset + ins.size; o += 0x40) out.instancePreculler.push(dv.getInt16(o + 0x1c, true));
  if (hk) for (let o = start(dv, hk); o + 4 <= hk.dataOffset + hk.size; o += 4) out.overrideHooks.push({ override: dv.getUint16(o, true), instance: dv.getUint16(o + 2, true) });
  return out;
}
