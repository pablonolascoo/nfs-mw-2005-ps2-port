// Simplificación por agrupación de vértices en celdas (vertex clustering): rápida y suficiente para el nivel lejano.
// Cada celda de `cell` metros se queda con un vértice (posición y color medios); los triángulos que colapsan se eliminan.
import type { GlbPrimitive } from "./glb";

export function clusterSimplify(p: GlbPrimitive, cell: number): GlbPrimitive {
  const n = p.positions.length / 3, map = new Int32Array(n);
  const key = new Map<string, number>(), acc: number[] = [], cnt: number[] = [], col: number[] = [];
  for (let i = 0; i < n; i++) {
    const x = p.positions[i * 3], y = p.positions[i * 3 + 1], z = p.positions[i * 3 + 2];
    const k = `${Math.floor(x / cell)},${Math.floor(y / cell)},${Math.floor(z / cell)}`;
    let id = key.get(k);
    if (id === undefined) { id = cnt.length; key.set(k, id); acc.push(0, 0, 0); col.push(0, 0, 0, 0); cnt.push(0); }
    acc[id * 3] += x; acc[id * 3 + 1] += y; acc[id * 3 + 2] += z;
    if (p.colors) for (let c = 0; c < 4; c++) col[id * 4 + c] += p.colors[i * 4 + c];
    cnt[id]++; map[i] = id;
  }
  const idx: number[] = [], seen = new Set<string>();
  for (let t = 0; t < p.indices.length; t += 3) {
    const a = map[p.indices[t]], b = map[p.indices[t + 1]], c = map[p.indices[t + 2]];
    if (a === b || b === c || a === c) continue;
    const s = [a, b, c].sort((u, v) => u - v).join(","); // quita duplicados (también las dos caras)
    if (seen.has(s)) continue; seen.add(s); idx.push(a, b, c);
  }
  const m = cnt.length;
  const pos = new Float32Array(m * 3), colors = p.colors ? new Float32Array(m * 4) : undefined;
  for (let i = 0; i < m; i++) { for (let c = 0; c < 3; c++) pos[i * 3 + c] = acc[i * 3 + c] / cnt[i]; if (colors) for (let c = 0; c < 4; c++) colors[i * 4 + c] = col[i * 4 + c] / cnt[i]; }
  return { material: p.material, positions: pos, colors, indices: new Uint32Array(idx) };
}
