# Traffic and police

Tags: [V] verified on SLES-53559 bytes or measured · [D] taken from the decomp · [I] inferred · [H] hypothesis.

Rockport is now alive in the native engine: traffic drives in its lanes, and police patrol, chase, ram, set up
roadblocks and bust you. Everything comes from the game data (`roads.json` and `ai.json`) and from the decomp logic
(`src/Speed/Indep/Src/AI/`).

## 1. Where the data comes from

| File | Produced by | Contents |
|---|---|---|
| `roads.json` | `tools/src/cli/roads.ts` | Nodes, Bézier segments, lane profiles and flags (doc 09) |
| `ai.json` | `tools/src/cli/ai-attribs.ts` (new) | Traffic and police tables from `GLOBAL\ATTRIBUTES.BIN` and zones from `TRACKS\L2RA.BUN` |
| `collision/*.bin` | `tools/src/cli/collision.ts` | Ground and walls: car height, line of sight, walls cutting streets |
| `cars/*.glb`, `cars.json` | `convert.ts car`, `car-attribs.ts` | Traffic and police models, wheels (doc 10) |

`ai-attribs.ts` is part of `build-all.ts` and of the installer (`install.ts`, step "Tráfico y policía").
`ai.json` is not committed (game data).

### 1.1 VLT tables used [V]

| Class (ATTRIBUTES.BIN) | Fields | Used for |
|---|---|---|
| `trafficpattern` (10) | `SpawnTime`, `SpeedStreet`/`SpeedHighway` (mph), `Vehicles[]` = `TrafficPatternRecord {RefSpec Vehicle, Rate, MaxInstances, Percent}` | Which cars spawn in each district, how often and how fast |
| `pursuitescalation` (1) | `heattable[10]`, `supporttable[10]`, `racetable`, `supportracetable` | Heat level N → `heat_0N` |
| `pursuitlevels` (21) | `cops[]` = `CopCountRecord {StringKey CopType, Count, Chance}`, `CopFormations[]`, `NumPatrolCars`, `FullEngagementCopCount`, `evadetimeout`, `BustSpeed`, `frontLOSdistance`, `rearLOSdistance`, `TimePerHeatLevel`, `ScaleEscalationPerBucket[15]`, `roadblockprobability`, `roadblockspikechance`, `SearchMode*`, `Collapse*`, `Boxin*`, `MeterDeadZone*`, `HiddenZoneTimeMultiplier`… | The whole pursuit |
| `pursuitsupport` (21) | `MinimumSupportDelay`, `Air/Heavy/LeaderSupportOptions` | Delay before roadblocks and support |
| `aivehicle` (23) | `MAXIMUM_AI_SPEED`, `TopSpeedMultiplier`, `AccelerationMultiplier` | Speed of each cop type |
| `pvehicle` (113) | `MODEL`, `MASS` | Collection → GLB model |
| `infractions` (8) | `amount` | Fines (speeding 150, racing 350, reckless_driving 1000, assault 350, hit_and_run 300, damage 100, resisting_arrest 300, off_road 75) |
| `world` | `TRAFFIC_TYPES` | `trafha`, `semilog` |

Collection names that have no text on the disc, recovered by Jenkins hash (`0xABCDEF00`) [V]: `heat_01`…`heat_10`,
`copmidsize`, `copghost`, `copgto`, `copgtoghost`, `copsport`, `copsportghost`, `copsporthench`, `copsuvpatrol`,
`copheli` and the 8 infractions.

Record layouts: `MWAttribUserTypes.h` and `AI/aireflectedtypes.h` [D]. `StringKey` = `u64 hash64 · u32 hash32 · char*`;
`hash32` is the Jenkins hash of the name [V].

### 1.2 Free-roam heat (heat_01…05) [V]

| Heat | Police | Patrols | Max chasing | Evade (s) | BustSpeed | Roadblock % | Spikes % | Formations |
|---|---|---|---|---|---|---|---|---|
| 1 | copmidsize ×4 | 1 | 5 | 20 | 9 | 0 | 0 | ROLLING_BLOCK |
| 2 | copghost ×5 | 1 | 10 | 45 | 12 | 10 | 0 | BOX_IN |
| 3 | copgto ×7 | 1 | 15 | 75 | 19 | 25 | 0 | BOX_IN, PIT, ROLLING_BLOCK, HERD |
| 4 | copgtoghost ×8 + copheli | 1 | 20 | 90 | 20 | 30 | 70 | PIT, BOX_IN, HERD, ROLLING_BLOCK |
| 5 | copsporthench ×10 + copheli | 1 | 25 | 120 | 25 | 40 | 80 | ROLLING_BLOCK, BOX_IN, PIT, HERD |

`heat_06…10` belong to events (race pursuits, the finale). Time per level = `TimePerHeatLevel × ScaleEscalationPerBucket[bin]`:
at heat 1–3 and early in the story, 120 s per level [V].

### 1.3 Traffic patterns per district [V]

The `TRAFFIC_PATTERN` zones (type 9) of `TrackPathManager` (chunk `0x0003414A` inside `0x80034147`, in `L2RA.BUN`)
are polygons in world X, Y; `Data[0]` = `bStringHash` of the pattern name [V]. There are 11: collegesouth, downtown, collegenorth,
collegehighway (×4), cityhighway (×2), coastalsouth, coastalnorth. Outside them, `default`.
Zone layout [D: `World/TrackPath.hpp`]: `s32 Type · f32 Position[2] · f32 Direction[2] · f32 Elevation · s8 · s8 · s16 ·
u32 · f32 BBoxMin[2] · f32 BBoxMax[2] · s32 Data[4] · s16 NumPoints · s16 MemoryImageSize · f32 Points[n][2]`.
Hiding spots (`HIDDEN`, 34), `NO_COP_SPAWN` (3), `PURSUIT_START` (3) and neighbourhoods (8) are exported too.

Example, `downtown`: taxi (25 %), garbage truck (max 1), news van (max 1), fire truck (max 1),
sedan A (25 %), courier (20 %). All patterns: 35 mph on streets and 55 mph on highways.

## 2. Lanes: driving on the network [D][V]

Same as `WRoadNav` (`World/Common/WRoadNetwork.cpp`):

- A segment is a cubic Bézier (straight without the `curved` flag). Each node has a road profile.
- Zones `[middleZone, numZones)` = direction node 0 → 1; `[0, middleZone)` = the opposite one. `n = 0` is the lane nearest the centre.
- `StartInverted` / `EndInverted` mirror the profile at that end.
- With these three rules the lane is **always on the right of the travel direction**, `|offset|` m from the axis: right-hand traffic.
  Confirmed in the screenshots: oncoming traffic stays on the left.
- Traffic uses type-1 zones only (`drivable_lanes[kLaneTraffic] = 2`) [D].
- The lateral offset is interpolated between the start and end node profiles.
- One-way: node 0 → 1 only. `noTraffic`: no traffic. Police: traffic allowed XOR `copsXorTraffic` [D].
- At a node: first the non-decision continuation; otherwise a random junction (decision) segment whose exit continues [D: `GetNextTraffic`].
- Speed: highway if the segment has 4 or more traffic lanes (both directions), street otherwise [D].
- Curves: `v = √(μg / |κ|)` with μ = 0.6 for traffic and 1.6 for police [D: `AIActionRace.cpp`].
- Following: stopping distance `Lerp(3, 50)` by speed; speed ≤ speed of the car ahead × gap / stop [D].
- Traffic acceleration capped at +2 m/s² [D].
- **Walls cutting a street** [V]: `collision/*.bin` has 11 m walls across some junctions (story barriers, `BARRIER_LOCKED`).
  The game marks those segments `CrossesBarrier` at load time [D]. Here it is computed on first use: if a segment axis crosses a wall, neither traffic nor police enter it.

## 3. Traffic [D: `AI/Activities/AITrafficManager.cpp`]

| Rule | Value |
|---|---|
| Update | every 0.5 s |
| Density | 1.0 in free roam; ×0.75 during a pursuit |
| Spawn rate (density 0…1, 11 steps) | 0, 0.05, 0.1, 0.125, 0.2, 0.4, 0.6, 1, 3, 5, 8 |
| A pattern record spawns when | timer > `Rate`, below `MaxInstances` (0 = no limit) and within its `Percent` |
| Spawn point | 200 ± 50 m ahead (+ velocity), rotated ±45°; facing you with probability `Lerp(1, 0.5, v/50)` |
| Rejected | closer than 150 m to the player, closer than 20 m to another car, no ground |
| Lane | random among the traffic lanes of that direction |
| Initial speed | `min(street, highway) × 0.75` |
| Despawn | off-screen for over 4 s and more than 40 m away (density 1) |
| Cap | PS2: 10 vehicles in total [D]. Here 20 traffic cars (`--traffic-max`) |
| Hit by the player (≥ 5 mph) | the car spins briefly and stays braked (`ACCIDENT_OVER`) [D] |

## 4. Police [D: `AICopManager.cpp`, `AIPursuit.cpp`, `AIVehicleCopCar.cpp`]

### 4.1 States
`none` (patrol) → `chase` → `cooldown` → `evaded`, or `busted`.

- **Patrol**: `NumPatrolCars` cars driving like traffic. Respawned when off-screen and more than 375 m from a point 75 m ahead of you.
- **Spotted** (every 0.25 s): within `frontLOSdistance` if you are in front of the cop (dot > −0.3), or within `rearLOSdistance`;
  no collision wall in between; never while inside a hiding spot.
- **Starts** when spotted and: you go 65 mph or faster, hit traffic less than 1 s ago, heat is above 3, or you ram a cop.
  Also inside a `PURSUIT_START` zone.
- **Heat**: `+dt / (TimePerHeatLevel × ScaleEscalationPerBucket[bin])` while chased (not in cooldown). Max 5 in free roam.
- **Backup**: one every `TimeBetweenCopSpawn` s up to `min(Σ cops.Count, FullEngagementCopCount, 8)`; type picked by `Chance`.
  They spawn on the network 150–320 m away, out of view, facing you, at 60 mph.
- **Busted**: spotted, below `BustSpeed` (km/h) and a cop within 15 m (± 1.5 m height):
  the counter rises 1/s and falls 2/s. At 5 s (`kBustedTimeout`): **BUSTED**. After 3 s the car returns to safehouse 1 [I].
- **Cooldown**: 7 s with nobody seeing you. The evade meter grows with unseen time (faster by `HiddenZoneTimeMultiplier` in a hiding spot)
  over `evadetimeout`, and decays ×0.93 every 0.25 s while you are seen; seen 2.5 s in a row → back to the chase.
  Cops search your last known position at `SearchModeCityMPH` / `SearchModeHwyMPH`.
  At 1: **EVADED**, heat × `EvadeSuccessHeatAdjust` (0.95) and 60 s without new cops.
- **Meter** (HUD bar) [D: P:2068-2093]: green if the nearest cop is beyond `MeterDeadZoneEvadeDist`;
  red if within `MeterDeadZoneBustedDistance` while you are slow.

### 4.2 Driving
- Far (> 60 m or no direct path): along the road network towards you, using a reverse Dijkstra from your node (rebuilt every second).
- Near (< 60 m with no wall in between): direct seek (`AIActionPursuitOffRoad`), turn rate limited by μ = 1.6.
- Speed: `min(MAXIMUM_AI_SPEED, your speed × TopSpeedMultiplier + catch-up)`; acceleration × `AccelerationMultiplier`.
- **Formations** (offsets relative to you, x right, z forward) [D: P:179-439]:
  FOLLOW (0,−13) (±3.5,−13) (0,−17)…, STAGGER (0,∓13) (±3.5,∓13), BOX_IN (0,14) (±3.5,0) (0,−7.5),
  ROLLING_BLOCK (0,14) (±2.5…5,10…14), PIT (±4,−2.7), HERD (−3,0) (−3,±5).
  Picked alternating between the `CopFormations` table (by `Frequency`) and STAGGER. BOX_IN and PIT ram after 4 s.
- **Collapse**: below `CollapseSpeed`, nearby cops surround you at `CollapseInnerRadius`.
- **Unstuck**: over 1.5 s against a wall → back to the network for 3 s (`AIActionGetUnstuck`).

### 4.3 Roadblocks [D: `AIRoadBlockSetups.cpp`, CM:1100-1307]
- Rolled every 8–12 s after `MinimumSupportDelay` (60 s at heat 1–3, 45 at 4, 35 at 5) with `roadblockprobability`
  (when unseen: `SearchModeRoadblockChance` by distance).
- 250 m ahead along the network, on a suitable segment (traffic, no junction, ≥ 30 m).
- Road width from the profile → the setup with the smallest positive `width − minWidth` (15 normal and 9 spike setups from the decomp table).
- Parked cop cars with lights, sawhorses and spike strips (boxes: the `XO_Sawhorse` model is not exported yet [I]).
- Once you pass it ("dodged") its cops join the chase. Spikes: the car brakes hard [I: the game blows the tyres].

### 4.4 Lights
- Flares at the model markers `COPLIGHTRED`, `COPLIGHTBLUE`, `COPLIGHTWHITE` (bStringHash `1e4150b4`, `e662c161`, `b4348dba`) [V].
- Red when `cos(8t) > 0.2`, blue in counter-phase, pulse `cos²(24t)`, whites `sin(pulse · cos(12(t + 1.5 i)) · 3)` [D: CarRender.cpp 2364-2423].
- On during pursuits and roadblocks; off when busting or leaving. Patrols do not use them [D].
- The controller (DualShock 4 / DualSense) turns red/blue during a pursuit (`Controllers.shared.setPursuit`).

## 5. Native engine

| File | Role |
|---|---|
| `AIRoads.swift` | Road network: Bézier, length table, lanes, rules, next segment, Dijkstra, spatial grid |
| `AIData.swift` | Reads `ai.json` (patterns, heat levels, zones) |
| `AIModels.swift` | Assembles traffic and police models (one part per slot, wheels from `cars.json`) on background threads; light markers |
| `AIVehicle.swift` | Own kinematic follower: lane or direct mode, height from real collision, knock after a hit |
| `AIWorld.swift` | Orchestration; curves, following, collisions (SAT rectangles) and stats |
| `TrafficManager.swift` | Spawning, per-district pattern, despawning |
| `PoliceManager.swift` | Patrol, pursuit, heat, busted, evade, formations, roadblocks |
| `AIRender.swift` | Instanced drawing (one call per model and material), brake lights, flares, sawhorses |
| `HUDPursuit.swift` | MW HUD: heat, EVADE/BUSTED bar, COOLDOWN, BUSTED/EVADED |
| `AIEngine.swift` | Engine hook and the `--traffic-test` run |

Small hooks: `Engine.swift` (`ai`, `aiRenderer`, `setupAI`, `updateAI` before drawing), `Renderer.swift` (`overlays`: three draw points),
`main.swift` (options). Hits against AI cars slow the player's car by scaling its velocity (the game physics has no car-to-car collisions yet).

## 6. Headless test

```bash
cd native-engine && swift build -c release
./.build/release/Rockport --traffic-test 90 --screenshot .build/shots/traffic.png --size 1920x1080
./.build/release/Rockport --traffic-test 150 --heat 5 --test-plan run --screenshot .build/shots/heat5.png
ROCKPORT_DEBUG_AI=1 …   # each cop's state every 2 s, crossed walls, overlaps, roadblock rolls
```

A test car drives the network (125 km/h, then 70, then stopped; `--test-plan run` = always 130; `flee` = 300 km/h once chased).
It saves three screenshots (30 %, 60 %, end), one of the roadblock if any (`-control.png`) and a `.json` with the numbers.

Results (MacBook Air M4, 2026-10-12) [V]:

| Test | Result |
|---|---|
| 90 s, heat 1, 1920×1080 | 73 traffic cars (max 17 at once), 1 pursuit, **BUSTED** at 74 s; 100 % on the ground, 0 lane jumps, 52 steps over a wall (0.07 %) |
| 150 s, heat 5, 1600×900 | Corvette cops (copsporthench), 11 cops at once, 1 roadblock dodged; 99.96 % on the ground |
| 150 s, heat 1, `flee` (300 km/h once chased) | cooldown at 28 s, **EVADED** at 41 s, 60 s without cops, new pursuit at 147 s |
| 90 s, heat 5, 2940×1912 (Retina) | 19 traffic + 12 cops: GPU median 4.3 ms (p95 5.7), CPU 1.0 ms, 124 AI draw calls |

## 7. Open items
- Helicopter (`copheli`, `HeliFuelTime`, `AirSupportOptions`), heavy support (ramming SUVs) and leader (`copcross`).
- Real sawhorse and spike strip models (`XO_Sawhorse_1b_00`, `XO_SpikeBelt_1b_DW_00`) and actual tyre damage.
- Physical car-to-car collisions (the player physics has none yet: speed is scaled instead).
- Horn and sounds (`Siren*` timing, `HornType`), radio voices (`nSpeechId` of `RNrd`).
- Voluntary lane changes (the game's traffic does not do them either [D]).
- At some junctions the lateral offset cuts a corner through a wall (≈ 0.1 % of steps).
- Bounty (`RepPointsPerMinute`, cost to state) on the HUD.
