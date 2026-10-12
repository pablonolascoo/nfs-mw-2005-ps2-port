// Conversor disco PS2 → map-data/<disco>/ (GLB + index.json) para el visor.
// Uso: bun src/cli/convert.ts <iso> <ID> car <NOMBRE> [<NOMBRE>…]
//      bun src/cli/convert.ts <iso> <ID> tiles [tamaño=400]   (casillas con dos niveles de detalle para ver la ciudad a 60 fps)
//      bun src/cli/convert.ts <iso> <ID> world [SECCIÓN…]   (sin secciones = Rockport entero)
import { GameDisc } from "../lib/zdir";
import { readSolidList, type Solid } from "../lib/solid-ps2";
import { readTexturePack, type Texture } from "../lib/tex-ps2";
import { solidToMesh, ps2ColorToLinear } from "../lib/mesh-build";
import { MaterialTable, alphaFor } from "../lib/materials";
import { writeGlb } from "../lib/glb";
import { hex8, bStringHash } from "../lib/hash";
import { parseChunks } from "../lib/bchunk";
import { readSectionTable, readScenery, modelHash, readSceneryGroups } from "../lib/world-ps2";
import { groupNameTable, groupKind } from "../lib/group-names";
import { readSolidListsDeep, stripTriangles } from "../lib/solid-ps2";
import type { GlbMesh, GlbNode } from "../lib/glb";
import { flatten, type FlatInstance } from "../lib/flatten";
import { clusterSimplify } from "../lib/simplify";
import { carPlaceholders } from "../lib/car-textures";
import { carPartInfo, MARKER_NAMES } from "../lib/car-parts";
import { mkdirSync, existsSync, readFileSync } from "node:fs";

const [iso, disc, mode, ...names] = Bun.argv.slice(2);
const root = new URL("../../../", import.meta.url).pathname;
const outDir = process.env.ROCKPORT_OUT ?? `${root}map-data/${disc}`; // ROCKPORT_OUT: destino del instalador (src/lib/paths.ts)
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

/** Para cada pieza deja solo el mejor nivel de detalle disponible (sufijo _A < _B < …). Descarta los paneles rotos (DAMAGE1+). */
function bestLod(solids: Solid[]) {
  const best = new Map<string, Solid>();
  for (const s of solids) {
    if (/_DAMAGE[1-9]/.test(s.name)) continue; // DAMAGE0 = panel intacto (policía/tráfico) o capa de golpes: se queda
    const m = /^(.*)_([A-E])$/.exec(s.name); const key = m ? m[1] : s.name;
    const cur = best.get(key);
    if (!cur || (m && cur.name.slice(-1) > m[2])) best.set(key, s);
  }
  return [...best.values()];
}

if (mode === "car") {
  // Texturas comunes de los coches: CARS\TEXTURES.BIN y, sobre todo, GLOBAL\GLOBALB.BUN (TREAD, TIRE_BACK, ROTOR1-4,
  // CARBONFIBRE, WINDOW_MASK, DOORLINE, CARBOTTOM, GRILL_0n, RADIATOR, DRIVER_CUTOUT…) y GLOBAL\INGAMEA.BUN (DRIVER_COP) [V].
  const shared = await texturesFrom(["CARS\\TEXTURES.BIN", "GLOBAL\\GLOBALB.BUN", "GLOBAL\\INGAMEA.BUN"]);
  for (const name of names) {
    const geo = d.find(`CARS\\${name}\\GEOMETRY.BIN`);
    if (!geo) { console.error(`No existe CARS\\${name}\\GEOMETRY.BIN`); continue; }
    // Todas las piezas (kits, capós, llantas…) con su mejor LOD; sin daños. Cada nodo lleva en extras.pieza qué es y si
    // va de serie (carPartInfo): el visor y el motor eligen kit, capó, alerón y llantas sin duplicar piezas.
    const solids = bestLod(readSolidList(await d.readEntry(geo)));
    const textures = await texturesFrom([`CARS\\${name}\\TEXTURES.BIN`]);
    for (const [h, t] of shared) if (!textures.has(h)) textures.set(h, t);
    // Tráfico: <COCHE>_TIRE se sustituye por TRAFFIC_TIRE (REPLACETEX_TIRE) [D: CarRender.cpp 1206-1210].
    const trafficTire = shared.get(bStringHash("TRAFFIC_TIRE"));
    if (trafficTire && !textures.has(bStringHash(`${name}_TIRE`))) textures.set(bStringHash(`${name}_TIRE`), trafficTire);
    const mats = new MaterialTable(textures, { placeholders: carPlaceholders(name), missingColor: [0.16, 0.16, 0.17, 1] });
    const meshes = solids.map(s => {
      const m = solidToMesh(s, h => mats.get(h));
      const markers = s.markers.map(k => ({ nombre: MARKER_NAMES.get(k.nameHash) ?? hex8(k.nameHash), matriz: k.matrix.map(v => +v.toFixed(5)) }));
      m.extras = { ...m.extras, pieza: carPartInfo(name, s.name), ...(markers.length ? { marcadores: markers } : {}) };
      return m;
    });
    const glb = writeGlb(meshes, mats.materials, mats.images, name);
    await Bun.write(`${outDir}/cars/${name}.glb`, glb);
    const stock = meshes.filter(m => (m.extras!.pieza as { stock: boolean }).stock);
    const tris = stock.reduce((a, m) => a + m.primitives.reduce((b, p) => b + p.indices.length / 3, 0), 0);
    const verts = stock.reduce((a, m) => a + m.primitives.reduce((b, p) => b + p.positions.length / 3, 0), 0);
    const warn = solids.flatMap(s => s.warnings.map(w => `${s.name}: ${w}`));
    const kits = [...new Set(solids.map(s => carPartInfo(name, s.name).kit).filter(k => k !== undefined))];
    console.log(`${name}: ${solids.length} piezas (${stock.length} de serie, kits ${kits.join(",") || "—"}), ${tris} triángulos de serie, ${mats.images.length} texturas usadas, sin encontrar: ${[...mats.missing].map(hex8).join(" ") || "ninguna"}${warn.length ? `\n  avisos: ${warn.slice(0, 5).join(" | ")}` : ""}`);
    index.items = index.items.filter(i => i.id !== `car:${name}`);
    const group = /^COP/.test(name) ? "Policía" : /^(TRAF|TAXI|PIZZA|GARB|CEMTR|MINIVAN|PICKUPA|SEMI)/.test(name) ? "Tráfico" : /^TRAILER/.test(name) ? "Remolques" : /^(WHEELS|SPOILER|ROOF|BRAKES)/.test(name) ? "Piezas de tuneo" : "Coches";
    index.items.push({ id: `car:${name}`, group, label: name, glb: `cars/${name}.glb`, tris, verts, source: `CARS\\${name}\\GEOMETRY.BIN` });
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
  // GLOBALB/INGAMEA traen HEADLIGHTGLOW y GRAY_MID_A, que usan farolas y señales del mundo [V].
  for (const t of (await texturesFrom(["TRACKS\\L2RA.BUN", "GLOBAL\\GLOBALA.BUN", "GLOBAL\\GLOBALB.BUN", "GLOBAL\\INGAMEA.BUN"])).values()) if (!textures.has(t.nameHash)) textures.set(t.nameHash, t);
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
      if (!h || (inst.excludeFlags & 0x02)) continue; // 0x02 = fuera de la vista del jugador (ver modo tiles)
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
if (mode === "interior") {
  // Interiores del frontend (garajes, concesionario, taller): FRONTEND\PLATFORMS\<NOMBRE>.BIN
  mkdirSync(`${outDir}/interiors`, { recursive: true });
  for (const name of names) {
    const path = `FRONTEND\\PLATFORMS\\${name}.BIN`, e = d.find(path);
    if (!e) { console.error(`No existe ${path}`); continue; }
    const buf = await d.readEntry(e);
    // Solo la estructura visible: fuera emisores de partículas, ayudantes de luz, mapas de sombra, la copia para reflejos y la variante "next-gen".
    const all = readSolidList(buf);
    const solids = all.filter(s => /^BACKDROP_(CRIB|CURRGEN)$|^OBJECT\d+$/.test(s.name));
    console.log(`  ${name}: se omiten ${all.filter(s => !solids.includes(s)).map(s => s.name).join(", ")}`);
    const pack = readTexturePack(buf);
    const textures = await texturesFrom(["GLOBAL\\GLOBALA.BUN"]);
    for (const t of pack.textures) textures.set(t.nameHash, t);
    const mats = new MaterialTable(textures, { unlit: false });
    const meshes = solids.map(s => solidToMesh(s, h => mats.get(h)));
    await Bun.write(`${outDir}/interiors/${name}.glb`, writeGlb(meshes, mats.materials, mats.images, name));
    const tris = meshes.reduce((a, m) => a + m.primitives.reduce((b, p) => b + p.indices.length / 3, 0), 0);
    const bb = solids.reduce((a, s) => ({ min: a.min.map((v, i) => Math.min(v, s.aabbMin[i])), max: a.max.map((v, i) => Math.max(v, s.aabbMax[i])) }), { min: [Infinity, Infinity, Infinity], max: [-Infinity, -Infinity, -Infinity] });
    console.log(`${name}: ${solids.length} piezas (${solids.map(s => s.name).join(", ")}) · ${tris} tris · ${pack.textures.length} texturas propias · faltan ${mats.missing.size} · caja ${bb.min.map(v => v.toFixed(1))} → ${bb.max.map(v => v.toFixed(1))}`);
    index.items = index.items.filter(i => i.id !== `int:${name}`);
    index.items.push({ id: `int:${name}`, group: "Interiores", label: name, glb: `interiors/${name}.glb`, tris, verts: 0, source: path });
  }
}
if (mode === "tiles") {
  const TILE = +(names[0] ?? 400), FAR_MIN = 6, FAR_CELL = +(names[1] ?? 3); // objetos < 6 m fuera del nivel lejano; celdas de simplificación
  mkdirSync(`${outDir}/tiles`, { recursive: true }); mkdirSync(`${outDir}/textures`, { recursive: true });
  const sections = readSectionTable(await d.readEntry(d.find("TRACKS\\L2RA.BUN")!));
  const stream = await d.readEntry(d.find("TRACKS\\STREAML2RA.BUN")!);
  const solids = new Map<number, Solid>(), textures = new Map<number, Texture>();
  const parsed = sections.map(s => { const buf = stream.subarray(s.offset, s.offset + s.size); return { s, buf, ch: parseChunks(buf) }; });
  for (const p of parsed) {
    for (const so of readSolidListsDeep(p.buf, p.ch)) if (!solids.has(so.nameHash)) solids.set(so.nameHash, so);
    if (p.ch.some(c => c.id === 0xb3300000)) for (const t of readTexturePack(p.buf).textures) if (!textures.has(t.nameHash)) textures.set(t.nameHash, t);
  }
  // GLOBALB/INGAMEA traen HEADLIGHTGLOW y GRAY_MID_A, que usan farolas y señales del mundo [V].
  for (const t of (await texturesFrom(["TRACKS\\L2RA.BUN", "GLOBAL\\GLOBALA.BUN", "GLOBAL\\GLOBALB.BUN", "GLOBAL\\INGAMEA.BUN"])).values()) if (!textures.has(t.nameHash)) textures.set(t.nameHash, t);
  // Color medio de cada textura (para el nivel lejano, que no lleva texturas). En las opacas el alfa no cuenta
  // (el asfalto MODULATED+SRCCOPY tiene alfa ≈ 0 y antes salía gris por defecto).
  const avg = new Map<number, [number, number, number]>();
  for (const t of textures.values()) { const opaque = alphaFor(t).alphaMode === "OPAQUE"; let r = 0, g = 0, b = 0, n = 0; for (let i = 0; i < t.rgba.length; i += 16) if (opaque || t.rgba[i + 3] > 64) { r += t.rgba[i]; g += t.rgba[i + 1]; b += t.rgba[i + 2]; n++; } if (n) avg.set(t.nameHash, [r / n / 255, g / n / 255, b / n / 255]); }
  type Inst = { so: Solid; low: Solid; matrix: number[]; meta: Record<string, unknown>; size: number };
  const tiles = new Map<string, Inst[]>();
  // Grupos de escenario (bloqueos de carril, candados, puertas): sus objetos van a capas aparte.
  const l2ra = await d.readEntry(d.find("TRACKS\\L2RA.BUN")!);
  const groups = readSceneryGroups(l2ra);
  const elfEntry = d.files.find(f => /^S[LC][A-Z]{2}_\d{3}\.\d{2}$/.test(f.path));
  const gnames = groupNameTable(elfEntry ? await d.iso.read(elfEntry.lba * 2048, elfEntry.size) : undefined, `${outDir}/gameplay.json`);
  const memberOf = new Map<string, number>(); // "sección:instancia" → índice de grupo
  groups.forEach((g, gi) => { if (g.number !== 1) for (const m of g.members) memberOf.set(`${m.section}:${m.instance}`, gi); });
  const groupInst = new Map<number, Inst[]>();
  let hiddenSkipped = 0, mainViewExcluded = 0;
  for (const { s, buf, ch } of parsed) for (const sc of readScenery(buf, ch)) for (const [k, inst] of sc.instances.entries()) {
    const info = sc.infos[inst.info], h = info && modelHash(info), so = h ? solids.get(h) : undefined;
    if (!so || !h) continue;
    // El cielo (SKYDOME/SKY_SPECULAR) usa texturas que el juego genera al vuelo y no están en el disco: lo dibuja el visor.
    if (/^SKY(DOME|_SPECULAR)/i.test(so.name)) continue;
    const gi = memberOf.get(`${sc.sectionNumber}:${k}`);
    const hidden = (inst.excludeFlags & 0x10) !== 0; // oculto por defecto: solo aparece si el juego activa su grupo
    // 0x02: excluido de las vistas del jugador (EVIEW_PLAYER1/2) [D: SetupSceneryCullInfo + Scenery.cpp, máscara ^0x60].
    // En el disco son copias ~20 m más bajas de pórticos y carteles de autopista, puentes…: se veían duplicados.
    if ((inst.excludeFlags & 0x02) && gi === undefined) { mainViewExcluded++; continue; }
    // Nivel lejano: el mismo que usa el juego de lejos, pModel[2] (si falta, pModel[1]) [D: Scenery.cpp, carga y selección
    // por tamaño en pantalla]. pModel[3] es para reflejos y sombras; pModel[0] no existe en PS2 (se copia de pModel[1]).
    const low = solids.get(info.hashes[2]) ?? so;
    const cx = (inst.bbMin[0] + inst.bbMax[0]) / 2, cy = (inst.bbMin[1] + inst.bbMax[1]) / 2;
    const key = `${Math.floor(cx / TILE)}_${Math.floor(cy / TILE)}`;
    const r = inst.rotation, p = inst.position;
    const target = gi !== undefined ? (groupInst.get(gi) ?? groupInst.set(gi, []).get(gi)!) : hidden ? null : (tiles.get(key) ?? tiles.set(key, []).get(key)!);
    if (!target) { hiddenSkipped++; continue; }
    target.push({ so, low, matrix: [r[0], r[1], r[2], 0, r[3], r[4], r[5], 0, r[6], r[7], r[8], 0, p[0], p[1], p[2], 1], size: Math.hypot(inst.bbMax[0] - inst.bbMin[0], inst.bbMax[1] - inst.bbMin[1], inst.bbMax[2] - inst.bbMin[2]), meta: { "Sección": s.name, "Modelo": info.name, "Hash modelo": hex8(h), "Instancia": k } });
  }
  const written = new Set<number>();
  const out: { id: string; x: number; y: number; size: number; near: string; far: string; tris: number; farTris: number; objects: number; zMin: number; zMax: number }[] = [];
  let nearTris = 0, farTrisAll = 0;
  for (const [key, list] of tiles) {
    const [tx, ty] = key.split("_").map(Number);
    const mats = new MaterialTable(textures, { unlit: true, external: { dir: `${outDir}/textures`, uriPrefix: "../textures/", written } });
    const meshCache = new Map<Solid, GlbMesh>();
    const meshOf = (so: Solid) => meshCache.get(so) ?? meshCache.set(so, solidToMesh(so, t => mats.get(t))).get(so)!;
    const near = flatten(list.map((it, id) => ({ mesh: meshOf(it.so), matrix: it.matrix, id })));
    await Bun.write(`${outDir}/tiles/${key}.glb`, writeGlb([{ name: `tile ${key}`, primitives: near, extras: { Casilla: key, objetos: list.map(i => i.meta) } }], mats.materials, mats.images, `tile_${key}`));
    // Nivel lejano: una sola malla con color por vértice = color medio de textura × luz horneada.
    const farMats = new MaterialTable(new Map(), { unlit: true });
    const farMat = farMats.get(undefined); farMats.materials[farMat] = { name: "lejano", color: [1, 1, 1, 1], unlit: true };
    // El nivel lejano no lleva sombras horneadas (SHD_*): su color medio es negro y oscurecería la casilla.
    const farInst = list.filter(i => i.size >= FAR_MIN && !i.so.name.startsWith("SHD_")).map((it0, id) => {
      const it = { ...it0, so: it0.low };
      // Teñir los vértices con el color medio de la textura × luz horneada, en lineal (ver ps2ColorToLinear).
      // Fuera las tiras con recorte o mezcla (hojas de árbol, vallas, pintadas): sin su alfa serían placas sólidas
      // flotando en el cielo; de lejos el árbol se reconoce por el tronco y la copa opaca, si la tiene.
      const strips = it.so.strips.filter(st => { const t = st.texture >= 0 ? textures.get(it.so.textureHashes[st.texture]) : undefined; return !t || alphaFor(t).alphaMode === "OPAQUE"; });
      const cols: number[] = [], pos: number[] = [], idx: number[] = []; let base = 0;
      for (const st of strips) {
        const c = (st.texture >= 0 && avg.get(it.so.textureHashes[st.texture])) || [0.6, 0.6, 0.6];
        for (let k = 0; k < st.nv; k++) { const b = st.colors?.[k] ?? [1, 1, 1, 1]; cols.push(...ps2ColorToLinear([c[0] * b[0], c[1] * b[1], c[2] * b[2], 1])); pos.push(...st.positions[k]); }
        for (const t of stripTriangles(st)) idx.push(base + t[0], base + t[1], base + t[2]);
        base += st.nv;
      }
      const m = solidToMesh(it.so, () => farMat);
      m.primitives = [{ material: farMat, positions: new Float32Array(pos), colors: new Float32Array(cols), indices: new Uint32Array(idx) }];
      return { mesh: m, matrix: it.matrix, id };
    });
    const far = flatten(farInst).map(p => clusterSimplify({ ...p, normals: undefined, uvs: undefined, ids: undefined }, FAR_CELL));
    await Bun.write(`${outDir}/tiles/${key}_far.glb`, writeGlb([{ name: `far ${key}`, primitives: far }], farMats.materials, [], `far_${key}`));
    const tris = near.reduce((a, p) => a + p.indices.length / 3, 0), farTris = far.reduce((a, p) => a + p.indices.length / 3, 0);
    let zMin = Infinity, zMax = -Infinity; for (const p of near) for (let i = 2; i < p.positions.length; i += 3) { zMin = Math.min(zMin, p.positions[i]); zMax = Math.max(zMax, p.positions[i]); }
    out.push({ id: key, x: tx * TILE, y: ty * TILE, size: TILE, near: `tiles/${key}.glb`, far: `tiles/${key}_far.glb`, tris, farTris, objects: list.length, zMin, zMax });
    nearTris += tris; farTrisAll += farTris;
  }
  mkdirSync(`${outDir}/groups`, { recursive: true });
  const groupOut: { name: string; hash: string; number: number; kind: string; barrier: boolean; driveThrough: boolean; objects: number; glb: string; min: number[]; max: number[] }[] = [];
  for (const [gi, list] of groupInst) {
    const g = groups[gi], name = gnames.get(g.nameHash) ?? hex8(g.nameHash);
    const mats = new MaterialTable(textures, { unlit: true, external: { dir: `${outDir}/textures`, uriPrefix: "../textures/", written } });
    const prims = flatten(list.map((it, id) => ({ mesh: solidToMesh(it.so, t => mats.get(t)), matrix: it.matrix, id })));
    await Bun.write(`${outDir}/groups/${name}.glb`, writeGlb([{ name, primitives: prims, extras: { Grupo: name, objetos: list.map(i => i.meta) } }], mats.materials, mats.images, name));
    const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
    for (const p of prims) for (let i = 0; i < p.positions.length; i++) { min[i % 3] = Math.min(min[i % 3], p.positions[i]); max[i % 3] = Math.max(max[i % 3], p.positions[i]); }
    groupOut.push({ name, hash: hex8(g.nameHash), number: g.number, kind: groupKind(gnames.get(g.nameHash), g.barrier), barrier: g.barrier, driveThrough: g.driveThrough, objects: list.length, glb: `groups/${name}.glb`, min, max });
  }
  console.log(`Grupos: ${groupOut.length} exportados (${["carrera", "candado", "puerta", "otro"].map(k => `${k} ${groupOut.filter(g => g.kind === k).length}`).join(", ")}) · objetos ocultos sin grupo omitidos: ${hiddenSkipped} · fuera de la vista del jugador (0x02): ${mainViewExcluded}`);
  const wj = existsSync(`${outDir}/world.json`) ? JSON.parse(readFileSync(`${outDir}/world.json`, "utf8")) : { disc, upAxis: "Z", sections: [] };
  wj.groups = groupOut.sort((a, b) => a.number - b.number);
  wj.tiles = out.sort((a, b) => a.id.localeCompare(b.id)); wj.tileSize = TILE;
  if (!wj.sections?.length) wj.sections = sections.filter(s => s.radius > 0).map(s => ({ name: s.name, number: s.number, centre: s.centre, radius: s.radius, glb: "", instances: 0, tris: 0 }));
  await Bun.write(`${outDir}/world.json`, JSON.stringify(wj, null, 1));
  console.log(`Casillas ${out.length} de ${TILE} m · detalle ${(nearTris / 1e6).toFixed(2)} M tris · lejano ${(farTrisAll / 1e6).toFixed(2)} M tris`);
}
index.generated = new Date().toISOString();
index.items.sort((a, b) => a.group.localeCompare(b.group) || a.label.localeCompare(b.label));
await Bun.write(indexPath, JSON.stringify(index, null, 1));
