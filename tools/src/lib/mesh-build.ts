// Convierte sólidos PS2 en mallas GLB agrupando las tiras por textura.
import type { Solid } from "./solid-ps2";
import { stripTriangles } from "./solid-ps2";
import type { GlbMesh, GlbPrimitive } from "./glb";
import { hex8 } from "./hash";

/**
 * Color de vértice PS2 → COLOR_0 de glTF. El GS modula en espacio de pantalla (gamma): salida = textura × color/128 [D/V].
 * glTF define COLOR_0 en espacio lineal y lo multiplica por la textura ya linealizada; como (a·b)^2,2 = a^2,2 · b^2,2,
 * basta con elevar el color a 2,2 para que cualquier visor glTF dé el mismo resultado que la PS2. Puede pasar de 1
 * (hasta (255/128)^2,2 ≈ 4,5): es la iluminación horneada "sobreexpuesta" del juego. El alfa (agua) no se toca.
 */
export const ps2ColorToLinear = (c: number[]) => [Math.pow(c[0], 2.2), Math.pow(c[1], 2.2), Math.pow(c[2], 2.2), c[3]];

/** `materialFor` recibe también el hash del material de luz de la tira (eStripEntry +15 → `lightMaterialHashes`), si lo tiene. */
export function solidToMesh(s: Solid, materialFor: (textureHash: number | undefined, lightMaterialHash?: number) => number, transform?: number[]): GlbMesh {
  const groups = new Map<number, { pos: number[]; nor: number[]; uv: number[]; col: number[]; idx: number[] }>();
  const hasColors = s.strips.some(st => st.colors);
  for (const st of s.strips) {
    const texHash = st.texture >= 0 ? s.textureHashes[st.texture] : undefined;
    const lightHash = st.lightMaterial >= 0 ? s.lightMaterialHashes[st.lightMaterial] : undefined;
    const mat = materialFor(texHash, lightHash);
    const g = groups.get(mat) ?? groups.set(mat, { pos: [], nor: [], uv: [], col: [], idx: [] }).get(mat)!;
    const base = g.pos.length / 3;
    for (let k = 0; k < st.nv; k++) {
      g.pos.push(...st.positions[k]);
      g.nor.push(...(st.normals[k] ?? [0, 0, 1]));
      g.uv.push(...(st.uvs[k] ?? [0, 0]));
      if (hasColors) g.col.push(...ps2ColorToLinear(st.colors?.[k] ?? [1, 1, 1, 1]));
    }
    for (const t of stripTriangles(st)) g.idx.push(base + t[0], base + t[1], base + t[2]);
  }
  const primitives: GlbPrimitive[] = [...groups].map(([material, g]) => ({ material, positions: new Float32Array(g.pos), normals: new Float32Array(g.nor), uvs: new Float32Array(g.uv), ...(hasColors ? { colors: new Float32Array(g.col) } : {}), indices: new Uint32Array(g.idx) }));
  return { name: s.name || hex8(s.nameHash), primitives, matrix: transform, extras: { "Hash": hex8(s.nameHash), "Tiras": s.strips.length, "Polígonos (cabecera)": s.numPolys, "Texturas": s.textureHashes.map(hex8).join(" ") } };
}
