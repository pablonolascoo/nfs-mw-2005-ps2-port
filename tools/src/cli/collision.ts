// Colisión real de Rockport (chunks 0x0003B801 de STREAML2RA.BUN) → map-data/<ID>/collision/<tx>_<ty>.bin + index.json.
// Uso: bun src/cli/collision.ts <iso> <ID> [tamaño de casilla = 400]
// Misma rejilla que las casillas visuales (world.json → tiles): tx = floor(x / tamaño), ty = floor(y / tamaño).
// Formato .bin (little endian), ver docs/es/09-red-de-carreteras.md §5:
//   u32 'NFSC' · u32 versión (1) · u32 nTri · u32 nMuros
//   f32 tri[nTri × 9]   (3 vértices x, y, z en mundo, Z arriba)
//   f32 muro[nMuros × 6] (ax, ay, bx, by, zMin, zMax): segmento vertical en planta [V: longitud = 1/invXZLength]
import { mkdir } from "node:fs/promises";
import { GameDisc } from "../lib/zdir";
import { parseChunks, walk } from "../lib/bchunk";
import { readSectionTable } from "../lib/world-ps2";
import { readCollisionPack, instanceToWorld } from "../lib/roads-ps2";

const [iso, id, sizeArg] = Bun.argv.slice(2);
if (!iso || !id) { console.error("uso: bun src/cli/collision.ts <iso> <ID> [tamaño]"); process.exit(1); }
const SIZE = Number(sizeArg ?? 400);
const root = new URL("../../../", import.meta.url).pathname, out = `${root}map-data/${id}/collision`;
await mkdir(out, { recursive: true });
const disc = await GameDisc.open(iso);
const l2ra = await disc.readEntry(disc.find("TRACKS\\L2RA.BUN")!);
const stream = await disc.readEntry(disc.find("TRACKS\\STREAML2RA.BUN")!);

type Bucket = { tris: number[]; walls: number[] };
const buckets = new Map<string, Bucket>();
const bucket = (tx: number, ty: number) => { const k = `${tx}_${ty}`; let b = buckets.get(k); if (!b) buckets.set(k, b = { tris: [], walls: [] }); return b; };
const span = (vals: number[]) => [Math.floor(Math.min(...vals) / SIZE), Math.floor(Math.max(...vals) / SIZE)];

const seen = new Set<number>();
let nTris = 0, nWalls = 0, degenerate = 0;
for (const s of readSectionTable(l2ra)) {
  const b = stream.subarray(s.offset, s.offset + s.size);
  for (const [c] of walk(parseChunks(b))) {
    if (c.id !== 0x0003b801) continue;
    const p = readCollisionPack(b, c.dataOffset, c.dataOffset + c.size);
    if (seen.has(p.sectionNumber)) continue; // un mismo pack aparece en dos secciones de streaming (N y N+40)
    seen.add(p.sectionNumber);
    for (const inst of p.instances) {
      const a = p.articles.get(inst.article); if (!a) continue;
      for (const st of a.strips) {
        const W = st.verts.map(v => instanceToWorld(inst, v.p));
        for (let i = 0; i + 2 < W.length; i++) {
          const t = [W[i], W[i + 1], W[i + 2]];
          const ux = t[1][0] - t[0][0], uy = t[1][1] - t[0][1], vx = t[2][0] - t[0][0], vy = t[2][1] - t[0][1];
          const uz = t[1][2] - t[0][2], vz = t[2][2] - t[0][2];
          const cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx;
          if (cx * cx + cy * cy + cz * cz < 1e-8) { degenerate++; continue; } // tiras: triángulos de unión
          const [x0, x1] = span(t.map(q => q[0])), [y0, y1] = span(t.map(q => q[1]));
          for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) bucket(x, y).tris.push(...t[0], ...t[1], ...t[2]);
          nTris++;
        }
      }
      for (const br of a.barriers) {
        const A = instanceToWorld(inst, br.a), B = instanceToWorld(inst, br.b);
        const w = [A[0], A[1], B[0], B[1], Math.min(A[2], B[2]), Math.max(A[2], B[2])];
        const [x0, x1] = span([A[0], B[0]]), [y0, y1] = span([A[1], B[1]]);
        for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) bucket(x, y).walls.push(...w);
        nWalls++;
      }
    }
  }
}

const tiles: { id: string; tris: number; walls: number; bytes: number }[] = [];
for (const [k, b] of buckets) {
  const nt = b.tris.length / 9, nw = b.walls.length / 6;
  const buf = new ArrayBuffer(16 + (b.tris.length + b.walls.length) * 4), dv = new DataView(buf);
  dv.setUint32(0, 0x4353464e, true); dv.setUint32(4, 1, true); dv.setUint32(8, nt, true); dv.setUint32(12, nw, true);
  const f = new Float32Array(buf, 16); f.set(b.tris, 0); f.set(b.walls, b.tris.length);
  await Bun.write(`${out}/${k}.bin`, buf);
  tiles.push({ id: k, tris: nt, walls: nw, bytes: buf.byteLength });
}
tiles.sort((a, b) => a.id.localeCompare(b.id, "en", { numeric: true }));
await Bun.write(`${out}/index.json`, JSON.stringify({ disc: id, tileSize: SIZE, format: "NFSC v1: u32 magic, u32 version, u32 nTri, u32 nWalls, f32 tri[nTri*9], f32 wall[nWalls*6] (ax, ay, bx, by, zMin, zMax)", packs: seen.size, triangles: nTris, walls: nWalls, degenerateSkipped: degenerate, tiles }, null, 1));
const mb = tiles.reduce((a, t) => a + t.bytes, 0) / 1048576;
console.log(`Colisión: ${seen.size} packs · ${nTris} triángulos · ${nWalls} muros · ${degenerate} degenerados descartados · ${tiles.length} casillas · ${mb.toFixed(1)} MB → ${out}`);
