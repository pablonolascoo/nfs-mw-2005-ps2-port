// Red de carreteras de Rockport → map-data/<ID>/roads.json.
// Uso: bun src/cli/roads.ts <iso> <ID>
// Lee L2RA.BUN (chunk 0x0003B800, grupo RNgp) y valida contra la colisión de STREAML2RA.BUN (chunks 0x0003B801):
// cada nodo debe caer sobre un triángulo de suelo de colisión. Ver docs/es/09-red-de-carreteras.md.
import { mkdir } from "node:fs/promises";
import { GameDisc } from "../lib/zdir";
import { parseChunks, walk } from "../lib/bchunk";
import { readSectionTable } from "../lib/world-ps2";
import { outDir } from "../lib/paths";
import { readRoadNetwork, readCollisionPack, instanceToWorld, segmentPoint, type RoadNetwork } from "../lib/roads-ps2";

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("uso: bun src/cli/roads.ts <iso> <ID>"); process.exit(1); }
const out = outDir(id);
const disc = await GameDisc.open(iso);
const l2ra = await disc.readEntry(disc.find("TRACKS\\L2RA.BUN")!);
const net = readRoadNetwork(l2ra);
const secs = readSectionTable(l2ra);
const stream = await disc.readEntry(disc.find("TRACKS\\STREAML2RA.BUN")!);

// ── Colisión: resumen por pack + rejilla 2D de triángulos para validar alturas ──
const CELL = 8, tris = new Map<string, number[][][]>(), packs: object[] = [], seen = new Set<number>();
let nTris = 0, nBarriers = 0, nChunks = 0;
for (const s of secs) {
  const b = stream.subarray(s.offset, s.offset + s.size);
  for (const [c] of walk(parseChunks(b))) {
    if (c.id !== 0x0003b801) continue;
    nChunks++;
    const p = readCollisionPack(b, c.dataOffset, c.dataOffset + c.size);
    if (seen.has(p.sectionNumber)) continue; // el mismo pack aparece en varias secciones de streaming
    seen.add(p.sectionNumber);
    let strips = 0, t = 0, bar = 0;
    for (const inst of p.instances) {
      const a = p.articles.get(inst.article); if (!a) continue;
      bar += a.barriers.length;
      for (const st of a.strips) {
        strips++;
        const W = st.verts.map(v => instanceToWorld(inst, v.p));
        for (let i = 0; i + 2 < W.length; i++) {
          const tri = [W[i], W[i + 1], W[i + 2]]; t++;
          const xs = tri.map(q => Math.floor(q[0] / CELL)), ys = tri.map(q => Math.floor(q[1] / CELL));
          for (let x = Math.min(...xs); x <= Math.max(...xs); x++) for (let y = Math.min(...ys); y <= Math.max(...ys); y++) {
            const k = `${x},${y}`; let L = tris.get(k); if (!L) tris.set(k, L = []); L.push(tri);
          }
        }
      }
    }
    nTris += t; nBarriers += bar;
    packs.push({ section: p.sectionNumber, foundIn: s.name, instances: p.instances.length, articles: p.articles.size, strips, triangles: t, barriers: bar });
  }
}

/** Alturas de los triángulos de colisión bajo (x, y). */
function groundZ(p: number[]) {
  const out: number[] = [];
  for (const [a, b, c] of tris.get(`${Math.floor(p[0] / CELL)},${Math.floor(p[1] / CELL)}`) ?? []) {
    const d = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1]); if (Math.abs(d) < 1e-9) continue;
    const l1 = ((b[1] - c[1]) * (p[0] - c[0]) + (c[0] - b[0]) * (p[1] - c[1])) / d, l2 = ((c[1] - a[1]) * (p[0] - c[0]) + (a[0] - c[0]) * (p[1] - c[1])) / d, l3 = 1 - l1 - l2;
    if (l1 >= -1e-4 && l2 >= -1e-4 && l3 >= -1e-4) out.push(l1 * a[2] + l2 * b[2] + l3 * c[2]);
  }
  return out;
}
function onGround(pts: number[][]) {
  let noTriangle = 0, within1m = 0; const err: number[] = [];
  for (const p of pts) { const z = groundZ(p); if (!z.length) { noTriangle++; continue; } const e = Math.min(...z.map(v => Math.abs(v - p[2]))); err.push(e); if (e < 1) within1m++; }
  err.sort((a, b) => a - b);
  return { points: pts.length, noTriangle, within1m, medianError: +(err[err.length >> 1] ?? NaN).toFixed(3) };
}

// ── Comprobaciones de la red ──
function checks(n: RoadNetwork) {
  const P = n.nodes.map(x => x.position), ax = (k: number) => [Math.min(...P.map(p => p[k])), Math.max(...P.map(p => p[k]))].map(v => +v.toFixed(1));
  let badSegRef = 0, notBackLinked = 0, badNodeRef = 0;
  n.nodes.forEach((x, i) => x.segments.forEach(s => { if (s >= n.segments.length) badSegRef++; else if (!n.segments[s].nodes.includes(i)) notBackLinked++; }));
  n.segments.forEach(s => { if (s.nodes.some(k => k >= n.nodes.length)) badNodeRef++; });
  const arc = n.segments.map(s => { let L = 0, p = segmentPoint(n, s, 0); for (let i = 1; i <= 32; i++) { const q = segmentPoint(n, s, i / 32); L += Math.hypot(q[0] - p[0], q[1] - p[1], q[2] - p[2]); p = q; } return Math.abs(s.length - L); }).sort((a, b) => a - b);
  const par = n.nodes.map((_, i) => i), f = (i: number): number => par[i] === i ? i : (par[i] = f(par[i]));
  n.segments.forEach(s => { par[f(s.nodes[0])] = f(s.nodes[1]); });
  const degree: Record<number, number> = {}, flags: Record<string, number> = {};
  n.nodes.forEach(x => degree[x.segments.length] = (degree[x.segments.length] ?? 0) + 1);
  n.segments.forEach(s => s.flagNames.forEach(k => flags[k] = (flags[k] ?? 0) + 1));
  return {
    bbox: { x: ax(0), y: ax(1), z: ax(2) }, badSegRef, notBackLinked, badNodeRef,
    storedIndexMismatch: n.nodes.filter((x, i) => x.storedIndex !== i).length + n.segments.filter((s, i) => s.storedIndex !== i).length,
    segmentsWithoutRoad: n.segments.filter(s => s.road < 0).length, connectedComponents: new Set(n.nodes.map((_, i) => f(i))).size,
    lengthVsBezierArc: { median: +arc[arc.length >> 1].toFixed(3), p95: +arc[Math.floor(arc.length * 0.95)].toFixed(3) },
    nodeDegree: degree, segmentFlags: flags,
  };
}

const r1 = (v: number) => Math.round(v * 1000) / 1000, v3 = (v: number[]) => v.map(r1);
const json = {
  source: { iso: iso.split("/").pop(), l2raChunk: "0x0003B800 (CARP/UWorld) → RNgp", collisionChunk: "0x0003B801 (WCollisionPack) en STREAML2RA.BUN" },
  coordinates: "mundo Z arriba, metros (Bond→mundo: X=z, Y=-x, Z=y)",
  info: net.info,
  stats: {
    nodes: net.nodes.length, segments: net.segments.length, profiles: net.profiles.length, roads: net.roads.length,
    ...checks(net),
    nodesOnCollision: onGround(net.nodes.map(x => x.position)),
    segmentMidpointsOnCollision: onGround(net.segments.map(s => segmentPoint(net, s, 0.5))),
    collision: { chunks: nChunks, distinctPacks: seen.size, triangles: nTris, barriers: nBarriers },
  },
  grid: net.grid && { minBond: net.grid.minBond, edgeSize: net.grid.edgeSize, rows: net.grid.rows, cols: net.grid.cols, cellsStored: net.grid.cells.length,
    cellsWithRoads: net.grid.cells.filter(c => c.roadSegments.length).map(c => ({ cell: c.index, row: c.row, col: c.col, segments: c.roadSegments })) },
  nodes: net.nodes.map(x => ({ i: x.index, p: v3(x.position), profile: x.profile, segments: x.segments })),
  segments: net.segments.map(s => ({ i: s.index, nodes: s.nodes, length: r1(s.length), road: s.road, flags: s.flags, flagNames: s.flagNames, startControl: v3(s.startControl), endControl: v3(s.endControl) })),
  profiles: net.profiles.map(p => ({ i: p.index, numZones: p.numZones, middleZone: p.middleZone, lanes: p.lanes.map(l => ({ type: l.type, width: r1(l.width), offset: r1(l.offset) })) })),
  roads: net.roads.map(r => ({ i: r.index, nLength: r.nLength, lengthM: r1(r.nLength / 16.384), minWidth: r.minWidth, speechId: r.speechId, shortcut: r.shortcut })),
  collisionPacks: packs,
};
await mkdir(out, { recursive: true });
await Bun.write(`${out}/roads.json`, JSON.stringify(json));
console.log(JSON.stringify({ nodes: net.nodes.length, segments: net.segments.length, profiles: net.profiles.length, roads: net.roads.length,
  nodesOnCollision: json.stats.nodesOnCollision, packs: seen.size, out: `${out}/roads.json` }, null, 1));
