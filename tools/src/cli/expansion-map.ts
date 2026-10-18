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
const W = { x0: -5000, x1: 6400, y0: -5150, y1: 8000 };
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

// ── 2. La propuesta: geografía que continúa la del juego ─────────────────────────────────────────────────────
// Bordes del mapa del juego medidos en MINI_MAP [V]: mar en todo el borde este y en el norte desde x 4739; al oeste salen
// el río de Rosewood (y 841–913) y el del suroeste (y −544…−421), que también toca el borde sur (x −217…134); al sur hay
// tierra salvo una ría (x 4778–5090). La propuesta sigue esa lógica:
//   · el río de Rosewood nace en las montañas del noroeste (embalse y presa de Black Hollow) y baja por el valle de Ironwood;
//   · la ría del sur se abre en una bahía (Calder Bay) que sale al mar por el este; el río del suroeste desemboca en ella.
const mainRiver: P[] = [[F.x0 - 20, 877], [-1700, 930], [-2300, 1150], [-2800, 1700], [-3050, 2500], [-2950, 3300], [-2750, 3950]];
const westRiver: P[] = [[F.x0 - 20, -482], [-1800, -700], [-2800, -640], [-3700, -900], [-5000, -800]];
const southRiver: P[] = [[-40, F.y0 + 30], [250, -2150], [900, -2550], [1700, -2720], [2450, -2660]];
const inlet: P[] = [[4934, F.y0 + 30], [4850, -2000], [4550, -2350]];
const bayToSea: P[] = [[4500, -2750], [5500, -2950], [6800, -3050]];
const bay = { c: [3500, -2650] as P, rx: 1250, ry: 560 };
const lake = { c: [-2650, 4380] as P, rx: 620, ry: 340 };
const ellipseD = (x: number, y: number, e: { c: P; rx: number; ry: number }) => (1 - Math.hypot((x - e.c[0]) / e.rx, (y - e.c[1]) / e.ry)) * Math.min(e.rx, e.ry);
/** Distancia con signo (m, positiva dentro del agua) de la geografía propuesta. */
function proposedWater(x: number, y: number): number {
  const wx = x + 90 * fbm(x / 600, y / 600), wy = y + 90 * fbm(x / 600 + 40, y / 600 + 40);
  const rx = x + 30 * fbm(x / 240, y / 240, 3), ry = y + 30 * fbm(x / 240 + 7, y / 240 + 7, 3);
  let sea: number;
  if (y >= F.y1) sea = wx - (4739 + (y - F.y1) * 0.18);
  else if (y >= F.y0) sea = x - F.x1 + 30;
  else sea = wx - (F.x1 + (F.y0 - y) * 0.55);
  // El río se estrecha aguas arriba (36 m en Rockport → 22 m bajo la presa)
  const up = clamp((F.x0 - x) / 2600 + (y - 900) / 6000);
  return Math.max(sea,
    36 - 14 * up - polyDist(rx, ry, mainRiver), 58 - polyDist(rx, ry, westRiver), 62 - polyDist(rx, ry, southRiver),
    150 - polyDist(wx, wy, inlet), 240 - polyDist(wx, wy, bayToSea), ellipseD(wx, wy, bay), ellipseD(wx, wy, lake));
}
/** Relieve propuesto (escala de gris de las bandas de MINI_MAP): cordillera con crestas al noroeste, colinas al norte,
 *  valles excavados por los ríos y llanura costera junto a la bahía. */
function proposedElev(x: number, y: number): number {
  const g = (cx: number, cy: number, rx: number, ry: number) => Math.exp(-(((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2));
  const ridged = 1 - Math.abs(fbm(x / 950, y / 950, 5));
  let e = 46 + 9 * fbm(x / 1600, y / 1600, 5) + 5 * fbm(x / 420 + 3, y / 420, 3)
    + g(-3100, 5400, 2300, 1900) * (24 + 62 * ridged * ridged)
    + 15 * g(1700, 6700, 2100, 800) + 8 * g(-1800, -2600, 1500, 900);
  const dr = Math.min(polyDist(x, y, mainRiver), polyDist(x, y, westRiver), polyDist(x, y, southRiver), Math.max(0, -ellipseD(x, y, lake)));
  e -= 16 * Math.exp(-((dr / 520) ** 2));
  e -= 10 * Math.exp(-((Math.max(0, -ellipseD(x, y, bay)) / 700) ** 2));
  return e;
}

// ── 3. Campos rasterizados (agua y relieve), que también usan las carreteras nuevas ─────────────────────────
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
  water[i] = Math.max(clamp(0.5 + proposedWater(x, y) * S), mw * (1 - smooth(0, 400, dOut)));
  elev[i] = soft + (proposedElev(x, y) - soft) * smooth(0, 1200, dOut);
}
const field = (arr: Float32Array, x: number, y: number) => {
  const u = clamp(sx(x) - 0.5, 0, PX - 1.001), v = clamp(sy(y) - 0.5, 0, H - 1.001), i = Math.floor(u), j = Math.floor(v), fu = u - i, fv = v - j, o = j * PX + i;
  return (arr[o] * (1 - fu) + arr[o + 1] * fu) * (1 - fv) + (arr[o + PX] * (1 - fu) + arr[o + PX + 1] * fu) * fv;
};
const wet = (p: P) => field(water, p[0], p[1]) > 0.3;

// ── 4. Carreteras nuevas: trazadas sobre el relieve, como se hacen las de verdad ────────────────────────────
// Rutas: camino de coste mínimo en una rejilla de 50 m (Dijkstra con heurística). Coste = longitud × (1 + pendiente² ·
// k) + agua (puentes caros, así cruzan por los estrechos) + no atravesar Rockport. Luego se simplifica y se suaviza.
const elevSoft = blur(elev, PX, H, 6, 2);
const G = 50, gw = Math.ceil((W.x1 - W.x0) / G) + 1, gh = Math.ceil((W.y1 - W.y0) / G) + 1;
const gE = new Float32Array(gw * gh), gWet = new Float32Array(gw * gh), gCity = new Uint8Array(gw * gh), gNoise = new Float32Array(gw * gh);
for (let j = 0; j < gh; j++) for (let i = 0; i < gw; i++) {
  const x = W.x0 + i * G, y = W.y1 - j * G, k = j * gw + i;
  gE[k] = field(elevSoft, x, y); gWet[k] = field(water, x, y); gNoise[k] = 1 + 0.45 * (fbm(x / 650 + 11, y / 650 - 5, 3) + 1);
  gCity[k] = x > F.x0 + 250 && x < F.x1 - 250 && y > F.y0 + 250 && y < F.y1 - 250 ? 1 : 0;
}
const used = new Float32Array(gw * gh);   // rutas ya hechas: las siguientes las reaprovechan (cruces naturales)
type RouteOpts = { slope: number; water: number; city?: number; reuse?: number; tol?: number; noise?: boolean };
const route = (a: P, b: P, o: RouteOpts): P[] => catmull(simplify(routeCells(a, b, o), o.tol ?? 55), false, 8);
function routeCells(a: P, b: P, o: RouteOpts): P[] {
  const ci = (p: P) => [clamp(Math.round((p[0] - W.x0) / G), 0, gw - 1), clamp(Math.round((W.y1 - p[1]) / G), 0, gh - 1)];
  const [ai, aj] = ci(a), [bi, bj] = ci(b), start = aj * gw + ai, goal = bj * gw + bi;
  const dist = new Float64Array(gw * gh).fill(Infinity), prev = new Int32Array(gw * gh).fill(-1), done = new Uint8Array(gw * gh);
  const heap: [number, number][] = [];
  const push = (f: number, k: number) => { heap.push([f, k]); let c = heap.length - 1; while (c) { const p = (c - 1) >> 1; if (heap[p][0] <= heap[c][0]) break; [heap[p], heap[c]] = [heap[c], heap[p]]; c = p; } };
  const pop = () => { const top = heap[0], last = heap.pop()!; if (heap.length) { heap[0] = last; let c = 0; for (;;) { const l = 2 * c + 1, r = l + 1; let m = c; if (l < heap.length && heap[l][0] < heap[m][0]) m = l; if (r < heap.length && heap[r][0] < heap[m][0]) m = r; if (m === c) break; [heap[m], heap[c]] = [heap[c], heap[m]]; c = m; } } return top; };
  const hx = (k: number) => Math.hypot((k % gw) - bi, Math.floor(k / gw) - bj) * G * (o.reuse ? 0.55 : 1);
  dist[start] = 0; push(hx(start), start);
  const nb = [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1], [2, 1], [1, 2], [-2, 1], [-1, 2], [2, -1], [1, -2], [-2, -1], [-1, -2]];
  while (heap.length) {
    const [, k] = pop(); if (done[k]) continue; done[k] = 1; if (k === goal) break;
    const i = k % gw, j = Math.floor(k / gw);
    for (const [di, dj] of nb) {
      const ni = i + di, nj = j + dj; if (ni < 0 || nj < 0 || ni >= gw || nj >= gh) continue;
      const n = nj * gw + ni, len = Math.hypot(di, dj) * G, dE = Math.abs(gE[n] - gE[k]) * G / len;
      let c = len * (1 + o.slope * dE * dE) + o.water * len * Math.max(gWet[n], gWet[k]) + (o.city ?? 6) * len * gCity[n];
      if (o.noise !== false) c *= gNoise[n];
      if (o.reuse) c *= 1 - o.reuse * used[n];
      const nd = dist[k] + c; if (nd < dist[n]) { dist[n] = nd; prev[n] = k; push(nd + hx(n), n); }
    }
  }
  const cells: P[] = []; for (let k = goal; k !== -1; k = prev[k]) cells.push([W.x0 + (k % gw) * G, W.y1 - Math.floor(k / gw) * G]);
  cells.reverse(); cells[0] = a; cells[cells.length - 1] = b;
  for (const p of cells) { const [i, j] = ci(p); for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) { const ii = i + di, jj = j + dj; if (ii >= 0 && jj >= 0 && ii < gw && jj < gh) used[jj * gw + ii] = Math.max(used[jj * gw + ii], di || dj ? 0.5 : 1); } }
  return cells;
}
/** Douglas-Peucker. */
function simplify(pts: P[], tol: number): P[] {
  if (pts.length < 3) return pts;
  let idx = 0, md = 0; const a = pts[0], b = pts[pts.length - 1];
  for (let i = 1; i < pts.length - 1; i++) { const d = segDist(pts[i][0], pts[i][1], a[0], a[1], b[0], b[1]); if (d > md) { md = d; idx = i; } }
  return md > tol ? [...simplify(pts.slice(0, idx + 1), tol).slice(0, -1), ...simplify(pts.slice(idx), tol)] : [a, b];
}
const rot = (c: P, a: number, u: number, v: number): P => [c[0] + u * Math.cos(a) - v * Math.sin(a), c[1] + u * Math.sin(a) + v * Math.cos(a)];
/** Calles de pueblo como las de Rockport: manzanas irregulares (bordes de Voronoi de puntos repartidos al azar con
 *  separación mínima), cruces en T y en Y, calles algo curvas y alguna sin salida; nada en el agua. */
function organicTown(c: P, rx: number, ry: number, a: number, sp: number, drop = 0.1): P[][] {
  const inside = (p: P, k = 1) => { const u = (p[0] - c[0]) * Math.cos(-a) - (p[1] - c[1]) * Math.sin(-a), v = (p[0] - c[0]) * Math.sin(-a) + (p[1] - c[1]) * Math.cos(-a); return (u / rx) ** 2 + (v / ry) ** 2 <= k * (1 + 0.22 * fbm(u / 350 + c[0], v / 350)); };
  const seeds: P[] = [];
  for (let t = 0; t < 4000 && seeds.length < 400; t++) {
    const p = rot(c, a, (rnd() * 2 - 1) * rx * 1.25, (rnd() * 2 - 1) * ry * 1.25);
    const local = sp * (0.75 + 0.75 * (fbm(p[0] / 900 + 5, p[1] / 900 - 3, 3) + 1) / 2);   // manzanas de tamaño variado
    if (!inside(p, 1.5) || seeds.some(q => Math.hypot(q[0] - p[0], q[1] - p[1]) < local)) continue;
    seeds.push(p);
  }
  // Delaunay (Bowyer-Watson) → Voronoi: cada arista compartida por dos triángulos une sus circuncentros
  type T = { a: number; b: number; c: number; cx: number; cy: number; r2: number };
  const pts: P[] = [...seeds, [c[0] - 1e5, c[1] - 1e5], [c[0] + 1e5, c[1] - 1e5], [c[0], c[1] + 1e5]];
  const circ = (i: number, j: number, k: number): T => {
    const [ax, ay] = pts[i], [bx, by] = pts[j], [cx, cy] = pts[k], d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by));
    const ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / d;
    const uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / d;
    return { a: i, b: j, c: k, cx: ux, cy: uy, r2: (ax - ux) ** 2 + (ay - uy) ** 2 };
  };
  let tris: T[] = [circ(seeds.length, seeds.length + 1, seeds.length + 2)];
  for (let p = 0; p < seeds.length; p++) {
    const [x, y] = pts[p], bad = tris.filter(t => (x - t.cx) ** 2 + (y - t.cy) ** 2 < t.r2);
    const edgeCount = new Map<string, [number, number]>();
    for (const t of bad) for (const [u, v] of [[t.a, t.b], [t.b, t.c], [t.c, t.a]]) { const k = u < v ? `${u},${v}` : `${v},${u}`; edgeCount.has(k) ? edgeCount.delete(k) : edgeCount.set(k, [u, v]); }
    tris = tris.filter(t => !bad.includes(t));
    for (const [u, v] of edgeCount.values()) tris.push(circ(u, v, p));
  }
  const byEdge = new Map<string, T[]>();
  for (const t of tris) for (const [u, v] of [[t.a, t.b], [t.b, t.c], [t.c, t.a]]) { const k = u < v ? `${u},${v}` : `${v},${u}`; (byEdge.get(k) ?? byEdge.set(k, []).get(k)!).push(t); }
  // Tramos válidos (bordes de Voronoi dentro del pueblo y en seco)
  const key = (p: P) => `${p[0].toFixed(2)},${p[1].toFixed(2)}`;
  const nodes = new Map<string, P>(), adj = new Map<string, Set<string>>();
  const link = (A: P, B: P) => { for (const [p, q] of [[A, B], [B, A]] as [P, P][]) { nodes.set(key(p), p); (adj.get(key(p)) ?? adj.set(key(p), new Set()).get(key(p))!).add(key(q)); } };
  for (const ts of byEdge.values()) {
    if (ts.length !== 2) continue;
    const A: P = [ts[0].cx, ts[0].cy], B: P = [ts[1].cx, ts[1].cy], L = Math.hypot(B[0] - A[0], B[1] - A[1]);
    const mid: P = [(A[0] + B[0]) / 2, (A[1] + B[1]) / 2];
    if (L < sp * 0.12 || L > sp * 2.2 || !inside(mid) || !inside(A, 1.25) || !inside(B, 1.25) || rnd() < drop) continue;
    if (wet(A) || wet(B) || wet(mid)) continue;
    link(A, B);
  }
  // Poda: fuera las calles sin salida muy cortas de los bordes (Rockport casi no tiene)
  for (const [k, ns] of [...adj]) {
    if (ns.size !== 1) continue;
    const [n] = ns, A = nodes.get(k)!, B = nodes.get(n)!;
    if (Math.hypot(A[0] - B[0], A[1] - B[1]) < sp * 0.7) { adj.get(n)?.delete(k); adj.delete(k); }
  }
  // Cadenas: desde cada tramo libre, se alarga por los dos extremos tomando en cada cruce el giro más suave (< 55°)
  const usedE = new Set<string>(), ek = (a: string, b: string) => a < b ? `${a}|${b}` : `${b}|${a}`;
  const extend = (chain: string[]) => {
    for (;;) {
      const a = nodes.get(chain[chain.length - 2])!, b = nodes.get(chain[chain.length - 1])!;
      let best: string | null = null, bt = Math.cos(55 * Math.PI / 180);
      for (const n of adj.get(chain[chain.length - 1]) ?? []) {
        if (usedE.has(ek(chain[chain.length - 1], n))) continue;
        const c2 = nodes.get(n)!, d1 = [b[0] - a[0], b[1] - a[1]], d2 = [c2[0] - b[0], c2[1] - b[1]];
        const cos = (d1[0] * d2[0] + d1[1] * d2[1]) / (Math.hypot(d1[0], d1[1]) * Math.hypot(d2[0], d2[1]) || 1);
        if (cos > bt) { bt = cos; best = n; }
      }
      if (!best) return;
      usedE.add(ek(chain[chain.length - 1], best)); chain.push(best);
    }
  };
  const out: P[][] = [];
  for (const [a, ns] of adj) for (const b of ns) {
    if (usedE.has(ek(a, b))) continue;
    usedE.add(ek(a, b));
    const fwd = [a, b]; extend(fwd);
    const back = [b, a]; extend(back);
    const chain = [...back.slice(2).reverse(), ...fwd].map(k => nodes.get(k)!);
    out.push(catmull(chain.map(([x, y]) => [x + 35 * fbm(x / 400, y / 400, 2), y + 35 * fbm(x / 400 + 9, y / 400, 2)] as P), false, 6));
  }
  return out;
}
/** Ronda que rodea el pueblo por tierra (se encoge donde toca agua). */
function ringRoad(c: P, rx: number, ry: number, a: number): P[] {
  const pts: P[] = [];
  for (let k = 0; k < 20; k++) {
    const t = k / 20 * Math.PI * 2; let r = 1.12 + 0.12 * fbm(k / 3 + c[0], c[1]);
    while (r > 0.55 && wet(rot(c, a, Math.cos(t) * rx * r, Math.sin(t) * ry * r))) r -= 0.04;
    pts.push(rot(c, a, Math.cos(t) * rx * r, Math.sin(t) * ry * r));
  }
  return catmull(pts, true, 6);
}
/** Paralela a una polilínea (orilla de un río), solo los tramos dentro de una elipse y en seco. */
function bankRoad(line: P[], off: number, c: P, rx: number, ry: number, a: number): P[][] {
  const out: P[][] = []; let cur: P[] = [];
  for (let i = 0; i < line.length - 1; i++) for (let s = 0; s < 8; s++) {
    const t = s / 8, A = line[i], B = line[i + 1], dx = B[0] - A[0], dy = B[1] - A[1], L = Math.hypot(dx, dy);
    const p: P = [A[0] + dx * t - dy / L * off, A[1] + dy * t + dx / L * off];
    const u = (p[0] - c[0]) * Math.cos(-a) - (p[1] - c[1]) * Math.sin(-a), v = (p[0] - c[0]) * Math.sin(-a) + (p[1] - c[1]) * Math.cos(-a);
    if ((u / rx) ** 2 + (v / ry) ** 2 <= 1 && !wet(p)) cur.push(p); else { if (cur.length > 3) out.push(cur); cur = []; }
  }
  if (cur.length > 3) out.push(cur);
  return out;
}
/** Muelles paralelos: a lo largo de la orilla sur de la bahía, cada uno hacia el norte desde donde empieza el agua. */
function piers(x0: number, x1: number, n: number, reach: number): P[][] {
  const out: P[][] = [];
  for (let k = 0; k < n; k++) {
    const x = x0 + (x1 - x0) * k / (n - 1);
    let shore: number | null = null;
    for (let y = bay.c[1] - bay.ry - 900; y < bay.c[1]; y += 10) if (wet([x, y])) { shore = y; break; }
    if (shore !== null) out.push([[x, shore - 110], [x, shore + reach]]);
  }
  return out;
}

const nearestNode = (score: (p: number[]) => number) => { let best = roads.nodes[0].p, bs = -Infinity; for (const n of roads.nodes) { const s = score(n.p); if (s > bs) { bs = s; best = n.p; } } return [best[0], best[1]] as P; };
// Accesos desde carreteras reales de Rockport: la autopista que sale por el oeste, lo más al norte de Rosewood,
// lo más al sur del centro y el extremo suroeste del centro
const westExit = nearestNode(p => -p[0]);
const northExit = nearestNode(p => p[0] > 800 && p[0] < 3200 ? p[1] : -Infinity);
const southExit = nearestNode(p => p[0] > 1200 && p[0] < 3000 ? -p[1] : -Infinity);
const swExit = nearestNode(p => p[1] < 600 && p[1] > -700 ? -p[0] : -Infinity);

type Road = { pts: P[]; w: number };
type District = { n: number; name: string; sub: string; en: string; bl: string; label: P; roads: Road[] };
const R = (pts: P[], w = 8): Road => ({ pts, w });
const streets = { slope: 1.2, water: 40, city: 6 };
// Centros: pegados a la ciudad (0,5–2 km del borde de Rockport) y donde el relieve lo pide
const C = {
  millbrook: [1750, 6000] as P, ironwood: [-2450, 1350] as P, hollow: [-1950, 3650] as P, mine: [-3900, 5000] as P,
  calder: [2700, -3550] as P, dam: [-2700, 4020] as P, pass: [-4650, 6650] as P,
};
const riverAngle = Math.atan2(1700 - 930, -2800 + 1700);
const ST = 24, AV = 30;   // ancho de calle y de avenida (m), como los tramos de roads.json
const districts: District[] = [
  { n: 1, name: "MILLBROOK", sub: "Pueblo obrero en las colinas · nuevo refugio", en: "Hillside working-class town · new safehouse", bl: "#15–#11", label: [1750, 7150],
    roads: [...organicTown(C.millbrook, 1450, 720, 0.12, 190, 0.16).map(p => R(p, ST)), ...organicTown([3450, 6150], 520, 380, -0.3, 180, 0.14).map(p => R(p, ST)),
      R(route(northExit, C.millbrook, streets), AV), R(route([1100, 4560], [700, 5900], streets), AV), R(route(C.millbrook, [3450, 6150], streets), AV),
      R(route([3450, 6150], [4250, 5300], streets), ST)] },
  { n: 2, name: "IRONWOOD", sub: "Valle del río · altos hornos · vías de tren", en: "River valley · steel mills · rail yards", bl: "#10–#6", label: [-3650, 450],
    roads: [...organicTown(C.ironwood, 1550, 820, riverAngle, 270, 0.14).map(p => R(p, AV)),
      ...bankRoad(mainRiver, 190, C.ironwood, 1600, 850, riverAngle).map(p => R(p, AV)), ...bankRoad(mainRiver, -200, C.ironwood, 1600, 850, riverAngle).map(p => R(p, AV)),
      R(route(westExit, C.ironwood, streets), AV), R(route(swExit, [-2200, 500], streets), AV)] },
  { n: 3, name: "CALDER BAY", sub: "Bahía · grúas · contenedores · puente levadizo", en: "Bay · cranes · containers · lift bridge", bl: "#5–#2", label: [2700, -4380],
    roads: [...organicTown(C.calder, 1650, 520, -0.05, 185, 0.12).map(p => R(p, ST)),
      ...(() => { const ps = piers(2900, 4300, 9, 280); return [...ps.map(p => R(p, 34)), R(catmull([[2500, ps[0][0][1] - 60], ...ps.map(p => p[0])]), AV)]; })(),   // muelles y calle del muelle
      R(route(southExit, C.calder, { ...streets, water: 25 }), AV)] },
  { n: 4, name: "BLACK HOLLOW", sub: "Montañas · embalse y presa · mina · puerto de montaña", en: "Mountains · reservoir and dam · coal mine · mountain pass", bl: "#1", label: [-2750, 6250],
    roads: [...organicTown(C.hollow, 620, 420, 0.4, 175, 0.06).map(p => R(p, ST)),
      R(catmull([[C.dam[0] - 330, C.dam[1] + 30], [C.dam[0] + 330, C.dam[1] - 20]]), AV),
      R(route(C.hollow, [C.dam[0] + 380, C.dam[1] - 20], streets), ST), R(route([C.dam[0] - 380, C.dam[1] + 30], C.mine, { slope: 0.6, water: 60 }), ST),
      ...organicTown(C.mine, 360, 240, 0.6, 150, 0.1).map(p => R(p, ST)), R(route(C.mine, C.pass, { slope: 0.5, water: 60 }), ST),
      R(route(C.hollow, westExit, streets), AV)] },
];
// Interestatal I-99: rodea la ciudad por fuera uniendo los cuatro distritos (pendiente muy cara, como una autopista)
const highway = { slope: 4, water: 18, city: 12, tol: 170, noise: false };
const i99Way: P[] = [[1600, -3450], [-1500, -2300], [-3200, 600], [-2600, 3000], [-1500, 5000], [600, 5950]];
// Una sola ruta continua (se suaviza entera, sin quiebros en los puntos de paso)
const i99: P[] = catmull(simplify(i99Way.slice(1).flatMap((b, k) => routeCells(i99Way[k], b, highway).slice(k ? 1 : 0)), 220), false, 10);
const expansionRoads: Road[] = [...districts.flatMap(d => d.roads), R(i99, 36)];
// Puntos de interés (rótulos pequeños)
const crossing = (pts: P[]) => pts.find(p => field(water, p[0], p[1]) > 0.6) ?? pts[Math.floor(pts.length / 2)];
const notes: { p: P; es: string; en: string }[] = [
  { p: [C.dam[0], C.dam[1] - 120], es: "Presa", en: "Dam" },
  { p: [lake.c[0], lake.c[1] + 40], es: "Embalse", en: "Reservoir" },
  { p: [C.mine[0], C.mine[1] - 240], es: "Mina de carbón", en: "Coal mine" },
  { p: [C.pass[0] + 250, C.pass[1] - 100], es: "Puerto de montaña", en: "Mountain pass" },
  { p: [-2050, 1900], es: "Altos hornos", en: "Steel mills" },
  { p: crossing(districts[2].roads[districts[2].roads.length - 1].pts), es: "Puente levadizo", en: "Lift bridge" },
  { p: [bay.c[0] - 300, bay.c[1] + 30], es: "Terminal de contenedores", en: "Container terminal" },
];

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
${outlined(`x="${(sx(i99[Math.floor(i99.length * 0.3)][0]) + 10).toFixed(0)}" y="${sy(i99[Math.floor(i99.length * 0.3)][1]).toFixed(0)}" ${mono} font-size="14" font-weight="700" fill="${amber}"`, `I-99`, 4)}
${notes.map(n => `<circle cx="${sx(n.p[0]).toFixed(0)}" cy="${sy(n.p[1]).toFixed(0)}" r="3.5" fill="${amber}" stroke="${ink}" stroke-width="1.5"/>` +
  outlined(`x="${(sx(n.p[0]) + 8).toFixed(0)}" y="${(sy(n.p[1]) + 4).toFixed(0)}" ${mono} font-size="12" font-style="italic" fill="${paper}"`, `${n.es} · ${n.en}`, 4)).join("")}
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
<circle cx="20" cy="52" r="3.5" fill="${amber}" stroke="${ink}" stroke-width="1.5"/><text x="52" y="56">Lugar de la historia (presa, mina, puente…)</text>
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
