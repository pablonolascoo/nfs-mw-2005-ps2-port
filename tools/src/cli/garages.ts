// Garajes y tiendas: para cada zona del juego (menu_gate_*), localiza su edificio en el mapa y la cara de la puerta.
// Entrada: map-data/<ID>/zones.json (vlt-dump). Salida: map-data/<ID>/garages.json.
// Regla [V en 7 de 8 talleres]: la zona queda frente a una cara del edificio; se toma el eje local (±X, ±Y) más alineado
// con la dirección edificio→zona. Sin edificio identificado: la puerta mira hacia el punto de reaparición [H].
import { outDir } from "../lib/paths";
import { GameDisc } from "../lib/zdir";
import { parseChunks } from "../lib/bchunk";
import { readSectionTable, readScenery, modelHash } from "../lib/world-ps2";
import { readSolidListsDeep, stripTriangles, type Solid } from "../lib/solid-ps2";
import { readTexturePack } from "../lib/tex-ps2";
import { hex8 } from "../lib/hash";

const [iso, disc] = Bun.argv.slice(2);
const out = outDir(disc);
const zones = (await Bun.file(`${out}/zones.json`).json()).zones as { collection: string; zoneType: string; position: number[]; radius: number; respawn?: { position: number[]; rotation: number } }[];
const BUILDING: Record<string, RegExp> = { safehouse: /SafehouseA|SafeGarage/i, carlot: /CarParkDealership/i, customshop: /ChopShop/i };
const d = await GameDisc.open(iso);
const secs = readSectionTable(await d.readEntry(d.find("TRACKS\\L2RA.BUN")!));
const st = await d.readEntry(d.find("TRACKS\\STREAML2RA.BUN")!);
const cands: { name: string; min: number[]; max: number[]; rot: number[]; pos: number[]; hash: number }[] = [];
const local = new Map<number, { min: number[]; max: number[] }>();
const solidsByHash = new Map<number, Solid>();
let doorTex = 0;
for (const s of secs) { const b = st.subarray(s.offset, s.offset + s.size), ch = parseChunks(b);
  for (const so of readSolidListsDeep(b, ch)) if (Object.values(BUILDING).some(r => r.test(so.name))) { local.set(so.nameHash, { min: so.aabbMin, max: so.aabbMax }); solidsByHash.set(so.nameHash, so); }
  if (!doorTex && ch.some(c => c.id === 0xb3300000)) for (const t of readTexturePack(b).textures) if (t.name.startsWith("ARC_HOSPITAL_GARAGEDOOR")) doorTex = t.nameHash;
  for (const sc of readScenery(b, ch)) for (const i of sc.instances) { const info = sc.infos[i.info], n = info?.name ?? ""; if (Object.values(BUILDING).some(r => r.test(n))) cands.push({ name: n, min: i.bbMin, max: i.bbMax, rot: i.rotation, pos: i.position, hash: modelHash(info) ?? 0 }); } }
/**
 * Puertas reales del edificio: triángulos con la textura ARC_HOSPITAL_GARAGEDOOR (la usan todos los garajes) [V],
 * pasados a mundo y agrupados por cercanía. Devuelve centro, normal hacia fuera, ancho y alto de cada hueco.
 */
function doorsOf(c: (typeof cands)[number]) {
  const so = solidsByHash.get(c.hash); if (!so || !doorTex) return [];
  const r = c.rot, W = (v: number[]) => [0, 1, 2].map(k => v[0] * r[k] + v[1] * r[3 + k] + v[2] * r[6 + k] + c.pos[k]);
  const tris: number[][][] = [];
  for (const st of so.strips) if (so.textureHashes[st.texture] === doorTex) for (const t of stripTriangles(st)) tris.push(t.map(i => W(st.positions[i])));
  const groups: number[][][][] = [];
  for (const t of tris) {
    const cen = [0, 1, 2].map(k => (t[0][k] + t[1][k] + t[2][k]) / 3);
    const g = groups.find(g => g.some(u => Math.hypot(...[0, 1, 2].map(k => (u[0][k] + u[1][k] + u[2][k]) / 3 - cen[k])) < 4));
    if (g) g.push(t); else groups.push([t]);
  }
  return groups.map(g => {
    const pts = g.flat(), cen = [0, 1, 2].map(k => pts.reduce((a, p) => a + p[k], 0) / pts.length);
    const t0 = g[0], e1 = [0, 1, 2].map(k => t0[1][k] - t0[0][k]), e2 = [0, 1, 2].map(k => t0[2][k] - t0[0][k]);
    let n = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], 0]; const nl = Math.hypot(n[0], n[1]) || 1; n = [n[0] / nl, n[1] / nl, 0];
    const tang = [-n[1], n[0]];
    const us = pts.map(p => (p[0] - cen[0]) * tang[0] + (p[1] - cen[1]) * tang[1]), zs = pts.map(p => p[2]);
    return { center: cen, normal: n, width: Math.max(...us) - Math.min(...us), height: Math.max(...zs) - Math.min(...zs), bottom: Math.min(...zs) };
  });
}

/** Caja orientada del edificio: caja local del modelo transformada por la instancia (filas de la matriz = ejes). */
function obb(c: (typeof cands)[number]) {
  const L = local.get(c.hash); if (!L) return null;
  const r = c.rot, lc = [0, 1, 2].map(k => (L.min[k] + L.max[k]) / 2), lh = [0, 1, 2].map(k => (L.max[k] - L.min[k]) / 2);
  const axes = [[r[0], r[1], r[2]], [r[3], r[4], r[5]], [r[6], r[7], r[8]]];
  const center = [0, 1, 2].map(k => lc[0] * axes[0][k] + lc[1] * axes[1][k] + lc[2] * axes[2][k] + c.pos[k]);
  const len = axes.map(a => Math.hypot(...a));
  return { center, axes: axes.map((a, i) => a.map(v => v / len[i])), half: lh.map((h, i) => h * len[i]) };
}
const result = zones.map(z => {
  const zp = z.position;
  const b = cands.filter(c => BUILDING[z.zoneType].test(c.name) && (c.max[0] - c.min[0]) > 8)
    .map(c => ({ ...c, c: [0, 1, 2].map(k => (c.min[k] + c.max[k]) / 2), dist: Math.hypot((c.min[0] + c.max[0]) / 2 - zp[0], (c.min[1] + c.max[1]) / 2 - zp[1]) }))
    .sort((a, b) => a.dist - b.dist)[0];
  if (b && b.dist < 45 && local.has(b.hash)) {
    const o = obb(b); if (!o) return null;
    const X = [o.axes[0][0], o.axes[0][1]], Y = [o.axes[1][0], o.axes[1][1]];
    const toZone = [zp[0] - o.center[0], zp[1] - o.center[1]];
    const opts = [{ d: X, h: o.half[0], w: o.half[1] }, { d: [-X[0], -X[1]], h: o.half[0], w: o.half[1] }, { d: Y, h: o.half[1], w: o.half[0] }, { d: [-Y[0], -Y[1]], h: o.half[1], w: o.half[0] }];
    const best = opts.sort((p, q) => (q.d[0] * toZone[0] + q.d[1] * toZone[1]) - (p.d[0] * toZone[0] + p.d[1] * toZone[1]))[0];
    const outDir = best.d, along = best.h * 2, across = best.w * 2;
    const face = [o.center[0] + outDir[0] * best.h, o.center[1] + outDir[1] * best.h];
    b.c = o.center;
    // Puerta real más cercana a la zona (si existe), con su normal orientada hacia la zona
    const doors = doorsOf(b).sort((p, q) => Math.hypot(p.center[0] - zp[0], p.center[1] - zp[1]) - Math.hypot(q.center[0] - zp[0], q.center[1] - zp[1]));
    const rd = doors[0];
    if (rd) {
      const toZ = [zp[0] - rd.center[0], zp[1] - rd.center[1]];
      if (rd.normal[0] * toZ[0] + rd.normal[1] * toZ[1] < 0) rd.normal = rd.normal.map(v => -v);
      // medidas del edificio respecto a la normal de la puerta
      const dAxis = opts.slice().sort((p, q) => (q.d[0] * rd.normal[0] + q.d[1] * rd.normal[1]) - (p.d[0] * rd.normal[0] + p.d[1] * rd.normal[1]))[0];
      return { collection: z.collection, zoneType: z.zoneType, zone: zp, radius: z.radius, building: { name: b.name, center: b.c, along: dAxis.h * 2, across: dAxis.w * 2, height: o.half[2] * 2, floor: o.center[2] - o.half[2] }, out: [rd.normal[0], rd.normal[1]], door: [rd.center[0], rd.center[1], rd.bottom], doorSize: [rd.width, rd.height], doorTexture: hex8(doorTex), source: "puerta real" };
    }
    // la puerta queda en la proyección de la zona sobre la fachada
    const t = (zp[0] - face[0]) * -outDir[1] + (zp[1] - face[1]) * outDir[0];
    const door = [face[0] + -outDir[1] * t, face[1] + outDir[0] * t, zp[2]];
    return { collection: z.collection, zoneType: z.zoneType, zone: zp, radius: z.radius, building: { name: b.name, center: b.c, along, across, height: o.half[2] * 2, floor: o.center[2] - o.half[2] }, out: outDir, door, source: "edificio" };
  }
  const r = z.respawn?.position ?? [zp[0] + 1, zp[1], zp[2]];
  const v = [r[0] - zp[0], r[1] - zp[1]], n = Math.hypot(v[0], v[1]) || 1;
  const outDir = [v[0] / n, v[1] / n];
  return { collection: z.collection, zoneType: z.zoneType, zone: zp, radius: z.radius, building: null, out: outDir, door: [zp[0] - outDir[0] * 6, zp[1] - outDir[1] * 6, zp[2]], source: "reaparición" };
}).filter((g): g is NonNullable<typeof g> => !!g);
await Bun.write(`${out}/garages.json`, JSON.stringify({ disc, garages: result }, null, 1));
for (const g of result) console.log(g.collection.split("/").pop()!.padEnd(20), g.source.padEnd(11), g.building ? `${g.building.name} ${g.building.along.toFixed(0)}×${g.building.across.toFixed(0)} m` : "", "puerta", g.door.map(v => v.toFixed(0)).join(","), "sale", g.out.map(v => v.toFixed(2)).join(","));
