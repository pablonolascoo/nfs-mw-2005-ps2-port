// Carreras y Lista Negra → map-data/<ID>/races.json (lo lee el motor nativo: native-engine/Sources/Rockport/Race/).
// Uso: bun src/cli/races.ts <iso> <ID>
//
// Fuentes (todas leídas de los bytes del disco):
//   - GLOBAL\GAMEPLAY.BIN, ya volcado por el paso «vlt-dump» en gameplay.json [V]. Aquí se resuelve la herencia de cada
//     colección (padre → hijo, como Attrib::Collection) y se arma cada prueba: salida (startgrid), puntos de control
//     (Checkpoint[]), meta (racefinish), radares (SpeedTrapList), reinicio (resetplayertrigger), atajos, rivales
//     (Opponents → character/boss: PresetRide, SkillLevel), vallas (Barriers, «*» = invertida [D: GetBarrierIsFlipped]),
//     reglas (NumLaps, KnockoutsPerLap, TimeLimit, CopsInRace, TrafficLevel, CatchUp*…) y el disparador del mundo
//     (engagetrigger_* con TargetActivity). Lista Negra: race_bin_NN (WorldRaces, BossRaces, Required*, Barriers), hitos.
//   - TRACKS\L2RA.BUN chunk 0x80034147 → 0x0003414D: TrackPathBarrier[] de 24 B {bVector2 a, b; s8 Enabled, Pad,
//     PlayerBarrier, LeftHanded; u32 GroupHash = bStringHash(nombre del grupo)} [D: World/TrackPath.hpp][V: 1 376 vallas,
//     751 grupos]. Son las líneas que cierran el paso: las que el juego activa con EnableBarriers(grupo) en cada prueba.
//   - world.json (paso «convert»): GLB de cada grupo de escenario (BARRIER_SPLINE_n, BARRIER_LOCKED_n) para dibujarlos.
// Formato y reglas: docs/es/18-carreras-y-lista-negra.md.
import { existsSync, readFileSync } from "node:fs";
import { GameDisc } from "../lib/zdir";
import { parseChunks, walk } from "../lib/bchunk";
import { bStringHash, hex8 } from "../lib/hash";
import { outDir } from "../lib/paths";

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/races.ts <iso> <ID>"); process.exit(1); }
const out = outDir(id);
if (!existsSync(`${out}/gameplay.json`)) { console.error(`Falta ${out}/gameplay.json: ejecuta antes el paso «vlt-dump»`); process.exit(1); }

type Coll = { name: string; parent: string | null; vault: string; values: Record<string, any> };
const gp = JSON.parse(readFileSync(`${out}/gameplay.json`, "utf8")) as { collections: Coll[] };
const byName = new Map(gp.collections.map(c => [c.name, c]));
/** Valores finales de una colección: se sube por la cadena de padres y el hijo pisa al padre (AttribSys) [D]. */
const cache = new Map<string, Record<string, any>>();
function R(name: string | null | undefined): Record<string, any> | undefined {
  if (!name || name === "null") return undefined;
  if (cache.has(name)) return cache.get(name);
  const chain: Coll[] = [];
  let c = byName.get(name);
  const seen = new Set<string>();
  while (c && !seen.has(c.name)) { seen.add(c.name); chain.push(c); c = c.parent ? byName.get(c.parent) : undefined; }
  if (!chain.length) return undefined;
  const v: Record<string, any> = {};
  for (const x of chain.reverse()) Object.assign(v, x.values);
  v.__parents = chain.map(x => x.name);
  cache.set(name, v);
  return v;
}
const isA = (v: Record<string, any> | undefined, t: string) => !!v?.__parents?.includes(t);
const r3 = (p: number[]) => p.map(x => Math.round(x * 1000) / 1000);
const deg2 = (d: number) => Math.round(((d % 360) + 360) % 360 * 1000) / 1000;

/** Marcador: posición [V] y rumbo (º, desde +X hacia +Y como el yaw del motor: la salida apunta al 1.er punto de control
 * ±30º en 255 pruebas) [V: estadística en la conversión]. */
function marker(name: string | null | undefined) {
  const v = R(name);
  if (!v?.Position) return undefined;
  const m: Record<string, any> = { name, pos: r3(v.Position), yaw: deg2(v.Rotation ?? 0) };
  if (v.Dimensions) m.dims = r3(v.Dimensions);           // caja: [fondo, ancho, alto] (m) [I: fondo 2–3 m en la marcha]
  if (v.TimeBonus) m.timeBonus = v.TimeBonus;            // time_bonus_checkpoint (peaje)
  if (v.Radius) m.radius = v.Radius;
  if (v.Width) m.width = v.Width;                        // planetrigger (reinicio)
  return m;
}

// ── Vallas de TrackPath (L2RA.BUN) ──────────────────────────────────────────────────────────────────────────────
const disc = await GameDisc.open(iso);
const l2ra = await disc.readEntry(disc.find("TRACKS\\L2RA.BUN")!);
const dv = new DataView(l2ra.buffer, l2ra.byteOffset, l2ra.byteLength);
const linesByHash = new Map<number, number[][]>();
let barrierCount = 0;
for (const [c] of walk(parseChunks(l2ra))) {
  if (c.id !== 0x0003414d) continue;
  if (c.size % 24) throw new Error(`TrackPathBarriers de ${c.size} B no es múltiplo de 24`);
  for (let o = c.dataOffset; o < c.dataOffset + c.size; o += 24) {
    const a = [dv.getFloat32(o, true), dv.getFloat32(o + 4, true)], b = [dv.getFloat32(o + 8, true), dv.getFloat32(o + 12, true)];
    const h = dv.getUint32(o + 20, true);
    let l = linesByHash.get(h); if (!l) linesByHash.set(h, l = []);
    l.push(r3([...a, ...b]));
    barrierCount++;
  }
}
if (!barrierCount) throw new Error("No hay TrackPathBarriers (0x0003414D) en L2RA.BUN");

// Grupos de escenario dibujables (world.json → groups/<nombre>.glb)
type Group = { name: string; hash: string; kind: string; barrier: boolean; driveThrough: boolean; glb: string; min: number[]; max: number[] };
const world = existsSync(`${out}/world.json`) ? JSON.parse(readFileSync(`${out}/world.json`, "utf8")) : { groups: [] };
const groupByName = new Map<string, Group>((world.groups ?? []).map((g: Group) => [g.name.toUpperCase(), g]));
const barrierGroups: Record<string, any> = {};
let missingLines = 0;
function useGroup(raw: string) {
  const flipped = raw.startsWith("*");
  const name = (flipped ? raw.slice(1) : raw).toUpperCase();
  if (!barrierGroups[name]) {
    const g = groupByName.get(name);
    const lines = linesByHash.get(bStringHash(name)) ?? [];
    if (!lines.length) missingLines++;
    barrierGroups[name] = { hash: hex8(bStringHash(name)), number: (g as any)?.number ?? null, glb: g?.glb ?? null, driveThrough: g?.driveThrough ?? false, min: g?.min, max: g?.max, lines };
  }
  return { group: name, flipped };
}

// ── Pruebas ─────────────────────────────────────────────────────────────────────────────────────────────────────
const KIND: [string, string][] = [   // tipo de la plantilla → tipo de prueba (GRace::Type [D])
  ["challengerace", "challenge"], ["tollboothrace", "tollbooth"], ["speedtraprace", "speedtrap"], ["drag", "drag"],
  ["lapknockout", "knockout"], ["circuit", "circuit"], ["p2p", "sprint"], ["multipoint", "sprint"],
];
const binOfRace = new Map<string, { bin: string; boss: boolean }>();
const bins: any[] = [];
for (const c of gp.collections.filter(c => c.parent === "race_bin")) {
  const v = R(c.name)!;
  for (const r of v.WorldRaces ?? []) if (!binOfRace.has(r)) binOfRace.set(r, { bin: c.name, boss: false });
  for (const r of v.BossRaces ?? []) binOfRace.set(r, { bin: c.name, boss: true });
}

function opponent(name: string) {
  const v = R(name);
  if (!v) return { name, missing: true };
  return {
    name, racerName: v.RacerName || null, preset: v.PresetRide || null, carType: v.CarType || null,
    skill: v.SkillLevel ?? 100, minPerformance: v.MinimumAIPerformance ?? 0, boss: !!v.IsBoss,
  };
}

// Disparadores del mundo: engagetrigger_* → TargetActivity
const engage = new Map<string, any>();
for (const c of gp.collections) {
  const v = R(c.name);
  if (!v || !v.TargetActivity || !v.Position || v.Template) continue;
  if (!isA(v, "engagetrigger")) continue;
  engage.set(v.TargetActivity, { name: c.name, pos: r3(v.Position), radius: v.Radius ?? 25 });
}

const events: any[] = [];
const warnings: string[] = [];
for (const c of gp.collections) {
  const v = R(c.name);
  if (!v || !v.EventID || v.Template || !isA(v, "race")) continue;
  const kindPair = KIND.find(([t]) => isA(v, t));
  if (!kindPair) { warnings.push(`${c.name}: tipo desconocido (${v.__parents.join(" < ")})`); continue; }
  const kind = kindPair[1];
  const start = marker(v.racestart), finish = marker(v.racefinish);
  const checkpoints = (v.Checkpoint ?? []).map(marker).filter(Boolean);
  if (!start) warnings.push(`${c.name}: sin salida (racestart ${v.racestart})`);
  if ((v.Checkpoint ?? []).length !== checkpoints.length) warnings.push(`${c.name}: ${(v.Checkpoint ?? []).length - checkpoints.length} puntos de control sin posición`);
  const resets = (v.Children ?? []).map(R).filter((x: any) => isA(x, "resetplayertrigger")).map((x: any) => marker(x.CollectionName));
  const bin = binOfRace.get(c.name);
  const e: Record<string, any> = {
    id: c.name, eventId: v.EventID, kind, template: c.parent,
    bin: bin?.bin ?? c.name.split("/")[0], binIndex: R(bin?.bin ?? c.name.split("/")[0])?.BinIndex ?? null, bossRace: !!(v.BossRace || bin?.boss),
    region: v.Region ?? null, laps: kind === "circuit" || kind === "knockout" ? (v.NumLaps ?? 1) : 1,
    length: v.RaceLength ?? 0, cash: v.CashValue ?? 0, reputation: v.Reputation ?? 0,
    looping: !!v.IsLoopingRace, knockoutsPerLap: v.KnockoutsPerLap ?? 0, timeLimit: v.TimeLimit ?? 0,
    copsInRace: !!v.CopsInRace, scriptedCops: !!v.ScriptedCopsInRace, pursuitRace: !!v.PursuitRace,
    trafficLevel: v.TrafficLevel ?? 100, trafficPattern: v.TrafficPattern || null,
    maxHeat: v.MaxHeatLevel ?? 10, forceHeat: v.ForceHeatLevel ?? 0, useWorldHeat: !!v.UseWorldHeat,
    doCountdown: v.DoCountdown !== false, rollingStart: !!v.RollingStart, initialSpeed: v.InitialPlayerSpeed ?? 0,
    playerCar: v.PlayerCarType || null, playerCarPerformance: v.PlayerCarPerformance ?? 1,
    rankByPoints: !!v.RankPlayersByPoints, rivalBestTime: v.RivalBestTime ?? 0,
    targets: { gold: v.TargetGold ?? 0, silver: v.TargetSilver ?? 0, bronze: v.TargetBronze ?? 0 },
    catchUp: { enabled: v.CatchUp !== false, override: !!v.CatchUpOverride, skill: String(v.CatchUpSkill ?? "0.2").split(/[ ,;]+/).filter(Boolean).map(Number),
      spread: String(v.CatchUpSpread ?? "1000").split(/[ ,;]+/).filter(Boolean).map(Number), integral: v.CatchUpIntegral ?? 0, derivative: v.CatchUpDerivative ?? 0 },
    availableQuickRace: !!v.AvailableQR, initiallyUnlocked: v.InitiallyUnlocked !== false, challengeSeries: !!v.ChallengeSeriesRace,
    unlockRaces: v.UnlockRaces ?? [], postRaceActivity: v.PostRaceActivity || null, timeOfDay: v.TOD ?? -1,
    checkpointsVisible: v.CheckpointsVisible !== false,
    start, finish, checkpoints,
    startReverse: marker(v.racestartReverse) ?? null, finishReverse: marker(v.racefinishReverse) ?? null,
    speedtraps: (v.SpeedTrapList ?? []).map((n: string) => { const s = R(n); return s?.Position ? { name: n, pos: r3(s.Position), radius: s.Radius ?? 20, threshold: s.ThreshholdSpeed ?? 0, bounty: s.Bounty ?? 0 } : null; }).filter(Boolean),
    shortcuts: (v.Shortcuts ?? []).map((n: string) => { const s = R(n); return s?.Position ? { pos: r3(s.Position), min: s.ShortcutMinChance ?? 0, max: s.ShortcutMaxChance ?? 1 } : null; }).filter(Boolean),
    resets: resets.filter(Boolean),
    copSpawns: (v.CopSpawnPoints ?? []).map(marker).filter(Boolean),
    opponents: (v.Opponents ?? []).map(opponent),
    barriers: (v.Barriers ?? []).map(useGroup),
    engage: engage.get(c.name) ?? null,
  };
  if (kind === "challenge") {
    e.challenge = { milestone: v.MilestoneName || null, threshold: v.ThreshholdValue ?? 0, biggerIsBetter: v.MilestoneBiggerIsBetter !== false, epic: !!v.IsEpicPursuitRace };
  }
  if (kind !== "challenge" && !finish && kind !== "speedtrap") warnings.push(`${c.name}: sin meta`);
  events.push(e);
}
events.sort((a, b) => a.eventId.localeCompare(b.eventId, "en", { numeric: true }) || a.id.localeCompare(b.id));

// ── Lista Negra (race_bin_NN) ──────────────────────────────────────────────────────────────────────────────────
const milestones = gp.collections.filter(c => c.name.startsWith("milestones/bin_") && c.parent !== "folder").map(c => R(c.name)!)
  .filter(v => isA(v, "milestone") && v.MilestoneName).map(v => ({
    id: v.CollectionName, binIndex: v.BinIndex, type: v.MilestoneName, goalEasy: v.GoalEasy ?? 0, goalHard: v.GoalHard ?? 0,
    bounty: v.Bounty ?? 0, spawn: marker(v.SpawnPoint) ?? null,
  }));
// Radares de la zona libre (speedtraps/bin_NN/speedtrapN, OpenWorldSpeedTrap): también son «desafíos» del bin. Con ellos
// RequiredChallenges cuadra en todos los bins (bins 1–4 piden 5 y tienen 4 hitos + 3 radares) [V].
for (const c of gp.collections) {
  const v = R(c.name);
  if (!v || v.Template || !v.OpenWorldSpeedTrap || !v.Position) continue;
  milestones.push({ id: c.name, binIndex: v.BinIndex, type: "speedtrap", goalEasy: v.ThreshholdSpeed ?? 0, goalHard: v.ThreshholdSpeed ?? 0,
    bounty: v.Bounty ?? 0, spawn: marker(v.SpawnPoint) ?? null, pos: r3(v.Position), radius: v.Radius ?? 20 } as any);
}
for (const c of gp.collections.filter(c => c.parent === "race_bin")) {
  const v = R(c.name)!;
  const boss = R(v.Boss);
  const rewards = (R(`${c.name}/rewards`)?.Children ?? []).map((n: string) => {
    const r = R(n); if (!r) return null;
    return { id: n, type: r.RewardMarkerType ?? r.__parents[1] ?? null, cash: r.CashReward ?? 0, carType: r.CarType || null };
  }).filter(Boolean);
  bins.push({
    id: c.name, binIndex: v.BinIndex, boss: v.Boss || null, bossPreset: boss?.PresetRide || null, bossSkill: boss?.SkillLevel ?? null,
    bossRacerName: boss?.RacerName || null, bossReputation: v.BossReputation ?? 0,
    worldRaces: v.WorldRaces ?? [], bossRaces: v.BossRaces ?? [],
    requiredBounty: v.RequiredBounty ?? 0, requiredRacesWon: v.RequiredRacesWon ?? 0, requiredChallenges: v.RequiredChallenges ?? 0,
    barriers: (v.Barriers ?? []).map(useGroup),
    heat: { base: v.BaseOpenWorldHeat ?? 0, max: v.MaxOpenWorldHeat ?? 1, scale: v.ScaleOpenWorldHeat ?? 1 },
    debugSpawn: marker(v.DebugJumpPoint) ?? null,
    rewards,
    milestones: milestones.filter(m => m.binIndex === v.BinIndex).map(m => m.id),
  });
}
bins.sort((a, b) => b.binIndex - a.binIndex);

const outJson = {
  disc: id,
  source: "GLOBAL\\GAMEPLAY.BIN (vía gameplay.json) + TRACKS\\L2RA.BUN 0x0003414D (TrackPathBarrier)",
  note: "Coordenadas del mundo del motor (Z arriba, metros). yaw en grados desde +X hacia +Y. Ver docs/es/18-carreras-y-lista-negra.md.",
  counts: { events: events.length, bins: bins.length, milestones: milestones.length, barrierGroups: Object.keys(barrierGroups).length, trackPathBarriers: barrierCount, trackPathGroups: linesByHash.size },
  events, bins, milestones, barrierGroups, warnings,
};
await Bun.write(`${out}/races.json`, JSON.stringify(outJson));
const byKind: Record<string, number> = {};
for (const e of events) byKind[e.kind] = (byKind[e.kind] ?? 0) + 1;
console.log(`Carreras: ${events.length} pruebas (${Object.entries(byKind).map(([k, n]) => `${k} ${n}`).join(", ")}) · ${bins.length} bins · ${milestones.length} hitos · ` +
  `${Object.keys(barrierGroups).length} grupos de vallas usados (${missingLines} sin líneas) de ${linesByHash.size} · ${barrierCount} vallas · ${warnings.length} avisos → ${out}/races.json`);
