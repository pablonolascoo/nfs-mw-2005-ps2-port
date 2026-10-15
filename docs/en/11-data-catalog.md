# Generated data catalog (`map-data/<ID>/`)

Everything comes from **one ISO** with `bun run build-all /path/to/your.iso` (in `tools/`).
None of it is pushed to GitHub except small metadata JSON files. Figures are for SLES-53559 [V].

## 1. Which file answers which question

| Question | File | Generator | Doc |
|---|---|---|---|
| What files are on the disc and what are they? | `inventory/<ID>.csv` | `src/cli/inventory.ts` | 00, 02 |
| Where is each map section? | `world.json` → `sections[718]` | `convert.ts tiles` | 03 |
| Which 400 m tile do I load? | `world.json` → `tiles[212]`, `tiles/*.glb` (424) | `convert.ts tiles` | 03, 06 |
| Where are race barriers and padlocks? | `world.json` → `groups[752]`, `groups/*.glb` | `convert.ts tiles` | 03 |
| Where are safehouses, car lots and shops? | `zones.json` (15), `garages.json` (15) | `vlt-dump.ts`, `garages.ts` | 05, 07 |
| Which races, Blacklist and milestones exist? | `gameplay.json` → `summary` | `vlt-dump.ts` | 05 |
| Start, gates, opponents, barriers and rules of each event; bins and challenges? | `races.json` (254 events), `collision/groups/<n>.bin` | `races.ts`, `collision.ts` | 18 |
| Any value from the game database? | `gameplay.json` → `collections[6287]` | `vlt-dump.ts` | 05 |
| Where do streets and lanes run? | `roads.json` | `roads.ts` | 09 |
| Where are ground and walls (collision)? | `roads.json` → `collisionPacks[390]` (summary) | `roads.ts` | 09 |
| What do cars and wheels look like? | `cars/*.glb` (91), `cars.json` (92) | `convert.ts car`, `car-attribs.ts` | 10 |
| How is each Blacklist car built (parts, paint, vinyl)? | `presets.json` (82), `vinyls/*.png` (112, local only) | `presets.ts` | 10 §8 |
| How does each car drive (physics, cameras, pad dead zones)? | `physics.json` (113 `pvehicle`) | `physics-attribs.ts` | 13, 15 |
| Which traffic drives in each district and how do cops behave per heat level? | `ai.json` (10 patterns, 21 pursuit levels, 59 zones) | `ai-attribs.ts` | 14 |
| What does the police radio say at each moment? | `radio/radio.json` + `radio/COPSPEECH.BIG` (9854 clips, 559 banks, 139 events) | `radio.ts` | 16 |
| Garage interiors? | `interiors/*.glb` (5) | `convert.ts interior` | 07 |
| Top-down map? | `rockport-plano.png` + `.json` (scale) | `topdown.ts` | 03 |
| What can the viewer open? | `index.json` → `items[814]` | all | 04 |

## 2. Rockport in numbers
- **718 world sections**, 106,714 instances, 5.84 M triangles, 2565 textures.
- **212 tiles** of 400 m (near textured + far vertex-coloured).
- **752 scenery groups**: 745 race barriers (`BARRIER_SPLINE_n`), 6 story padlocks (`BARRIER_LOCKED_10…15`), 1 door group.
- **15 zones**: 4 safehouses, 3 car lots, 8 customisation shops.
- **Road network**: 4385 nodes, 6538 segments, 710 road profiles, 1308 roads, one connected graph.
  Bounds: X −1404…4857, Y −987…4569, Z −13…265 m.
- **Collision**: 243,418 ground triangles, 45,793 walls.
- **Database**: 272 vaults, 6287 collections, 255 events, 20 Blacklist bins, 55 milestones.
  Events by type: 68 tollbooth, 49 sprint, 39 circuit, 37 challenge, 32 speedtrap, 18 lap knockout, 11 drag.

## 3. Axes and units
- World and viewer: **Z up**, metres. X east, Y north [I].
- Roads and collision are stored in "Bond" space (Y up): **X = z, Y = −x, Z = y** [D][V].
- Cars: X forward, Y left, Z up.
- Instance rotation: `s16 / 8192`; scenery `ExcludeFlags` (0x10 hidden, 0x400 mirrored) [V].

## 4. Key fields (summary)
- `world.json.tiles[]`: `id "x_y"`, `x`, `y`, `size`, `near`, `far`, `tris`, `farTris`, `zMin`, `zMax`.
- `world.json.groups[]`: `name`, `hash`, `kind` (carrera = race / candado = padlock / puerta = door), `barrier`, `driveThrough`, `glb`, `min`, `max`.
- `garages.json.garages[]`: `collection`, `zoneType`, `zone`, `radius`, `building` (building box), `out` (exit direction), `door` (centre, normal, size).
- `roads.json`: `nodes[] {pos, profile, segments}`, `segments[] {nodes, length, road, flagNames, startControl, endControl}` (cubic Bézier), `profiles[] {lanes[] {type, width, offset}}`, `roads[]`, `grid`.
- `cars.json.cars[name]`: `tires` = 4 × `[x, y, z, radius]`, `className`, `spokes`, `skidWidth`, `kitWidthScale`, `kitOffsetFront/Rear`, `camber`, `feCompression`, `rimSize` (see doc 10).
- `ai.json`: `trafficPatterns`, `heatTable` (heat_01…10), `pursuitLevels`, `pursuitSupport`, `aiVehicle`, `vehicles` (pvehicle → model), `infractions`, `zones` (hiding spots, per-district pattern, no-cop-spawn, pursuit start) (see doc 14).
- `radio/`: `COPSPEECH.BIG` (the disc's MicroTalk clips) and `radio.json` with `clips` [offset, bytes, samples], `banks` (phrase, clips, parameter values) and `events` (alternatives → pieces → conditions) (see doc 16 §5–6). Never committed.
- `cars/*.glb`: each node has `extras.pieza` (slot, kit, style, stock) and, when present, `extras.marcadores`.

## 5. Regenerate a single part
```bash
cd tools
bun src/cli/vlt-dump.ts   ../original/SLES-53559.iso SLES-53559   # zones.json + gameplay.json
bun src/cli/roads.ts      ../original/SLES-53559.iso SLES-53559   # roads.json
bun src/cli/car-attribs.ts ../original/SLES-53559.iso SLES-53559  # cars.json
bun src/cli/physics-attribs.ts ../original/SLES-53559.iso SLES-53559  # physics.json
bun src/cli/ai-attribs.ts ../original/SLES-53559.iso SLES-53559   # ai.json (traffic and police)
bun src/cli/radio.ts ../original/SLES-53559.iso SLES-53559      # radio/ (police radio)
bun src/cli/garages.ts    ../original/SLES-53559.iso SLES-53559   # garages.json
```
