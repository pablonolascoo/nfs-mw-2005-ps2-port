// Conversor disco PS2 → map-data/<disco>/ (GLB + index.json) para el visor.
// Uso: bun src/cli/convert.ts <iso> <ID> car <NOMBRE> [<NOMBRE>…]
//      bun src/cli/convert.ts <iso> <ID> world [SECCIÓN…]   (sin secciones = Rockport entero)
import { GameDisc } from "../lib/zdir";
import { readSolidList, type Solid } from "../lib/solid-ps2";
import { readTexturePack, type Texture } from "../lib/tex-ps2";
import { solidToMesh } from "../lib/mesh-build";
import { MaterialTable } from "../lib/materials";
import { writeGlb } from "../lib/glb";
import { hex8 } from "../lib/hash";
import { parseChunks } from "../lib/bchunk";
import { readSectionTable, readScenery, modelHash } from "../lib/world-ps2";
import { readSolidListsDeep } from "../lib/solid-ps2";
import type { GlbMesh, GlbNode } from "../lib/glb";
import { flatten, type FlatInstance } from "../lib/flatten";
import { mkdirSync, existsSync, readFileSync } from "node:fs";

const [iso, disc, mode, ...names] = Bun.argv.slice(2);
const root = new URL("../../../", import.meta.url).pathname;
const outDir = `${root}map-data/${disc}`;
mkdirSync(`${outDir}/cars`, { recursive: true });
const d = await GameDisc.open(iso);

interface Item { id: string; group: string; label: string; glb: string; tris: number; verts: number; source: string }
const indexPath = `${outDir}/index.json`;
const index: { disc: string; generated: string; upAxis: "Z"; items: Item[] } = existsSync(indexPath) ? JSON.parse(readFileSync(indexPath, "utf8")) : { disc, generated: "", upAxis: "Z", items: [] };

async function texturesFrom(paths: string[]) {
  const map = new Map<number, Texture>();
  for (const p of paths) {
    const e = d.find(p); if (!e || !e.size) continue;
    const pack = readTexturePack(await d.readEntry(e));
    for (const w of pack.warnings) console.warn(`  [${p}] ${w}`);
    for (const t of pack.textures) if (!map.has(t.nameHash)) map.set(t.nameHash, t);
  }
  return map;
}

/** Para cada pieza deja solo el mejor nivel de detalle disponible (sufijo _A < _B < …). Descarta piezas de daño. */
function bestLod(solids: Solid[]) {
  const best = new Map<string, Solid>();
  for (const s of solids) {
    if (/_DAMAGE\d/.test(s.name)) continue;
    const m = /^(.*)_([A-E])$/.exec(s.name); const key = m ? m[1] : s.name;
    const cur = best.get(key);
    if (!cur || (m && cur.name.slice(-1) > m[2])) best.set(key, s);
  }
  return [...best.values()];
}

if (mode === "car") {
  for (const name of names) {
    const geo = d.find(`CARS\\${name}\\GEOMETRY.BIN`);
    if (!geo) { console.error(`No existe CARS\\${name}\\GEOMETRY.BIN`); continue; }
    const solids = bestLod(readSolidList(await d.readEntry(geo)));
    const textures = await texturesFrom([`CARS\\${name}\\TEXTURES.BIN`, "CARS\\TEXTURES.BIN"]);
    const mats = new MaterialTable(textures);
    const meshes = solids.map(s => solidToMesh(s, h => mats.get(h)));
    const glb = writeGlb(meshes, mats.materials, mats.images, name);
    await Bun.write(`${outDir}/cars/${name}.glb`, glb);
    const tris = meshes.reduce((a, m) => a + m.primitives.reduce((b, p) => b + p.indices.length / 3, 0), 0);
    const verts = meshes.reduce((a, m) => a + m.primitives.reduce((b, p) => b + p.positions.length / 3, 0), 0);
    const warn = solids.flatMap(s => s.warnings.map(w => `${s.name}: ${w}`));
    console.log(`${name}: ${solids.length} piezas, ${tris} triángulos, ${textures.size} texturas disponibles, ${mats.images.length} usadas, sin encontrar: ${[...mats.missing].map(hex8).join(" ") || "ninguna"}${warn.length ? `\n  avisos: ${warn.slice(0, 5).join(" | ")}` : ""}`);
    index.items = index.items.filter(i => i.id !== `car:${name}`);
    index.items.push({ id: `car:${name}`, group: "Coches", label: name, glb: `cars/${name}.glb`, tris, verts, source: `CARS\\${name}\\GEOMETRY.BIN` });
  }
}
if (mode === "world") {
  mkdirSync(`${outDir}/world`, { recursive: true }); mkdirSync(`${outDir}/textures`, { recursive: true });
  const sections = readSectionTable(await d.readEntry(d.find("TRACKS\\L2RA.BUN")!));
  const stream = await d.readEntry(d.find("TRACKS\\STREAML2RA.BUN")!);
  const wanted = names.length ? new Set(names.map(n => n.toUpperCase())) : null;
  // 1) Todos los sólidos y texturas del mundo, indexados por hash (un modelo puede vivir en otra sección).
  const solids = new Map<number, Solid>();
  const textures = new Map<number, Texture>();
  const parsed = sections.map(s => { const buf = stream.subarray(s.offset, s.offset + s.size); return { s, buf, ch: parseChunks(buf) }; });
  for (const p of parsed) {
    for (const so of readSolidListsDeep(p.buf, p.ch)) if (!solids.has(so.nameHash)) solids.set(so.nameHash, so);
    if (p.ch.some(c => c.id === 0xb3300000)) for (const t of readTexturePack(p.buf).textures) if (!textures.has(t.nameHash)) textures.set(t.nameHash, t);
  }
  for (const t of (await texturesFrom(["TRACKS\\L2RA.BUN", "GLOBAL\\GLOBALA.BUN"])).values()) if (!textures.has(t.nameHash)) textures.set(t.nameHash, t);
  console.log(`Mundo: ${sections.length} secciones, ${solids.size} sólidos, ${textures.size} texturas`);
  const written = new Set<number>();
  const manifest: { name: string; number: number; centre: [number, number]; radius: number; glb: string; instances: number; tris: number }[] = [];
  let totalTris = 0, totalInst = 0, missingSolids = 0;
  const missingTex = new Set<number>();
  for (const { s, buf, ch } of parsed) {
    if (wanted && !wanted.has(s.name)) continue;
    const scen = readScenery(buf, ch);
    const meshes: GlbMesh[] = [], nodes: GlbNode[] = [];
    const meshIndex = new Map<number, number>();
    const mats = new MaterialTable(textures, { unlit: true, external: { dir: `${outDir}/textures`, uriPrefix: "../textures/", written } });
    let tris = 0;
    for (const sc of scen) for (const [k, inst] of sc.instances.entries()) {
      const info = sc.infos[inst.info]; const h = info && modelHash(info);
      if (!h) continue;
      const so = solids.get(h); if (!so) { missingSolids++; continue; }
      let mi = meshIndex.get(h);
      if (mi === undefined) { meshes.push(solidToMesh(so, t => mats.get(t))); mi = meshes.length - 1; meshIndex.set(h, mi); }
      const r = inst.rotation, p = inst.position;
      nodes.push({ name: `${info.name}#${k}`, mesh: mi, matrix: [r[0], r[1], r[2], 0, r[3], r[4], r[5], 0, r[6], r[7], r[8], 0, p[0], p[1], p[2], 1], extras: { "Sección": s.name, "Modelo": info.name, "Hash modelo": hex8(h), "Instancia": k } });
      tris += meshes[mi].primitives.reduce((a, pr) => a + pr.indices.length / 3, 0);
    }
    for (const m of mats.missing) missingTex.add(m);
    if (!nodes.length) continue;
    // Una malla por material: los objetos se identifican por el atributo _ID → extras.objetos[_ID].
    const flatInst: FlatInstance[] = nodes.map((n, id) => ({ mesh: meshes[n.mesh], matrix: n.matrix!, id }));
    const merged: GlbMesh = { name: s.name, primitives: flatten(flatInst), extras: { "Sección": s.name, objetos: nodes.map(n => n.extras) } };
    await Bun.write(`${outDir}/world/${s.name}.glb`, writeGlb([merged], mats.materials, mats.images, s.name));
    manifest.push({ name: s.name, number: s.number, centre: s.centre, radius: s.radius, glb: `world/${s.name}.glb`, instances: nodes.length, tris });
    totalTris += tris; totalInst += nodes.length;
    index.items = index.items.filter(i => i.id !== `sec:${s.name}`);
    index.items.push({ id: `sec:${s.name}`, group: "Rockport", label: s.name, glb: `world/${s.name}.glb`, tris, verts: 0, source: `TRACKS\\STREAML2RA.BUN @${s.offset}` });
  }
  const prev = existsSync(`${outDir}/world.json`) && wanted ? JSON.parse(readFileSync(`${outDir}/world.json`, "utf8")).sections as typeof manifest : [];
  const merged = [...prev.filter(p => !manifest.some(m => m.name === p.name)), ...manifest].sort((a, b) => a.number - b.number);
  await Bun.write(`${outDir}/world.json`, JSON.stringify({ disc, upAxis: "Z", units: "metros (hipótesis)", sections: merged }, null, 1));
  console.log(`Exportadas ${manifest.length} secciones · ${totalInst} instancias · ${totalTris} triángulos · texturas PNG ${written.size} · instancias sin sólido ${missingSolids} · texturas no encontradas ${missingTex.size}`);
}
index.generated = new Date().toISOString();
index.items.sort((a, b) => a.group.localeCompare(b.group) || a.label.localeCompare(b.label));
await Bun.write(indexPath, JSON.stringify(index, null, 1));
