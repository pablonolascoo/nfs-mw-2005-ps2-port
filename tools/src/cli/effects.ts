// Efectos, luces y datos del mundo → map-data/<ID>/effects.json + effects/ (doc 24).
// Uso: bun src/cli/effects.ts <iso> <ID>
//
//   effects.json            · biblioteca de efectos (emittergroup/emitterdata/effects/simsurface/smackable de ATTRIBUTES.BIN),
//                             emisores colocados en el mundo y en los garajes (0x0003BC00), destellos del escenario (marcadores
//                             de sólidos 0x0013401A), objetos rompibles (0x00034027), regiones Weatherman (0x00034250), mapas de
//                             parámetros (0x8003B600), marcadores y cajas de pista, animaciones del mundo, TrackInfo, texturas
//                             animadas, jerarquías de modelos y resúmenes de los archivos de abajo.
//   effects/triggers.json   · EventTrigger de cada sección (0x80036000): sonidos ambiente, tren, avión…
//   effects/heli-sheet.json · hoja de altura del helicóptero (0x00034159), enteros tal cual (x,y ×0.25 m; z ×0.0625 m)
//   effects/visibility.json · visibilidad y streaming (0x80034150, 0x00034113)
//   effects/troughs.json    · perímetros TRN_*/TROUGH_* (TRACKS\L2RA\TROUGHBOUNDARY.BIN, 0x00034190)
//   effects/particles/*.png · las 46 texturas de partícula (pack «PARTICLE» de GLOBAL\INGAMEB.BUN)
// No toca lo que ya exporta el paso fx (doc 20): sol (0x00034202), visuallook, light_flares_cg, eLightMaterial, cielo.
// Nada de esto se sube a git.
import { mkdirSync, rmSync } from "node:fs";
import { GameDisc } from "../lib/zdir";
import { parseChunks, walk, type Chunk } from "../lib/bchunk";
import { bStringHash, hex8 } from "../lib/hash";
import { outDir, embedded } from "../lib/paths";
import { loadCandidates } from "../lib/names";
import { lzDecompress } from "../lib/lz";
import { encodePng } from "../lib/png";
import { readTexturePack } from "../lib/tex-ps2";
import { AttribDatabase, Vault, parseVpak, attribHash } from "../lib/vlt";
import { loadAttribNames } from "../lib/attrib-names";
import { readSectionTable, readScenery, modelHash, type ScenerySection } from "../lib/world-ps2";
import {
  readEmitterLibraryPack, readSmokeableSpawnerPack, readEventTriggerPack, readHeliSection, readSolidMarkers, readTextureAnimPack, readModelHierarchy, textureNames,
  buildEffectLibrary, simToWorld, simQuatToWorldYaw, skipPad, EVENT_IDS, FLARE_TYPES, PARTICLE_TEXTURES, type EmitterLibraryPack, type SolidMarkers,
} from "../lib/effects";
import { readWeatherRegions, readParameterMaps, readTrackPositionMarkers, readTrackOBBs, readWorldAnim, readTrackInfos, readTrough, readVisibility, readDiscBundles, parameterSetAt } from "../lib/world-extra";

const t0 = performance.now();
const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/effects.ts <iso> <ID>"); process.exit(1); }
const out = outDir(id);
rmSync(`${out}/effects`, { recursive: true, force: true });
mkdirSync(`${out}/effects/particles`, { recursive: true });

const disc = await GameDisc.open(iso);
disc.resolveNames(await loadCandidates(disc, embedded.filenameLists));
const read = async (name: string) => {
  const e = disc.find(name);
  if (!e || !e.size) return undefined;
  let b = await disc.readEntry(e);
  if (b.length >= 4 && b[0] === 0x4a && b[1] === 0x44 && b[2] === 0x4c && b[3] === 0x5a) b = lzDecompress(b); // «JDLZ»
  return b;
};
const r3 = (x: number) => Math.round(x * 1000) / 1000;
const warnings: string[] = [];
const BOUNDS = { x: [-1500, 5500], y: [-1500, 5000], z: [-100, 1000] };
const inRockport = (p: number[]) => p[0] >= BOUNDS.x[0] && p[0] <= BOUNDS.x[1] && p[1] >= BOUNDS.y[0] && p[1] <= BOUNDS.y[1] && p[2] >= BOUNDS.z[0] && p[2] <= BOUNDS.z[1];

// ── 1. Biblioteca de efectos (ATTRIBUTES.BIN) y texturas de partícula (INGAMEB.BUN) ─────────────────────────────────────
const db = new AttribDatabase();
await loadAttribNames(db);
for (const v of parseVpak((await read("GLOBAL\\ATTRIBUTES.BIN"))!)) db.addVault(new Vault(v.name, v.vlt, v.bin));
const texNames = new Map(PARTICLE_TEXTURES.map(n => [bStringHash(n), n]));
const lib = buildEffectLibrary(db, texNames);
const particleTextures: Record<string, { file: string; width: number; height: number; hash: string; alphaBlend: number }> = {};
{
  const pack = readTexturePack((await read("GLOBAL\\INGAMEB.BUN"))!);
  for (const t of pack.textures) {
    const name = texNames.get(t.nameHash) ?? t.name;
    if (!name.startsWith("FX_")) continue;
    await Bun.write(`${out}/effects/particles/${name}.png`, encodePng(t.rgba, t.width, t.height));
    particleTextures[name] = { file: `effects/particles/${name}.png`, width: t.width, height: t.height, hash: hex8(t.nameHash), alphaBlend: t.alphaBlend };
  }
  const missing = PARTICLE_TEXTURES.filter(n => !particleTextures[n]);
  if (missing.length) warnings.push(`texturas de partícula sin encontrar: ${missing.join(", ")}`);
}
const usedTextures = new Set(Object.values(lib.emitterData).map(v => (v as any)?.Texture?.texture).filter(Boolean));

// ── 2. L2RA.BUN: datos globales del mundo ────────────────────────────────────────────────────────────────────────────
const l2ra = (await read("TRACKS\\L2RA.BUN"))!;
const l2dv = new DataView(l2ra.buffer, l2ra.byteOffset, l2ra.byteLength);
const l2top = parseChunks(l2ra);
const l2all = [...walk(l2top)].map(([c]) => c);
const one = (id: number) => l2all.find(c => c.id === id);
const weather = one(0x00034250) ? readWeatherRegions(l2ra, one(0x00034250)!) : undefined;
// Nombres por bStringHash, sacados de ParameterAccessor(...) de la decomp y de cadenas del ELF [V: hash = NameHash del disco].
const pmNames = new Map(["Ambience", "Clouds", "Rain", "Reverb", "Speech", "Screen Tint SunRise", "Screen Tint Midday", "Wind", "Normal Fog", "Rain Fog", "Fog Blend Distance"].map(n => [bStringHash(n), n]));
const markerNames = new Map(["GasStationMoment", "FirehallMoment", "WaterTowerMoment", "PorchCollapseMoment", "SignageCollapseMoment", "ScaffoldingCollapseMoment",
  "GazeboCollapseMoment", "FishMarketMoment", "BoatKnockdownMoment", "BustedMomentMarker", "TollboothMarker", "GarageMarker", "PoliceStationGroundMoment",
  "DriveInMoment", "TrailerParkMoment", "TorusRoofMoment", "AmphitheatreMoment", "StripMallMoment", "IconMarker"].map(n => [bStringHash(n), n]));
const triggerParamNames = new Map(["Comment", "OVERPASS"].map(n => [bStringHash(n), n]));
const parameterMaps = one(0x8003b600) ? readParameterMaps(l2ra, one(0x8003b600)!, pmNames) : [];
const positionMarkers = one(0x00034146) ? readTrackPositionMarkers(l2ra, one(0x00034146)!) : [];
const trackOBBs = one(0x00034191) ? readTrackOBBs(l2ra, one(0x00034191)!) : [];
const worldAnim = readWorldAnim(l2ra, l2all.filter(c => [0x00037080, 0x00037090, 0x00037110, 0x00037150].includes(c.id)));
// Los overlays 0x34158 están fuera del 0x80034150, al nivel superior de L2RA.BUN [V].
const visibility = one(0x80034150) ? readVisibility(l2ra, { ...one(0x80034150)!, children: [...one(0x80034150)!.children!, ...l2all.filter(c => c.id === 0x00034158)] }) : undefined;
const discBundles = one(0x00034113) ? readDiscBundles(l2ra, one(0x00034113)!) : [];
const streamingInfo = one(0x00034111) ? [l2dv.getInt32(one(0x00034111)!.dataOffset, true), l2dv.getInt32(one(0x00034111)!.dataOffset + 4, true)] : [];
const hierarchies = l2all.filter(c => c.id === 0x0003410c).map(c => readModelHierarchy(l2ra, c));
// SceneryOverrideInfo (6 B: s16 sección, s16 instancia, u16 ExcludeFlags) [V: world-ps2.ts] → para comprobar los rompibles.
const overrides: number[][] = [];
{ const c = one(0x00034108)!; for (let o = skipPad(l2dv, c.dataOffset, c.dataOffset + c.size); o + 6 <= c.dataOffset + c.size; o += 6) overrides.push([l2dv.getInt16(o, true), l2dv.getInt16(o + 2, true), l2dv.getUint16(o + 4, true)]); }
const sections = readSectionTable(l2ra);
const sectionName = new Map(sections.map(s => [s.number, s.name]));

// ── 3. STREAML2RA.BUN, sección a sección ─────────────────────────────────────────────────────────────────────────────
const stream = (await read("TRACKS\\STREAML2RA.BUN"))!;
const emitterPacks = new Map<number, EmitterLibraryPack>();
const smokePacks = new Map<number, ReturnType<typeof readSmokeableSpawnerPack>>();
const triggerPacks = new Map<number, ReturnType<typeof readEventTriggerPack>>();
const heli = new Map<number, Int16Array>();
const scenery = new Map<number, ScenerySection>();
const solidMarkers = new Map<number, SolidMarkers>();
const solidName = new Map<number, string>(); // bStringHash del nombre del sólido → nombre [V]
const textureAnims = new Map<string, unknown>();
const texNameByHash = new Map<number, string>();
for (const s of sections) {
  const b = stream.subarray(s.offset, s.offset + s.size);
  let ch: Chunk[];
  try { ch = parseChunks(b); } catch (e) { warnings.push(`${s.name}: ${(e as Error).message}`); continue; }
  for (const sc of readScenery(b, ch)) if (!scenery.has(sc.sectionNumber)) scenery.set(sc.sectionNumber, sc);
  for (const [c] of walk(ch)) {
    try {
      switch (c.id) {
        case 0x0003bc00: { const p = readEmitterLibraryPack(b, c); if (!emitterPacks.has(p.section)) emitterPacks.set(p.section, p); break; }
        case 0x00034027: { const p = readSmokeableSpawnerPack(b, c); if (!smokePacks.has(p.section)) smokePacks.set(p.section, p); break; }
        case 0x80036000: { const p = readEventTriggerPack(b, c); if (!triggerPacks.has(p.section)) triggerPacks.set(p.section, p); break; }
        case 0x00034159: { const h = readHeliSection(b, c); if (!heli.has(h.section)) heli.set(h.section, h.polys); break; }
        case 0x80134010: {
          const m = readSolidMarkers(b, c); if (m && !solidMarkers.has(m.nameHash)) solidMarkers.set(m.nameHash, m);
          const hd = c.children?.find(k => k.id === 0x00134011);
          if (hd) { const sdv = new DataView(b.buffer, b.byteOffset, b.byteLength), h = skipPad(sdv, hd.dataOffset, hd.dataOffset + hd.size); let n = ""; for (let i = 0; i < 64 && b[h + 0xa0 + i]; i++) n += String.fromCharCode(b[h + 0xa0 + i]); solidName.set(sdv.getUint32(h + 0x10, true), n); }
          break;
        }
        case 0xb0300100: for (const a of readTextureAnimPack(b, c)) textureAnims.set(a.name, { ...a, source: `STREAML2RA ${s.name}` }); textureNames(b, ch, texNameByHash); break;
      }
    } catch (e) { warnings.push(`${s.name} ${hex8(c.id)}: ${(e as Error).message}`); }
  }
}

// Texturas animadas también en GLOBALB/INGAMEA y garajes; nombres de fotogramas desde los TPK donde viven.
const extraFiles = ["GLOBAL\\GLOBALB.BUN", "GLOBAL\\INGAMEA.BUN"];
const platforms = disc.entries.filter(e => e.name?.startsWith("FRONTEND\\PLATFORMS\\")).map(e => e.name!);
const frontendEmitters: Record<string, unknown[]> = {};
const globalb = (await read("GLOBAL\\GLOBALB.BUN"))!;
for (const f of [...extraFiles, ...platforms]) {
  const b = f === "GLOBAL\\GLOBALB.BUN" ? globalb : await read(f);
  if (!b) continue;
  let ch: Chunk[]; try { ch = parseChunks(b); } catch (e) { warnings.push(`${f}: ${(e as Error).message}`); continue; }
  for (const [c] of walk(ch)) {
    if (c.id === 0xb0300100) for (const a of readTextureAnimPack(b, c)) textureAnims.set(a.name, { ...a, source: f });
    if (c.id === 0x0003bc00) { const p = readEmitterLibraryPack(b, c); (frontendEmitters[f.split("\\").pop()!.replace(".BIN", "")] ??= []).push(...p.libraries.map(l => ({ group: lib.collectionName(l.groupKey), pos: [l.matrix[12], l.matrix[13], l.matrix[14]], matrix: l.matrix, triggers: l.triggers }))); }
  }
  textureNames(b, ch, texNameByHash);
}
// Nombres de los fotogramas: TextureInfo de los TPK del mismo archivo o sección [V].
for (const a of textureAnims.values() as Iterable<any>) a.frameNames = a.frames.map((h: number) => texNameByHash.get(h) ?? hex8(h));

// ── 4. Emisores del mundo ────────────────────────────────────────────────────────────────────────────────────────────
const worldEmitters: unknown[] = [];
let emOut = 0, emUnnamed = 0;
for (const p of [...emitterPacks.values()].sort((a, b) => a.section - b.section)) for (const l of p.libraries) {
  const pos = [l.matrix[12], l.matrix[13], l.matrix[14]];
  if (!inRockport(pos)) emOut++;
  const group = lib.collectionName(l.groupKey);
  if (!group || group.startsWith("0x")) emUnnamed++;
  worldEmitters.push({ group, section: p.section, sectionName: sectionName.get(p.section) ?? null, pos, matrix: l.matrix, mode: l.triggers.length ? "trigger" : "always", triggers: l.triggers });
}

// ── 5. Destellos del escenario: marcador del sólido → mundo (Scenery.cpp: (marcador − pivote) × matriz de la instancia) ─────
const flares: unknown[] = [];
let flaresOutBox = 0;
for (const [secNum, sc] of [...scenery].sort((a, b) => a[0] - b[0])) for (const [k, inst] of sc.instances.entries()) {
  const info = sc.infos[inst.info]; const h = info && modelHash(info);
  const sm = h ? solidMarkers.get(h) : undefined;
  if (!sm || !sm.markers.length) continue;
  const r = inst.rotation, P = inst.position;
  for (const m of sm.markers) {
    const l = [m.pos[0] - sm.pivot[0], m.pos[1] - sm.pivot[1], m.pos[2] - sm.pivot[2]];
    const w = [0, 1, 2].map(j => r3(l[0] * r[j] + l[1] * r[3 + j] + l[2] * r[6 + j] + P[j]));
    const tol = 1;
    const outside = w.some((x, j) => x < inst.bbMin[j] - tol || x > inst.bbMax[j] + tol);
    if (outside) flaresOutBox++;
    const type = m.iParam0 + 14;
    flares.push({ type, typeName: FLARE_TYPES[type] ?? null, pos: w, section: secNum, model: sm.name, instance: k, hidden: !!(inst.excludeFlags & 0x10), fParam: [r3(m.fParam0), r3(m.fParam1)], ...(outside ? { outsideBox: true, excludeFlags: inst.excludeFlags } : {}) });
  }
}

// ── 6. Objetos rompibles (smokeables) ─────────────────────────────────────────────────────────────────────────────
const modelNames = new Map<number, string>();
for (const n of solidName.values()) { modelNames.set(attribHash(n), n); modelNames.set(attribHash(n.toUpperCase()), n); }
for (const sc of scenery.values()) for (const i of sc.infos) modelNames.set(attribHash(i.name), i.name);
// Rompibles de varias piezas: su UCrc32 de modelo es el nombre de una ModelHierarchy; se nombra por el sólido del nodo raíz [V].
for (const h of hierarchies) if (!modelNames.has(h.nameHash) && h.nodes[0]) modelNames.set(h.nameHash, `hierarchy:${solidName.get(h.nodes[0].model) ?? hex8(h.nodes[0].model)}`);
const smokeables: unknown[] = [];
let smkMatched = 0, smkChecked = 0, smkOut = 0;
for (const p of [...smokePacks.values()].sort((a, b) => a.section - b.section)) for (const s of p.spawners) {
  const pos = simToWorld(s.simPos).map(r3);
  if (!inRockport(pos)) smkOut++;
  const ov = overrides[s.overrideInfo];
  const inst = ov ? scenery.get(ov[0])?.instances[ov[1]] : undefined;
  const instName = inst && ov ? scenery.get(ov[0])!.infos[inst.info]?.name : undefined;
  if (instName && !modelNames.has(s.model)) for (const v of [instName, instName + "0", instName + "00", instName + "_00", ...["A", "B", "C", "Z"].map(x => instName + x)]) if (attribHash(v) === s.model) modelNames.set(s.model, v);
  if (inst) { smkChecked++; if (Math.hypot(inst.position[0] - pos[0], inst.position[1] - pos[1], inst.position[2] - pos[2]) < 0.05) smkMatched++; }
  smokeables.push({ id: s.uniqueId, section: p.section, type: lib.collectionName(s.attributes), model: modelNames.get(s.model) ?? hex8(s.model), collision: modelNames.get(s.collision) ?? hex8(s.collision),
    sceneryModel: instName ?? null, pos, yaw: simQuatToWorldYaw(s.quat), simQuat: s.quat, excludeFlags: hex8(s.excludeFlags), sceneryOverride: ov ? { section: ov[0], instance: ov[1] } : null });
}

// ── 7. Disparadores, helicóptero, troughs ──────────────────────────────────────────────────────────────────────────
const triggers: unknown[] = []; const byType: Record<string, number> = {}, byParameter: Record<string, number> = {}; let trigOut = 0;
for (const p of [...triggerPacks.values()].sort((a, b) => a.section - b.section)) for (const t of p.triggers) {
  const type = EVENT_IDS[t.eventId] ?? hex8(t.eventId);
  byType[type] = (byType[type] ?? 0) + 1;
  const par = triggerParamNames.get(t.parameter) ?? hex8(t.parameter); byParameter[par] = (byParameter[par] ?? 0) + 1;
  if (!inRockport(t.pos)) trigOut++;
  triggers.push({ section: p.section, type, nameHash: hex8(t.nameHash), parameter: triggerParamNames.get(t.parameter) ?? hex8(t.parameter), directionMask: t.directionMask, pos: t.pos, radius: t.radius });
}
let heliPolys = 0; const hb = [Infinity, Infinity, Infinity, -Infinity, -Infinity, -Infinity];
const heliOut: Record<number, number[]> = {};
for (const [sec, p] of [...heli].sort((a, b) => a[0] - b[0])) {
  heliPolys += p.length / 9; heliOut[sec] = Array.from(p);
  for (let i = 0; i < p.length; i += 9) for (let v = 0; v < 3; v++) {
    const q = [p[i + v] * 0.25, p[i + 3 + v] * 0.25, p[i + 6 + v] * 0.0625];
    for (let j = 0; j < 3; j++) { hb[j] = Math.min(hb[j], q[j]); hb[3 + j] = Math.max(hb[3 + j], q[j]); }
  }
}
const troughBuf = await read("TRACKS\\L2RA\\TROUGHBOUNDARY.BIN");
const troughs = troughBuf ? parseChunks(troughBuf).filter(c => c.id === 0x00034190).map(c => readTrough(troughBuf, c)) : [];

// ── 8. GLOBALB: TrackInfo ─────────────────────────────────────────────────────────────────────────────────────────
const tiChunk = [...walk(parseChunks(globalb))].map(([c]) => c).find(c => c.id === 0x00034201);
const trackInfos = tiChunk ? readTrackInfos(globalb, tiChunk) : [];
const sunNames = new Map(["MIDDAY", "SUNSET"].map(n => [bStringHash(n), n]));
for (const t of trackInfos as any[]) t.sunInfo = sunNames.get(t.sunInfoHash) ?? (t.sunInfoHash ? hex8(t.sunInfoHash) : null);

// Comprobación de los mapas de parámetros: la capa debe dar un conjunto válido en el centro de Rockport.
for (const l of parameterMaps) { const k = parameterSetAt(l, 1500, 1500); if (k < 0 || k >= Math.max(1, l.sets.length)) warnings.push(`parameter map ${l.name ?? hex8(l.nameHash)}: índice ${k} fuera de rango`); }

// ── 9. Escritura ───────────────────────────────────────────────────────────────────────────────────────────────────
await Bun.write(`${out}/effects/triggers.json`, JSON.stringify({ disc: id, source: "TRACKS\\STREAML2RA.BUN 0x80036000 (EventTriggerPack v2)", note: "type = EVENT_ID [D]; nameHash/parameter sin resolver", triggers }));
await Bun.write(`${out}/effects/heli-sheet.json`, JSON.stringify({ disc: id, source: "TRACKS\\STREAML2RA.BUN 0x00034159", format: "por sección: s16 [x0,x1,x2, y0,y1,y2, z0,z1,z2] por triángulo; x,y × 0.25 m, z × 0.0625 m; altura = plano del triángulo en (x,y) [D: HeliSheet.cpp]", sections: heliOut }));
await Bun.write(`${out}/effects/visibility.json`, JSON.stringify({ disc: id, source: "TRACKS\\L2RA.BUN 0x80034150, 0x00034113, 0x00034111", ...visibility, discBundles, streamingInfo }));
await Bun.write(`${out}/effects/troughs.json`, JSON.stringify({ disc: id, source: "TRACKS\\L2RA\\TROUGHBOUNDARY.BIN 0x00034190", troughs }));

const counts = {
  emitterGroups: Object.keys(lib.emitterGroups).length, emitterData: Object.keys(lib.emitterData).length, effects: Object.keys(lib.effects).length,
  particleTextures: Object.keys(particleTextures).length, particleTexturesUsed: usedTextures.size,
  worldEmitters: worldEmitters.length, emitterSections: emitterPacks.size, frontendEmitters: Object.values(frontendEmitters).reduce((a, l) => a + l.length, 0),
  flares: flares.length, flareModels: [...solidMarkers.values()].filter(s => s.markers.length).length,
  smokeables: smokeables.length, smokeableSections: smokePacks.size, triggers: triggers.length, triggerSections: triggerPacks.size,
  heliSections: heli.size, heliPolys, weatherRegions: weather?.regions.length ?? 0, parameterMaps: parameterMaps.length, positionMarkers: positionMarkers.length,
  trackOBBs: trackOBBs.length, worldAnimTrees: worldAnim.trees.length, worldAnimInstances: worldAnim.instances.length, trackInfos: trackInfos.length,
  textureAnims: textureAnims.size, modelHierarchies: hierarchies.length, troughs: troughs.length,
  visibilityBoundaries: visibility?.boundaries.length ?? 0, drivableSections: visibility?.drivable.length ?? 0, loadingSections: visibility?.loading.length ?? 0, discBundles: discBundles.length,
};
const checks = {
  worldEmittersOutsideRockport: emOut, worldEmitterGroupsUnnamed: emUnnamed, flaresOutsideInstanceBox: flaresOutBox,
  smokeablesOutsideRockport: smkOut, smokeablesWithSceneryInstance: smkChecked, smokeablesMatchingInstance: smkMatched, triggersOutsideRockport: trigOut,
  heliBox: hb.map(r3),
};
await Bun.write(`${out}/effects.json`, JSON.stringify({
  disc: id, version: 1,
  source: "GLOBAL\\ATTRIBUTES.BIN (emittergroup, emitterdata, effects, simsurface, smackable, fuelcell_*) · GLOBAL\\INGAMEB.BUN (TPK PARTICLE) · TRACKS\\STREAML2RA.BUN (0x0003BC00, 0x00034027, 0x80036000, 0x00034159, 0x0013401A, 0xB0300100) · TRACKS\\L2RA.BUN (0x00034250, 0x8003B600, 0x00034146, 0x00034191, 0x3708x/0x3709x/0x3711x/0x3715x, 0x0003410C, 0x80034150, 0x00034113) · GLOBAL\\GLOBALB.BUN (0x00034201) · FRONTEND\\PLATFORMS\\*.BIN (0x0003BC00)",
  seeAlso: { sun: "fx/fx.json · suns (0x00034202, paso fx, doc 20)", lightMaterials: "fx/fx.json", carFlares: "fx/fx.json · attribs.light_flares_cg", sky: "fx/*.png" },
  counts, checks, warnings,
  particles: { textures: particleTextures, note: "emitterdata.Texture.texture = nombre; .index = fila en la página de texturas [D: EmitterSystem.cpp]" },
  library: { emitterGroups: lib.emitterGroups, emitterData: lib.emitterData, effects: lib.effects, tireEffectsBySurface: lib.tireEffects, smackableTypes: lib.smackables, fuelcell: lib.fuelcell },
  worldEmitters, frontendEmitters, flares, smokeables,
  weather, parameterMaps, positionMarkers: positionMarkers.map(m => ({ ...m, name: markerNames.get(m.nameHash) ?? null, nameHash: hex8(m.nameHash) })), trackOBBs: trackOBBs.map(o => ({ ...o, typeHash: hex8(o.typeHash) })),
  worldAnim, trackInfos, textureAnims: [...textureAnims.values()], modelHierarchies: hierarchies.map(h => ({ key: hex8(h.nameHash), name: modelNames.get(h.nameHash) ?? null, flags: h.flags, nodes: h.nodes.map(n => ({ ...n, name: hex8(n.name), model: solidName.get(n.model) ?? hex8(n.model) })) })),
  triggers: { file: "effects/triggers.json", total: triggers.length, byType, byParameter },
  heliSheet: { file: "effects/heli-sheet.json", sections: heli.size, polys: heliPolys, box: hb.map(r3) },
  visibility: { file: "effects/visibility.json", lodOffset: visibility?.lodOffset, boundaries: counts.visibilityBoundaries, drivable: counts.drivableSections, loading: counts.loadingSections, overlays: visibility?.overlays.length ?? 0, discBundles: discBundles.length },
  troughs: { file: "effects/troughs.json", count: troughs.length },
}));
const ms = Math.round(performance.now() - t0);
console.log(`effects: ${counts.worldEmitters} emisores (${counts.emitterGroups} grupos, ${counts.particleTextures} texturas) · ${counts.flares} destellos · ${counts.smokeables} rompibles · ${counts.triggers} disparadores · ${counts.heliPolys} triángulos de helicóptero · ${counts.weatherRegions} regiones · ${counts.parameterMaps} mapas · ${warnings.length} avisos · ${ms} ms`);
