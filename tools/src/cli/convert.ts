// Conversor disco PS2 → map-data/<disco>/ (GLB + index.json) para el visor.
// Uso: bun src/cli/convert.ts <iso> <ID> car <NOMBRE> [<NOMBRE>…]
import { GameDisc } from "../lib/zdir";
import { readSolidList, type Solid } from "../lib/solid-ps2";
import { readTexturePack, type Texture } from "../lib/tex-ps2";
import { solidToMesh } from "../lib/mesh-build";
import { MaterialTable } from "../lib/materials";
import { writeGlb } from "../lib/glb";
import { hex8 } from "../lib/hash";
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
index.generated = new Date().toISOString();
index.items.sort((a, b) => a.group.localeCompare(b.group) || a.label.localeCompare(b.label));
await Bun.write(indexPath, JSON.stringify(index, null, 1));
