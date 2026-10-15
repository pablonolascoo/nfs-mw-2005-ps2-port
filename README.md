# NFS Most Wanted (2005) · PS2 → native

[Español](README.es.md) · English

<a href="https://rockport-native.vercel.app"><img src="site/img/banner.jpg" alt="Rockport Native: the Most Wanted BMW M3 GTR in the native macOS engine" width="100%"></a>

<p align="center"><b><a href="https://github.com/pablonolascoo/nfs-mw-2005-ps2-port/releases/latest">⬇️ Download for Mac (v0.4)</a></b> · <a href="https://rockport-native.vercel.app">🌐 Project page</a> · <a href="#user-guide">User guide</a> · <a href="#the-rust-belt-expansion">The expansion</a> · <a href="ROADMAP.en.md">Roadmap</a> · <a href="CONTRIBUTING.md">Contribute</a> · <a href="CONTEXT.md">Context</a></p>

<img src="site/img/blacklist-grid.jpg" alt="The 15 Blacklist cars with their exclusive liveries" width="100%">

| Race with the original HUD | Police pursuit |
|---|---|
| <img src="site/img/carrera.jpg" alt="Sprint race with the original HUD and the event barriers"> | <img src="site/img/persecucion.jpg" alt="Pursuit with the original HUD and radar"> |
| **Race results** | **Blacklist screen** |
| <img src="site/img/resultados.jpg" alt="Original results screen"> | <img src="site/img/listanegra-pantalla.jpg" alt="Blacklist screen with Sonny, #15"> |

Open research and tools to turn your own **PlayStation 2** copy of *Need for Speed: Most Wanted* (2005) into open formats (glTF/PNG/JSON), as a base for **native ports to any platform**, macOS first.

> **No game data is included.** You need your own disc. Everything here reads your ISO and writes derived files locally. This project is not affiliated with Electronic Arts.

## What works today
| Area | Status |
|---|---|
| Disc container (ZDIR/ZZDATA), file names | ✅ 95 % of files named |
| Compression HUFF / JDLZ / RAWW | ✅ byte-exact |
| PS2 geometry (VIF packets, strip restarts) | ✅ 181,535 strips decoded, 0 errors |
| PS2 textures PSMT8 / PSMT4 (GS swizzle) | ✅ |
| Whole Rockport: 718 sections, 106,714 objects, 5.8 M triangles | ✅ exported to glTF |
| Cars with textures, paint, glass, lights and 4 wheels (TireOffsets) | ✅ |
| **Native macOS engine (Swift + Metal)**: full screen, screen resolution, 60 fps, PS2 tone, drivable car — [native-engine/](native-engine/README.en.md) | ✅ first version |
| Research web viewer (Three.js) | ✅ |
| Decompilation (dbalatoni13/nfsmw) builds on Apple Silicon | ✅ with Rosetta 2 |
| Gameplay database (VLT): 6,287 collections, 255 events, Blacklist, 15 garage/shop zones | ✅ |
| Frontend interiors (garages, car lot, tuning shop) | ✅ exported |
| Whole city at 60 fps (HLOD tiles, texture arrays, workers, dynamic resolution) | ✅ |
| Drivable car on the real city (arcade prototype, 60 fps) | ✅ |
| Garages without loading screens: real door opens, interior already loaded, park, showcase, drive out | ✅ |
| Mods: original data layered over your ISO (`mods/`), example "Unique garages" | ✅ |
| Road network (4385 nodes, 6538 Bézier segments, lanes) and collision (243k triangles) | ✅ decoded and validated |
| **Game's own driving physics** (decomp), 4 cameras, controllers (Xbox, PS3/PS4/PS5, PS2 via USB) with light bar and touchpad — [doc 13](docs/en/13-driving-physics.md), [doc 15](docs/en/15-controllers.md) | ✅ v0.2 |
| **Traffic, police and pursuits** with the game's tables: heat, backup, formations, roadblocks — [doc 14](docs/en/14-traffic-and-police.md) | ✅ v0.2 |
| **The game's original interface** at native resolution: title, main menu, career, pause and MW HUD, Spanish/English text from your disc — [doc 17](docs/en/17-interface.md) | ✅ v0.3 |
| **Story cars with their exact liveries**: classic silver/blue BMW M3 GTR, Razor's Mustang and all 15 Blacklist cars (82 preset rides, vinyls composited like the game) — [doc 10](docs/en/10-cars.md) | ✅ v0.3 |
| **Police radio** from your disc (own MicroTalk decoder), event-driven, through the PS4/PS5 pad speaker or the Mac; configurable light bar — [doc 15](docs/en/15-controllers.md), [doc 16](docs/en/16-audio-and-voices.md) | ✅ v0.3 |
| Original voices and scene audio extracted from your disc (local use) — [doc 16](docs/en/16-audio-and-voices.md) | ✅ |
| **Playable races and Blacklist**: sprint, circuit, knockout, drag, speedtrap, tollbooth and challenges; rivals with the game's AI and cars; 15 → 1 progression, pink slips, district padlocks and save game — [doc 18](docs/en/18-races-and-blacklist.md) | ✅ v0.4 |
| **100 % original HUD** with the game's radar, race screens, results, Blacklist and pursuit endings — [doc 17](docs/en/17-interface.md) | ✅ v0.4 |
| Garages in the native engine, engine sound, movies, car-to-car collisions | 🔜 |

## Play on your Mac
1. Download `Rockport-<version>.dmg` from [Releases](https://github.com/pablonolascoo/nfs-mw-2005-ps2-port/releases) and drag **Rockport** to Applications.
2. Open it (first time: right-click → Open, it is not notarised yet).
3. Choose your PS2 ISO. It detects **PAL SLES-53559** or **NTSC-U SLUS-21351** and converts the game in about 5 minutes.
4. The game starts full screen at your screen's resolution. Converted data stays in `~/Library/Application Support/Rockport/`.

Build the `.dmg` yourself: `native-engine/scripts/make-dmg.sh` (needs Xcode tools and Bun). Details: [native-engine/README.en.md](native-engine/README.en.md).

## The "Rust Belt" expansion

A fan-made expansion **as if it were 2006**. It unlocks after beating the original Blacklist and continues the story with a **Blacklist 2** of 15 rivals with unique cars. Same look: Rust Belt, autumn and the warm PS2 tone.

<img src="docs/expansion/valle.jpg" alt="Industrial valley of the expansion" width="100%">

| Map: real Rockport + 4 new districts | Districts |
|---|---|
| <img src="docs/expansion/mapa-expansion.svg" alt="Expansion map" width="420"> | **1 · Millbrook**: working-class town, new safehouse (Blacklist 2 #15–#11)<br>**2 · River Steelworks**: blast furnaces and rail yards (#10–#6)<br>**3 · Freight Harbor**: cranes and containers (#5–#2)<br>**4 · High Ridge**: mountain pass and dam (#1)<br><br>Linked by the **I-99** interstate. Classic cars such as the Countach, Testarossa or 959. |

| River Steelworks | Freight Harbor | High Ridge | Bridge and I-99 |
|---|---|---|---|
| <img src="docs/expansion/acerias.jpg" alt="Steelworks"> | <img src="docs/expansion/puerto.jpg" alt="Harbor"> | <img src="docs/expansion/sierra-alta.jpg" alt="High Ridge"> | <img src="docs/expansion/puente-interestatal.jpg" alt="Bridge"> |

Full design, story and modelling rules: [docs/en/12-rust-belt-expansion.md](docs/en/12-rust-belt-expansion.md). AI mood sketches (not game assets).

## User guide

### First launch
1. Open **Rockport** from Applications. First time: right-click → **Open** (the app is not signed by Apple yet).
2. Click **CHOOSE MY PS2 ISO** and pick your copy. It detects PAL **SLES-53559** or NTSC-U **SLUS-21351** on its own.
3. Wait for the bar (a few minutes). When it finishes, the game starts full screen at your screen's resolution.
4. Press **C** (or **Menu / Options** on a pad) to switch from the free camera to the car.

### Controls

| Action | Xbox | PlayStation | Keyboard |
|---|---|---|---|
| Throttle (analog) | RT | R2 | W / ↑ |
| Brake and reverse (analog) | LT | L2 | S / ↓ |
| Steer | left stick | left stick | A D / ← → |
| Handbrake | A or RB | ✕ or R1 | Space |
| Nitrous | B | ○ | N or Shift |
| Look back (hold) | LB or L3 | L1 or L3 | X |
| Change camera (4 game views) | Y · d-pad → / ← | △ · d-pad → / ← | V |
| Reset the car onto the road | X or View | □ or Share / Create | R |
| Shift up / down | d-pad ↑ / ↓ | d-pad ↑ / ↓ | E / Q |
| Free camera / photo mode | Menu | Options / Start | C |
| Release mouse · Quit | — | — | Tab · Esc |

- Gears are automatic, as in the game. Use the d-pad to shift by hand whenever you want.
- The right stick can also throttle (↑) and brake (↓).
- The warm, yellowish PS2 tone is **always** on: it is part of the game.

### PS4 (DualShock 4) and PS5 (DualSense) extras

| Extra | What it does |
|---|---|
| Light bar | Takes your car's colour. During a pursuit it flashes red and blue |
| Swipe → / ← on the touchpad | Next / previous camera |
| Press the touchpad (hold) | Look back while held |
| Short tap on the touchpad | 1-second glance back |
| Two fingers on the touchpad | Free camera (photo mode) and back to the car |
| Adaptive triggers (PS5 only) | L2 resists when braking and buzzes when the wheels lock. R2 is almost free, shakes at the rev limiter and goes loose with nitrous |
| Rumble | Follows tyre grip, the rev limiter, nitrous and hits |

### Pursuits
- **Top left**: heat level (HEAT, 1 to 5) and number of cops.
- **Bottom**: the **EVADE ← → BUSTED** bar.
  - Going slowly with a cop on you fills it towards **BUSTED**: you get arrested.
  - Once they lose sight of you, **COOLDOWN** starts. Stay hidden until **EVADED** appears.
- **To escape**: break line of sight (corners, tunnels, alleys) and use the game's hiding spots (under bridges, car parks). Cops can't see you there.
- **From heat 2** there are roadblocks, some with spike strips. Find the gap or take another street.
- **Cops chase you if** you speed past them, hit traffic or ram a patrol car.

### Supported controllers
- **No install needed**, wired or Bluetooth: Xbox One and Series, PS4, PS5, Switch Pro and MFi pads.
- **Wired only**: PS3 (DualShock 3) and PS2 pads through a USB adapter.
- **Xbox 360**: macOS needs the free [360Controller](https://github.com/360Controller/360Controller) driver. The game tells you if it is missing.
- Plug and unplug at any time. Full details: [docs/en/15-controllers.md](docs/en/15-controllers.md).

### Troubleshooting
| Problem | Fix |
|---|---|
| "Cannot be opened because the developer cannot be verified" | Right-click the app → **Open** → **Open** |
| A PS3, PS2 or generic pad does nothing | System Settings › Privacy & Security › **Input Monitoring** → enable Rockport |
| I want to convert my ISO again | Delete `~/Library/Application Support/Rockport/<ID>/` and open the app |
| I updated the app | If the data is from an older version, it is reconverted automatically from the same ISO |
| Uninstall | Delete **Rockport** from Applications and the `~/Library/Application Support/Rockport/` folder |

## Quick start (research tools)
**One PAL ISO (SLES-53559) is enough for the whole project** (SLUS-21351 also works).
```bash
# requirements: Bun and your own ISO
cd tools && bun install
bun run build-all /path/to/your.iso        # everything in ~6 min → map-data/<disc>/
cd ../viewer && bun install && bunx vite    # http://localhost:5181 → «Cargar ciudad completa» → «Conducir»
```
Step by step:
```bash
cd tools && bun install
bun src/cli/inventory.ts ../original/SLES-53559.iso SLES-53559
bun src/cli/convert.ts   ../original/SLES-53559.iso SLES-53559 tiles 400 3   # all of Rockport as 60-fps tiles (~1 min)
bun src/cli/convert.ts   ../original/SLES-53559.iso SLES-53559 interior CAREER_SAFEHOUSE CAR_LOT CUSTOMIZATION_SHOP
bun src/cli/vlt-dump.ts  ../original/SLES-53559.iso SLES-53559                # gameplay.json + zones.json
bun src/cli/convert.ts   ../original/SLES-53559.iso SLES-53559 car BMWM3GTRE46
bun src/cli/topdown.ts   ../original/SLES-53559.iso SLES-53559 4096          # top-down PNG map
cd ../viewer && bun install && bunx vite                                    # http://localhost:5181
```

## Documentation
| Topic | English | Español |
|---|---|---|
| Disc identification | [docs/en/00](docs/en/00-disc-identification.md) | [docs/es/00](docs/es/00-identificacion-disco.md) |
| Decomp compatibility | [docs/en/01](docs/en/01-sles53559-compatibility.md) | [docs/es/01](docs/es/01-compatibilidad-sles53559.md) |
| PS2 formats | [docs/en/02](docs/en/02-ps2-formats.md) | [docs/es/02](docs/es/02-formatos-ps2.md) |
| Rockport world | [docs/en/03](docs/en/03-rockport-world-ps2.md) | [docs/es/03](docs/es/03-mundo-rockport-ps2.md) |
| Porting architecture | [docs/en/04](docs/en/04-port-architecture.md) | [docs/es/04](docs/es/04-arquitectura-port.md) |
| Driving and garages | [docs/en/07](docs/en/07-driving-and-garages.md) | [docs/es/07](docs/es/07-conduccion-y-garajes.md) |
| Mods and expansions | [docs/en/08](docs/en/08-mods.md) | [docs/es/08](docs/es/08-mods.md) |
| Gameplay database (VLT): zones, races, Blacklist | [docs/en/05](docs/en/05-vlt-attributes.md) | [docs/es/05](docs/es/05-vlt-atributos.md) |
| Viewer performance | [docs/en/06](docs/en/06-performance.md) | [docs/es/06](docs/es/06-rendimiento.md) |
| Road network and collision | [docs/en/09](docs/en/09-road-network.md) | [docs/es/09](docs/es/09-red-de-carreteras.md) |
| Cars: replacement textures, paint, wheels | [docs/en/10](docs/en/10-cars.md) | [docs/es/10](docs/es/10-coches.md) |
| "Rust Belt" expansion: map, sketches, story | [docs/en/12](docs/en/12-rust-belt-expansion.md) | [docs/es/12](docs/es/12-expansion-rust-belt.md) |
| Generated data catalog (which file answers what) | [docs/en/11](docs/en/11-data-catalog.md) | [docs/es/11](docs/es/11-catalogo-de-datos.md) |
| **Project context: start here to resume work** | [CONTEXT.md](CONTEXT.md) | [CONTEXT.md](CONTEXT.md) |

Every claim is tagged **[V]** verified on real data, **[D]** from the decomp's debug types, **[I]** inferred, or **[H]** hypothesis.

## Layout
`tools/` format readers and converters (TypeScript/Bun, platform-independent) · `viewer/` Three.js viewer · `docs/` research · `inventory/` per-disc inventories (hashes and sizes only).

## Credits
- [dbalatoni13/nfsmw](https://github.com/dbalatoni13/nfsmw) (CC0): PS2 debug types, chunk IDs, LZ/HUFF source.
- [TsyVM/MWEncyclopedia](https://github.com/TsyVM/MWEncyclopedia): PC format reference.
- GS memory tables follow the public GS documentation (same as PCSX2).

## License
MIT (code and docs). See [LICENSE](LICENSE).
