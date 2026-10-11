// Fusiona instancias (malla + matriz) en una sola malla por material. Guarda en cada vértice el índice del objeto (_ID)
// para poder identificarlo al hacer clic. Matriz en convención de filas del motor: mundo = local × M (M columna-mayor de glTF).
import type { GlbMesh, GlbPrimitive } from "./glb";

export interface FlatInstance { mesh: GlbMesh; matrix: number[]; id: number }

export function flatten(instances: FlatInstance[]): GlbPrimitive[] {
  const acc = new Map<number, { pos: number[]; nor: number[]; uv: number[]; col: number[]; ids: number[]; idx: number[]; colors: boolean }>();
  for (const { mesh, matrix: m, id } of instances) {
    for (const p of mesh.primitives) {
      const g = acc.get(p.material) ?? acc.set(p.material, { pos: [], nor: [], uv: [], col: [], ids: [], idx: [], colors: false }).get(p.material)!;
      const base = g.pos.length / 3, n = p.positions.length / 3;
      if (p.colors && !g.colors) { g.colors = true; for (let i = 0; i < base; i++) g.col.push(1, 1, 1, 1); }
      for (let i = 0; i < n; i++) {
        const x = p.positions[i * 3], y = p.positions[i * 3 + 1], z = p.positions[i * 3 + 2];
        g.pos.push(x * m[0] + y * m[4] + z * m[8] + m[12], x * m[1] + y * m[5] + z * m[9] + m[13], x * m[2] + y * m[6] + z * m[10] + m[14]);
        if (p.normals) {
          const a = p.normals[i * 3], b = p.normals[i * 3 + 1], c = p.normals[i * 3 + 2];
          const nx = a * m[0] + b * m[4] + c * m[8], ny = a * m[1] + b * m[5] + c * m[9], nz = a * m[2] + b * m[6] + c * m[10];
          const l = Math.hypot(nx, ny, nz) || 1; g.nor.push(nx / l, ny / l, nz / l);
        } else g.nor.push(0, 0, 1);
        g.uv.push(p.uvs ? p.uvs[i * 2] : 0, p.uvs ? p.uvs[i * 2 + 1] : 0);
        if (g.colors) { if (p.colors) g.col.push(p.colors[i * 4], p.colors[i * 4 + 1], p.colors[i * 4 + 2], p.colors[i * 4 + 3]); else g.col.push(1, 1, 1, 1); }
        g.ids.push(id);
      }
      // Si la matriz invierte (determinante < 0) hay que invertir el sentido de los triángulos.
      const det = m[0] * (m[5] * m[10] - m[6] * m[9]) - m[4] * (m[1] * m[10] - m[2] * m[9]) + m[8] * (m[1] * m[6] - m[2] * m[5]);
      for (let t = 0; t < p.indices.length; t += 3) {
        if (det < 0) g.idx.push(base + p.indices[t], base + p.indices[t + 2], base + p.indices[t + 1]);
        else g.idx.push(base + p.indices[t], base + p.indices[t + 1], base + p.indices[t + 2]);
      }
    }
  }
  return [...acc].map(([material, g]) => ({ material, positions: new Float32Array(g.pos), normals: new Float32Array(g.nor), uvs: new Float32Array(g.uv), ...(g.colors ? { colors: new Float32Array(g.col) } : {}), ids: new Float32Array(g.ids), indices: new Uint32Array(g.idx) }));
}
