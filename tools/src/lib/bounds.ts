// Volúmenes de colisión del juego (CollisionGeometry) [D: Physics/Bounds.h, CollisionGeometry::BoundsPack][V: SLES-53559]
//   0x8003B900 BoundsPack (contenedor) → 0x0003B901 una colección por objeto:
//     (relleno 0x11 hasta 16) · BoundsHeader 16 B {UCrc32 nombre, i32 nº de volúmenes, i32 resuelto (0 en disco), i32 relleno}
//     · Bounds[n] de 0x30 B · PCloudHeader 16 B {i32 nº de nubes, relleno} · por nube: PCloud 16 B {i32 nº de vértices, 2 × relleno,
//       puntero} + nº × Vector4 (x, y, z, w floats)
//   Bounds (0x30): +0x00 cuaternión s16×4 / 32767 · +0x08 posición s16×3 / 1000 (m) · +0x0E u16 flags (BoundFlags) ·
//     +0x10 semidimensiones s16×3 / 1000 · +0x16 u8 nº de hijos · +0x17 s8 nube de puntos (−1 = ninguna) · +0x18 pivote s16×3 / 1000 ·
//     +0x1E s16 primer hijo (−1) · +0x20 f32 radio · +0x24 UCrc32 superficie (SimSurface) · +0x28 UCrc32 nombre del nodo · +0x2C puntero (0)
//   El primero es la raíz (flags 0x40 = caja, sin superficie); sus hijos son las cajas/esferas reales.
//   GLOBAL\GLOBALB: 83 colecciones (coches: caja raíz ≈ medio ancho 1 m × medio alto 0,55 m × medio largo 2,2 m) [V];
//   TRACKS\L2RA.BUN: 405 colecciones (objetos del mundo que se rompen/mueven: farolas, señales, vallas…) [V].
//   Ejes en espacio del modelo del juego (X derecha, Y arriba, Z adelante para los coches) [I: el largo va en Z].
import { parseChunks, walk } from "./bchunk";

export const BOUND_FLAGS: Record<number, string> = {
  0x1: "Disabled", 0x2: "PrimVsWorld", 0x4: "PrimVsObjects", 0x8: "PrimVsGround", 0x10: "MeshVsGround", 0x20: "Internal",
  0x40: "Box", 0x80: "Sphere", 0x100: "Constraint_Conical", 0x200: "Constraint_Prismatic", 0x400: "Joint_Female",
  0x800: "Joint_Male", 0x1000: "Male_Post", 0x2000: "Joint_Invert",
};

export interface Bound {
  orientation: [number, number, number, number]; position: [number, number, number]; flags: number; flagNames: string[];
  halfDimensions: [number, number, number]; numChildren: number; pcloud: number; pivot: [number, number, number];
  childIndex: number; radius: number; surface: number; name: number;
}
export interface BoundsCollection { name: number; bounds: Bound[]; pclouds: number[][][] }

export function parseBoundsChunk(buf: Uint8Array, dataOffset: number, size: number): BoundsCollection {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const end = dataOffset + size;
  let o = dataOffset;
  while (o + 4 <= end && dv.getUint32(o, true) === 0x11111111) o += 4;
  const name = dv.getUint32(o, true), n = dv.getInt32(o + 4, true);
  if (n < 0 || o + 16 + n * 0x30 > end) throw new Error(`BoundsHeader incoherente (n = ${n})`);
  const v3 = (p: number, k: number) => [0, 1, 2].map(i => dv.getInt16(p + i * 2, true) / k) as [number, number, number];
  const bounds: Bound[] = [];
  for (let i = 0; i < n; i++) {
    const p = o + 16 + i * 0x30, flags = dv.getUint16(p + 0x0e, true);
    bounds.push({
      orientation: [0, 1, 2, 3].map(k => dv.getInt16(p + k * 2, true) / 32767) as [number, number, number, number],
      position: v3(p + 8, 1000), flags, flagNames: Object.entries(BOUND_FLAGS).filter(([b]) => flags & +b).map(([, s]) => s),
      halfDimensions: v3(p + 0x10, 1000), numChildren: buf[p + 0x16], pcloud: dv.getInt8(p + 0x17), pivot: v3(p + 0x18, 1000),
      childIndex: dv.getInt16(p + 0x1e, true), radius: dv.getFloat32(p + 0x20, true), surface: dv.getUint32(p + 0x24, true), name: dv.getUint32(p + 0x28, true),
    });
  }
  const pclouds: number[][][] = [];
  let q = o + 16 + n * 0x30;
  if (q + 16 <= end) {
    const np = dv.getInt32(q, true); q += 16;
    for (let k = 0; k < np && q + 16 <= end; k++) {
      const nv = dv.getInt32(q, true); q += 16;
      const pts: number[][] = [];
      for (let j = 0; j < nv && q + 16 <= end; j++, q += 16) pts.push([dv.getFloat32(q, true), dv.getFloat32(q + 4, true), dv.getFloat32(q + 8, true)]);
      pclouds.push(pts);
    }
  }
  return { name, bounds, pclouds };
}

/** Todas las colecciones 0x0003B901 de un archivo (ya descomprimido). */
export function readBounds(buf: Uint8Array): BoundsCollection[] {
  const out: BoundsCollection[] = [];
  for (const [c] of walk(parseChunks(buf))) if (c.id === 0x0003b901) out.push(parseBoundsChunk(buf, c.dataOffset, c.size));
  return out;
}

