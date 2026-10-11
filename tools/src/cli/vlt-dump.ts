// Vuelca la base de atributos de juego (VPAK/VLT) a JSON y extrae las zonas del mundo.
// Uso: bun src/cli/vlt-dump.ts <iso> <ID> [GLOBAL\GAMEPLAY.BIN]
//   → map-data/<ID>/gameplay.json  (todas las colecciones, con nombres de campo resueltos)
//   → map-data/<ID>/zones.json     (zonas safehouse / carlot / customshop con posición, radio y respawn)
// El esquema (tipos y clases) sale de GLOBAL\ATTRIBUTES.BIN, que se lee siempre.
// Formato: docs/es/05-vlt-atributos.md
import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { Glob } from "bun";
import { GameDisc } from "../lib/zdir";
import { AttribDatabase, Vault, attribHash, hexKey, parseVpak, type CollectionInfo, type Value } from "../lib/vlt";

const [iso, id, file = "GLOBAL\\GAMEPLAY.BIN"] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/vlt-dump.ts <iso> <ID> [GLOBAL\\GAMEPLAY.BIN]"); process.exit(1); }

const ROOT = resolve(import.meta.dir, "../../..");
const GEN = join(ROOT, "experiments/decomp/nfsmw/src/Speed/Indep/Src/Generated/AttribSys/Classes");
const ZONE_TYPES = ["safehouse", "carlot", "customshop"];
// Caja aproximada de Rockport (Z arriba) para la comprobación de cordura.
const BOUNDS = { x: [-900, 5200], y: [-1200, 4800], z: [0, 900] } as const;

const disc = await GameDisc.open(iso);
const read = async (name: string) => {
  const e = disc.find(name);
  if (!e) throw new Error(`No está en ZDIR: ${name}`);
  return disc.readEntry(e);
};

const db = new AttribDatabase();

// 1) Nombres conocidos: claves "static const Key X = 0x…" del decomp (solo si el hash cuadra; quita el prefijo key_).
let decompNames = 0;
try {
  for await (const f of new Glob("*.h").scan(GEN)) {
    const text = await Bun.file(join(GEN, f)).text();
    for (const m of text.matchAll(/static const Key (\w+) = (0x[0-9a-fA-F]+);/g)) {
      const h = parseInt(m[2], 16) >>> 0;
      for (const cand of [m[1], m[1].replace(/^key_/, "")]) if (attribHash(cand) === h) { db.names.set(h, cand); decompNames++; break; }
    }
  }
} catch { console.warn("Aviso: no se encontró el decomp; los campos se resolverán solo con cadenas del disco."); }

// 2) Esquema (ATTRIBUTES.BIN) + datos (GAMEPLAY.BIN u otro VPAK).
const schemaVaults = parseVpak(await read("GLOBAL\\ATTRIBUTES.BIN"));
for (const e of schemaVaults) db.addVault(new Vault(e.name, e.vlt, e.bin));
const schemaCollections = new Set(db.collections.keys());
const dataBuf = await read(file);
const dataVaults = parseVpak(dataBuf);
for (const e of dataVaults) db.addVault(new Vault(e.name, e.vlt, e.bin));

const ours = [...db.collections.entries()].filter(([k]) => !schemaCollections.has(k)).map(([, c]) => c);
for (const c of db.collections.values()) db.collectionName(c); // registra CollectionName antes de decodificar referencias

// 3) Volcado completo.
const name = (c: CollectionInfo) => db.collectionName(c);
const resolvedCache = new Map<CollectionInfo, Record<string, Value>>();
const resolved = (c: CollectionInfo) => { let r = resolvedCache.get(c); if (!r) { r = db.resolvedValues(c); resolvedCache.set(c, r); } return r; };
const ancestors = (c: CollectionInfo) => {
  const out: string[] = [];
  for (let p = c.parent ? db.getCollection(c.classKey, c.parent) : undefined, i = 0; p && i < 32; p = p.parent ? db.getCollection(p.classKey, p.parent) : undefined, i++) out.push(name(p));
  return out;
};
const byName = new Map<string, CollectionInfo>();
for (const c of ours) byName.set(name(c), c);

const unresolvedFields = new Set<string>();
const collections = ours.map(c => {
  const values = db.ownValues(c);
  for (const k of Object.keys(values)) if (k.startsWith("0x")) unresolvedFields.add(k);
  return { name: name(c), key: hexKey(c.key), class: db.names.name(c.classKey), parent: c.parent ? db.names.name(c.parent) : null, vault: c.vault.name, values };
});

// 4) Resúmenes: carreras, lista negra, hitos.
const RACE_KINDS = ["sprint", "circuit", "drag", "lapknockout", "knockout", "speedtraprace", "tollboothrace", "p2p", "challengerace"];
const raceKind = (c: CollectionInfo) => [name(c), ...ancestors(c)].find(a => RACE_KINDS.includes(a)) ?? ancestors(c)[0] ?? null;
const bins = ours.filter(c => ancestors(c).includes("race_bin") && resolved(c).Template === false);
const binOf = new Map<string, string>();
for (const b of bins) for (const f of ["WorldRaces", "BossRaces"]) for (const r of (resolved(b)[f] as Value[] | undefined) ?? []) if (typeof r === "string") binOf.set(r, name(b));

const races = ours.filter(c => { const r = resolved(c); return typeof r.EventID === "string" && r.EventID !== "" && r.Template === false; }).map(c => {
  const r = resolved(c);
  return {
    name: name(c), eventId: r.EventID, kind: raceKind(c), bin: binOf.get(name(c)) ?? null, region: r.Region ?? null,
    laps: r.NumLaps ?? null, length: r.RaceLength ?? null, cash: r.CashValue ?? null, bossRace: r.BossRace ?? false,
    opponents: Array.isArray(r.Opponents) ? r.Opponents.length : 0, checkpoints: Array.isArray(r.Checkpoint) ? r.Checkpoint.length : 0,
    playerCar: r.PlayerCarType || null,
  };
}).sort((a, b) => String(a.eventId).localeCompare(String(b.eventId), "en", { numeric: true }));

const blacklist = bins.map(b => {
  const r = resolved(b);
  const boss = typeof r.Boss === "string" ? byName.get(r.Boss) : undefined;
  const br = boss ? resolved(boss) : {};
  return {
    bin: name(b), binIndex: r.BinIndex, boss: r.Boss ?? null, bossCar: br.PresetRide ?? null, racerName: br.RacerName || null,
    requiredBounty: r.RequiredBounty, requiredRacesWon: r.RequiredRacesWon, requiredChallenges: r.RequiredChallenges,
    worldRaces: Array.isArray(r.WorldRaces) ? r.WorldRaces.length : 0, bossRaces: Array.isArray(r.BossRaces) ? r.BossRaces.length : 0,
  };
}).sort((a, b) => Number(b.binIndex) - Number(a.binIndex));

const milestones = ours.filter(c => ancestors(c).includes("milestone") && resolved(c).Template === false).map(c => {
  const r = resolved(c);
  return { name: name(c), type: r.MilestoneName ?? null, binIndex: r.BinIndex ?? null, goalEasy: r.GoalEasy ?? null, goalHard: r.GoalHard ?? null, bounty: r.Bounty ?? null };
});

// 5) Zonas.
const vec3 = (v: Value | undefined) => (Array.isArray(v) && v.length === 3 && v.every(n => typeof n === "number") ? (v as number[]) : null);
const inBounds = (p: number[] | null) => !!p && p[0] >= BOUNDS.x[0] && p[0] <= BOUNDS.x[1] && p[1] >= BOUNDS.y[0] && p[1] <= BOUNDS.y[1] && p[2] >= BOUNDS.z[0] && p[2] <= BOUNDS.z[1];
const gateOf = new Map<string, string>();
for (const c of ours) for (const z of (resolved(c).ZoneList as Value[] | undefined) ?? []) if (typeof z === "string") gateOf.set(z, name(c));

// Se descartan las plantillas (zone_safehouse…: Template=true, posición heredada 0,0,0).
const zones = ours.filter(c => { const r = resolved(c); return ZONE_TYPES.includes(String(r.ZoneType)) && r.Template !== true && vec3(r.Position); }).map(c => {
  const r = resolved(c);
  const respawnC = typeof r.RespawnMarker === "string" ? byName.get(r.RespawnMarker) : undefined;
  const rr = respawnC ? resolved(respawnC) : null;
  const { CollectionName, Name, message_id, Children, Template, ...fields } = r;
  return {
    collection: name(c), zoneType: r.ZoneType, position: vec3(r.Position), radius: r.Radius ?? null,
    dimensions: vec3(r.Dimensions), rotation: r.Rotation ?? null, binIndex: r.BinIndex ?? null, gate: gateOf.get(name(c)) ?? null,
    respawn: rr ? { collection: name(respawnC!), position: vec3(rr.Position), rotation: rr.Rotation ?? null } : null,
    inRockportBounds: inBounds(vec3(r.Position)), fields,
  };
}).sort((a, b) => (a.zoneType as string).localeCompare(b.zoneType as string) || a.collection.localeCompare(b.collection, "en", { numeric: true }));

// 6) Escritura.
const outDir = join(ROOT, "map-data", id);
mkdirSync(outDir, { recursive: true });
const parentCounts: Record<string, number> = {};
for (const c of collections) if (c.parent) parentCounts[c.parent] = (parentCounts[c.parent] ?? 0) + 1;
const gameplay = {
  source: { iso: iso.split(/[\\/]/).pop(), file, bytes: dataBuf.length, schema: "GLOBAL\\ATTRIBUTES.BIN" },
  counts: {
    vaults: dataVaults.length, collections: collections.length, races: races.length, blacklistBins: blacklist.length, milestones: milestones.length,
    zones: zones.length, schemaTypes: db.types.size, schemaClasses: db.classes.size, decompNames, unresolvedFieldKeys: unresolvedFields.size,
  },
  byParent: Object.fromEntries(Object.entries(parentCounts).sort((a, b) => b[1] - a[1])),
  summary: { blacklist, races, milestones },
  warnings: db.warnings,
  collections,
};
await Bun.write(join(outDir, "gameplay.json"), JSON.stringify(gameplay, null, 1));
await Bun.write(join(outDir, "zones.json"), JSON.stringify({
  source: gameplay.source, axes: "Z arriba (unidades del motor ≈ metros) [H]", bounds: BOUNDS, zones,
}, null, 2));

// 7) Informe por consola.
console.log(`${file}: ${dataVaults.length} vaults, ${collections.length} colecciones (+${schemaCollections.size} del esquema ATTRIBUTES.BIN, ${db.classes.size} clases, ${db.types.size} tipos)`);
console.log(`Campos sin nombre: ${unresolvedFields.size} · avisos: ${db.warnings.length}`);
console.log(`Carreras: ${races.length} · lista negra: ${blacklist.length} · hitos: ${milestones.length}`);
console.log(`Zonas (${zones.length}):`);
for (const z of zones) console.log(`  ${String(z.zoneType).padEnd(10)} ${z.collection.padEnd(42)} pos=[${z.position!.map(n => n.toFixed(1)).join(", ")}] r=${z.radius} ${z.inRockportBounds ? "OK" : "FUERA DE RANGO"}`);
const bad = zones.filter(z => !z.inRockportBounds).length;
console.log(bad ? `Cordura: ${bad} zona(s) fuera de la caja de Rockport` : "Cordura: todas las zonas caen dentro de la caja de Rockport");
console.log(`→ ${join(outDir, "gameplay.json")}\n→ ${join(outDir, "zones.json")}`);
