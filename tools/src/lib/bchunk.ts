// bChunk: {u32 id, u32 tamaño} + datos. Bit 0x80000000 del id = contenedor con hijos.
// id 0 = relleno de alineación (verificado al recorrer L2RA.BUN, STREAML2RA.BUN y GEOMETRY.BIN de SLES-53559).
import { hex8 } from "./hash";

export interface Chunk { id: number; size: number; offset: number; dataOffset: number; children?: Chunk[] }

export function parseChunks(buf: Uint8Array, start = 0, end = buf.length, depth = 0): Chunk[] {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const out: Chunk[] = [];
  let o = start;
  while (o + 8 <= end) {
    const id = dv.getUint32(o, true), size = dv.getUint32(o + 4, true);
    if (o + 8 + size > end) throw new Error(`Chunk ${hex8(id)} @${o} (${size} B) se sale del padre (fin ${end})`);
    const c: Chunk = { id, size, offset: o, dataOffset: o + 8 };
    if ((id & 0x80000000) && depth < 16) c.children = parseChunks(buf, o + 8, o + 8 + size, depth + 1);
    out.push(c);
    o += 8 + size;
  }
  if (o !== end && end - o >= 8) throw new Error(`Bytes sobrantes al final del bloque: ${end - o}`);
  return out;
}

export function* walk(chunks: Chunk[], depth = 0): Generator<[Chunk, number]> {
  for (const c of chunks) { yield [c, depth]; if (c.children) yield* walk(c.children, depth + 1); }
}

export function dumpTree(chunks: Chunk[], maxLines = 200, skipPad = true) {
  const lines: string[] = [];
  for (const [c, d] of walk(chunks)) {
    if (skipPad && c.id === 0) continue;
    if (lines.length >= maxLines) { lines.push("…"); break; }
    lines.push(`${"  ".repeat(d)}${hex8(c.id)}  ${c.size} B  @${c.offset}`);
  }
  return lines.join("\n");
}
