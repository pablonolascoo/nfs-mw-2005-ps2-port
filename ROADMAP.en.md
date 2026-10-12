# Roadmap · Rockport Native and the "expansion pack"

> Versión en español: [ROADMAP.md](ROADMAP.md)

In one sentence: **the original NFS: Most Wanted (2005), native on macOS, built from your own ISO, followed by an expansion that continues the story as if the same studio had made it in 2006.**

## Golden rules (VERY IMPORTANT)
Everything that enters the project must look like **it belongs to the original game**. If it would not pass as 2005–2006 content, it does not go in.

1. **Original look.** US Rust Belt: factories, ports, steel, brick, autumn, low warm sun. Nothing futuristic or from another era.
2. **PS2 tone.** Keep the warm, slightly yellow look of the PS2 version. Well-made low-resolution textures, not "clean" HD.
3. **Original logic.** Same game rules: Blacklist, heat, pursuits, fines, safehouses, shops, milestones.
4. **Player's data.** The game is built from **your** ISO (PAL SLES-53559 or NTSC-U SLUS-21351). EA data is never distributed.
5. **Everything documented.** Every format, decision and system goes into `docs/es` and `docs/en`.

## Phase 1 · Playable native port (in progress)
| # | What | Status |
|---|---|---|
| 1.1 | Disc formats: geometry, textures, world, database, roads, collision | ✅ |
| 1.2 | Native macOS engine (Swift + Metal): city, streaming, PS2 tone, full screen, adaptive resolution | 🚧 `native-engine/` |
| 1.3 | Installer: the `.dmg` asks for the ISO, detects PAL or NTSC-U and converts data into `~/Library/Application Support/Rockport` | 🔜 |
| 1.4 | Perfect cars: wheels, rims, kits, spoilers, paint, vinyls | 🚧 |
| 1.5 | Driving with the game's physics (from the decomp) and real collision | 🔜 |
| 1.6 | Traffic, police and pursuits with the original AI (roads and lanes already decoded) | 🔜 |
| 1.7 | Races, Blacklist, milestones, garages without loading screens | 🔜 / ✅ garages |
| 1.8 | Audio (engines, sirens, police radio, music) | 🔜 |
| 1.9 | GitHub release: signed `Rockport.dmg` | 🔜 |

## Phase 2 · "Most Wanted: Rust Belt" expansion (proposal)

**Full design with map and sketches: [docs/en/12-rust-belt-expansion.md](docs/en/12-rust-belt-expansion.md).** 4 districts unlocked after the original Blacklist: Millbrook, River Steelworks, Freight Harbor and High Ridge.

![Expansion map](docs/expansion/mapa-expansion.svg)
Meant as a period-correct DLC, built as a **data mod** on top of the original game (`mods/`).

### Story (proposal, open for discussion)
- Starts **right after the ending**: the player has the BMW M3 GTR back and has crossed the bridge.
- Across the river lies **Iron Harbor** (working name), the industrial district of a neighbouring county. Still Rust Belt.
- A **second Blacklist of 15** racers rules that county, each with a **unique**, race-prepared car.
- County police play by other rules: new units, bridge checkpoints, pursuits through the freight port and the mountains.
- Sergeant Cross returns as a federal agent; Mia comes back as a contact. The finale is a **mountain pass** showdown.

### Map (proposal)
All connected to Rockport by the bridge and the highway, same scale and palette:
- **River steelworks**: blast furnaces, conveyors, rail yards, rusty sheds.
- **Freight port**: cranes, containers, long piers for pursuits.
- **Working-class neighbourhood**: brick houses, churches, bars, narrow streets.
- **High Sierra**: winding mountain road, pines, snow at the top, a dam and tunnels. Appalachian influence.
- **Interstate highway** with toll booths and rest stops.

### New cars (proposal)
Classic and period cars at the same level of detail as the game:
- Lamborghini Countach, Ferrari Testarossa, Porsche 959, BMW M1, Ford Mustang Boss 429, 1969 Dodge Charger, Toyota AE86, Nissan Skyline R34.
- Every car in the new Blacklist is **unique**: its own kit, vinyl and colour, like the original ones.
- New tuning parts: body kits, spoilers, rims, hoods, exclusive paints. The game's part system is already identified (see [docs/en/10-cars.md](docs/en/10-cars.md)).

### Pursuits and street life
- Traffic and police on the real road network (4385 nodes, lanes and directions).
- Interactive elements: new pursuit breakers (water towers, scaffolding, port cranes), roadblocks, spike strips, helicopter.
- All with the behaviour and pacing of the original.

## How to contribute
Read [CONTRIBUTING.md](CONTRIBUTING.md). Anyone can propose changes through a pull request; the maintainer reviews them and decides what goes into `main`.

Most useful right now:
- Native engine (Swift/Metal) and physics from the decomp.
- Hash names and fields still unresolved (tagged [H] in the docs).
- Sketches of the new map and designs for Blacklist 2 cars.
- Modelling of **your own original** cars and parts (never ripped from other games).
