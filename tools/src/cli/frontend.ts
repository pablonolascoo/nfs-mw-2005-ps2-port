// Interfaz original del juego (FEng): paquetes .fng, texturas de la interfaz, fuentes y textos → map-data/<ID>/frontend/
// Uso: bun src/cli/frontend.ts <iso> <ID>
// Lo usa el motor nativo (native-engine/Sources/Rockport/UI/). Formato y fuentes en docs/es/17-interfaz.md.
//
// Salida:
//   frontend/index.json              paquetes, fuentes, texturas (hash → archivo y tamaño) e idiomas
//   frontend/packages/<Nombre>.json  objetos (árbol por guid de padre), datos animables, scripts con pistas y eventos, recursos
//   frontend/textures/<hash>.png     texturas de interfaz a su tamaño original (hash = bStringHash del nombre en mayúsculas)
//   frontend/fonts/<nombre>.json     métricas de glifos (la textura del atlas va en textures/)
//   frontend/fonts/<nombre>.sdf.png  campo de distancias del atlas (8 bits, ×4) para dibujar letras nítidas a cualquier tamaño
//   frontend/strings/<idioma>.json   textos del idioma: {hash: texto}
//   frontend/minimaps/<MAPA>.png     radar del HUD: los 64 trozos (MINI_MAP_CHOPn, 128×128) de TRACKS\L2RA\<MAPA>.BIN en una
//                                    rejilla de 8×8 (trozo n en x = n%8·128, y = ⌊n/8⌋·128); index.json con la calibración del
//                                    mapa (TrackInfo 2000 de GLOBALB: esquina, ancho en metros) [D: FeMinimap.cpp, TrackInfo.hpp]
import { mkdirSync } from "node:fs";
import { outDir } from "../lib/paths";
import { GameDisc } from "../lib/zdir";
import { lzDecompress } from "../lib/lz";
import { readTexturePack, type Texture } from "../lib/tex-ps2";
import { encodePng } from "../lib/png";
import { parseChunks, walk } from "../lib/bchunk";
import { hex8 } from "../lib/hash";
import { findFEngChunks, parseFEPackage, parseFont, parseLanguage, feHash, type FEFont, type FEPackage } from "../lib/feng";

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/frontend.ts <iso> <ID>"); process.exit(1); }
const out = `${outDir(id)}/frontend`;
for (const d of ["packages", "textures", "fonts", "strings", "minimaps"]) mkdirSync(`${out}/${d}`, { recursive: true });
const disc = await GameDisc.open(iso);

async function read(name: string) {
  const e = disc.find(name);
  if (!e) return undefined;
  let b = await disc.readEntry(e);
  if (b.length >= 4 && b[0] === 0x4a && b[1] === 0x44 && b[2] === 0x4c && b[3] === 0x5a) b = lzDecompress(b); // «JDLZ»
  return b;
}

// Archivos con paquetes FEng [V: búsqueda de chunks 0x30203/0x30210 en todo SLES-53559]. INGAMESPLITSCREEN.BUN trae los HUD de
// pantalla partida (HUD_Player1/2, HUD_Drag_Player1/2) [V: SLES-53559; GameFlow.cpp lo carga solo en pantalla partida [D]].
const PACKAGE_FILES = ["FRONTEND\\FRONTB.LZC", "GLOBAL\\GLOBALA.BUN", "GLOBAL\\GLOBALB.LZC", "GLOBAL\\INGAMEB.LZC", "GLOBAL\\WIDESCREEN_GLOBAL.BUN",
  "GLOBAL\\INGAMESPLITSCREEN.BUN"];
// Packs de texturas de la interfaz (los mismos archivos + HUD, fuentes por idioma, tarjetas) [V]
const TEXTURE_FILES = [...PACKAGE_FILES, "GLOBAL\\INGAMEA.BUN", "LANGUAGES\\LANGUAGETEXTURES.BIN", "GLOBAL\\HUDTEXRACE.BIN", "GLOBAL\\HUDTEXSPLIT.BIN",
  "GLOBAL\\HUDTEXDRAG.BIN", "GLOBAL\\HUDTEXDRAGSPLIT.BIN", "GLOBAL\\CARDTEXTURES.BIN", "GLOBAL\\DYNTEX.BIN", "GLOBAL\\RIVALS.BIN", ...[...Array(11)].map((_, i) => `GLOBAL\\HUDS_CUSTOM_${String(i).padStart(2, "0")}.BIN`),
  // Mapas de las pruebas de la carrera rápida (TRACK_MAP_<id>, 512×512, 297 [V]) que UITrackMapStreamer pone en Track_Select [D]
  "TRACKS\\L2RA\\TRACKMAPS.BIN"];
// Idioma por disco: PAL → castellano (SLES-53559 lleva el texto en español [V]); NTSC-U → inglés. El inglés va siempre de reserva.
const LANGS = id.startsWith("SLUS") ? ["ENGLISH"] : ["SPANISH", "ENGLISH"];

// 1) Texturas
const textures = new Map<number, Texture & { source: string }>();
for (const f of TEXTURE_FILES) {
  const b = await read(f);
  if (!b) continue;
  try { for (const t of readTexturePack(b).textures) if (!textures.has(t.nameHash)) textures.set(t.nameHash, { ...t, source: f }); }
  catch (e) { console.warn(`texturas de ${f}: ${(e as Error).message}`); }
}

// 2) Paquetes y fuentes
const packages: { pk: FEPackage; source: string }[] = [];
const fonts = new Map<number, FEFont & { source: string }>();
for (const f of [...PACKAGE_FILES, ...LANGS.map(l => `LANGUAGES\\${l}.BIN`)]) {
  const b = await read(f);
  if (!b) continue;
  const found = findFEngChunks(b);
  for (const p of found.packages) {
    try { const pk = parseFEPackage(p.data); if (!packages.some(q => q.pk.name === pk.name)) packages.push({ pk, source: f }); }
    catch (e) { console.warn(`paquete de ${f}: ${(e as Error).message}`); }
  }
  // Las fuentes del idioma principal mandan (van primero en LANGS); las de FRONTB/INGAMEB/GLOBALA completan.
  for (const c of found.fonts) {
    try { const ft = parseFont(c); if (!fonts.has(ft.hash) || f.includes(LANGS[0])) fonts.set(ft.hash, { ...ft, source: f }); }
    catch (e) { console.warn(`fuente de ${f}: ${(e as Error).message}`); }
  }
}

// 3) Textos
const stringsIndex: Record<string, number> = {};
for (const l of LANGS) {
  const b = await read(`LANGUAGES\\${l}.BIN`);
  if (!b) continue;
  const m = parseLanguage(b);
  const obj: Record<string, string> = {};
  for (const [h, s] of [...m].sort((a, b) => a[0] - b[0])) obj[hex8(h)] = s;
  await Bun.write(`${out}/strings/${l.toLowerCase()}.json`, JSON.stringify(obj));
  stringsIndex[l.toLowerCase()] = m.size;
}

// 4) Qué texturas hacen falta: recursos de imagen de cada paquete, texturas de multi-imagen y atlas de las fuentes
const needed = new Set<number>();
const missing = new Map<number, string>();
for (const { pk } of packages) {
  for (const r of pk.resources) if (r.type === 1 || r.type === 6 || r.type === 7) {
    const h = feHash(r.name.replace(/^.*[\\/]/, "").replace(/\.[^.]*$/, ""));
    if (textures.has(h)) needed.add(h); else if (r.type !== 7) missing.set(h, r.name);
  }
  for (const o of pk.objects) for (const t of o.multi?.tex ?? []) if (t) { if (textures.has(t)) needed.add(t); else missing.set(t, `multi ${hex8(t)}`); }
}
for (const f of fonts.values()) { if (textures.has(f.textureHash)) needed.add(f.textureHash); else missing.set(f.textureHash, `fuente ${f.texture}`); }
// Texturas que el código del HUD elige por nombre (FEngSetTextureHash): se exportan todas las de los packs del HUD y del juego.
// Iconos de menú que pone el código (MAIN_ICON_*, INGAME_ICON_*…): se exportan todos los packs de interfaz.
for (const [h, t] of textures) if (/HUD|INGAME|GLOBALA|GLOBALB|FRONTB|WIDESCREEN|RIVALS|TRACKMAPS/.test(t.source)) needed.add(h);
// DYNTEX: rótulos por idioma que el código pone a mano (BUSTED_SPA, EVADED_ENG…), consejos de carga y mandos [V: DYNTEX.BIN]
for (const [h, t] of textures) if (t.source.includes("DYNTEX") && /^(BUSTED|EVADED|DEFEATED|IMPOUNDED|TIP_|LOADING_CONTROLLER_PS2|INGAME_ICON|MILESTONE|RACE_ICON|EVENT_ICON)/.test(t.name)) needed.add(h);

const texIndex: Record<string, { name: string; w: number; h: number; blend: number; wrap: number; source: string }> = {};
for (const h of needed) {
  const t = textures.get(h)!;
  await Bun.write(`${out}/textures/${hex8(h)}.png`, encodePng(t.rgba, t.width, t.height));
  // blend = AlphaBlendType (2 = aditiva); wrap = TilableUV (bit 0 repite U, bit 1 repite V; 0 = recortar al borde) [D: TextureInfo 0x4F]
  texIndex[hex8(h)] = { name: t.name, w: t.width, h: t.height, blend: t.alphaBlend, wrap: t.tilableUV & 3, source: t.source };
}

// 5) Fuentes: métricas + campo de distancias del atlas
for (const f of fonts.values()) {
  const t = textures.get(f.textureHash);
  const { source, ...json } = f;
  await Bun.write(`${out}/fonts/${f.name.toLowerCase()}.json`, JSON.stringify({ ...json, hashHex: hex8(f.hash), textureHex: hex8(f.textureHash), atlas: t ? { w: t.width, h: t.height } : null, source }));
  if (t) await Bun.write(`${out}/fonts/${f.name.toLowerCase()}.sdf.png`, encodePng(...sdfAtlas(t.rgba, t.width, t.height, 4)));
}

// 6) Paquetes
for (const { pk, source } of packages) {
  const resources = pk.resources.map(r => ({ ...r, hash: hex8(feHash(r.name.replace(/^.*[\\/]/, "").replace(/\.[^.]*$/, ""))) }));
  await Bun.write(`${out}/packages/${pk.name.replace(/\.fng$/i, "")}.json`, JSON.stringify({ ...pk, resources, source }));
}

// 7) Radar del HUD: mapas troceados (chunks 0x3A100 = cabecera LZ + pack de texturas con un trozo) [D: ChoppedMiniMapManager]
const minimaps: Record<string, { file: string; chops: number }> = {};
{
  // Nombre = «MINI_MAP_» + id del evento con «.» → «_» (ChooseMinimapTextureName + FixDot) [D]; se prueban por hash
  const names = ["MINI_MAP", "MINI_MAP_UNLOCK_1", "MINI_MAP_UNLOCK_2", "MINI_MAP_13_4_1_0"];
  for (let a = 1; a <= 25; a++) for (let b = 0; b <= 12; b++) {
    names.push(`MINI_MAP_${a}_${b}_0`);
    for (let c = 1; c <= 70; c++) for (const r of ["", "_R"]) names.push(`MINI_MAP_${a}_${b}_${c}${r}`);
  }
  for (const name of names) {
    const e = disc.find(`TRACKS\\L2RA\\${name}.BIN`);
    if (!e) continue;
    const b = await disc.readEntry(e);
    const atlas = new Uint8Array(1024 * 1024 * 4);
    let n = 0;
    for (const c of parseChunks(b)) {
      if (c.id !== 0x3a100) continue;
      try {
        const tp = readTexturePack(lzDecompress(b.subarray(c.dataOffset, c.dataOffset + c.size)));
        for (const t of tp.textures) {
          const m = /_CHOP(\d+)$/.exec(t.name);
          if (!m || t.width !== 128 || t.height !== 128) continue;
          const k = +m[1], ox = (k % 8) * 128, oy = Math.floor(k / 8) * 128;
          for (let y = 0; y < 128; y++) atlas.set(t.rgba.subarray(y * 512, y * 512 + 512), ((oy + y) * 1024 + ox) * 4);
          n++;
        }
      } catch (err) { console.warn(`radar ${name}: ${(err as Error).message}`); }
    }
    if (!n) continue;
    await Bun.write(`${out}/minimaps/${name}.png`, encodePng(atlas, 1024, 1024));
    minimaps[name] = { file: `minimaps/${name}.png`, chops: n };
  }
  // Calibración del mapa: TrackInfo (0x120 B) del circuito 2000 en GLOBALB, chunk 0x34201 [D: TrackInfo.hpp][V]
  let calib: { upperLeft: number[]; widthMetres: number; rotation: number } | null = null;
  const g = await read("GLOBAL\\GLOBALB.LZC");
  if (g) for (const [c] of walk(parseChunks(g))) if (c.id === 0x34201) {
    const dv = new DataView(g.buffer, g.byteOffset + c.dataOffset, c.size);
    for (let o = 0; o + 0x120 <= c.size; o += 0x120) if (dv.getInt16(o + 0x8a, true) === 2000)
      calib = { upperLeft: [dv.getFloat32(o + 0xac, true), dv.getFloat32(o + 0xb0, true)], widthMetres: dv.getFloat32(o + 0xb4, true), rotation: dv.getUint16(o + 0xb8, true) };
  }
  await Bun.write(`${out}/minimaps/index.json`, JSON.stringify({ track: 2000, calibration: calib, chopsPerSide: 8, chopSize: 128, maps: minimaps }, null, 1));
}

await Bun.write(`${out}/index.json`, JSON.stringify({
  format: 1, disc: id, languages: LANGS.map(l => l.toLowerCase()), strings: stringsIndex, virtualScreen: [640, 480],
  packages: packages.map(p => ({ name: p.pk.name, file: `packages/${p.pk.name.replace(/\.fng$/i, "")}.json`, source: p.source, objects: p.pk.objects.length })),
  fonts: [...fonts.values()].map(f => ({ name: f.name, hash: hex8(f.hash), file: `fonts/${f.name.toLowerCase()}.json`, texture: hex8(f.textureHash), height: f.height })),
  textures: texIndex, missingTextures: Object.fromEntries([...missing].map(([h, n]) => [hex8(h), n])),
}, null, 1));
console.log(`Radar: ${Object.keys(minimaps).length} mapas`);
console.log(`Interfaz: ${packages.length} paquetes, ${fonts.size} fuentes, ${needed.size} texturas (${missing.size} sin encontrar), textos ${JSON.stringify(stringsIndex)} → ${out}`);

/**
 * Campo de distancias firmado del atlas de una fuente, a `scale` veces su tamaño [I: técnica estándar, no es del juego].
 * El alfa original (con antialias) se reescala con interpolación bicúbica, se corta en 0,5 y se mide la distancia euclídea
 * exacta al borde (transformada de Felzenszwalb). Salida: R=G=B=255, A = 128 + distancia·(127/rango); rango = 4 px de salida.
 * Así el motor dibuja las letras con bordes limpios a 4K sin la borrosidad de ampliar un mapa de bits de 640×480.
 */
function sdfAtlas(rgba: Uint8Array, w: number, h: number, scale: number): [Uint8Array, number, number] {
  const W = w * scale, H = h * scale;
  const a = (x: number, y: number) => rgba[((Math.min(h - 1, Math.max(0, y)) * w + Math.min(w - 1, Math.max(0, x))) * 4) + 3] / 255;
  const cub = (p0: number, p1: number, p2: number, p3: number, t: number) => p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)));
  const inside = new Uint8Array(W * H);
  for (let Y = 0; Y < H; Y++) for (let X = 0; X < W; X++) {
    const fx = (X + 0.5) / scale - 0.5, fy = (Y + 0.5) / scale - 0.5, x0 = Math.floor(fx), y0 = Math.floor(fy), tx = fx - x0, ty = fy - y0;
    const row = (yy: number) => cub(a(x0 - 1, yy), a(x0, yy), a(x0 + 1, yy), a(x0 + 2, yy), tx);
    inside[Y * W + X] = cub(row(y0 - 1), row(y0), row(y0 + 1), row(y0 + 2), ty) >= 0.5 ? 1 : 0;
  }
  const INF = 1e20;
  const edt = (seed: (i: number) => boolean) => {
    const f = new Float64Array(W * H);
    for (let i = 0; i < W * H; i++) f[i] = seed(i) ? 0 : INF;
    const n = Math.max(W, H), d = new Float64Array(n), v = new Int32Array(n), z = new Float64Array(n + 1), g = new Float64Array(n);
    const pass = (len: number, get: (k: number) => number, set: (k: number, x: number) => void) => {
      for (let q = 0; q < len; q++) g[q] = get(q);
      let k = 0; v[0] = 0; z[0] = -INF; z[1] = INF;
      for (let q = 1; q < len; q++) {
        let s = ((g[q] + q * q) - (g[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k]);
        while (s <= z[k]) { k--; s = ((g[q] + q * q) - (g[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k]); }
        k++; v[k] = q; z[k] = s; z[k + 1] = INF;
      }
      k = 0;
      for (let q = 0; q < len; q++) { while (z[k + 1] < q) k++; d[q] = (q - v[k]) * (q - v[k]) + g[v[k]]; }
      for (let q = 0; q < len; q++) set(q, d[q]);
    };
    for (let x = 0; x < W; x++) pass(H, y => f[y * W + x], (y, val) => { f[y * W + x] = val; });
    for (let y = 0; y < H; y++) pass(W, x => f[y * W + x], (x, val) => { f[y * W + x] = val; });
    return f;
  };
  const dOut = edt(i => inside[i] === 1), dIn = edt(i => inside[i] === 0);
  const res = new Uint8Array(W * H * 4), range = 4;
  for (let i = 0; i < W * H; i++) {
    const sd = inside[i] ? Math.sqrt(dIn[i]) - 0.5 : -(Math.sqrt(dOut[i]) - 0.5);
    res[i * 4] = res[i * 4 + 1] = res[i * 4 + 2] = 255;
    res[i * 4 + 3] = Math.max(0, Math.min(255, Math.round(128 + sd * (127 / range))));
  }
  return [res, W, H];
}
