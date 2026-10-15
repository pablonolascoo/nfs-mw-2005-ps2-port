// Suavizado de normales de los coches (chunks 0x00134017/18/19 dentro de cada sólido 0x80134010 de CARS\<COCHE>\GEOMETRY.BIN).
// Al montar el coche con piezas de tuneo, el juego promedia las normales de los vértices que coinciden entre piezas
// (costuras de capó, parachoques, aletas…) [D: Ecstasy/EcstasyData.hpp, eSolid::SmoothNormals, CarRender.cpp eSmoothNormals].
//   0x00134017 eNormalSmoother (12 B): punteros y contadores; en el disco van a CERO (se rellenan al cargar) [V]
//   0x00134018 eSmoothVertex[] (8 B): u32 VertexHash · u8 SmoothingGroupNumber · s8 NX, NY, NZ (normal × 127) [V: 99,7 % con
//              |n| ≈ 127 en los 91 coches]
//   0x00134019 eSmoothVertexPlat[] (12 B): u32 VertexHash · u32 SmoothingGroup (máscara de bits [I]) ·
//              u32 VertexOffset = u16 nº de tira | u16 nº de vértice dentro de la tira << 16 [V: 165 846/165 846 índices válidos
//              en 5 coches; todos los vértices con el mismo VertexHash están en la misma posición (±1 cm): VertexHash = hash de la posición]
// Los datos empiezan tras el relleno de alineación (0x11) hasta múltiplo de 8/12 desde el final del chunk.
import { type Chunk } from "./bchunk";

export interface SmoothVertex { hash: number; group: number; normal: [number, number, number] }
export interface SmoothVertexPlat { hash: number; groupMask: number; strip: number; vertex: number }

export function readSmoothing(buf: Uint8Array, solidChunk: Chunk): { verts: SmoothVertex[]; plats: SmoothVertexPlat[] } | null {
  const kids = solidChunk.children ?? [];
  const sv = kids.find(k => k.id === 0x00134018), sp = kids.find(k => k.id === 0x00134019);
  if (!sv || !sp) return null;
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const verts: SmoothVertex[] = [], plats: SmoothVertexPlat[] = [];
  for (let o = sv.dataOffset + (sv.size % 8); o < sv.dataOffset + sv.size; o += 8)
    verts.push({ hash: dv.getUint32(o, true), group: buf[o + 4], normal: [dv.getInt8(o + 5) / 127, dv.getInt8(o + 6) / 127, dv.getInt8(o + 7) / 127] });
  for (let o = sp.dataOffset + (sp.size % 12); o < sp.dataOffset + sp.size; o += 12) {
    const vo = dv.getUint32(o + 8, true);
    plats.push({ hash: dv.getUint32(o, true), groupMask: dv.getUint32(o + 4, true), strip: vo & 0xffff, vertex: vo >>> 16 });
  }
  return { verts, plats };
}
