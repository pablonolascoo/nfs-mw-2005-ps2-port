// Plano de la expansión «Rust Belt» sobre la geografía real de Rockport → docs/expansion/mapa-expansion.svg
//
// Rockport sale del disco:
//   · relieve, costa y ríos  ← frontend/minimaps/MINI_MAP.png (el mapa del radar y de la pausa, 1024×1024, 6,5 m/px) con su
//     calibración de TrackInfo (esquina superior izquierda y ancho en metros, doc 17 §8) [V]
//   · carreteras             ← roads.json (tramos Bézier y anchos de carril de los perfiles RNgp, doc 09) [V]
// Fuera del marco del mapa original, el relieve, el mar, los ríos y las carreteras de los 4 distritos nuevos son una PROPUESTA
// (ROADMAP.md, doc 12): se generan aquí con el mismo estilo y empalman con los bordes del mapa del juego.
//
// Salidas:
//   docs/expansion/mapa-expansion.svg      pública: todo dibujado por nosotros (la imagen de EA no se copia, solo se mide)
//   <datos>/expansion/mapa-expansion-original.{png,svg}   solo local (map-data/ no va a git): con el MINI_MAP del disco encima
// Uso: bun src/cli/expansion-map.ts [ID=SLES-53559]
import { mkdirSync } from "node:fs";
import { outDir, repoRoot } from "../lib/paths";
import { decodePng, encodePng } from "../lib/png";

type P = [number, number];
const id = Bun.argv[2] ?? "SLES-53559";
const data = outDir(id);
const roads = await Bun.file(`${data}/roads.json`).json() as {
  nodes: { p: number[]; profile: number }[]; profiles: { lanes: { width: number }[] }[];
  segments: { nodes: number[]; length: number; startControl: number[]; endControl: number[] }[];
};
const mmIndex = await Bun.file(`${data}/frontend/minimaps/index.json`).json() as { calibration: { upperLeft: number[]; widthMetres: number } };
const mm = decodePng(new Uint8Array(await Bun.file(`${data}/frontend/minimaps/MINI_MAP.png`).arrayBuffer()));

// ── Ventana del plano (metros del mundo, Z arriba, norte arriba) ──────────────────────────────────────────────
const W = { x0: -7400, x1: 6600, y0: -6600, y1: 10300 };
const PX = 1600, S = PX / (W.x1 - W.x0), H = Math.round((W.y1 - W.y0) * S), M = 1 / S;
const sx = (x: number) => (x - W.x0) * S, sy = (y: number) => (W.y1 - y) * S;
const wxOf = (px: number) => W.x0 + (px + 0.5) * M, wyOf = (py: number) => W.y1 - (py + 0.5) * M;

// Marco del mapa original (calibración del disco): u = (x − x0)/ancho, v = (y0 − y)/ancho + 1
const cal = mmIndex.calibration, FW = cal.widthMetres;
const F = { x0: cal.upperLeft[0], x1: cal.upperLeft[0] + FW, y0: cal.upperLeft[1], y1: cal.upperLeft[1] + FW };
const MMW = mm.w, MMS = FW / MMW;   // 6,5 m por píxel

// ── Utilidades ────────────────────────────────────────────────────────────────────────────────────────────────
let seed = 0x52b2005;
const rnd = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
const hash = (i: number, j: number) => { let h = Math.imul(i, 374761393) + Math.imul(j, 668265263) ^ 0x5bd1e995; h = Math.imul(h ^ (h >>> 13), 1274126177); return ((h ^ (h >>> 16)) >>> 0) / 4294967296; };
const vnoise = (x: number, y: number) => {
  const i = Math.floor(x), j = Math.floor(y), fx = x - i, fy = y - j, u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy);
  const a = hash(i, j), b = hash(i + 1, j), c = hash(i, j + 1), d = hash(i + 1, j + 1);
  return a + (b - a) * u + (c - a + (a - b + d - c) * u) * v;
};
const fbm = (x: number, y: number, oct = 4) => { let s = 0, a = 0.5, f = 1, n = 0; for (let k = 0; k < oct; k++) { s += a * (vnoise(x * f + k * 17.3, y * f - k * 9.1) * 2 - 1); n += a; a *= 0.5; f *= 2; } return s / n; };
const clamp = (v: number, a = 0, b = 1) => v < a ? a : v > b ? b : v;
const smooth = (a: number, b: number, v: number) => { const t = clamp((v - a) / (b - a)); return t * t * (3 - 2 * t); };
const segDist = (px: number, py: number, ax: number, ay: number, bx: number, by: number) => {
  const dx = bx - ax, dy = by - ay, t = clamp(((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy || 1e-9));
  return Math.hypot(px - ax - t * dx, py - ay - t * dy);
};
const polyDist = (x: number, y: number, pts: P[]) => { let d = Infinity; for (let i = 1; i < pts.length; i++) d = Math.min(d, segDist(x, y, pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1])); return d; };
/** Desenfoque de caja separable (r píxeles), n pasadas ≈ gaussiano. */
function blur(src: Float32Array, w: number, h: number, r: number, passes = 2): Float32Array {
  let a = Float32Array.from(src), b = new Float32Array(src.length);
  const k = 1 / (2 * r + 1);
  for (let p = 0; p < passes; p++) {
    for (let y = 0; y < h; y++) {
      const row = y * w; let s = 0;
      for (let x = -r; x <= r; x++) s += a[row + clamp(x, 0, w - 1)];
      for (let x = 0; x < w; x++) { b[row + x] = s * k; s += a[row + Math.min(x + r + 1, w - 1)] - a[row + Math.max(x - r, 0)]; }
    }
    for (let x = 0; x < w; x++) {
      let s = 0;
      for (let y = -r; y <= r; y++) s += b[clamp(y, 0, h - 1) * w + x];
      for (let y = 0; y < h; y++) { a[y * w + x] = s * k; s += b[Math.min(y + r + 1, h - 1) * w + x] - b[Math.max(y - r, 0) * w + x]; }
    }
  }
  return a;
}
const catmull = (pts: P[], closed = false, n = 8): P[] => {
  const q = closed ? [pts[pts.length - 1], ...pts, pts[0], pts[1]] : [pts[0], ...pts, pts[pts.length - 1]];
  const out: P[] = [];
  for (let i = 1; i < q.length - 2; i++) {
    const [p0, p1, p2, p3] = [q[i - 1], q[i], q[i + 1], q[i + 2]];
    for (let k = 0; k < n; k++) {
      const t = k / n, t2 = t * t, t3 = t2 * t;
      out.push([0, 1].map(c => 0.5 * (2 * p1[c] + (-p0[c] + p2[c]) * t + (2 * p0[c] - 5 * p1[c] + 4 * p2[c] - p3[c]) * t2 + (-p0[c] + 3 * p1[c] - 3 * p2[c] + p3[c]) * t3)) as P);
    }
  }
  out.push(closed ? out[0] : pts[pts.length - 1]);
  return out;
};

// ── 1. Lo que dice el disco: agua y relieve de MINI_MAP ──────────────────────────────────────────────────────
// Agua = azul (b − r); relieve = gris de las bandas de altura. Las carreteras del mapa se tapan con roads.json
// y se rellenan con el relieve de alrededor (convolución normalizada).
const roadW = (n: number) => roads.profiles[roads.nodes[n].profile]?.lanes.reduce((a, l) => a + l.width, 0) || 8;
const rockportRoads: { pts: P[]; w: number }[] = roads.segments.map(s => {
  const a = roads.nodes[s.nodes[0]].p, b = roads.nodes[s.nodes[1]].p;
  const c1 = [a[0] + s.startControl[0], a[1] + s.startControl[1]], c2 = [b[0] + s.endControl[0], b[1] + s.endControl[1]];
  const n = Math.max(2, Math.ceil((s.length || 50) / 35)), pts: P[] = [];
  for (let k = 0; k <= n; k++) {
    const t = k / n, u = 1 - t;
    pts.push([0, 1].map(c => u * u * u * a[c] + 3 * u * u * t * c1[c] + 3 * u * t * t * c2[c] + t * t * t * b[c]) as P);
  }
  return { pts, w: Math.max(roadW(s.nodes[0]), roadW(s.nodes[1])) };
});
const mmWater = new Float32Array(MMW * MMW), mmLum = new Float32Array(MMW * MMW), mmKnown = new Float32Array(MMW * MMW);
{
  const road = new Uint8Array(MMW * MMW);
  for (const r of rockportRoads) {
    const rad = (r.w / 2 + 9) / MMS;
    for (let i = 1; i < r.pts.length; i++) {
      const ax = (r.pts[i - 1][0] - F.x0) / MMS, ay = (F.y1 - r.pts[i - 1][1]) / MMS, bx = (r.pts[i][0] - F.x0) / MMS, by = (F.y1 - r.pts[i][1]) / MMS;
      for (let y = Math.max(0, Math.floor(Math.min(ay, by) - rad)); y <= Math.min(MMW - 1, Math.ceil(Math.max(ay, by) + rad)); y++)
        for (let x = Math.max(0, Math.floor(Math.min(ax, bx) - rad)); x <= Math.min(MMW - 1, Math.ceil(Math.max(ax, bx) + rad)); x++)
          if (segDist(x + 0.5, y + 0.5, ax, ay, bx, by) <= rad) road[y * MMW + x] = 1;
    }
  }
  for (let i = 0; i < MMW * MMW; i++) {
    const r = mm.rgba[i * 4], g = mm.rgba[i * 4 + 1], b = mm.rgba[i * 4 + 2];
    mmWater[i] = clamp((b - r - 10) / 20);
    const neutral = Math.abs(r - g) < 6 && Math.abs(g - b) < 6;
    if (!road[i] && neutral && r > 30 && mmWater[i] < 0.2) { mmLum[i] = r; mmKnown[i] = 1; }
  }
  // Rellena huecos (carreteras, agua) con el relieve vecino, de radio pequeño a grande
  for (const rad of [4, 10, 24]) {
    const num = blur(mmLum.map((v, i) => v * mmKnown[i]), MMW, MMW, rad), den = blur(mmKnown, MMW, MMW, rad);
    for (let i = 0; i < MMW * MMW; i++) if (!mmKnown[i] && den[i] > 0.02) { mmLum[i] = num[i] / den[i]; mmKnown[i] = 0.5; }
  }
  for (let i = 0; i < MMW * MMW; i++) if (!mmKnown[i]) mmLum[i] = 44;
}
const mmLumSoft = blur(mmLum, MMW, MMW, 18, 3);
const mmSample = (arr: Float32Array, x: number, y: number) => {
  const u = clamp((x - F.x0) / MMS - 0.5, 0, MMW - 1.001), v = clamp((F.y1 - y) / MMS - 0.5, 0, MMW - 1.001);
  const i = Math.floor(u), j = Math.floor(v), fu = u - i, fv = v - j, o = j * MMW + i;
  return (arr[o] * (1 - fu) + arr[o + 1] * fu) * (1 - fv) + (arr[o + MMW] * (1 - fu) + arr[o + MMW + 1] * fu) * fv;
};
const mmRGB = (x: number, y: number) => {
  const u = clamp((x - F.x0) / MMS - 0.5, 0, MMW - 1.001), v = clamp((F.y1 - y) / MMS - 0.5, 0, MMW - 1.001);
  const i = Math.floor(u), j = Math.floor(v), fu = u - i, fv = v - j;
  return [0, 1, 2].map(c => {
    const at = (a: number, b: number) => mm.rgba[((j + b) * MMW + i + a) * 4 + c];
    return (at(0, 0) * (1 - fu) + at(1, 0) * fu) * (1 - fv) + (at(0, 1) * (1 - fu) + at(1, 1) * fu) * fv;
  });
};

// ── 2. La propuesta: geografía alrededor del mapa original ───────────────────────────────────────────────────
// Bordes del mapa del juego medidos en MINI_MAP [V]: mar en todo el borde este y en el norte desde x 4739; al oeste salen
// el río de Rosewood (y 841–913) y el del suroeste (y −544…−421), que también toca el borde sur (x −217…134);
// al sur hay tierra salvo una ría (x 4778–5090). La propuesta continúa esos ríos y esa ría.
const mainRiver: P[] = [[F.x0 - 20, 877], [-2000, 950], [-3000, 1300], [-4200, 1700], [-5100, 2500], [-5350, 3700], [-4950, 4900], [-4550, 5750], [-4350, 6150]];
const westRiver: P[] = [[F.x0 - 20, -482], [-2200, -700], [-3400, -520], [-4600, -900], [-6200, -800], [-7800, -1000]];
const southRiver: P[] = [[-40, F.y0 + 30], [120, -2200], [600, -2900], [1600, -3300], [2800, -3450], [3400, -3480]];
const inlet: P[] = [[4934, F.y0 + 30], [4800, -2300], [4450, -2950]];
const bayToSea: P[] = [[4900, -3650], [5800, -3850], [7200, -3950]];
const bay = { c: [3950, -3500] as P, rx: 1250, ry: 720 };
const lake = { c: [-4300, 6450] as P, rx: 850, ry: 470 };
const ellipseD = (x: number, y: number, e: { c: P; rx: number; ry: number }) => (1 - Math.hypot((x - e.c[0]) / e.rx, (y - e.c[1]) / e.ry)) * Math.min(e.rx, e.ry);
/** Distancia con signo (m, positiva dentro del agua) de la geografía propuesta. */
function proposedWater(x: number, y: number): number {
  const wx = x + 110 * fbm(x / 650, y / 650), wy = y + 110 * fbm(x / 650 + 40, y / 650 + 40);
  const rx = x + 35 * fbm(x / 260, y / 260, 3), ry = y + 35 * fbm(x / 260 + 7, y / 260 + 7, 3);
  let sea: number;
  if (y >= F.y1) sea = wx - (4739 + (y - F.y1) * 0.18);
  else if (y >= F.y0) sea = x - F.x1 + 30;
  else sea = wx - (F.x1 + (F.y0 - y) * 0.55);
  return Math.max(sea,
    38 - polyDist(rx, ry, mainRiver), 62 - polyDist(rx, ry, westRiver), 70 - polyDist(rx, ry, southRiver),
    160 - polyDist(wx, wy, inlet), 280 - polyDist(wx, wy, bayToSea), ellipseD(wx, wy, bay), ellipseD(wx, wy, lake));
}
/** Relieve propuesto (misma escala de gris que las bandas de MINI_MAP): montañas al noroeste, colinas al norte. */
function proposedElev(x: number, y: number): number {
  const g = (cx: number, cy: number, rx: number, ry: number) => Math.exp(-(((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2));
  return 46 + 12 * fbm(x / 1500, y / 1500, 5) + 7 * fbm(x / 420 + 3, y / 420, 3)
    + 62 * g(-4900, 7200, 2400, 2100) + 34 * g(-5800, 4300, 1600, 1500) + 20 * g(1700, 8100, 2200, 1200) + 14 * g(-3300, -2800, 1500, 1200);
}

// ── 3. Carreteras de los distritos nuevos (propuesta) ────────────────────────────────────────────────────────
const nearestNode = (score: (p: number[]) => number) => { let best = roads.nodes[0].p, bs = -Infinity; for (const n of roads.nodes) { const s = score(n.p); if (s > bs) { bs = s; best = n.p; } } return [best[0], best[1]] as P; };
// Accesos desde las carreteras reales de Rockport: la autopista que sale por el oeste, lo más al norte de Rosewood
// y lo más al sur de la ciudad
const westExit = nearestNode(p => -p[0]);
const northExit = nearestNode(p => p[0] > 800 && p[0] < 3200 ? p[1] : -Infinity);
const southExit = nearestNode(p => p[0] > 1200 && p[0] < 3000 ? -p[1] : -Infinity);

const rot = (c: P, a: number, u: number, v: number): P => [c[0] + u * Math.cos(a) - v * Math.sin(a), c[1] + u * Math.sin(a) + v * Math.cos(a)];
const ring = (c: P, rx: number, ry: number, a: number, jit = 0.13): P[] => catmull(Array.from({ length: 18 }, (_, k) => { const t = k / 18 * Math.PI * 2, r = 1 + jit * (rnd() * 2 - 1); return rot(c, a, Math.cos(t) * rx * r, Math.sin(t) * ry * r); }), true);
const wiggle = (a: P, b: P, amp = 0.12, k = 5): P[] => {
  const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy), nx = -dy / L, ny = dx / L;
  return catmull([a, ...Array.from({ length: k - 1 }, (_, i) => { const t = (i + 1) / k, o = amp * L * (rnd() * 2 - 1); return [a[0] + dx * t + nx * o, a[1] + dy * t + ny * o] as P; }), b]);
};
const switchback = (a: P, b: P, turns: number, amp: number): P[] => {
  const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy), nx = -dy / L, ny = dx / L;
  return catmull([a, ...Array.from({ length: turns }, (_, i) => { const t = (i + 0.5) / turns, o = (i % 2 ? 1 : -1) * amp * (0.8 + 0.4 * rnd()); return [a[0] + dx * t + nx * o, a[1] + dy * t + ny * o] as P; }), b], false, 10);
};
/** Cuadrícula de calles dentro de una elipse (pueblo, polígono industrial, muelles). */
const grid = (c: P, su: number, sv: number, a: number, bu: number, bv: number): P[][] => {
  const out: P[][] = [];
  const line = (fixed: number, alongU: boolean) => {
    const lim = alongU ? su * Math.sqrt(Math.max(0, 1 - (fixed / sv) ** 2)) : sv * Math.sqrt(Math.max(0, 1 - (fixed / su) ** 2));
    if (lim < (alongU ? bu : bv)) return;
    const pts: P[] = [];
    for (let s = -lim; s <= lim + 1; s += (alongU ? bu : bv) * 0.5) {
      const jit = (alongU ? bv : bu) * 0.45 * fbm(s / 260 + fixed / 97, fixed / 180);
      pts.push(alongU ? rot(c, a, s, fixed + jit) : rot(c, a, fixed + jit, s));
    }
    out.push(catmull(pts, false, 3));
  };
  for (let v = -sv + bv * (0.5 + rnd() * 0.3); v < sv; v += bv * (0.8 + rnd() * 0.4)) line(v, true);
  for (let u = -su + bu * (0.5 + rnd() * 0.3); u < su; u += bu * (0.8 + rnd() * 0.4)) line(u, false);
  return out;
};

/** Deformación suave para que las calles nuevas no parezcan dibujadas con regla, como las del mapa del juego. */
const warp = (pts: P[], amp = 70, sc = 520): P[] => pts.map(([x, y]) => [x + amp * fbm(x / sc, y / sc, 3), y + amp * fbm(x / sc + 31, y / sc - 17, 3)]);
type District = { n: number; name: string; sub: string; en: string; bl: string; label: P; roads: { pts: P[]; w: number }[] };
const R = (pts: P[], w = 10) => ({ pts: warp(pts), w });
const districts: District[] = [
  { n: 1, name: "MILLBROOK", sub: "Pueblo obrero · nuevo refugio", en: "Working-class town · new safehouse", bl: "#15–#11", label: [2050, 8350],
    roads: [R(ring([2000, 7250], 1500, 900, 0.1), 14), ...grid([1750, 7150], 700, 450, 0.2, 150, 130).map(p => R(p, 9)), ...grid([3000, 7550], 380, 300, -0.35, 140, 120).map(p => R(p, 9)),
      R(wiggle([600, 7300], [-500, 8300]), 10), R(wiggle([3450, 7000], [4300, 6200]), 10), R(wiggle([2600, 6400], [3700, 5600]), 9)] },
  { n: 2, name: "IRONWOOD", sub: "Altos hornos · vías de tren · río", en: "Steel mills · rail yards · river", bl: "#10–#6", label: [-3750, 2900],
    roads: [R(ring([-3800, 1550], 1700, 1000, 0.32), 14), ...grid([-3750, 1500], 1350, 560, 0.32, 230, 330).map(p => R(p, 11)),
      R(wiggle([-5400, 900], [-6900, 1900]), 10), R(wiggle([-2300, 2400], [-1900, 3600]), 9), R(wiggle([-4800, 300], [-5600, -1600]), 10)] },
  { n: 3, name: "CALDER BAY", sub: "Grúas · contenedores · muelles · puente levadizo", en: "Cranes · containers · piers · lift bridge", bl: "#5–#2", label: [1650, -4750],
    roads: [R(ring([2200, -3650], 1450, 900, -0.08), 14), ...grid([1700, -3700], 800, 600, 0.0, 160, 140).map(p => R(p, 9)),
      R(catmull([[2700, -2750], [2780, -3300], [2700, -3900], [2950, -4350], [3600, -4400]]), 12),
      ...Array.from({ length: 6 }, (_, k) => R([[2750 - k * 8, -2950 - k * 230], [3250, -2950 - k * 230]] as P[], 12)),
      R(wiggle([3600, -4400], [5400, -4700]), 10), R(wiggle([800, -4300], [-600, -5300]), 10)] },
  { n: 4, name: "BLACK HOLLOW", sub: "Puerto de montaña · presa · túneles · mina", en: "Mountain pass · dam · tunnels · coal mine", bl: "#1", label: [-4300, 8950],
    roads: [R(switchback([-3300, 4500], [-5300, 8400], 7, 420), 10), R(catmull([[-4950, 5550], [-4150, 6000]]), 12),
      R(ring([-5700, 7900], 450, 300, 0.4), 9), R(wiggle([-3900, 7300], [-2300, 8600]), 9), R(switchback([-5900, 5200], [-6800, 3400], 4, 260), 9),
      R(ring([-4300, 6450], 1150, 700, 0, 0.06), 10)] },
];
// Interestatal I-99 y accesos desde Rockport
const i99: P[] = catmull([[2200, -2650], [600, -2700], [-1200, -2500], [-2600, -1300], [-3150, 200], [-3300, 1600], [-3050, 3000], [-3250, 4300], [-3650, 5400], [-2500, 7150], [-700, 7950], [650, 7650]], false, 10);
const accesses: P[][] = [
  catmull([westExit, [westExit[0] - 700, westExit[1] + 80], [-2600, westExit[1] + 40], [-3050, 3000]]),
  catmull([northExit, [northExit[0] + 50, northExit[1] + 500], [2050, 6350]]),
  catmull([southExit, [southExit[0] + 60, southExit[1] - 600], [2150, -2200], [2200, -2650]]),
];
const expansionRoads = [...districts.flatMap(d => d.roads), R(i99, 22), ...accesses.map(p => R(p, 14))];

// ── 4. Rasterizado al estilo del mapa del juego ──────────────────────────────────────────────────────────────
const N = PX * H;
const water = new Float32Array(N), elev = new Float32Array(N), frameA = new Float32Array(N);
for (let py = 0; py < H; py++) for (let px = 0; px < PX; px++) {
  const x = wxOf(px), y = wyOf(py), i = py * PX + px;
  const dOut = Math.hypot(Math.max(F.x0 - x, 0, x - F.x1), Math.max(F.y0 - y, 0, y - F.y1));
  const dIn = Math.min(x - F.x0, F.x1 - x, y - F.y0, F.y1 - y);
  frameA[i] = smooth(0, 320, dIn);
  const mw = mmSample(mmWater, x, y), soft = mmSample(mmLumSoft, x, y);
  // Dentro: bandas del disco; cerca del borde se funden con su versión suave, que es la que se prolonga hacia fuera
  if (dOut === 0) { water[i] = mw; const ml = mmSample(mmLum, x, y); elev[i] = soft + (ml - soft) * smooth(0, 380, dIn); continue; }
  const ml = soft;
  water[i] = Math.max(clamp(0.5 + proposedWater(x, y) * S), mw * (1 - smooth(0, 400, dOut)));
  elev[i] = ml + (proposedElev(x, y) - ml) * smooth(0, 1400, dOut);
}
// Bandas de altura como en el mapa del juego (escalones suaves de gris)
const STEP = 8.5;
const banded = blur(elev.map(v => Math.round(v / STEP) * STEP), PX, H, 1, 2);
const deep = blur(water, PX, H, 10, 3), near = blur(water, PX, H, 2, 2), halo = blur(water, PX, H, 7, 2);

function stampRoads(list: { pts: P[]; w: number }[], fill: Float32Array, line: Float32Array) {
  for (const r of list) {
    const rf = Math.max(r.w * S / 2, 0.8), ro = rf + 1.05;
    for (let i = 1; i < r.pts.length; i++) {
      const ax = sx(r.pts[i - 1][0]), ay = sy(r.pts[i - 1][1]), bx = sx(r.pts[i][0]), by = sy(r.pts[i][1]);
      for (let y = Math.max(0, Math.floor(Math.min(ay, by) - ro - 1)); y <= Math.min(H - 1, Math.ceil(Math.max(ay, by) + ro + 1)); y++)
        for (let x = Math.max(0, Math.floor(Math.min(ax, bx) - ro - 1)); x <= Math.min(PX - 1, Math.ceil(Math.max(ax, bx) + ro + 1)); x++) {
          const d = segDist(x + 0.5, y + 0.5, ax, ay, bx, by), o = y * PX + x;
          line[o] = Math.max(line[o], clamp(ro + 0.5 - d)); fill[o] = Math.max(fill[o], clamp(rf + 0.5 - d));
        }
    }
  }
}
const rpFill = new Float32Array(N), rpLine = new Float32Array(N), exFill = new Float32Array(N), exLine = new Float32Array(N);
stampRoads(rockportRoads, rpFill, rpLine);
stampRoads(expansionRoads, exFill, exLine);

function compose(original: boolean): Uint8Array {
  const out = new Uint8Array(N * 4);
  for (let py = 0; py < H; py++) for (let px = 0; px < PX; px++) {
    const i = py * PX + px, x = wxOf(px), y = wyOf(py);
    // Tierra: bandas de gris; agua: azul profundo hacia dentro, orilla clara con espuma y halo cian en tierra
    const g = banded[i];
    let c = [g, g, g];
    const wv = water[i];
    if (wv > 0) {
      const dp = smooth(0.35, 1, deep[i]);
      const wc = [26 + (7 - 26) * dp, 74 + (29 - 74) * dp, 104 + (47 - 104) * dp];
      const rim = clamp((1 - near[i]) * 2.2) * clamp(wv * 1.6), foam = rim * (0.55 + 0.45 * hash(px, py));
      c = c.map((v, k) => v + (wc[k] + ([150, 205, 228][k] - wc[k]) * foam - v) * wv);
    }
    const hl = halo[i] * (1 - wv) * 0.55;
    c = c.map((v, k) => v + ([110, 175, 205][k] - v) * hl);
    // Carreteras de Rockport (contorno oscuro + gris)
    c = c.map(v => v + (16 - v) * rpLine[i]); c = c.map(v => v + (150 - v) * rpFill[i]);
    if (original && frameA[i] > 0) { const o = mmRGB(x, y); c = c.map((v, k) => v + (o[k] - v) * frameA[i]); }
    // Carreteras nuevas, mismo estilo
    c = c.map(v => v + (16 - v) * exLine[i]); c = c.map(v => v + (150 - v) * exFill[i]);
    out[i * 4] = clamp(c[0], 0, 255); out[i * 4 + 1] = clamp(c[1], 0, 255); out[i * 4 + 2] = clamp(c[2], 0, 255); out[i * 4 + 3] = 255;
  }
  return out;
}

// ── 5. Rótulos y leyenda (vector) ────────────────────────────────────────────────────────────────────────────
const amber = "#ffb21a", fog = "#a9b0a6", paper = "#f2f2ee", ink = "#0b0c0b";
const heavy = `font-family="'Eurostile','Microgramma','Arial Black','Helvetica Neue',sans-serif" font-weight="900"`;
const mono = `font-family="'IBM Plex Mono',ui-monospace,Menlo,monospace"`;
/** Texto con contorno en dos capas (el contorno debajo), en vez de paint-order, que no todos los visores respetan. */
const outlined = (attrs: string, body: string, sw: number) =>
  `<text ${attrs.replace(/ fill="[^"]*"/, "")} fill="${ink}" stroke="${ink}" stroke-width="${sw}" stroke-linejoin="round">${body}</text><text ${attrs}>${body}</text>`;
const pl = (pts: P[]) => pts.map((p, i) => `${i ? "L" : "M"}${sx(p[0]).toFixed(1)} ${sy(p[1]).toFixed(1)}`).join("");
const label = (p: P, lines: string[], size = 30) => lines.map((l, k) =>
  outlined(`x="${sx(p[0]).toFixed(0)}" y="${(sy(p[1]) + k * size * 0.95).toFixed(0)}" text-anchor="middle" ${heavy} font-size="${size}" fill="${paper}" letter-spacing="1"`, l, 7)).join("");
// Barrios del juego (textos del disco: «Rosewood», «Camden Beach», «Downtown Rockport», «Gray Point») [V]
const original = [label([1150, 3350], ["ROSEWOOD"]), label([4350, 450], ["CAMDEN", "BEACH"], 26), label([4150, 3050], ["GRAY", "POINT"], 22), label([1150, -150], ["DOWNTOWN", "ROCKPORT"], 26)].join("");
let z = "";
for (const d of districts) {
  const x = sx(d.label[0]).toFixed(0), y = sy(d.label[1]);
  z += `<g><rect x="${+x - 17}" y="${(y - 64).toFixed(0)}" width="34" height="34" fill="${amber}"/><text x="${x}" y="${(y - 37).toFixed(0)}" text-anchor="middle" ${heavy} font-size="26" fill="${ink}">${d.n}</text>`;
  z += `${outlined(`x="${x}" y="${y.toFixed(0)}" text-anchor="middle" ${heavy} font-size="32" fill="${paper}" letter-spacing="1"`, `${d.name}`, 7)}`;
  z += `${outlined(`x="${x}" y="${(y + 22).toFixed(0)}" text-anchor="middle" ${mono} font-size="13" fill="${fog}"`, `${d.sub}`, 4)}`;
  z += `${outlined(`x="${x}" y="${(y + 39).toFixed(0)}" text-anchor="middle" ${mono} font-size="12" fill="${fog}" opacity=".8"`, `${d.en}`, 4)}`;
  z += `${outlined(`x="${x}" y="${(y + 59).toFixed(0)}" text-anchor="middle" ${mono} font-size="13" font-weight="600" fill="${amber}"`, `LISTA NEGRA 2 · ${d.bl}`, 4)}</g>`;
}
const frame = `<rect x="${sx(F.x0).toFixed(1)}" y="${sy(F.y1).toFixed(1)}" width="${(FW * S).toFixed(1)}" height="${(FW * S).toFixed(1)}" fill="none" stroke="${paper}" stroke-opacity=".22" stroke-dasharray="3 7"/>`;
const overlay = (sub: string) => `
${frame}
<path d="${pl(i99)}" fill="none" stroke="${amber}" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" opacity=".95"/>
${accesses.map(a => `<path d="${pl(a)}" fill="none" stroke="${amber}" stroke-width="2" stroke-dasharray="5 5" stroke-linecap="round"/>`).join("")}
${outlined(`x="${sx(-3000).toFixed(0)}" y="${sy(-1650).toFixed(0)}" ${mono} font-size="14" font-weight="700" fill="${amber}"`, `I-99`, 4)}
${original}
${z}
<g transform="translate(28 30)">
<rect x="-12" y="-14" width="640" height="78" rx="4" fill="${ink}" fill-opacity=".78"/>
<rect x="0" y="0" width="58" height="40" fill="${amber}"/><text x="29" y="31" text-anchor="middle" ${heavy} font-size="28" fill="${ink}">MW</text>
<text x="74" y="30" ${heavy} font-size="31" fill="${paper}">ROCKPORT · EXPANSIÓN «RUST BELT»</text>
<text x="74" y="54" ${mono} font-size="13" fill="${fog}">${sub}</text>
</g>
<g transform="translate(28 ${H - 98})" ${mono} font-size="13" fill="${fog}">
<rect x="-12" y="-22" width="760" height="96" rx="4" fill="${ink}" fill-opacity=".78"/>
<rect x="0" y="-10" width="40" height="18" fill="none" stroke="${paper}" stroke-opacity=".5" stroke-dasharray="3 5"/><text x="52" y="4">Mapa del juego: Rockport, sus barrios, costa y ríos</text>
<line x1="0" y1="26" x2="40" y2="26" stroke="${amber}" stroke-width="3"/><text x="52" y="30">Interestatal I-99 (nueva)</text>
<line x1="0" y1="52" x2="40" y2="52" stroke="${amber}" stroke-width="2" stroke-dasharray="5 5"/><text x="52" y="56">Accesos nuevos desde Rockport</text>
<rect x="380" y="-10" width="18" height="18" fill="${amber}"/><text x="408" y="4">Distrito nuevo · número = orden de desbloqueo</text>
<text x="380" y="30">Norte arriba · 1 km ≈ ${(1000 * S).toFixed(0)} px</text>
<text x="380" y="56">Fuera del marco: propuesta de fans</text>
</g>`;
const svgOf = (png: Uint8Array, sub: string) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${PX} ${H}" width="${PX}" height="${H}">
<image href="data:image/png;base64,${Buffer.from(png).toString("base64")}" width="${PX}" height="${H}"/>${overlay(sub)}
</svg>`;

const pub = encodePng(compose(false), PX, H);
const outPub = `${repoRoot}docs/expansion/mapa-expansion.svg`;
await Bun.write(outPub, svgOf(pub, "Geografía del disco (relieve, costa, ríos y carreteras) redibujada · 4 distritos nuevos"));
const localDir = `${data}/expansion`; mkdirSync(localDir, { recursive: true });
const orig = encodePng(compose(true), PX, H);
await Bun.write(`${localDir}/mapa-expansion-original.png`, orig);
await Bun.write(`${localDir}/mapa-expansion-original.svg`, svgOf(orig, "Con el mapa original del disco (solo en tu equipo) · 4 distritos nuevos"));
console.log(`Plano: ${outPub} (${PX}×${H}, ${(pub.length / 1e6).toFixed(1)} MB de fondo, ${roads.segments.length} tramos reales + ${expansionRoads.length} nuevos)`);
console.log(`Local con el MINI_MAP original: ${localDir}/mapa-expansion-original.svg`);
console.log(`Accesos: oeste ${westExit.map(Math.round)} · norte ${northExit.map(Math.round)} · sur ${southExit.map(Math.round)}`);
