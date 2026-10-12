// Plano cenital de Rockport rasterizado desde los datos del disco (sin GPU).
// Color = color medio de la textura × color de vértice horneado. Se queda la superficie más alta (z-buffer).
// Uso: bun src/cli/topdown.ts <iso> <ID> [px=4096]
import { outDir } from "../lib/paths";
import { GameDisc } from "../lib/zdir";
import { parseChunks } from "../lib/bchunk";
import { readSectionTable, readScenery, modelHash } from "../lib/world-ps2";
import { readSolidListsDeep, stripTriangles, type Solid } from "../lib/solid-ps2";
import { readTexturePack } from "../lib/tex-ps2";
import { encodePng } from "../lib/png";

const [iso, disc, pxArg = "4096"] = Bun.argv.slice(2);
const PX = +pxArg;
const out0 = outDir(disc);
const d = await GameDisc.open(iso);
const sections = readSectionTable(await d.readEntry(d.find("TRACKS\\L2RA.BUN")!));
const stream = await d.readEntry(d.find("TRACKS\\STREAML2RA.BUN")!);
const solids = new Map<number, Solid>(), texAvg = new Map<number, [number, number, number]>();
const parsed = sections.map(s => { const buf = stream.subarray(s.offset, s.offset + s.size); return { s, buf, ch: parseChunks(buf) }; });
for (const p of parsed) {
  for (const so of readSolidListsDeep(p.buf, p.ch)) if (!solids.has(so.nameHash)) solids.set(so.nameHash, so);
  if (p.ch.some(c => c.id === 0xb3300000)) for (const t of readTexturePack(p.buf).textures) {
    let r = 0, g = 0, b = 0, n = 0;
    for (let i = 0; i < t.rgba.length; i += 16) if (t.rgba[i + 3] > 64) { r += t.rgba[i]; g += t.rgba[i + 1]; b += t.rgba[i + 2]; n++; }
    if (n) texAvg.set(t.nameHash, [r / n, g / n, b / n]);
  }
}
// Límites: centros de sección ± radio (la geometría de horizonte queda fuera a propósito).
// Percentiles 1–99 de los centros: las secciones de horizonte (radio enorme) quedan fuera.
const live = sections.filter(s => s.radius > 0 && s.radius < 1500);
const q = (a: number[], p: number) => { const b = [...a].sort((x, y) => x - y); return b[Math.floor((b.length - 1) * p)]; };
const xs = live.map(s => s.centre[0]), ys = live.map(s => s.centre[1]), M = 300;
const minX = q(xs, 0.01) - M, maxX = q(xs, 0.99) + M, minY = q(ys, 0.01) - M, maxY = q(ys, 0.99) + M;
const span = Math.max(maxX - minX, maxY - minY), scale = PX / span;
const img = new Uint8Array(PX * PX * 4), zbuf = new Float32Array(PX * PX).fill(-Infinity);
for (let i = 0; i < PX * PX; i++) img.set([16, 20, 18, 255], i * 4);
const toPx = (x: number, y: number) => [(x - minX) * scale, PX - 1 - (y - minY) * scale];
let tris = 0;
for (const { buf, ch } of parsed) for (const sc of readScenery(buf, ch)) for (const inst of sc.instances) {
  const info = sc.infos[inst.info], h = info && modelHash(info), so = h ? solids.get(h) : undefined;
  if (!so || so.name.startsWith("SHD_")) continue;
  const r = inst.rotation, t = inst.position;
  const W = (v: number[]) => [v[0] * r[0] + v[1] * r[3] + v[2] * r[6] + t[0], v[0] * r[1] + v[1] * r[4] + v[2] * r[7] + t[1], v[0] * r[2] + v[1] * r[5] + v[2] * r[8] + t[2]];
  for (const st of so.strips) {
    const base = (st.texture >= 0 && texAvg.get(so.textureHashes[st.texture])) || [128, 128, 128];
    const P = st.positions.map(W);
    for (const [a, b, c] of stripTriangles(st)) {
      const pa = P[a], pb = P[b], pc = P[c];
      const [ax, ay] = toPx(pa[0], pa[1]), [bx, by] = toPx(pb[0], pb[1]), [cx, cy] = toPx(pc[0], pc[1]);
      const area = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay);
      if (Math.abs(area) < 1e-6) continue;
      const col = st.colors ? [0, 1, 2].map(k => (st.colors![a][k] + st.colors![b][k] + st.colors![c][k]) / 3) : [1, 1, 1];
      const rgb = [0, 1, 2].map(k => Math.min(255, 255 * Math.pow((base[k] / 255) * col[k] * 1.5, 0.8)));
      const x0 = Math.max(0, Math.floor(Math.min(ax, bx, cx))), x1 = Math.min(PX - 1, Math.ceil(Math.max(ax, bx, cx)));
      const y0 = Math.max(0, Math.floor(Math.min(ay, by, cy))), y1 = Math.min(PX - 1, Math.ceil(Math.max(ay, by, cy)));
      for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
        const px = x + 0.5, py = y + 0.5;
        const w0 = ((bx - px) * (cy - py) - (cx - px) * (by - py)) / area, w1 = ((cx - px) * (ay - py) - (ax - px) * (cy - py)) / area, w2 = 1 - w0 - w1;
        if (w0 < 0 || w1 < 0 || w2 < 0) continue;
        const z = w0 * pa[2] + w1 * pb[2] + w2 * pc[2], i = y * PX + x;
        if (z <= zbuf[i]) continue;
        zbuf[i] = z; img[i * 4] = rgb[0]; img[i * 4 + 1] = rgb[1]; img[i * 4 + 2] = rgb[2];
      }
      tris++;
    }
  }
}
const out = `${out0}/rockport-plano.png`;
await Bun.write(out, encodePng(img, PX, PX));
await Bun.write(`${out0}/rockport-plano.json`, JSON.stringify({ px: PX, minX, minY, metrosPorPixel: 1 / scale, nota: "x_mundo = minX + px*m; y_mundo = minY + (PX-1-py)*m" }, null, 1));
console.log(`Plano: ${out} · ${tris} triángulos · ${(1 / scale).toFixed(2)} m/px · X ${minX.toFixed(0)}..${maxX.toFixed(0)} Y ${minY.toFixed(0)}..${maxY.toFixed(0)}`);
