// Coches predefinidos del juego («preset rides»: Lista Negra, coche inicial, coches de escena…) → presets.json + vinilos.
// Fuente: GLOBAL\GLOBALB.BUN (PresetCar 0x00030220 + CarPartPack 0x80034602, ver tools/src/lib/car-presets.ts) [V],
// texturas de vinilo CARS\<COCHE>\VINYLS.BIN (<BASE>_<TEXTURE> + <BASE>_<TEXTURE>_MASK, 512×512 en PS2) [V] y
// máscaras de llanta CARS\WHEELS\TEXTURES.BIN (<LLANTA>_WHEEL_INNER_MASK) [V]. Composición: CarSkin.cpp [D].
// Necesita los GLB de cars/ (paso «Coches»): cada pieza del preset se resuelve al nodo (sólido) exacto por el hash del modelo.
// Uso: bun src/cli/presets.ts <iso> <ID>  → map-data/<ID>/presets.json y map-data/<ID>/vinyls/*.png (solo local)
import { mkdirSync, existsSync, readdirSync, readFileSync } from "node:fs";
import { GameDisc } from "../lib/zdir";
import { readCarDb, SLOT, SLOT_NAMES, findPart, modelNameHash, type CarPart, type CarDb } from "../lib/car-presets";
import { readTexturePack, type Texture } from "../lib/tex-ps2";
import { parseChunks } from "../lib/bchunk";
import { encodePng } from "../lib/png";
import { bStringHash as H, hex8 } from "../lib/hash";
import { outDir } from "../lib/paths";

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/presets.ts <iso> <ID>"); process.exit(1); }
const out = outDir(id);
const d = await GameDisc.open(iso);
const globalb = await d.readEntry(d.find("GLOBAL\\GLOBALB.BUN")!);
const db: CarDb = readCarDb(globalb);

// Materiales de luz (eLightMaterial, chunk 0x00135200 de GLOBALB): +0x0C hash, +0x14 nombre [V: bStringHash("ALUMINUM") = 2e65e067]
const lightMaterials = new Map<number, string>();
{
  const dv = new DataView(globalb.buffer, globalb.byteOffset, globalb.byteLength);
  for (const c of parseChunks(globalb)) if (c.id === 0x00135200) {
    let n = ""; for (let i = 0; i < 48; i++) { const b = globalb[c.dataOffset + 0x14 + i]; if (!b) break; n += String.fromCharCode(b); }
    lightMaterials.set(dv.getUint32(c.dataOffset + 0x0c, true), n);
  }
}
const BRANDS = new Map(["GLOSS", "METAL", "PEARL", "VINYL", "RIM", "CALIPER", "MATTE", "CANDY", "CHROME"].map(n => [H(n), n]));

// Nodos de todos los GLB de coche ya convertidos: hash del nombre → { glb, nodo }
const nodeByHash = new Map<number, { glb: string; node: string }>();
const carsDir = `${out}/cars`;
if (!existsSync(carsDir)) { console.error(`Faltan los coches convertidos (${carsDir}): ejecuta antes el paso «Coches»`); process.exit(1); }
for (const f of readdirSync(carsDir).filter(f => f.endsWith(".glb"))) {
  const b = readFileSync(`${carsDir}/${f}`);
  const jl = b.readUInt32LE(12);
  const j = JSON.parse(b.subarray(20, 20 + jl).toString("utf8")) as { nodes?: { name?: string }[] };
  for (const n of j.nodes ?? []) if (n.name) nodeByHash.set(H(n.name), { glb: f.replace(/\.glb$/, ""), node: n.name });
}

const rgb = (p: CarPart) => [p.attrs.RED, p.attrs.GREEN, p.attrs.BLUE].map(v => (+v & 255).toString(16).padStart(2, "0")).join("");
const colour = (p?: CarPart) => p && "RED" in p.attrs ? { name: p.name, rgb: rgb(p), gloss: +(p.attrs.GLOSS ?? 0), finish: BRANDS.get(p.brandHash) ?? hex8(p.brandHash),
  material: typeof p.attrs.LIGHT_MATERIAL_NAME === "number" ? lightMaterials.get(p.attrs.LIGHT_MATERIAL_NAME) ?? hex8(p.attrs.LIGHT_MATERIAL_NAME) : undefined } : null;

// Color aproximado del tintado de cristales a partir de su nombre (el juego cambia el material de luz, no una textura) [I].
const TINT_COLOURS: Record<string, string> = { BLACK: "101214", RED: "5a1010", BLUE: "10204a", GREEN: "123a18", GOLD: "6a5418", AQUA: "105050", ORANGE: "6a3010", YELLOW: "6a6010", PINK: "6a2a4a", GRAPE: "3a1a4a", LAVENDER: "4a3a6a", LIME: "3a6010", SILVER: "50565c" };
function tint(p?: CarPart) {
  if (!p) return null;
  const words = p.name.toUpperCase().split(/\s+/);
  const col = words.find(w => w in TINT_COLOURS);
  const level = words.includes("DARK") ? 0.82 : words.includes("MEDIUM") ? 0.66 : words.includes("LIGHT") ? 0.5 : 0.4;
  const mat = typeof p.attrs.LIGHT_MATERIAL_NAME === "number" ? lightMaterials.get(p.attrs.LIGHT_MATERIAL_NAME) : undefined;
  return { name: p.name, material: mat, rgb: col ? TINT_COLOURS[col] : "0a0c10", opacity: col ? level : 0.78, pearl: words.includes("PEARL") };
}

// Texturas sueltas de un pack (se descodifica solo la pedida: los VINYLS.BIN traen ~276 de 512×512)
const rawPacks = new Map<string, Uint8Array | null>();
async function packTexture(file: string, hash: number): Promise<Texture | undefined> {
  if (!rawPacks.has(file)) { const e = d.find(file); rawPacks.set(file, e && e.size ? await d.readEntry(e) : null); }
  const buf = rawPacks.get(file);
  return buf ? readTexturePack(buf, h => h === hash).textures[0] : undefined;
}

mkdirSync(`${out}/vinyls`, { recursive: true });
const written = new Set<string>();
const sizes = new Map<string, { width: number; height: number }>();
const wheelNames = new Map<string, string | null>();
async function writeTex(t: Texture, file: string, mask: boolean) {
  if (written.has(file)) return;
  written.add(file);
  // Máscara: canal R de la paleta (CarSkin.cpp lee el byte 0); se guarda en gris. Imagen: RGBA tal cual (alfa ×2 = brillo).
  const px = mask ? t.rgba.map((v, i) => (i % 4 === 3 ? 255 : t.rgba[i - (i % 4)])) : t.rgba;
  await Bun.write(`${out}/vinyls/${file}`, encodePng(px, t.width, t.height));
}

const MODEL_SLOTS = SLOT_NAMES.slice(0, 76);
const HIDDEN_SLOTS = new Set(["DAMAGE0_FRONT", "DAMAGE0_FRONTLEFT", "DAMAGE0_FRONTRIGHT", "DAMAGE0_REAR", "DAMAGE0_REARLEFT", "DAMAGE0_REARRIGHT"]);
const blacklist: Record<string, number> = { RAZORMUSTANG: 1 };
for (let i = 2; i <= 15; i++) blacklist[`BL${i}`] = i;

const presets: unknown[] = [];
let missingNodes = 0, vinylsOut = 0;
for (const p of db.presets) {
  const type = db.types.find(t => t.name === p.carType);
  const base = type?.baseModel ?? p.carType;
  const part = (slot: string): CarPart | undefined => { const h = p.parts[SLOT[slot]]; return h > 1 ? findPart(db, p.carType, SLOT[slot], h) : undefined; };
  const solids: { slot: string; part: string; glb: string; node: string }[] = [];
  const missing: string[] = [];
  for (const slot of MODEL_SLOTS) {
    const h = p.parts[SLOT[slot]];
    if (h === 0) continue;
    // 1 = la pieza de serie (nivel 0) [D: FillWithPreset no la cambia; SetStockParts ya la puso]
    const cp = h === 1 ? findPart(db, p.carType, SLOT[slot], 0, 0) : findPart(db, p.carType, SLOT[slot], h);
    const optional = /^(DAMAGE|ATTACHMENT)|^LICENSE_PLATE$/.test(slot); // sin geometría propia en PS2 (daños, cargas, matrícula) [V]
    if (!cp) { if (!optional) missing.push(`${slot}:${hex8(h)}`); continue; }
    // LOD B (el del jugador en el juego) y si no hay, A, C, D, E
    let hit: { glb: string; node: string } | undefined;
    for (const lod of [1, 0, 2, 3, 4]) { const mh = modelNameHash(db, cp, lod); if (mh && (hit = nodeByHash.get(mh))) break; }
    if (hit) solids.push({ slot, part: cp.name, ...hit });
    else if (!optional && (modelNameHash(db, cp, 1) || modelNameHash(db, cp, 0))) missing.push(`${slot}:${cp.name}`);
  }
  missingNodes += missing.length;

  // Vinilo: <BASE>_<TEXTURE> + _MASK en CARS\<COCHE>\VINYLS.BIN [D: GetVinylLayerHash / GetVinylLayerMaskHash]
  const vp = part("VINYL_LAYER0");
  let vinyl: unknown = null;
  if (vp && typeof vp.attrs.TEXTURE === "string") {
    const f = `${base}_${vp.attrs.TEXTURE}`, vf = `CARS\\${p.carType}\\VINYLS.BIN`;
    const img = written.has(`${f}.png`) ? sizes.get(f) : await packTexture(vf, H(f));
    const mask = written.has(`${f}_MASK.png`) ? sizes.get(f) : await packTexture(vf, H(`${f}_MASK`));
    if (img && "rgba" in img) { sizes.set(f, { width: img.width, height: img.height }); await writeTex(img as Texture, `${f}.png`, false); vinylsOut++; }
    if (mask && "rgba" in mask) await writeTex(mask as Texture, `${f}_MASK.png`, true);
    const colours = [0, 1, 2, 3].map(i => colour(part(`VINYL_COLOUR0_${i}`)));
    vinyl = { name: vp.name, texture: vp.attrs.TEXTURE, image: img ? `vinyls/${f}.png` : null, mask: mask ? `vinyls/${f}_MASK.png` : null,
      size: img ? [img.width, img.height] : null, remap: +(vp.attrs.REMAP ?? 0), numColours: +(vp.attrs.NUMCOLOURS ?? 0), colours };
  }

  // Llanta y su pintura: <TEXTURE_NAME>_WHEEL + _WHEEL_INNER_MASK [D: CompositeRim, GetWheelTextureMaskHash]
  const wp = part("FRONT_WHEEL");
  let rim: unknown = null;
  if (wp) {
    const tn = typeof wp.attrs.TEXTURE_NAME === "number" ? wp.attrs.TEXTURE_NAME : 0;
    let maskFile: string | null = null, texName: string | null = null;
    if (tn) {
      const key = hex8(tn);
      if (!wheelNames.has(key)) {
        const w = await packTexture("CARS\\WHEELS\\TEXTURES.BIN", H("_WHEEL", tn)), m = await packTexture("CARS\\WHEELS\\TEXTURES.BIN", H("_WHEEL_INNER_MASK", tn));
        wheelNames.set(key, w?.name ?? null);
        if (m && w) await writeTex(m, `${w.name}_INNER_MASK.png`, true);
      }
      texName = wheelNames.get(key) ?? null;
      if (texName && written.has(`${texName}_INNER_MASK.png`)) maskFile = `vinyls/${texName}_INNER_MASK.png`;
    }
    rim = { name: wp.name, texture: texName, innerMask: maskFile, outerRadius: wp.attrs.OUTER_RADIUS ?? null, innerRadius: wp.attrs.INNER_RADIUS ?? null, spokes: wp.attrs.SPOKE_COUNT ?? null };
  }

  const decals: { slot: string; part: string; texture?: string }[] = [];
  for (const slot of SLOT_NAMES.filter(s => /^DECAL_.*_TEX\d$/.test(s))) { const dp = part(slot); if (dp) decals.push({ slot, part: dp.name, texture: dp.attrs.TEXTURE as string | undefined }); }
  const body = part("BODY");
  presets.push({
    name: p.name, car: p.carType, base, blacklist: blacklist[p.name] ?? null,
    kit: body?.attrs.KITNUMBER ?? 0,
    solids: solids.filter(s => !HIDDEN_SLOTS.has(s.slot)),
    paint: colour(part("BASE_PAINT")),
    vinyl, rim, rimPaint: colour(part("PAINT_RIM")),
    windowTint: tint(part("WINDOW_TINT")),
    licensePlate: part("LICENSE_PLATE")?.name ?? null,
    decals,
    missing: missing.length ? missing : undefined,
    feKey: p.feKey, vehicleKey: p.vehicleKey,
  });
}

const doc = {
  disc: id,
  source: "GLOBAL\\GLOBALB.BUN · PresetCar (0x00030220) + CarPartPack (0x80034602) · CARS\\<COCHE>\\VINYLS.BIN · CARS\\WHEELS\\TEXTURES.BIN",
  note: "solids = nodo exacto de cars/<glb>.glb por ranura (sin daños ni zonas de calcomanía vacías); paint/vinyl/rimPaint como CarSkin.cpp (CompositeSkin, CompositeRim). Blacklist: RAZORMUSTANG = nº 1, BLn = nº n.",
  compositing: "skin = base (paint.rgb, alfa = gloss) → por píxel: m = mask.R; m ≥ 128 → vinilo; 0 < m < 128 → mezcla m/128; alfa del vinilo = brillo (×2 en PNG)",
  presets,
};
await Bun.write(`${out}/presets.json`, JSON.stringify(doc, null, 1));
const bl = (presets as { name: string; blacklist: number | null }[]).filter(x => x.blacklist).length;
console.log(`Presets: ${presets.length} (${bl} de la Lista Negra) · ${vinylsOut} vinilos · ${written.size} PNG en vinyls/ · piezas sin nodo: ${missingNodes}`);
