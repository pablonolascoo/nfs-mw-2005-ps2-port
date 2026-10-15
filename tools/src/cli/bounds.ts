// Volúmenes de colisión del juego (cajas y esferas de cada coche y de los objetos del mundo) → map-data/<ID>/bounds.json.
// Fuente: GLOBAL\GLOBALB.BUN y TRACKS\L2RA.BUN, chunks 0x8003B900 → 0x0003B901 (lib/bounds.ts, doc 22 §5).
// Sirve para los choques coche-coche y coche-objeto del juego original (hoy el port usa una caja aproximada).
// Los contornos «trough» (0x00034190) los exporta effects.ts (lib/world-extra.ts readTrough, doc 24 §9).
// Uso: bun src/cli/bounds.ts <iso> <ID>
import { mkdirSync, writeFileSync } from "node:fs";
import { GameDisc } from "../lib/zdir";
import { loadCandidates } from "../lib/names";
import { embedded, outDir } from "../lib/paths";
import { readBounds, type BoundsCollection } from "../lib/bounds";
import { attribHash, AttribDatabase, Vault, parseVpak } from "../lib/vlt";
import { loadAttribNames } from "../lib/attrib-names";
import { lzDecompress } from "../lib/lz";
import { hex8 } from "../lib/hash";
import { parseChunks, walk } from "../lib/bchunk";
import { readScenery } from "../lib/world-ps2";

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/bounds.ts <iso> <ID>"); process.exit(1); }
const disc = await GameDisc.open(iso);
disc.resolveNames(await loadCandidates(disc, embedded.filenameLists));
const read = async (n: string) => { let b = await disc.readEntry(disc.find(n)!); if (b[0] === 0x4a && b[1] === 0x44) b = lzDecompress(b); return b; };

// Nombres candidatos (UCrc32 = hash de Attrib, Jenkins con semilla 0xABCDEF00 [V: los 83 coches]):
// coches del disco, claves de Attrib y nombres de las colecciones de la base de datos (superficies simsurface, etc.)
const names = new Map<number, string>();
const addName = (s: string) => { if (s) { names.set(attribHash(s), s); names.set(attribHash(s.toLowerCase()), s.toLowerCase()); } };
for (const e of disc.entries) { const m = /^CARS\\([A-Z0-9_]+)\\GEOMETRY\.BIN$/.exec(e.name ?? ""); if (m) addName(m[1]); }
for (const l of embedded.attribNames.split("\n")) if (l && !l.startsWith("#")) addName(l.trim());
const db = new AttribDatabase();
await loadAttribNames(db);
for (const v of parseVpak(await read("GLOBAL\\ATTRIBUTES.BIN"))) db.addVault(new Vault(v.name, v.vlt, v.bin));
for (const c of db.collections.values()) { const n = db.names.name(c.key); if (n && !n.startsWith("0x")) names.set(c.key, n); }
// Objetos del mundo: su UCrc32 es attribHash del nombre del modelo de escenario (p. ej. «XS_Speed35_1b_00») [V: 202 de 378]
{ const sb = await read("TRACKS\\STREAML2RA.BUN");
  for (const sc of readScenery(sb, [...walk(parseChunks(sb))].map(([c]) => c))) for (const i of sc.infos) if (i.name) { names.set(attribHash(i.name), i.name); names.set(attribHash(i.name.replace(/_00$/, "")), i.name.replace(/_00$/, "")); } }
const nm = (h: number) => (h ? names.get(h) ?? hex8(h) : null);

const conv = (c: BoundsCollection) => ({
  name: nm(c.name), nameHash: hex8(c.name),
  bounds: c.bounds.map(b => ({ ...b, surface: nm(b.surface), name: nm(b.name) })),
  pointClouds: c.pclouds,
});
const cars = readBounds(await read("GLOBAL\\GLOBALB.BUN")).map(conv);
const world = readBounds(await read("TRACKS\\L2RA.BUN")).map(conv);
mkdirSync(outDir(id), { recursive: true });
writeFileSync(`${outDir(id)}/bounds.json`, JSON.stringify({
  disc: id, source: "GLOBAL\\GLOBALB.BUN + TRACKS\\L2RA.BUN · 0x8003B900/0x0003B901 CollisionGeometry::Bounds [D: Physics/Bounds.h][V]",
  units: "metros, espacio del modelo; orientación = cuaternión (x, y, z, w)", cars, world,
}));
const unres = [...cars, ...world].filter(c => /^[0-9a-f]{8}$/.test(c.name ?? "")).length;
console.log(`Colisión ${id}: ${cars.length} coches (${cars.reduce((s, c) => s + c.bounds.length, 0)} volúmenes), ${world.length} objetos del mundo (${world.reduce((s, c) => s + c.bounds.length, 0)} volúmenes, ${world.reduce((s, c) => s + c.pointClouds.length, 0)} nubes); ${unres} nombres sin resolver → bounds.json`);
