// Luz y efectos del juego (doc 20): lo que el motor necesita para que coches, cielo, sombras y postproceso se vean como en PS2.
//   fx/fx.json  · visuallook / visualrgbtweaker / visuallookeffect (tratamiento visual), light_flares_cg (destellos de luces),
//                 materiales de luz de los coches (eLightMaterial, chunk 0x00135200 de GLOBALB: difusa, especular, entorno)
//                 y la información del sol (SunChunkInfo, chunk 0x00034202) [V][D]
//   fx/*.png    · CARSHADOW y SHADOWRAMP (sombra del coche), SMALLENVMAP y <GARAJE>_CARSELECTENVMAP (mapas de entorno esféricos
//                 de los coches), SKY_* de GLOBAL\DYNTEX.BIN (cielo y reflejos del cielo), SUNCENTER/SUNHALO, destellos de faros [V]
// Nada de esto se sube a git: se genera desde la ISO del usuario.
// Uso: bun src/cli/fx.ts <iso> <ID>  → map-data/<ID>/fx/
import { mkdirSync } from "node:fs";
import { GameDisc } from "../lib/zdir";
import { AttribDatabase, Vault, parseVpak } from "../lib/vlt";
import { loadAttribNames } from "../lib/attrib-names";
import { readTexturePack, type Texture } from "../lib/tex-ps2";
import { parseChunks, walk } from "../lib/bchunk";
import { lzDecompress } from "../lib/lz";
import { encodePng } from "../lib/png";
import { bStringHash as H, hex8 } from "../lib/hash";
import { outDir } from "../lib/paths";

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/fx.ts <iso> <ID>"); process.exit(1); }
const out = `${outDir(id)}/fx`;
mkdirSync(out, { recursive: true });
const d = await GameDisc.open(iso);
const read = async (name: string) => {
  const e = d.find(name);
  if (!e || !e.size) return undefined;
  let b = await d.readEntry(e);
  if (b.length >= 4 && b[0] === 0x4a && b[1] === 0x44 && b[2] === 0x4c && b[3] === 0x5a) b = lzDecompress(b); // «JDLZ»
  return b;
};

// ---------- 1. Atributos (GLOBAL\ATTRIBUTES.BIN) ----------
const db = new AttribDatabase();
await loadAttribNames(db);
for (const v of parseVpak((await read("GLOBAL\\ATTRIBUTES.BIN"))!)) db.addVault(new Vault(v.name, v.vlt, v.bin));
const classes = ["visuallook", "visualrgbtweaker", "visuallookeffect", "visuallooktransition", "light_flares_cg"];
const attribs: Record<string, Record<string, unknown>> = {};
for (const c of db.collections.values()) {
  const cls = db.names.name(c.classKey);
  if (!classes.includes(cls)) continue;
  (attribs[cls] ??= {})[db.collectionName(c)] = db.resolvedValues(c);
}
// IVisualTreatment [D: World/VisualTreatment.cpp]: Midday 0xEEC2271A (no está en el disco PAL: el VLT cae en «default»),
// Sunset 0xCEDA4E4F, Uves 0x681BEF75 («uves»), CopCam 0xEE6074A3.
const visualLookKeys = { midday: "0xeec2271a", sunset: "0xceda4e4f", uves: "uves", copcam: "0xee6074a3" };

// ---------- 2. Materiales de luz de los coches (GLOBALB.BUN 0x00135200, eLightMaterial 0xA8 B) [V][D: eLight.hpp] ----------
const globalb = (await read("GLOBAL\\GLOBALB.BUN"))!;
const gdv = new DataView(globalb.buffer, globalb.byteOffset, globalb.byteLength);
const F = ["diffuseMinScale", "diffuseMinR", "diffuseMinG", "diffuseMinB", "diffuseMaxScale", "diffuseMaxR", "diffuseMaxG", "diffuseMaxB",
  "diffuseMinA", "diffuseMaxA", "specularPower", "specularMinScale", "specularMinR", "specularMinG", "specularMinB", "specularMaxScale",
  "specularMaxR", "specularMaxG", "specularMaxB", "envmapPower", "envmapMinScale", "envmapMinR", "envmapMinG", "envmapMinB",
  "envmapMaxScale", "envmapMaxR", "envmapMaxG", "envmapMaxB", "metallicScale", "specularHotSpot"];
const lightMaterials: Record<string, Record<string, number>> = {};
for (const c of parseChunks(globalb)) if (c.id === 0x00135200) {
  const o = c.dataOffset;
  let n = ""; for (let i = 0; i < 28; i++) { const b = globalb[o + 0x14 + i]; if (!b) break; n += String.fromCharCode(b); }
  const m: Record<string, number> = { hash: gdv.getUint32(o + 0x0c, true) };
  F.forEach((f, i) => { m[f] = +gdv.getFloat32(o + 0x30 + i * 4, true).toFixed(4); });
  lightMaterials[n] = m;
}

// ---------- 3. Sol (SunChunkInfo 0x00034202, 0x110 B) [D: PS2_types SunChunkInfo] ----------
const suns: unknown[] = [];
for (const f of ["TRACKS\\L2RA.BUN", "GLOBAL\\GLOBALB.BUN", "GLOBAL\\INGAMEA.BUN"]) {
  const b = f === "GLOBAL\\GLOBALB.BUN" ? globalb : await read(f);
  if (!b) continue;
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  for (const [c] of walk(parseChunks(b))) if (c.id === 0x00034202) {
    for (let o = c.dataOffset; o + 0x110 <= c.dataOffset + c.size; o += 0x110) {
      let name = ""; for (let i = 0; i < 24; i++) { const ch = b[o + 8 + i]; if (!ch) break; name += String.fromCharCode(ch); }
      const fl = (k: number) => +dv.getFloat32(o + k, true).toFixed(3);
      const layers = [];
      for (let l = 0; l < 6; l++) {
        const p = o + 0x38 + l * 0x24;
        layers.push({ texture: dv.getInt32(p, true), alpha: dv.getInt32(p + 4, true), intensity: +dv.getFloat32(p + 8, true).toFixed(3),
          size: +dv.getFloat32(p + 12, true).toFixed(3), offset: [+dv.getFloat32(p + 16, true).toFixed(3), +dv.getFloat32(p + 20, true).toFixed(3)],
          colour: [b[p + 24], b[p + 25], b[p + 26], b[p + 27]], angle: dv.getInt32(p + 28, true), sweep: +dv.getFloat32(p + 32, true).toFixed(3) });
      }
      suns.push({ file: f, version: dv.getInt32(o, true), name, position: [fl(0x20), fl(0x24), fl(0x28)], carShadowPosition: [fl(0x2c), fl(0x30), fl(0x34)], layers });
    }
  }
}

// ---------- 4. Texturas ----------
// DYNTEX.BIN trae los nombres truncados a 23 letras («SKY_MIDDAY_A_ENVIRONMEN»): se resuelven por hash con los nombres de
// SkyRender.cpp [D] y, si no, se guardan con el hash.
const skyNames: string[] = [];
for (const tod of ["MIDDAY", "SUNSET"]) for (const s of ["GRADIENT_A", "CAP_A", "CAP_B", "CLOUDS_A", "CLOUDS_B", "REFLECTION", "ENVIRONMENT_A", "ENVIRONMENT_B",
  "ENVIRONMENT_CAP_A", "ENVIRONMENT_CAP_B", "ENVIRONMENT_CAP_A_GAMECUBE", "ENVIRONMENT_CAP_B_GAMECUBE", "ENVIRONMENT_A_GAMECUBE", "ENVIRONMENT_CAP_A_PS2", "ENVIRONMENT_A_PS2"])
  skyNames.push(`SKY_${tod}_A_${s}`);
const byHash = new Map(skyNames.map(n => [H(n), n]));
const want: [string, RegExp][] = [
  ["GLOBAL\\GLOBALB.BUN", /^(CARSHADOW|SHADOWRAMP|SMALLENVMAP|HEADLIGHTFLAREINNER|HEADLIGHTFLAREOUTER|HEADLIGHTGLOW)$/],
  ["GLOBAL\\INGAMEA.BUN", /^(SUNCENTER|SUNHALO|SKY_REFSKYSPECULARB)$/],
  ["GLOBAL\\DYNTEX.BIN", /^(SKY_|.*_CARSELECTENVMAP$)/],
];
const textures: Record<string, { file: string; width: number; height: number; alphaUsage: number; alphaBlend: number; wrap: number; hash: string }> = {};
for (const [file, re] of want) {
  const b = file === "GLOBAL\\GLOBALB.BUN" ? globalb : await read(file);
  if (!b) { console.warn(`falta ${file}`); continue; }
  let pack: { textures: Texture[] };
  try { pack = readTexturePack(b); } catch (e) { console.warn(`${file}: ${e}`); continue; }
  for (const t of pack.textures) {
    if (!re.test(t.name)) continue;
    const name = byHash.get(t.nameHash) ?? (t.name.length >= 23 ? `${t.name}_${hex8(t.nameHash)}` : t.name);
    if (textures[name]) continue;
    await Bun.write(`${out}/${name}.png`, encodePng(t.rgba, t.width, t.height));
    textures[name] = { file, width: t.width, height: t.height, alphaUsage: t.alphaUsage, alphaBlend: t.alphaBlend, wrap: t.tilableUV, hash: hex8(t.nameHash) };
  }
}

await Bun.write(`${out}/fx.json`, JSON.stringify({
  disc: id,
  source: "GLOBAL\\ATTRIBUTES.BIN (visuallook, visualrgbtweaker, visuallookeffect, light_flares_cg) · GLOBAL\\GLOBALB.BUN 0x00135200 (eLightMaterial) · 0x00034202 (SunChunkInfo) · texturas de GLOBALB/INGAMEA/DYNTEX",
  visualLookKeys, attribs, lightMaterials, suns, textures,
}, null, 1));
console.log(`fx: ${Object.keys(lightMaterials).length} materiales de luz · ${Object.keys(attribs.visuallook ?? {}).length} visuallook · ${suns.length} soles · ${Object.keys(textures).length} texturas`);
