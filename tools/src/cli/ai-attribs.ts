// Tablas de IA del juego (GLOBAL\ATTRIBUTES.BIN): tráfico, policía, calor y persecuciones → map-data/<ID>/ai.json
// Lo usa el motor nativo (native-engine/Sources/Rockport/AI*.swift, Traffic*.swift, Police*.swift).
// Uso: bun src/cli/ai-attribs.ts <iso> <ID>
//
// Clases volcadas [V: SLES-53559] (estructuras de MWAttribUserTypes.h y AI/aireflectedtypes.h [D]):
//   trafficpattern     SpawnTime, SpeedStreet, SpeedHighway (mph) y Vehicles = TrafficPatternRecord {RefSpec Vehicle, Rate, MaxInstances, Percent}
//   pursuitescalation  heattable[10] → pursuitlevels heat_01…heat_10 (nivel de calor 1…10)
//   pursuitlevels      todos los campos + cops = CopCountRecord {StringKey CopType, Count, Chance} y CopFormations {Formation, Duration, Frequency}
//   pursuitsupport     Air/Heavy/LeaderSupport (estrategia, probabilidad, duración…)
//   aivehicle          MAXIMUM_AI_SPEED, TopSpeedMultiplier, AccelerationMultiplier
//   pvehicle           MODEL (nombre del GLB) y MASS de los coches de tráfico y policía
//   infractions        multa por infracción (amount)
//   world              TRAFFIC_TYPES
// Y las zonas de TrackPathManager (escondites, patrón de tráfico por barrio, sin policía, inicio de persecución) de L2RA.BUN.
import { GameDisc } from "../lib/zdir";
import { AttribDatabase, Vault, attribHash, parseVpak, type CollectionInfo } from "../lib/vlt";
import { loadAttribNames } from "../lib/attrib-names";
import { parseChunks, walk } from "../lib/bchunk";
import { bStringHash } from "../lib/hash";

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/ai-attribs.ts <iso> <ID>"); process.exit(1); }
const root = new URL("../../../", import.meta.url).pathname;
const d = await GameDisc.open(iso);
const db = new AttribDatabase();
await loadAttribNames(db);

// Nombres de colección que no están en el disco como texto: se comprueban por hash (Jenkins, semilla 0xABCDEF00) [V].
const extra: string[] = [];
for (let i = 1; i <= 10; i++) extra.push(`heat_${String(i).padStart(2, "0")}`, `race_${String(i).padStart(2, "0")}`);
extra.push("copmidsize", "copgto", "copsport", "copsuv", "copsuvl", "copheli", "copghost", "copgtoghost", "copsportghost", "copsporthench",
  "copsuvpatrol", "copcross", "copmidsizeint",
  "speeding", "racing", "reckless", "reckless_driving", "assault", "assaulting_police", "hitandrun", "hit_and_run", "damage",
  "damage_to_property", "property_damage", "resist", "resisting_arrest", "resisting", "offroad", "off_road", "driving_offroad");
for (const s of extra) db.names.set(attribHash(s), s);

for (const e of parseVpak(await d.readEntry(d.find("GLOBAL\\ATTRIBUTES.BIN")!))) db.addVault(new Vault(e.name, e.vlt, e.bin));
for (const c of db.collections.values()) db.collectionName(c);

const byClass = (cls: string) => [...db.collections.values()].filter(c => db.names.name(c.classKey) === cls);
const vals = (c: CollectionInfo) => db.resolvedValues(c) as Record<string, any>;
const u32 = (x: unknown) => parseInt(String(x), 16) >>> 0;
const f32 = (x: unknown) => { const b = new DataView(new ArrayBuffer(4)); b.setUint32(0, u32(x)); return +b.getFloat32(0).toFixed(4); };
const nameOfKey = (k: number) => db.names.get(k) ?? `0x${k.toString(16).padStart(8, "0")}`;
const records = (v: unknown) => (Array.isArray(v) ? v : []).map((r: any) => r.raw as string[]);

// pvehicle: colección → modelo (GLB) y masa
const pvehicle: Record<string, { model: string; mass: number; class?: string }> = {};
for (const c of byClass("pvehicle")) {
  const v = vals(c);
  pvehicle[db.collectionName(c)] = { model: v.MODEL ?? "", mass: v.MASS ?? 0 };
}

// trafficpattern
const trafficPatterns: Record<string, unknown> = {};
for (const c of byClass("trafficpattern")) {
  const v = vals(c);
  trafficPatterns[db.collectionName(c)] = {
    spawnTime: v.SpawnTime, speedStreetMph: v.SpeedStreet, speedHighwayMph: v.SpeedHighway,
    vehicles: records(v.Vehicles).map(r => {
      const veh = nameOfKey(u32(r[1]));
      return { vehicle: veh, model: pvehicle[veh]?.model ?? "", rate: f32(r[3]), maxInstances: u32(r[4]), percent: u32(r[5]) };
    }),
  };
}

// pursuitlevels (todas) y tabla de calor (pursuitescalation.heattable)
const decodeLevel = (v: Record<string, any>) => {
  const out: Record<string, unknown> = {};
  for (const [k, x] of Object.entries(v)) if (typeof x === "number" || typeof x === "boolean" || (Array.isArray(x) && x.every(y => typeof y === "number"))) out[k] = x;
  out.cops = records(v.cops).map(r => { const t = nameOfKey(u32(r[2])); return { copType: t, model: pvehicle[t]?.model ?? "", count: u32(r[4]), chance: u32(r[5]) }; });
  out.formations = records(v.CopFormations).map(r => ({ formation: ["?", "PIT", "BOX_IN", "ROLLING_BLOCK", "FOLLOW", "HELI_PURSUIT", "HERD", "STAGGER_FOLLOW"][u32(r[0])] ?? u32(r[0]), formationId: u32(r[0]), duration: f32(r[1]), frequency: f32(r[2]) }));
  return out;
};
const pursuitLevels: Record<string, unknown> = {};
for (const c of byClass("pursuitlevels")) pursuitLevels[db.collectionName(c)] = decodeLevel(vals(c));
const esc = byClass("pursuitescalation")[0];
const escV = esc ? vals(esc) : {};
const refName = (r: any) => (typeof r?.collection === "string" ? (r.collection.startsWith("0x") ? nameOfKey(u32(r.collection)) : r.collection) : "");
const heatTable = (escV.heattable ?? []).map(refName);
const supportRaceTable = (escV.supportracetable ?? []).map(refName);
const supportTable = (escV.supporttable ?? escV.SupportTable ?? []).map(refName);

const pursuitSupport: Record<string, unknown> = {};
for (const c of byClass("pursuitsupport")) {
  const v = vals(c);
  pursuitSupport[db.collectionName(c)] = {
    minimumSupportDelay: v.MinimumSupportDelay,
    air: records(v.AirSupportOptions).map(r => ({ strategy: u32(r[0]), chance: u32(r[1]), duration: f32(r[2]) })),
    heavy: records(v.HeavySupportOptions).map(r => ({ strategy: u32(r[0]), chance: u32(r[1]), duration: f32(r[2]), chanceBigSUV: u32(r[3]) })),
    leader: records(v.LeaderSupportOptions).map(r => ({ strategy: u32(r[0]), chance: u32(r[1]), duration: f32(r[2]), priorityChance: u32(r[3]), priorityTime: f32(r[4]) })),
  };
}

const aiVehicle: Record<string, unknown> = {};
for (const c of byClass("aivehicle")) {
  const v = vals(c);
  // RepPointsForDestroying[nivel de calor] (formato 11): reputación por destruir el coche [D: AIPursuit::IncNumCopsDestroyed]
  aiVehicle[db.collectionName(c)] = { maxSpeedKmh: v.MAXIMUM_AI_SPEED, topSpeedMultiplier: v.TopSpeedMultiplier, accelerationMultiplier: v.AccelerationMultiplier, repPointsForDestroying: v.RepPointsForDestroying ?? null };
}

const infractions: Record<string, number> = {};
for (const c of byClass("infractions")) infractions[db.collectionName(c)] = vals(c).amount;

const worldC = byClass("world")[0];
const world = worldC ? { trafficTypes: vals(worldC).TRAFFIC_TYPES ?? [] } : {};

// Zonas de TrackPathManager (TRACKS\\L2RA.BUN, chunk 0x0003414A dentro de 0x80034147) [D: World/TrackPath.hpp, V: SLES-53559]
// TrackPathZone: s32 Type · f32 Position[2] · f32 Direction[2] · f32 Elevation · s8 ZoneSource · s8 CachedIndex · s16 VisitInfo · u32 pUserData
//   · f32 BBoxMin[2] · f32 BBoxMax[2] · s32 Data[4] · s16 NumPoints · s16 MemoryImageSize · f32 Points[NumPoints][2]. Coordenadas = mundo X, Y.
// Tipos útiles para la IA: 8 HIDDEN (escondites), 9 TRAFFIC_PATTERN (Data[0] = bStringHash del patrón), 13 NO_COP_SPAWN, 14 PURSUIT_START.
const ZONE_TYPES: Record<number, string> = { 8: "hidden", 9: "trafficPattern", 11: "neighbourhood", 13: "noCopSpawn", 14: "pursuitStart" };
const zones: { type: string; data: (number | string)[]; bbox: number[]; points: number[][] }[] = [];
try {
  const l2ra = await d.readEntry(d.find("TRACKS\\L2RA.BUN")!);
  const zv = new DataView(l2ra.buffer, l2ra.byteOffset, l2ra.byteLength);
  const patternByHash = new Map(Object.keys(trafficPatterns).map(n => [bStringHash(n) >>> 0, n]));
  for (const [c] of walk(parseChunks(l2ra))) {
    if (c.id !== 0x0003414a) continue;
    for (let o = c.dataOffset; o + 0x44 <= c.dataOffset + c.size;) {
      const type = zv.getInt32(o, true), np = zv.getInt16(o + 0x40, true), size = zv.getInt16(o + 0x42, true);
      if (size <= 0) break;
      if (ZONE_TYPES[type]) {
        const data = [0, 1, 2, 3].map(k => zv.getUint32(o + 0x30 + k * 4, true));
        zones.push({
          type: ZONE_TYPES[type],
          data: type === 9 ? [patternByHash.get(data[0]) ?? data[0], ...data.slice(1)] : data,
          bbox: [0x20, 0x24, 0x28, 0x2c].map(k => +zv.getFloat32(o + k, true).toFixed(2)),
          points: Array.from({ length: Math.min(np, 64) }, (_, k) => [+zv.getFloat32(o + 0x44 + k * 8, true).toFixed(2), +zv.getFloat32(o + 0x48 + k * 8, true).toFixed(2)]),
        });
      }
      o += size;
    }
  }
} catch (e) { console.warn("Aviso: zonas de TrackPath no leídas:", (e as Error).message); }

// Solo los vehículos que interesan a la IA (tráfico y policía), con su modelo
const vehicles = Object.fromEntries(Object.entries(pvehicle).filter(([k, v]) => v.model && (/^(traf|cop|semi|taxi|pizza|garb|cemtr|minivan|pickup)/i.test(k))));

const out = {
  disc: id,
  source: "GLOBAL\\ATTRIBUTES.BIN · trafficpattern, pursuitescalation, pursuitlevels, pursuitsupport, aivehicle, pvehicle, infractions, world",
  units: { speedStreetMph: "mph", speedHighwayMph: "mph", maxSpeedKmh: "km/h [H]", frontLOSdistance: "m", evadetimeout: "s", TimePerHeatLevel: "s", BustSpeed: "mph [H]" },
  heatTable, supportTable, supportRaceTable,
  pursuitLevels, pursuitSupport, trafficPatterns, aiVehicle, vehicles, infractions, world, zones,
};
const path = `${process.env.ROCKPORT_OUT ?? `${root}map-data/${id}`}/ai.json`;
await Bun.write(path, JSON.stringify(out, null, 1));
console.log(`ai.json: ${Object.keys(trafficPatterns).length} patrones de tráfico · ${Object.keys(pursuitLevels).length} niveles de persecución (calor: ${heatTable.join(", ")}) · ${Object.keys(vehicles).length} vehículos · ${zones.length} zonas`);
