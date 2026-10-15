# Races and the Blacklist

Tags: [V] verified on SLES-53559 bytes or measured · [D] from the decomp · [I] inferred · [H] hypothesis.

All 254 events of the game can be raced in the native engine with their opponents, barriers and rules, and the career
mode walks the Blacklist from 15 to 1 with a save file. Everything comes from the disc data and from the decomp logic
(`src/Speed/Indep/Src/Gameplay/`, `AI/Actions/AIActionRace.cpp`, `AI/Common/AIVehicleRacecar.cpp`,
`AI/Common/AIVehicle.cpp`, `World/TrackPath.cpp`).

## 1. Data: `races.json` (step "Carreras y Lista Negra")

`tools/src/cli/races.ts <iso> <ID>` → `map-data/<ID>/races.json` (not committed). Registered in `build-all.ts` and in the
installer (`install.ts`); `DATA_FORMAT` is now 4 (`Config.dataFormat`), so older installs are reconverted automatically.

| Source | What is extracted |
|---|---|
| `GLOBAL\GAMEPLAY.BIN` (via `gameplay.json`, step "vlt-dump") | Events, bins, opponents, milestones, world triggers [V] |
| `TRACKS\L2RA.BUN` chunk `0x80034147` → `0x0003414D` | 1,376 `TrackPathBarrier` lines in 751 groups [V] |
| `world.json` (step "convert") | GLB and box of each scenery group |
| `collision/groups/<n>.bin` (step "collision") | Real collision of each group's objects (see §5) |

### 1.1 Inheritance
Each collection only stores what differs from its parent. `races.ts` resolves the whole chain
(`race_bin_15/15_1_1_circuit` → `circuit` → `basicrace` → `engaged` → `race` → `activity` → `baseelement`) [V].
The event type comes from the template it inherits from (GRace::Type [D]): `p2p`/`multipoint` sprint (49), `circuit` (39),
`lapknockout` (18), `drag` (11), `speedtraprace` (32), `tollboothrace` (68, 35 of them Challenge Series), `challengerace_*`
pursuit challenges (37). `16_nis_rog_razor` (`nis_shell`) is a cut-scene, not an event.

### 1.2 Event fields [V]
- Start `racestart` (startgrid), finish `racefinish` (finishline, `Dimensions` = [depth, width, height]), checkpoints
  `Checkpoint[]` (`time_bonus_checkpoint` with `TimeBonus` in tollbooths), speed traps `SpeedTrapList[]` (`Radius` 20 m),
  `Shortcuts[]`, reset plane `resetplayertrigger` (`Width` 150).
- Rules: `NumLaps`, `KnockoutsPerLap`, `TimeLimit`, `CopsInRace`, `ForceHeatLevel`, `MaxHeatLevel`, `TrafficLevel` (%),
  `DoCountdown`, `RollingStart`, `InitialPlayerSpeed`, `RankPlayersByPoints`, `CashValue`, `Reputation`, `BossRace`,
  `CatchUp*`.
- Opponents `Opponents[]` → `character` / `boss`: `PresetRide` (doc 10), `CarType`, `SkillLevel` (0–100),
  `MinimumAIPerformance`.
- `Barriers[]`: scenery group names; a leading `*` means flipped (`GetBarrierIsFlipped` [D]).
- World trigger: `engagetrigger_*` with `TargetActivity` and `Radius` 25 m (146 events; boss races and challenges start
  from menus) [V].
- Marker heading: degrees from +X towards +Y, like the engine yaw. Checked on all 255 events: the start points at the first
  checkpoint within ±30° [V].

### 1.3 Blacklist (race_bin_NN) [V]
`WorldRaces[]`, `BossRaces[]`, `Boss` (`PresetRide` BL15…BL2), `RequiredRacesWon`, `RequiredBounty`, `RequiredChallenges`,
`Barriers[]` (padlocks), open-world heat, rewards (pink slip, `cash_bonus`…).
**Bin challenges** = pursuit milestones (`milestones/bin_NN/*`) **plus the open-world speed traps**
(`speedtraps/bin_NN/speedtrapN`, `OpenWorldSpeedTrap`, `ThreshholdSpeed`, `Bounty`). Only then `RequiredChallenges`
adds up in every bin: bins 1–4 require 5 and have 4 milestones + 3 speed traps [V].
Padlocks per bin [V]: bins 15–13 close `BARRIER_LOCKED_11…15`; bins 12–9 close `10`, `12`, `13`; bins 8–1 none.

## 2. Race route
In the game, racers path-find on the road network (WRoadNav, kLaneRacing, race filter) towards the next checkpoint without
crossing active barriers (`TrackPathBarrier`, `EnableBarriers(group)`) [D]. The engine does the same once at the start
(`Race/RaceRoute.swift`): leg by leg Dijkstra over segments that do not cross an active barrier line (`DoLinesIntersect`
[D]); each gate is crossed along its heading (both directions tried, the one against the heading penalised [I]); loops
shorter than 80 m removed [I]; the racing line is the centre of the lanes of the travel direction (types 1, 4, 10), not the
network axis, which runs over median walls [V].

Checked with `Rockport --race-audit` (217 events, 0.9 s) against the game's `RaceLength` [V]: median route/data **0.997**
(p10 0.94, p90 1.16), 146 of 171 within ±10 %, 13 legs without a path overall (joined straight). For circuits `RaceLength`
does not count laps consistently (4.1.1 is one lap of 8,551 m with `NumLaps` 4) [H]; the engine route covers every lap.

## 3. Opponents: game physics and AI driver
Every opponent is a full `Car` with the game physics (PVehicle, doc 13) and its preset skin. `Race/RaceAI.swift` follows
AIActionRace (speed limit from curvature with `GetSpeedLimit`, grip from `GripTor`, skill tables, `fSpeedLimit` ramp with
exponent `Lerp(1.5, 2, skill)`), AIVehiclePid (throttle/brake PID −0.4/−0.01/−0.1, heading PID with the speed tables),
ComputeSkill (`SkillLevel/100` in career, `Tweak_QuickRaceSkills` in quick race), the "glue" rubber band (1 s PID of
`RaceLength/100 × (player% − AI%)`, 10 integral / 5 derivative terms, `CatchupGlueTable` / `SlowDownGlueTable`, catch-up cheat
= `Clamp(base + glue − 1, 0, 1) × 0.5`) and the NOS logic [D]. `ComputeCatchUpSkill` is not decompiled: here
`x = e/CatchUpSpread + ∫e·CatchUpIntegral + de·CatchUpDerivative`, clamped and × `CatchUpSkill` [I]. Own additions [I]:
braking look-ahead, 90 % grip margin, avoidance of cars, unstuck reset after 4 s, car-to-car contacts.

## 4. Rules per type (`Race/RaceSession.swift`)
Sprint (gates in order), circuit (`NumLaps`), knockout (last `KnockoutsPerLap` out each lap [D]), drag (manual gears,
left/right change lane, engine heat → blown engine, >14 m/s loss in 0.1 s → totalled [I], shift light [I]), speed trap (sum
of trap speeds, `RankPlayersByPoints`), tollbooth (`TimeLimit` + `TimeBonus` per booth), pursuit challenge (forced
pursuit, goal = `ThreshholdValue` of `MilestoneName`, busted = loss). Common: 3-2-1-GO, rolling start, 2-wide grid with
the player last [I], gates by crossing the box plane (or 80 m past it on the route) [I], wrong-way arrow, reset onto the
route, event traffic and police, busted = DNF, estimated times for unfinished AI [I], cash/bounty rewards in career.

## 5. Barriers in the world and group collision
Active groups (event + bin) are drawn with their GLB and add walls to `CollisionWorld.dynamicWalls`.
**Collision fix** [V]: 891 collision instances in `STREAML2RA.BUN` carry the `GroupNumber` of a hidden-by-default group
(u16 @0x18). They used to be merged into the city collision as **invisible walls** in free roam (e.g. mid-street at
(1574, 2256)). `collision.ts` now writes them to `collision/groups/<n>.bin` and the engine only uses them while the group is
active. Drive-through groups only block the AI route [I].

## 6. Career (`Career/`)
`Career.shared.start()` / `newGame()`; save in `~/Library/Application Support/Rockport/save.json`. World markers of the
current (and previous) bins start events (enter the circle, press Return / ✕). Evaded pursuits add bounty (cost to state)
and complete milestones (`GoalEasy`) [I]; open-world speed traps above `ThreshholdSpeed` (km/h [I]) complete challenges.
The rival unlocks with the three requirements; beating all `BossRaces` wins the boss car (pink slip), the `cash_bonus` and
moves to the next bin with its padlocks.

## 7. UI API
`QuickRace.shared.events`, `QuickRace.shared.start(eventID:)`, `Career.shared.start()/newGame()/showBlacklist()/challengeRival()`,
`RaceSystem.shared?.abandon()`. The HUD belongs to the UI (`UI/RaceHUD.swift`).

## 8. Headless tests
`Rockport --race-test <EventID> --autodrive --screenshot out.png [--seconds N] [--opponents N] [--no-traffic]` and
`Rockport --career-test [--save path.json]`, `Rockport --race-audit`.

Results (2026-10-15, Apple Silicon, 1280×720, release): 15.2.1 sprint won in 139.2 s; 15.1.1 circuit won 156.5 s;
15.3.1 and 14.3.1 knockouts won with knock-outs each lap; 10.2.1 boss sprint vs Karl Smit (BL10) won 228.6 s; 1.7.3 drag vs
Razor: totalled by traffic, won 30.8 s with `--no-traffic`; 1.5.1 speed trap 2nd on points; 19.8.32 tollbooth won 142.9 s
once, timed out another run; 19.8.1 pursuit-length challenge completed. CPU 0.5–0.8 ms median per frame.
`--career-test`: all 15 rivals beaten in order, cars won, padlocks correct per bin, save round-trip OK.

## 9. To do
Flipped barrier art, shortcuts, exact grid, NIS/films/photo-finish, random racer names, adaptive difficulty, exact
`ComputeCatchUpSkill`, `cops_destroyed` (needs damage), garage/shop.
