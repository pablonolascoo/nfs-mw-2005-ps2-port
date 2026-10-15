// Escenas de garaje conducibles: la conexión calle → interior que el juego no tiene (allí la zona menu_gate_* carga el
// frontend con EQuitToFE [D]) construida con texturas del propio disco.
//
// Uso: bun src/cli/garage-scenes.ts <iso> <ID>
// Entrada: map-data/<ID>/garages.json (paso garages), collision/ (paso collision: altura de la calle delante de la puerta),
//          FRONTEND\PLATFORMS\<platform>.BIN (texturas + sólidos para medir tamaño de textura y luz horneada) y
//          tools/data/garage-layouts.json (NUESTRO: solo números y nombres de texturas).
// Salida:  map-data/<ID>/garage-scenes/<zona>.glb   geometría en el marco de la puerta (x fuera, y izquierda, z arriba),
//                                     nodos SHELL (paredes, techo, vigas, suelo y carteles del volumen interior),
//                                     FRAME (jambas y dintel del hueco de la fachada) y APRON (umbral/rampa exterior)
//          map-data/<ID>/garage-scenes/<zona>.bin   colisión NFSC v1 en coordenadas de mundo (tris del umbral; muros del
//                                     volumen interior), mismo formato que collision/ (tools/src/cli/collision.ts)
//          map-data/<ID>/garage-scenes/<zona>.json  marco de la puerta, volumen, umbral y estadísticas
//          map-data/<ID>/garage-scenes/index.json   lista de zonas
//          map-data/<ID>/garage-scenes/textures/    PNG de las texturas usadas (del disco: no se suben a git)
// Lo lee native-engine/Sources/Rockport/Garage/GarageScenes.swift.
import { mkdirSync, existsSync, readFileSync, rmSync } from "node:fs";
import { GameDisc } from "../lib/zdir";
import { readSolidList, stripTriangles, type Solid } from "../lib/solid-ps2";
import { readTexturePack, type Texture } from "../lib/tex-ps2";
import { MaterialTable } from "../lib/materials";
import { writeGlb, type GlbMesh, type GlbPrimitive } from "../lib/glb";
import { bStringHash } from "../lib/hash";
import { ps2ColorToLinear } from "../lib/mesh-build";
import { outDir } from "../lib/paths";
import layoutsJson from "../../data/garage-layouts.json" with { type: "json" };

type V3 = [number, number, number];
interface Surface { texture: string; shade?: number[]; repeat?: number; color?: number[]; opaque?: boolean; from?: number; every?: number; size?: number[]; width?: number }
interface Decal { texture: string; wall: "back" | "left" | "right" | "front"; at: number; z: number; size: number[] }
interface KindLayout { platform: string; floor: Surface; walls: Surface; wallsTop?: Surface; ceiling: Surface; beams?: Surface; pillars?: Surface; frame: Surface; apron: Surface; decals?: Decal[] }
interface ZoneLayout { apronLength?: number; noApron?: boolean; extraDecals?: Decal[] }
const layouts = layoutsJson as unknown as { version: number; kinds: Record<string, KindLayout>; zones: Record<string, ZoneLayout> };

interface GarageInfo { collection: string; zoneType: string; zone: number[]; radius: number; building: { name: string; center: number[]; along: number; across: number; height: number; floor: number } | null; out: number[]; door: number[]; doorSize?: number[] }

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("uso: bun src/cli/garage-scenes.ts <iso> <ID>"); process.exit(1); }
const out = outDir(id);
const dest = `${out}/garage-scenes`;
rmSync(dest, { recursive: true, force: true });
mkdirSync(`${dest}/textures`, { recursive: true });
const garages = (JSON.parse(readFileSync(`${out}/garages.json`, "utf8")).garages ?? []) as GarageInfo[];
const disc = await GameDisc.open(iso);

// ── Colisión del mundo (NFSC) para medir la calle delante de cada puerta ────────────────────────────────────────────
const colTiles = new Map<string, { tris: Float32Array } | null>();
function colTile(tx: number, ty: number) {
  const k = `${tx}_${ty}`;
  if (colTiles.has(k)) return colTiles.get(k)!;
  const p = `${out}/collision/${k}.bin`;
  let t: { tris: Float32Array } | null = null;
  if (existsSync(p)) {
    const b = readFileSync(p), dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    if (dv.getUint32(0, true) === 0x4353464e) { const nt = dv.getUint32(8, true); t = { tris: new Float32Array(b.buffer.slice(b.byteOffset + 16, b.byteOffset + 16 + nt * 36)) }; }
  }
  colTiles.set(k, t);
  return t;
}
/** Muros del mundo (planta) cerca de un punto, con altura que cubra z0…z1. */
function worldWalls(x: number, y: number, r: number, z0: number, z1: number): number[][] {
  const outW: number[][] = [];
  const tx0 = Math.floor((x - r) / 400), tx1 = Math.floor((x + r) / 400), ty0 = Math.floor((y - r) / 400), ty1 = Math.floor((y + r) / 400);
  for (let tx = tx0; tx <= tx1; tx++) for (let ty = ty0; ty <= ty1; ty++) {
    const p = `${out}/collision/${tx}_${ty}.bin`; if (!existsSync(p)) continue;
    const b = readFileSync(p), dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    if (dv.getUint32(0, true) !== 0x4353464e) continue;
    const nt = dv.getUint32(8, true), nw = dv.getUint32(12, true);
    const f = new Float32Array(b.buffer.slice(b.byteOffset + 16 + nt * 36, b.byteOffset + 16 + nt * 36 + nw * 24));
    for (let i = 0; i < nw; i++) {
      const w = f.subarray(i * 6, i * 6 + 6);
      if (Math.max(w[4], w[5]) < z0 || Math.min(w[4], w[5]) > z1) continue;
      if (Math.min(Math.hypot(w[0] - x, w[1] - y), Math.hypot(w[2] - x, w[3] - y)) > r && Math.hypot((w[0] + w[2]) / 2 - x, (w[1] + w[3]) / 2 - y) > r) continue;
      outW.push([w[0], w[1], w[2], w[3]]);
    }
  }
  return outW;
}
/** Suelo del mundo bajo (x, y): el triángulo más alto que no pase de z + step (como CollisionWorld.ground). */
function worldGround(x: number, y: number, z: number, step = 1.5): number | undefined {
  const t = colTile(Math.floor(x / 400), Math.floor(y / 400)); if (!t) return undefined;
  const T = t.tris; let best: number | undefined;
  for (let i = 0; i + 8 < T.length; i += 9) {
    const ax = T[i], ay = T[i + 1], bx = T[i + 3], by = T[i + 4], cx = T[i + 6], cy = T[i + 7];
    if (x < Math.min(ax, bx, cx) || x > Math.max(ax, bx, cx) || y < Math.min(ay, by, cy) || y > Math.max(ay, by, cy)) continue;
    const v0x = bx - ax, v0y = by - ay, v1x = cx - ax, v1y = cy - ay, v2x = x - ax, v2y = y - ay;
    const den = v0x * v1y - v1x * v0y; if (Math.abs(den) < 1e-9) continue;
    const u = (v2x * v1y - v1x * v2y) / den, v = (v0x * v2y - v2x * v0y) / den;
    if (u < -1e-4 || v < -1e-4 || u + v > 1 + 1e-4) continue;
    const gz = T[i + 2] + u * (T[i + 5] - T[i + 2]) + v * (T[i + 8] - T[i + 2]);
    if (gz > z + step) continue;
    if (best === undefined || gz > best) best = gz;
  }
  return best;
}

// ── Estadísticas de las texturas en el interior del disco: m por repetición y color horneado medio ────────────────────
interface TexStat { repeatU: number; repeatV: number; color: number[]; n: number }
function textureStats(solids: Solid[]): Map<number, TexStat> {
  const acc = new Map<number, { ru: number[]; rv: number[]; c: number[]; n: number }>();
  for (const so of solids) {
    if (!/^BACKDROP/.test(so.name) || /NEXTGEN|REFLECTION/.test(so.name)) continue;
    for (const st of so.strips) {
      const h = so.textureHashes[st.texture]; if (h === undefined) continue;
      const a = acc.get(h) ?? acc.set(h, { ru: [], rv: [], c: [0, 0, 0], n: 0 }).get(h)!;
      for (const c of st.colors ?? []) { a.c[0] += c[0]; a.c[1] += c[1]; a.c[2] += c[2]; a.n++; }
      for (const [i, j, k] of stripTriangles(st)) {
        // Gradiente de UV: m por unidad de U y de V (pseudo-inversa de la matriz 3D ← UV del triángulo)
        const p0 = st.positions[i], p1 = st.positions[j], p2 = st.positions[k];
        const t0 = st.uvs[i], t1 = st.uvs[j], t2 = st.uvs[k];
        if (!t0 || !t1 || !t2) continue;
        const e1 = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]], e2 = [p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]];
        const du1 = t1[0] - t0[0], dv1 = t1[1] - t0[1], du2 = t2[0] - t0[0], dv2 = t2[1] - t0[1];
        const det = du1 * dv2 - du2 * dv1; if (Math.abs(det) < 1e-6) continue;
        const T = e1.map((_, q) => (e1[q] * dv2 - e2[q] * dv1) / det), B = e1.map((_, q) => (e2[q] * du1 - e1[q] * du2) / det);
        const lu = Math.hypot(...T), lv = Math.hypot(...B);
        if (lu > 0.05 && lu < 50) a.ru.push(lu);
        if (lv > 0.05 && lv < 50) a.rv.push(lv);
      }
    }
  }
  const med = (v: number[]) => { if (!v.length) return 0; const s = [...v].sort((x, y) => x - y); return s[s.length >> 1]; };
  const outMap = new Map<number, TexStat>();
  for (const [h, a] of acc) outMap.set(h, { repeatU: med(a.ru), repeatV: med(a.rv), color: a.n ? a.c.map(v => v / a.n) : [1, 1, 1], n: a.n });
  return outMap;
}

// ── Constructor de geometría (marco de la puerta) ─────────────────────────────────────────────────────────────────────
class Builder {
  prims = new Map<string, Map<number, { pos: number[]; nor: number[]; uv: number[]; col: number[]; idx: number[] }>>();
  /** Cuadrilátero p0 p1 p2 p3 (en orden), UV planas en metros / repetición; color por vértice (lineal). */
  quad(node: string, mat: number, p: V3[], uv: number[][], col: number[][]) {
    const nodeMap = this.prims.get(node) ?? this.prims.set(node, new Map()).get(node)!;
    const g = nodeMap.get(mat) ?? nodeMap.set(mat, { pos: [], nor: [], uv: [], col: [], idx: [] }).get(mat)!;
    const base = g.pos.length / 3;
    const e1 = sub(p[1], p[0]), e2 = sub(p[3], p[0]);
    const n = norm(cross(e1, e2));
    for (let i = 0; i < 4; i++) { g.pos.push(...p[i]); g.nor.push(...n); g.uv.push(...uv[i]); g.col.push(...col[i]); }
    g.idx.push(base, base + 1, base + 2, base, base + 2, base + 3);
  }
  meshes(): GlbMesh[] {
    return [...this.prims].map(([name, m]) => ({ name, primitives: [...m].map(([material, g]): GlbPrimitive => ({ material, positions: new Float32Array(g.pos), normals: new Float32Array(g.nor), uvs: new Float32Array(g.uv), colors: new Float32Array(g.col), indices: new Uint32Array(g.idx) })) }));
  }
}
const sub = (a: V3, b: V3): V3 => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const add = (a: V3, b: V3): V3 => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const mul = (a: V3, k: number): V3 => [a[0] * k, a[1] * k, a[2] * k];
const cross = (a: V3, b: V3): V3 => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const norm = (a: V3): V3 => { const l = Math.hypot(...a) || 1; return [a[0] / l, a[1] / l, a[2] / l]; };
const r3 = (v: number) => Math.round(v * 1000) / 1000;

// ── Por tipo de garaje: texturas del disco y estadísticas ─────────────────────────────────────────────────────────────
const kinds = new Map<string, { layout: KindLayout; textures: Map<number, Texture>; stats: Map<number, TexStat> }>();
for (const [k, layout] of Object.entries(layouts.kinds)) {
  const e = disc.find(`FRONTEND\\PLATFORMS\\${layout.platform}.BIN`);
  if (!e) { console.error(`  ${k}: no existe FRONTEND\\PLATFORMS\\${layout.platform}.BIN`); continue; }
  const buf = await disc.readEntry(e);
  const textures = new Map(readTexturePack(buf).textures.map(t => [t.nameHash, t] as const));
  kinds.set(k, { layout, textures, stats: textureStats(readSolidList(buf)) });
}

const written = new Set<number>();
const index: { zone: string; kind: string; json: string; glb: string; collision: string; apron: boolean; tris: number; walls: number }[] = [];
let missingTex = new Set<string>();
for (const g of garages) {
  const zone = g.collection.split("/").pop()!;
  const kind = kinds.get(g.zoneType);
  if (!kind) { console.log(`  ${zone}: sin plantilla para «${g.zoneType}»`); continue; }
  const L = kind.layout, Z = layouts.zones[zone] ?? {};
  // Marco de la puerta y volumen interior: las mismas cuentas que WorldGarages.place (native-engine, Garage/WorldGarage.swift)
  let ox = g.out[0] ?? 1, oy = g.out[1] ?? 0; const ol = Math.hypot(ox, oy) || 1; ox /= ol; oy /= ol;
  const ground = g.door.length >= 3 ? g.door[2] : g.zone[2];
  const doorP: V3 = [g.door[0], g.door[1], ground];
  const doorW = g.doorSize?.[0] ?? 6, doorH = g.doorSize?.[1] ?? 4;
  const b = g.building;
  const behind = b ? (b.center[0] - doorP[0]) * -ox + (b.center[1] - doorP[1]) * -oy + b.along / 2 : 16;
  // Volumen por defecto: la caja del edificio (como WorldGarages.place antes de las escenas)
  let depth = Math.max(8, Math.min(behind, 40)), width = b ? Math.min(b.across, 30) : 10;
  const height = b ? Math.max(4, Math.min(b.height, 9)) : 5;
  const toWorld = (p: V3): V3 => [doorP[0] + ox * p[0] - oy * p[1], doorP[1] + oy * p[0] + ox * p[1], doorP[2] + p[2]];
  const toLocal = (x: number, y: number): [number, number] => { const rx = x - doorP[0], ry = y - doorP[1]; return [rx * ox + ry * oy, -rx * oy + ry * ox]; };
  // Volumen real detrás de la puerta según la colisión del mundo (muros de la nave o del callejón cerrado): rayos desde
  // dentro hacia el fondo y hacia los lados. Así el recorte no se come fachadas retranqueadas a los lados de la puerta [V:
  // refugio 1, nave de 8 × 22,5 m detrás del arco «FLEA MARKET» con las alas de la fachada 6 m más atrás].
  const W2 = worldWalls(doorP[0], doorP[1], 60, ground + 0.3, ground + 2).map(w => [...toLocal(w[0], w[1]), ...toLocal(w[2], w[3])]);
  const ray = (px: number, py: number, dx: number, dy: number, max: number) => {
    let best = max;
    for (const [ax, ay, bx, by] of W2) {
      const sx = bx - ax, sy = by - ay, den = dx * sy - dy * sx; if (Math.abs(den) < 1e-9) continue;
      const qx = ax - px, qy = ay - py, t = (qx * sy - qy * sx) / den, u = (qx * dy - qy * dx) / den;
      if (t > 0.02 && u >= 0 && u <= 1 && t < best) best = t;
    }
    return best;
  };
  let left = width / 2, right = -width / 2, volSource = "edificio";
  const backHit = 1 + ray(-1, 0, -1, 0, 60);
  if (backHit >= 8 && backHit < 41) { depth = Math.min(depth, backHit); volSource = "colisión"; }
  {
    const xs = Array.from({ length: 8 }, (_, i) => -2 - i * (depth - 3) / 7);
    const l = Math.min(...xs.map(x => ray(x, 0, 0, 1, 15))), r = Math.min(...xs.map(x => ray(x, 0, 0, -1, 15)));
    const minHalf = doorW / 2 + 0.05;
    if (l < width / 2) { left = Math.max(l, minHalf); volSource = "colisión"; }
    if (r < width / 2) { right = -Math.max(r, minHalf); volSource = "colisión"; }
  }
  width = left - right;

  const mats = new MaterialTable(kind.textures, { unlit: false, external: { dir: `${dest}/textures`, uriPrefix: "textures/", written } });
  const matFor = (s: Surface, forceOpaque = false, forceRepeat = true) => {
    const h = bStringHash(s.texture);
    if (!kind.textures.has(h)) missingTex.add(`${L.platform}:${s.texture}`);
    const i = mats.get(h);
    const m = mats.materials[i];
    if ((forceOpaque || s.opaque) && m.alphaMode !== "OPAQUE") { m.alphaMode = "OPAQUE"; delete m.alphaCutoff; if (m.extras) delete m.extras.blend; }
    if (forceRepeat && m.texture !== undefined) { mats.images[m.texture].wrap = 3; if (m.extras) m.extras.wrap = 3; }
    return i;
  };
  const stat = (s: Surface) => kind.stats.get(bStringHash(s.texture));
  const repeat = (s: Surface): [number, number] => {
    if (s.repeat) return [s.repeat, s.repeat];
    const st = stat(s);
    const ru = st?.repeatU || 0, rv = st?.repeatV || 0;
    return [ru > 0.2 ? ru : rv > 0.2 ? rv : 3, rv > 0.2 ? rv : ru > 0.2 ? ru : 3];
  };
  /** Color horneado (lineal, como COLOR_0 de los interiores) a la altura relativa t (0 abajo, 1 arriba). */
  const colorAt = (s: Surface, t: number) => {
    const base = s.color ?? stat(s)?.color ?? [1, 1, 1];
    const sh = s.shade ?? [1, 1];
    const k = sh[0] + (sh[1] - sh[0]) * Math.max(0, Math.min(1, t));
    return ps2ColorToLinear([base[0] * k, base[1] * k, base[2] * k, 1]);
  };

  const B = new Builder();
  const X0 = -depth + 0.03, X1 = -0.6 - 0.02;             // fondo y cara interior de la fachada
  const YL = left - 0.03, YR = right + 0.03;                // paredes laterales (izquierda +, derecha −)
  const H = height - 0.8 - 0.02;                           // techo
  const gapY = doorW / 2 + 0.15, gapH = doorH + 0.2;      // hueco de la puerta (como el recorte del pasillo)
  const top = L.wallsTop?.from ?? H;
  // Pared vertical de a (x,y) a b (x,y) entre z0 y z1, con UV en metros a lo largo (u) y en altura (v).
  const wall = (node: string, s: Surface, a: [number, number], c: [number, number], z0: number, z1: number, u0 = 0) => {
    if (z1 - z0 < 0.01) return;
    const [ru, rv] = repeat(s), len = Math.hypot(c[0] - a[0], c[1] - a[1]);
    const mat = matFor(s, true);
    B.quad(node, mat, [[a[0], a[1], z0], [c[0], c[1], z0], [c[0], c[1], z1], [a[0], a[1], z1]],
      [[u0 / ru, -z0 / rv], [(u0 + len) / ru, -z0 / rv], [(u0 + len) / ru, -z1 / rv], [u0 / ru, -z1 / rv]],
      [colorAt(s, z0 / H), colorAt(s, z0 / H), colorAt(s, z1 / H), colorAt(s, z1 / H)]);
  };
  const wallBands = (node: string, a: [number, number], c: [number, number], z0: number, z1: number, u0 = 0) => {
    wall(node, L.walls, a, c, z0, Math.min(z1, top), u0);
    if (L.wallsTop && z1 > top) wall(node, L.wallsTop, a, c, Math.max(z0, top), z1, u0);
  };
  const horiz = (node: string, s: Surface, x0: number, x1: number, y0: number, y1: number, z: number, t = 0) => {
    const [ru, rv] = repeat(s), mat = matFor(s, true), c = colorAt(s, t);
    B.quad(node, mat, [[x0, y0, z], [x1, y0, z], [x1, y1, z], [x0, y1, z]], [[x0 / ru, y0 / rv], [x1 / ru, y0 / rv], [x1 / ru, y1 / rv], [x0 / ru, y1 / rv]], [c, c, c, c]);
  };
  /** Caja alineada (vigas, pilares) con todas sus caras salvo la de arriba/abajo si toca techo/suelo. */
  const box = (node: string, s: Surface, mn: V3, mx: V3) => {
    const [ru, rv] = repeat(s), mat = matFor(s, true);
    const P = (x: number, y: number, z: number): V3 => [x, y, z];
    const faces: V3[][] = [
      [P(mn[0], mn[1], mn[2]), P(mx[0], mn[1], mn[2]), P(mx[0], mn[1], mx[2]), P(mn[0], mn[1], mx[2])],
      [P(mx[0], mx[1], mn[2]), P(mn[0], mx[1], mn[2]), P(mn[0], mx[1], mx[2]), P(mx[0], mx[1], mx[2])],
      [P(mn[0], mx[1], mn[2]), P(mn[0], mn[1], mn[2]), P(mn[0], mn[1], mx[2]), P(mn[0], mx[1], mx[2])],
      [P(mx[0], mn[1], mn[2]), P(mx[0], mx[1], mn[2]), P(mx[0], mx[1], mx[2]), P(mx[0], mn[1], mx[2])],
      [P(mn[0], mn[1], mn[2]), P(mn[0], mx[1], mn[2]), P(mx[0], mx[1], mn[2]), P(mx[0], mn[1], mn[2])],
    ];
    for (const f of faces) {
      const along = Math.max(Math.hypot(f[1][0] - f[0][0], f[1][1] - f[0][1]), 0.01), hgt = Math.max(Math.abs(f[3][2] - f[0][2]), Math.hypot(f[3][0] - f[0][0], f[3][1] - f[0][1]));
      B.quad(node, mat, f, [[0, 0], [along / ru, 0], [along / ru, hgt / rv], [0, hgt / rv]], f.map(p => colorAt(s, p[2] / H)));
    }
  };

  // Suelo del volumen (2 cm por debajo del suelo del interior: solo se ve donde el interior no tiene suelo)
  horiz("SHELL", L.floor, X0, 0.02, YR, YL, -0.02, 0);
  // Paredes: fondo, izquierda (+Y), derecha (−Y) y la cara interior de la fachada con el hueco de la puerta
  wallBands("SHELL", [X0, YR], [X0, YL], 0, H);
  wallBands("SHELL", [X0, YL], [X1, YL], 0, H);
  wallBands("SHELL", [X1, YR], [X0, YR], 0, H);
  if (YL > gapY + 0.01) wallBands("SHELL", [X1, YL], [X1, gapY], 0, H);
  if (-gapY > YR + 0.01) wallBands("SHELL", [X1, -gapY], [X1, YR], 0, H, YL + gapY);
  wallBands("SHELL", [X1, Math.min(gapY, YL)], [X1, Math.max(-gapY, YR)], gapH, H, Math.max(0, YL - gapY));
  // Techo
  horiz("SHELL", L.ceiling, X0, X1, YR, YL, H, 1);
  // Vigas a lo ancho bajo el techo (y pilares contra las paredes laterales, si los hay)
  if (L.beams) {
    const every = L.beams.every ?? 4, [bw, bh] = L.beams.size ?? [0.3, 0.5];
    for (let x = X1 - every / 2; x > X0 + 0.5; x -= every) box("SHELL", L.beams, [x - bw / 2, YR, H - bh], [x + bw / 2, YL, H]);
  }
  if (L.pillars) {
    const every = L.pillars.every ?? 6, [pw, pd] = L.pillars.size ?? [0.5, 0.5];
    for (let x = X1 - every / 2; x > X0 + 0.5; x -= every) for (const sy of [1, -1]) {
      const y0 = sy > 0 ? YL : YR, y1 = sy > 0 ? YL - pd : YR + pd;
      box("SHELL", L.pillars, [x - pw / 2, Math.min(y0, y1), 0], [x + pw / 2, Math.max(y0, y1), H]);
    }
  }
  // Marco del hueco: jambas a lo largo del grosor de la fachada y dintel
  {
    const fw = L.frame.width ?? 0.3, xa = X1 - 0.02, xb = 0.04;
    box("FRAME", L.frame, [xa, gapY - 0.02, 0], [xb, gapY + fw, gapH + fw]);
    box("FRAME", L.frame, [xa, -gapY - fw, 0], [xb, -gapY + 0.02, gapH + fw]);
    box("FRAME", L.frame, [xa, -gapY, gapH - 0.02], [xb, gapY, gapH + fw]);
  }
  // Carteles y pintadas sobre las paredes (2 cm por delante)
  for (const dcl of [...(L.decals ?? []), ...(Z.extraDecals ?? [])]) {
    const h = bStringHash(dcl.texture);
    if (!kind.textures.has(h)) { missingTex.add(`${L.platform}:${dcl.texture}`); continue; }
    const mat = mats.get(h);
    // Pared vista desde dentro: origen a la izquierda, dirección hacia la derecha, normal hacia dentro
    const W: Record<Decal["wall"], { o: [number, number]; d: [number, number]; n: [number, number]; len: number }> = {
      back: { o: [X0, YL], d: [0, -1], n: [1, 0], len: YL - YR },
      left: { o: [X1, YL], d: [-1, 0], n: [0, -1], len: X1 - X0 },
      right: { o: [X0, YR], d: [1, 0], n: [0, 1], len: X1 - X0 },
      front: { o: [X1, YR], d: [0, 1], n: [-1, 0], len: YL - YR },
    };
    const w = W[dcl.wall], [dw, dh] = dcl.size;
    const c = w.len * dcl.at, off = 0.03;
    const cx = w.o[0] + w.d[0] * c + w.n[0] * off, cy = w.o[1] + w.d[1] * c + w.n[1] * off;
    const ax = cx - w.d[0] * dw / 2, ay = cy - w.d[1] * dw / 2, bx = cx + w.d[0] * dw / 2, by = cy + w.d[1] * dw / 2;
    const z0 = dcl.z - dh / 2, z1 = dcl.z + dh / 2;
    const col = colorAt(L.walls, dcl.z / H);
    B.quad("SHELL", mat, [[ax, ay, z0], [bx, by, z0], [bx, by, z1], [ax, ay, z1]], [[0, 1], [1, 1], [1, 0], [0, 0]], [col, col, col, col]);
  }

  // Umbral / rampa exterior: si la calle delante de la puerta no está a la altura del suelo del garaje (bordillo, acera),
  // una rampa de hormigón la salva. Se mide la colisión del mundo en tres líneas (centro y bordes del hueco).
  const coll: { tris: number[]; walls: number[] } = { tris: [], walls: [] };
  let apron = false, apronInfo: Record<string, number> = {};
  if (!Z.noApron) {
    const len = Z.apronLength ?? 3;
    const xs = Array.from({ length: Math.round(len / 0.25) + 1 }, (_, i) => 0.05 + i * 0.25);
    const ys = [-doorW / 2 + 0.3, 0, doorW / 2 - 0.3];
    const prof = xs.map(x => Math.max(...ys.map(y => { const w = toWorld([x, y, 0]); return (worldGround(w[0], w[1], ground + 0.6) ?? ground) - ground; })));
    const end = prof[prof.length - 1];
    // Envolvente: recta de 0 (puerta) a la altura de la calle al final, sin quedar por debajo de la calle en ningún punto
    let lift = 0;
    for (let i = 0; i < xs.length; i++) lift = Math.max(lift, prof[i] - end * (xs[i] - xs[0]) / (xs[xs.length - 1] - xs[0]));
    const step = Math.max(...prof.map((p, i) => i ? Math.abs(p - prof[i - 1]) : 0));
    apronInfo = { street: r3(end), maxStep: r3(step), lift: r3(lift), length: len };
    if (Math.abs(end) > 0.03 || step > 0.04) {
      apron = true;
      const n = xs.length, hw = doorW / 2 + 0.1;
      const zs = xs.map((x, i) => {
        const lin = end * (x - xs[0]) / (xs[n - 1] - xs[0]);
        // levanta el tramo del medio lo justo para cubrir el bordillo (curva suave que vuelve a la calle al final)
        const bump = lift * Math.sin(Math.PI * Math.min(1, (x - xs[0]) / (xs[n - 1] - xs[0]))) ;
        return Math.max(lin + bump, prof[i]) + 0.012;
      });
      zs[0] = 0.0; zs[n - 1] = Math.max(end, prof[n - 1]) + 0.005;
      const s = L.apron, [ru, rv] = repeat(s), mat = matFor(s, true), c = colorAt(s, 0.15);
      const edge = colorAt(s, 0);
      for (let i = 0; i + 1 < n; i++) {
        const xa = i === 0 ? -0.02 : xs[i], xb = xs[i + 1];
        const p: V3[] = [[xa, -hw, zs[i]], [xb, -hw, zs[i + 1]], [xb, hw, zs[i + 1]], [xa, hw, zs[i]]];
        B.quad("APRON", mat, p, p.map(q => [q[0] / ru, q[1] / rv]), [c, c, c, c]);
        // Faldones laterales hasta la calle (que no se vea el hueco por debajo)
        for (const sy of [-1, 1]) {
          const yy = sy * hw;
          const q: V3[] = [[xa, yy, zs[i] - 0.4], [xb, yy, zs[i + 1] - 0.4], [xb, yy, zs[i + 1]], [xa, yy, zs[i]]];
          B.quad("APRON", mat, q, q.map(v => [v[0] / ru, v[2] / rv]), [edge, edge, c, c]);
        }
        // Colisión del umbral (mundo)
        const w = p.map(toWorld);
        coll.tris.push(...w[0], ...w[1], ...w[2], ...w[0], ...w[2], ...w[3]);
      }
    }
  }
  // Muros del volumen interior (mundo): fondo, laterales y la fachada interior a los lados del hueco
  const segs: [[number, number], [number, number]][] = [
    [[X0, YR], [X0, YL]], [[X0, YL], [X1, YL]], [[X1, YR], [X0, YR]], [[X1, YL], [X1, gapY]], [[X1, -gapY], [X1, YR]],
  ];
  for (const [a, c] of segs) { const wa = toWorld([a[0], a[1], 0]), wc = toWorld([c[0], c[1], 0]); coll.walls.push(wa[0], wa[1], wc[0], wc[1], ground - 1, ground + H); }

  const meshes = B.meshes();
  await Bun.write(`${dest}/${zone}.glb`, writeGlb(meshes, mats.materials, mats.images, `GARAGE_SCENE_${zone}`));
  const nt = coll.tris.length / 9, nw = coll.walls.length / 6;
  const cb = new ArrayBuffer(16 + (coll.tris.length + coll.walls.length) * 4), dv = new DataView(cb);
  dv.setUint32(0, 0x4353464e, true); dv.setUint32(4, 1, true); dv.setUint32(8, nt, true); dv.setUint32(12, nw, true);
  const f = new Float32Array(cb, 16); f.set(coll.tris, 0); f.set(coll.walls, coll.tris.length);
  await Bun.write(`${dest}/${zone}.bin`, cb);
  const tris = meshes.reduce((a, m) => a + m.primitives.reduce((q, p) => q + p.indices.length / 3, 0), 0);
  const info = {
    zone, kind: g.zoneType, platform: L.platform, layoutVersion: layouts.version,
    frame: { door: doorP.map(r3), out: [r3(ox), r3(oy)], yaw: r3(Math.atan2(oy, ox)) },
    door: { width: r3(doorW), height: r3(doorH) },
    volume: { depth: r3(depth), width: r3(width), height: r3(height), left: r3(left), right: r3(right), source: volSource },
    shell: { back: r3(X0), front: r3(X1), left: r3(YL), right: r3(YR), ceiling: r3(H), gapHalfWidth: r3(gapY), gapHeight: r3(gapH) },
    apron: apron ? { ...apronInfo, area: [0, r3((Z.apronLength ?? 3) + 0.05), r3(doorW / 2 + 0.1)] } : null, apronProbe: apronInfo,
    glb: `${zone}.glb`, collision: `${zone}.bin`, tris, collisionTris: nt, collisionWalls: nw,
  };
  await Bun.write(`${dest}/${zone}.json`, JSON.stringify(info, null, 1));
  index.push({ zone, kind: g.zoneType, json: `${zone}.json`, glb: `${zone}.glb`, collision: `${zone}.bin`, apron, tris, walls: nw });
  console.log(`  ${zone}: ${L.platform} · volumen ${depth.toFixed(1)}×${width.toFixed(1)}×${height.toFixed(1)} m (${volSource}, izq. ${left.toFixed(1)}, dcha. ${(-right).toFixed(1)}) · ${tris} tris · umbral ${apron ? `sí (calle ${apronInfo.street} m, escalón ${apronInfo.maxStep} m)` : `no (calle ${apronInfo.street ?? "?"} m)`}`);
}
await Bun.write(`${dest}/index.json`, JSON.stringify({ disc: id, layoutVersion: layouts.version, frame: "x fuera, y izquierda, z arriba; origen en el centro de la persiana a ras de suelo", scenes: index }, null, 1));
console.log(`Escenas de garaje: ${index.length} · ${index.filter(i => i.apron).length} con umbral · texturas ${written.size}${missingTex.size ? ` · faltan ${[...missingTex].join(", ")}` : ""} → ${dest}`);
