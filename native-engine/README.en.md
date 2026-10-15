# Rockport · native macOS engine

> [Versión en español](README.md)

First native Mac version of the **Need for Speed: Most Wanted (2005, PS2)** port.
It is a real app: **Swift + AppKit + Metal**. Not a web page, no browser.
Full screen, no menus around the game, at your screen's real resolution.

It reads the data that `tools/` generates from **your own ISO**. There is no game data here.

Tags: [V] verified in bytes or measured · [D] from the decomp · [I] inferred · [H] hypothesis.

## What it does today

- Opens the whole of Rockport full screen at 60 fps with vsync [V].
- Loads the 400 m tiles around the camera on background threads, without hitches [V].
- Textures, alpha test with the game's threshold (`0x28`), blended graffiti and glass, baked shadows, additive and water [V][D].
- Per-texture, per-axis repeat or clamp to edge (the game's TilableUV) [V].
- Sky gradient and sea plane, like the web viewer [H: the game draws a sea plane].
- **PS2 look**: a warm, slightly yellow final pass with lifted blacks. One number controls it.
- Free-fly camera (WASD + mouse) and **driving** the BMW M3 GTR with the **game's physics**, gamepads and the game's chase cameras.
- The car is assembled like the game: one part per slot, wheels and brakes sized from `cars.json` [D].
- The car rides on the game's **real collision** (`collision/*.bin`) and hits its walls [V].
- Window-less mode for screenshots and performance runs (`--screenshot`, `--bench`).

## Screenshots

Written to `native-engine/.build/shots/` (never committed):

| File | Shows |
|---|---|
| `city.png` | Start view (safehouse 1), near and far tiles |
| `street.png` | Street level: alpha-tested fences, trees |
| `drive.png` | Driving the BMW M3 GTR, chase camera |
| `drive-grade0.png` | Same without the PS2 look (`--grade 0`), to compare |
| `drive-moving.png` | After 6 s of automatic driving (`--autodrive 6`) |
| `carside.png`, `car34.png` | The car from the side and three-quarter view (`--carcam`) |
| `carwheel.png` | Front wheel close-up: rim, disc and caliper |
| `aerial.png` | The whole city from 900 m (far level) |
| `garage/mainmenu-1920.png`, `-2940.png` | Main menu with the front-end garage and the BMW (`--ui-test MainMenu`) |
| `garage/safehouse-1920-1-fuera/2-dentro/3-aparcado.png` | Driving into safehouse 1: roller door, interior and menu (`--garage-test zone_safehouse_1`) |
| `garage2/ref8-menu-principal.png`, `ref9/ref10-refugio-mis-coches.png` | Menu scenes with every disc prop, comparable with the game's screenshots |
| `garage2/entrada-refugio1-*.png` (and `-taller2`, `-concesionario1`) | Driving in with the drivable scene: apron, bay with walls and ceiling, menu |
| `garage2/refugio1-mis-coches-swap-0…6.png`, `concesionario1-swap-…` | Car swap without a loading screen (`--garage-swap-test`) |
| `garage/customshop-paint-1920-3-aparcado.png`, `customshop-rims-…` | Shop: paint and rims fitted to the car |
| `garage/carlot-1920-3-aparcado.png` | Car lot with price and logos |

## Build and run

You need macOS 14 or later and the Xcode tools (Swift 5.9+). You do not need to open Xcode.

```bash
cd native-engine
swift build -c release                         # build (≈1 min the first time)
./.build/release/Rockport --data ../map-data/SLES-53559
./scripts/make-app.sh                          # assembles .build/Rockport.app (ad-hoc signed)
open .build/Rockport.app --args --data "$PWD/../map-data/SLES-53559"
```

Without `--data`, it looks for data in this order:
1. `--data <folder>` (the `<ID>` folder or its parent).
2. The `ROCKPORT_DATA` environment variable.
3. `~/Library/Application Support/Rockport/<ID>/` (where the installer will write).
4. Development: `map-data/<ID>/` walking up from the current folder or from the executable.

Generate the data first with `cd tools && bun run build-all <your ISO>` (see `CONTEXT.md`).

### Controls

| Key | Action |
|---|---|
| Mouse | Look |
| W A S D / arrows | Move (or throttle, brake and steer in the car) |
| E / Space, Q / Ctrl | Up and down (free camera). In the car: E/Q shift, Space handbrake |
| Shift | Fast (×5). In the car: nitrous (also N) |
| X · V | Car: look back · change camera (bumper, hood, close, far) |
| C | Switch between free camera and car |
| R | Reset the car (stopped, on the ground) |
| Gamepad | Xbox, PS3/PS4/PS5, PS2 adapters and generic HID: see [doc 15](../docs/en/15-controllers.md) |
| DualShock 4 / DualSense | Light bar as a tuning option plus pursuit colours; police radio through its speaker: [doc 15 §7–8](../docs/en/15-controllers.md) |
| Tab | Release or capture the mouse |
| Esc or ⌘Q | Quit |

### Launch options

| Option | Purpose |
|---|---|
| `--data <folder>` / `--disc <ID>` | Choose data and disc |
| `--grade <n>` | Development only: PS2 look strength. In the game it is **always** 1 and cannot be turned off. Also `ROCKPORT_GRADE` |
| `--cam x,y,z,heading,pitch` | Start camera (metres and degrees) |
| `--drive` / `--car` | Start driving / with the car parked |
| `--scale <f>` | Fixed render scale (no dynamic resolution) |
| `--quit-after <s>` | Quit by itself (tests) |
| `--screenshot <png> [--size WxH] [--frames N]` | Window-less: load, render, save a screenshot |
| `--bench [--seconds N] [--size WxH]` | Window-less: 250 km/h flight with frame timings |
| `--autodrive <s>` | With `--drive` and `--screenshot`: accelerate for s seconds on real collision and summarise |
| `--near <m>` | Debug: near-level radius (`--near -1`: far level only) |
| `--carcam ox,oy,oz,tx,ty,tz` | Camera fixed to the car (X forward, Y left, Z up) |
| `--car-preset <NAME>` | Game car from `presets.json`: `M3GTRCAREERSTART` (default), `RAZORMUSTANG`, `BL2…BL15`, `ninguno` |
| `--audit` | Loads every tile and checks geometry and textures |
| `--race <ID>` · `--career` | Start a quick race directly (EventID "15.1.1") · enter the career |
| `--race <ID> --players N` · `--displays all\|1\|2` | N-player split screen (2…4): "Press START" first to assign controllers · displays to use (not saved; `settings.json` → `multiplayer.displays`) |
| `--split-test N [--race ID] [--seconds S] [--displays D] [--unplug-test] [--screenshot base.png]` | Headless: N players on autopilot; `-start/-mid/-end` captures per display, GPU/CPU timings and JSON |
| `--quickrace-test [--split N] [--screenshot base.png]` | Headless: walks the Quick Race screens (and "Press START") up to the start, one capture per screen |
| `--race-test <ID> [--autodrive] [--seconds N] [--opponents N] [--screenshot base.png]` | Headless: run the event with the autopilot; positions, times, `-start/-mid/-results/-finish` captures and JSON |
| `--garage-test <zone> [--garage-mode drive\|inside\|list] [--garage-screen S] [--screenshot base.png]` | Headless: enters a garage (doc 07 §3.4) |
| `--garage-scene <kind> [--fe-angle A] [--scene-car C]` · `--garage-swap-test <zone> [--scene-car C]` | Headless: front-end scene with any camera · animated car swap (doc 07 §5) |
| `--career-test [--save path]` · `--race-audit` | Headless: simulated Blacklist 15 → 1 · routes of every event against `RaceLength` |
| `--physics-test [CAR] [--physics-trace]` | Window-less: game physics on a flat plane: 0–100, top speed, braking, cornering, handbrake, NOS |
| `--lightbar paint\|police\|heat\|off\|custom:RRGGBB` | Pad light bar mode for this session (not saved). Also `ROCKPORT_LIGHTBAR` |
| `--radio-out auto\|pad\|mac\|off` · `--radio-log` | Where the police radio plays · print each line to the console |
| `--audio-devices` · `--radio-test` · `--pad-audio-test` · `--lightbar-test` | Window-less: audio outputs and pads · disc radio (vs vgmstream) · pad Opus/SBC/HID reports · light bar colours |
| `--sound-off` · `--volume 0…1` | Game sound off · master volume (also `settings.json` → `"sound"`) |
| `--sound-dump` · `--sound-test [CAR]` · `--sound-trace` · `--sound-live [s]` | Window-less: decoded banks and engines (vs vgmstream) · scripted run rendered to `.build/sound-test/<CAR>.wav` · RPM and mix trace · real Mac output for a few seconds (silent with `--volume 0`) |
| `--no-movies` · `--skip-intro` · `--movie NAME` · `--iso <path>` · `--lang <language>` | No movies · no boot movies (logo, PSA, attract) · play NAME at start · ISO to read them from · audio and subtitle language (also `settings.json` → `"movies"`) |
| `--movie-test NAME\|all [--seconds N] [--realtime --mute] [--engine]` | Window-less: movie with a simulated clock → `.build/movie-test/` (screenshots, `audio.wav`, `stats.json`) · all of them · real time · inside the engine |
| `--fx-test burnout\|street\|pursuit\|stats [--screenshot base.png]` · `ROCKPORT_FX=0\|hide` | Window-less: burnout and nitrous · junction with traffic lights · patrol cars with light bars on (shots and GPU with and without effects) · curves · without the effects layer / without drawing it (doc 20 §9) |
| `--music-off` · `--music-volume 0…1` · `--music-test [--busted] [--project N]` · `--music-live S` | Music off · volume (also `settings.json` → `"music"`) · window-less: free roam → pursuit → evade → `.build/music-test/` · real output |

## Folder layout

```
native-engine/
├─ Package.swift            Swift package (one executable, no external dependencies)
├─ VERSION                  app version
├─ scripts/make-app.sh      assembles Rockport.app with its Info.plist
├─ Sources/Rockport/
│  ├─ main.swift            arguments, window-less mode (--screenshot, --bench), PNG output
│  ├─ App.swift             borderless full-screen window, MTKView, input, dynamic resolution
│  ├─ Engine.swift          game state: free camera, car, streaming, frame
│  ├─ Config.swift          ALL settings (PS2 look, radii, GPU budget, sky, fog)
│  ├─ GameData.swift        data location and world.json, zones.json, cars.json
│  ├─ GLB.swift             minimal GLB reader (only what tools/src/lib/glb.ts writes)
│  ├─ TextureCache.swift    PNG → Metal texture with mipmaps, shared cache
│  ├─ Mesh.swift            GPU buffers per GLB and draw ranges per material
│  ├─ TileStreamer.swift    400 m tiles: far always, near by distance
│  ├─ Renderer.swift        Metal passes and draw order
│  ├─ Shaders.swift         Metal shaders (compiled at start-up)
│  ├─ Collision.swift       NFSC v1 collision: ground and walls
│  ├─ Car.swift             car: wheels, paint, interpolated physics pose
│  ├─ Physics/              the game's physics (doc 13): RigidBody, Tire, SuspensionRacer, EngineRacer, PVehicle, test
│  ├─ Input/                keyboard and controllers (doc 15): GameController, IOKit HID, light, triggers, rumble
│  ├─ Camera/               chase camera with the game's camerainfo views (and the split-screen ones)
│  ├─ Garage/               menu background and seamless garages: scene, front-end camera, menus, tuning (doc 07)
│  ├─ Multiplayer/          split screen: controller per player, views, split HUD, several displays (doc 19)
│  ├─ Effects/              the game's particles (EmitterSystem), light flares, per-zone fog and tint, light shafts (doc 20 §9)
│  ├─ Movies/               movies read from the ISO: VideoToolbox, R3 audio, subtitles, story moments (doc 22 §13)
│  ├─ Audio/Music*.swift    PathFinder music: EA Trax, interactive pursuit music, ambiences, mixing (doc 25 §10)
│  └─ MathUtil.swift        matrices, boxes, frustum
└─ .build/                  build output and screenshots (git-ignored)
```

### User data and the future installer

The app never writes inside itself. Converted data lives outside:

```
~/Library/Application Support/Rockport/
└─ SLES-53559/              same layout as map-data/<ID>/
   ├─ world.json  zones.json  cars.json  garages.json  roads.json
   ├─ tiles/  textures/  cars/  interiors/  groups/  collision/
```

### First-launch installer (`Installer.swift` + `tools/src/cli/install.ts`)

```
Rockport.app/Contents/
├─ MacOS/Rockport                 this engine
├─ Resources/rockport-convert     tools/src/cli/install.ts compiled with `bun build --compile` (~60 MB, signed)
└─ Info.plist
```

1. The app finds no data and carries `rockport-convert` → shows the installer screen (black and amber, no menus).
2. "Choose my PS2 ISO" → `NSOpenPanel`.
3. **Disc detection** (`DiscProbe`): reads the ISO9660, finds `SYSTEM.CNF` and takes the ID from `BOOT2` [V on both ISOs]:
   PAL `SLES-53559` or NTSC-U `SLUS-21351`. Another disc → "untested" warning. Not a PS2 ISO → error.
4. Runs `rockport-convert install <iso> <ID> <destination>`. Each step runs in a fresh process of the same binary.
   The bar follows the `PASO i/n · name` lines.
5. Everything goes to `~/Library/Application Support/Rockport/<ID>/` (inventory included). The ISO is never copied or changed.
6. At the end it writes `install.ok`. A half-finished install (`install.log` without `install.ok`) is redone on next launch.
7. The game starts straight away.

Test detection without opening the app: `.build/release/Rockport --probe path/to/your.iso`.
Build the `.dmg`: `scripts/make-dmg.sh` → `.build/Rockport-<version>.dmg`.
With no data and no bundled converter (development), the app shows an alert with the searched paths.

## How it works

### 1. GLB reader (`GLB.swift`)
- Understands only what `tools/src/lib/glb.ts` writes. That is why it is short and fast.
- Reads positions, normals, UVs, `COLOR_0` (may exceed 1: PS2 baked lighting [V]) and indices.
- Materials: `baseColorFactor`, texture, `alphaMode`, `alphaCutoff`, `extras.blend`, `extras.role`.
- Car nodes: `extras.pieza` (slot, kit, style, stock) and `extras.marcadores` (game matrices).
- Per-texture sampler: repeat or clamp to edge, per axis (the game's TilableUV).
- Images by URI (tiles) or embedded (cars).
- Ignores the root node's −90° X rotation: everything stays in game coordinates, Z up.
- 32-byte vertex: position, UV, half-float colour, 8-bit normal.

### 2. Textures (`TextureCache.swift`)
- PNG via ImageIO **without premultiplying** alpha. Many textures are "modulated": alpha ≈ 0 but opaque.
- Box-filter mipmaps on the loading thread. Upload to private GPU memory with a blit.
- Textures with useful alpha: empty texels get their neighbours' colour and mipmaps are alpha-weighted. No more black edges on leaves, fences and graffiti.
- sRGB format: the GPU converts to linear on read.
- Own upload queue: the main thread never waits for an upload [V: without it there were 38 ms stalls].
- Cache by path: each texture loads once.

### 3. Streaming (`TileStreamer.swift`)
- Same rules as the web viewer (`viewer/src/main.ts`).
- At start-up all 212 **far** tiles load (vertex colour, ~0.9 M triangles).
- **Near** tiles (textured) come in within 650 m of the camera, 28 at most.
- They are freed beyond 1100 m after 5 s unused.
- All reading and preparation happens on background threads. The main thread only picks up finished tiles.
- Each tile is one vertex buffer and one index buffer, with one range per material.

### 4. Draw passes (`Renderer.swift`)
1. Sky: the game's textures (`SKY_MIDDAY_A_*` from `DYNTEX.BIN`) by elevation; without `fx/`, the viewer gradient (doc 20).
2. Opaque and alpha-tested (fences, trees): write depth.
3. Opaque car: the same lighting as the viewer (hemisphere + sun, Lambert diffuse and GGX specular).
4. Sea: plane at z = −0.2 with soft waves.
5. Baked shadows (`sombra`, `SHD_*` textures) with depth bias; car contact shadow.
6. Normal blending (`mezcla`, `recorte_mezcla`: signs, graffiti, branches).
7. Additive (`aditiva`). 8. Map water (`agua`, scrolling UVs). 9. Car glass.

- Reversed depth with an infinite far plane: precision for 6 km of city.
- Linear fog towards the horizon colour (1200–9000 m).
- The far level is no longer darkened: the converter now writes its colour like the near level's [V: measured on the same view].

### 5. PS2 look (final pass, `fs_post` in `Shaders.swift`)
The scene renders to an HDR texture. The final pass scales it to the screen and applies the look.
The scene already arrives encoded (gamma blending like the PS2, doc 20) with the game's visual treatment (bloom, black bloom).
The look works in display (gamma) space, in three steps:
1. **Lifted blacks** with a warm touch (PS2 analogue output rarely gave pure black [I]).
2. **Yellow/amber tint** in mid-tones and highlights, not in shadows.
3. **Saturation** slightly lower, keeping warm tones.

One number controls it all: `Config.ps2GradeStrength` (default 1).
0 = neutral image. 1 = default look. Above 1 = exaggerated.
It is always on in the game. For development only, change it with `--grade <n>` or `ROCKPORT_GRADE`.

### 6. Dynamic resolution and vsync (`App.swift`)
- Output is always the screen's real resolution (Retina pixels).
- The scene renders at a fraction (0.5–1.0) chosen from the last frame's GPU time.
- Target: 13.5 ms of GPU, below the 16.7 ms of 60 Hz. Vsync on.

### 7. Car (`Car.swift`, `Collision.swift`)
- Model `cars/BMWM3GTRE46.glb`, stock, with the player paint (`Config.playerPaint`).
- **One part per slot** (`Car.visibleParts`, a copy of the viewer's `applyCarConfig`) [D: CarInfo.cpp, CarRender.cpp]:
  - the chosen kit replaces KIT00 only in the slots it has;
  - no damage (`dano`), vinyl zones (`calcomania`) or aftermarket spoiler base;
  - a `DAMAGE0` panel is the intact body (police): shown only if the slot has no normal part.
- **Wheels** like the viewer's `mountWheels` [D: CarRender.cpp 1855-1999]:
  - one model (`FRONT_TIRE`, or `REAR_TIRE` at the back) placed four times;
  - radius `TireOffsets.w`, width `skidWidth × kitWidthScale`;
  - rim face at |TireOffsets.y| (+ `kitOffsetFront/Rear` in mm, outwards);
  - left side turned 180° (or mirrored if `spokes & 0x80`);
  - camber `camber × 7°`; axle height `z + feCompression − camber × 0.03`.
- **Brakes** (`FRONT_BRAKE`/`REAR_BRAKE`) at the wheel's marker, no radius scale, mirrored on the left.
- GPU parts: 0 body, 1–4 wheels (spin and steer), 5–8 brakes (steer only).
- Rim cards are drawn again: the converter fixed their orientation.
- `BMWM3` borrows the `bmwm3gtr` attributes (it has no collection of its own) [V: cars.json].
- Lighting: the game's light material per strip + environment map (doc 20, `SceneShading.swift` `carShade`). Without `fx/`: neutral light.
- Driving: **the game's physics** ported from the decomp (see "Game physics" below and doc 13). Without `physics.json`, the old arcade prototype.
- Ground: collision triangles in 8 m cells. Walls: vertical segments.

## Game lighting and effects (2026-10-15, doc 20)

- **PS2 colour space**: the scene is written encoded (sRGB) and blending happens in gamma, like the GS. Fixes the safehouse light
  shafts (they were opaque green boxes) and the weak baked shadows. Rule for new scene shaders: `scenePreludeMSL` +
  `sceneRGB(...)` (`SceneShading.swift`).
- **Cars**: the game's light material per strip (`eLightMaterial`, `extras.luz` in the GLBs; paint takes the preset's) and the
  garage's spherical environment map (`<GARAGE>_CARSELECTENVMAP`) or the sky one (`SMALLENVMAP`), scaled by skin gloss.
  Tinted windows use `WINDSHIELD_TINT_*`. Traffic and police share the same shading.
- **Car shadow**: `CARSHADOW` from the disc (player, rivals, showroom, traffic and police), stretched away from the sun.
- **Sky** with the `GLOBAL\DYNTEX.BIN` textures and a **sun** (centre and halo of `SunChunkInfo` MIDDAY).
- The game's **visual treatment** (`visuallook` "default": yellow bloom, black bloom, desaturation) before the PS2 grade.
- Per-garage front-end lighting (`SceneLighting.frontEnd`) [I] and low haze in the main menu.
- Data: `fx` step (`fx/`), `DATA_FORMAT` 8. Debug: `ROCKPORT_LOOK=0` (no treatment), `ROCKPORT_ENV=<n>` (reflections),
  `ROCKPORT_GARAGE_HIDE=NAME,…` (hide interior materials).
- Measured (M4, loaded machine): 2940×1912 fly-through GPU median 3.7 ms (3.3 without the visual treatment); 1920×1080 pursuit
  2.5 ms; 2-player split screen 2940×1912 4.7 ms. Well under the 13.5 ms budget.
- Before/after shots: `.build/shots/fx/before/` and `.build/shots/fx/after/`.

## Particles, light flares and per-zone fog (2026-10-15, doc 20 §9)

- **The game's particles** (`Effects/`): `EmitterSystem.cpp` ported with the VLT data (`effects.json`): lifetime colour and size
  curves, on/off cycles, volume/cone/disc emission, drag, gravity, inherited velocity, animated grids. World emitters (1,535:
  leaves, fog, chimney smoke, steam) streamed by distance like the game, plus the front-end garages' emitters: **the low haze and
  steam of the menu yard and the safehouse** are now the disc's own particles. Instanced billboards (two calls per view, textures
  in an array), blended in PS2 space.
- **Cars**: tyre smoke per surface (`simsurface`: slides, burnouts, rolling), **nitrous flames** on the exhaust markers, **sparks**
  on impacts. Player, rivals and split screen.
- **Light flares** (`light_flares_cg`): the world's traffic lights and cat's eyes (2,242, blinking like the game), head, tail and
  reverse lights of every car, the **police light bar** with `CarRender`'s flicker and its halo, the sun. Depth-occluded. The PS2
  has no street-lamp flares [V].
- **Per-zone fog and tint** (ParameterMaps "Normal Fog", "Screen Tint Midday") with the game's distance blending (50 m).
- **Garages**: the dark strip at the bottom when entering the safehouse is gone (door-gap ground and a threshold darker than the
  interior) and the windows of the drivable scenes' walls get light shafts.
- Measured cost: +0.1–0.4 ms GPU; 2-player split screen at 2940×1912 6.4–6.7 ms with effects (6.3–6.7 without).
- Tests: `--fx-test burnout|street|pursuit|stats`; `ROCKPORT_FX=0|hide`. Before/after shots in `.build/shots/fx/cmp-*.png`.

## Game cars: presets, vinyls and composite skins (2026-10-15)
- `CarSkin.swift` reads `presets.json` (82 presets from `GLOBAL\GLOBALB.BUN`: Blacklist `RAZORMUSTANG`, `BL2…BL15`, the story BMW `M3GTRCAREERSTART`…) and composites the body like `CarSkin.cpp`: base colour (alpha = gloss) + vinyl through its mask (`m ≥ 128` → vinyl, `0 < m < 128` → blend `m/128`). Composited on the CPU at 1024×1024 (twice the PS2 size) with bilinear sampling and uploaded with mipmaps. The same skin is used by the spoiler and roof scoop.
- `Car.swift` with a preset: mounts exactly the preset's solids (kit, hood), the rim from `WHEELS.glb`, the spoiler (`SPOILER*.glb`) and roof scoop (`ROOF.glb`) on the BASE solid's `SPOILER`/`ROOF_SCOOP` markers; tints the rim with `PAINT_RIM` (`_WHEEL_INNER_MASK`), darkens the windows by tint [I] and picks metalness/roughness by finish (GLOSS/METAL/PEARL) [I].
- The player defaults to the story BMW M3 GTR (silver + blue stripes). `--car-preset RAZORMUSTANG` (or `BL2…BL15`, `ninguno` = stock) and `--carcam` for screenshots. Traffic and police are unchanged (their `SKIN1` is a real disc texture).
- Formats and the Blacklist table: [docs/en/10-cars.md §8](../docs/en/10-cars.md).

## Original game interface: menus and HUD (2026-10-15)

- The app starts with **the game's own screens** (FEng `.fng` packages from the disc): "Press START" → main menu → Career
  (Resume / Start new) → free roam with the **original HUD** (tachometer, speedometer, nitrous, heat, pursuit board).
  Start or Esc: the game's pause menu (resume, restart, options, quit). ⌘Q quits.
- Text and fonts from the disc: Spanish on PAL, English on NTSC-U. Other options open the game's dialog with "Coming soon.".
- Native resolution: the 640×480 canvas is scaled keeping aspect; images use Catmull-Rom bicubic; text uses a distance field
  (×4 SDF from the converter). Drawn after the PS2 grade, like on PS2.
- Code in `Sources/Rockport/UI/`; data from the `frontend` step in `tools/`. `--no-ui` disables it; `--ui-test <screen>` takes
  screenshots (`.build/shots/ui/`). Format, decisions and gaps: [doc 17](../docs/en/17-interface.md).

## Changes for the new data (2026-10-12)

What changed in the converter and how the engine follows it:

| Data change | What the engine does now | Why |
|---|---|---|
| Vertex colour stored as `(c/128)^2.2` | The far-level ×0.45 fix is gone (`Config.farColorScale`, `--far-scale`) | Measured [V]: far/near = 0.95–1.2 without it (was 1.8). With grade 0 the engine's mean colour matches the viewer's (±2 of 255) |
| Alpha test with the game's `0x28` threshold | Alpha test uses the material `alphaCutoff` and passes when alpha > threshold | `_alphaRef` [D]. With 0.5, grates and branches vanished |
| Blended graffiti and glass | Already in the blend pass; now without black edges (bleed + alpha-weighted mips) | Same as `tile-worker.ts` |
| Per-texture repeat (TilableUV) | The `sampler` was already read; checked with the new GLB | 4 samplers (repeat/clamp per axis) |
| Tiles with more than 256 textures | No change needed: the engine uses no texture arrays | `--audit` [V]: 212 tiles × 2 levels, all with geometry and textures; the largest (10_1) has 269 |
| Cars with `extras.pieza` and `extras.marcadores` | One part per slot, wheels and brakes from the decomp | Before, every kit, damage layer and decal showed at once |
| `cars.json` with `skidWidth`, `camber`… | Read in `GameData.CarAttribs` | Real wheel measurements [D] |

Comparison with the viewer (same camera, `--carcam`, `--grade 0`) [V]:
- Paint on the shaded side: engine (57, 62, 74), viewer (59, 63, 74) in sRGB.
- Street of `street.png`: engine mean colour (76, 76, 72), viewer (75, 74, 71).

## Measured performance

MacBook Air M4 (16 GB), screen at 2940×1912 pixels. Release build. [V]

| Test | Result |
|---|---|
| Full-screen app, start view | Steady **60 fps**, GPU 5.6–5.9 ms, CPU 1.1–1.5 ms, scale 1.0 |
| Still capture 1920×1080 | Median GPU 4.0 ms, ~1400 draw calls, 0.67 M triangles |
| 250 km/h flight, 20 s, 1920×1080 | Median GPU 3.2 ms (p95 6.6), 0.2 % of frames > 16.7 ms |
| 250 km/h flight, 20 s, 2940×1912 | Median GPU 3.9–5.0 ms (p95 8.4–9.5), 0.4–3 % > 16.7 ms |
| Stress test: whole city in full detail (`--near 6000`) | 60 fps at scale 0.5, GPU ~12 ms, 9300 draw calls, 3.1 M triangles |
| New data (2026-10-12), 20 s flight, 1920×1080 | GPU median 3.2 ms (p95 4.4), 0.3 % > 16.7 ms, 722 draw calls |
| New data, 20 s flight, 2940×1912 | GPU median 5.3 ms (p95 7.8), 0.9 % > 16.7 ms |
| Car close-up, 1600×900 | GPU median 2.1–2.7 ms, ~1000 draw calls |
| `--audit`: all 212 tiles, near and far | 2.2 s, 6.6 M triangles, 2562 textures |
| Initial load (far + near tiles of the view) | 0.5–1 s |

Notes:
- In the window-less flight each frame waits for the GPU, so it is harsher than the real app.
- The web viewer reached 60 fps with tricks (texture arrays, 2 draw calls per tile). They are not needed here.
- Near-tile memory is about 25–40 MB; textures 35–45 MB in a normal view.

## Known limitations

- Seen from the air, the space between roads is the sea plane: the game map only has geometry along streets [V].
- The far level uses average texture colour: the switch to a near tile is visible.
- Car lighting is the viewer's, not the game's: the game uses environment maps [D].
- Aftermarket roof scoops (`ROOF` pack) are not offered in the shop yet; rims and spoilers are (doc 07 §3.3).
- The BMW driver texture (`4e8cf857`) is not on the disc: it shows dark grey, as in the viewer [V].
- Sound: without the engines' AEMS layer; sound effects still use the port's own levels (music already uses the game's mix map) (doc 16 §9, doc 25 §10.3). No options menu for music yet (only `settings.json`). Traffic and police without helicopter or physical car-to-car collisions (doc 14).
- Wall crashes: own impulses, not the game's `RigidBody::DoBarrierCollision` (doc 13).
- Controllers not yet tested on real hardware (doc 15).

## Seamless garages and the menu background (2026-10-15)

- **Menu background like the game**: "Press START", the main menu and the career menu show the front-end garage
  (`PLATFORMCRIB`: night industrial yard with water towers, sheds, forklift and the sky dome) with the player's car (the career car with its tuning; by
  default the story BMW M3 GTR), placed like `GarageMainScreen` and with the `GLOBAL\FE_ATTRIB.BIN` cameras
  (`SelectCarCameraMover`: entry → final → each screen's angle, with its camera roll) [D][V].
- **Garages without loading screens** (`Garage/`): the game's 15 garages. Drive slowly up to the real door: the building is cut
  out in the world shaders, the roller door lifts and the menu interior is already inside; drive in, park and the place's original
  menus appear with the front-end camera around the car: **safehouse** (Blacklist, My cars, Save), **car lot** (buy cars with the
  `FE_ATTRIB.BIN` price and unlock) and **customization shop** (paint, vinyls, rims, spoilers, body kit and the **controller light
  bar**, fitted to the car instantly). Reverse out and the door closes. Safehouses 2, 4 and 5 now have their real building
  (`XB_SafeHouse`, `XB_FishSafehouse`, `XB_TC_SafeHouse`). Example mod: `mods/garajes-unicos`.
- **Converter fix**: strips with float positions (V4-32) collapsed into a point; now the garages' sky dome and **5,071 world
  strips** (downtown skyscrapers, sky, background mountains) appear.
- **Icon carousel**: the centre is `OPTION_MASTER` (assembly), which is also hidden: no more overlapping icons; orange icons in
  game; arrows dim at the ends. Blacklist with its requirements panel and bounty/cash.
- **Complete scenes** (data format 10): the converter exports every `BACKDROP*` the game draws; the `BACKDROP_CAST_SHADOW_MAP*`
  solids are the props (menu water towers and forklift, safehouse tyres, barrels and boxes, shop car covers), not shadows.
  Safehouse floor reflection separately.
- **Drivable scenes** (`Garage/GarageScenes.swift`, `garage-scenes` step): bay measured from the world collision; walls, ceiling,
  beams, frame and apron/ramp built by us with disc textures (size and light measured in the interior), with collision; car swap
  in My cars and the car lot without a loading screen. Edited in `tools/data/garage-layouts.json`.
- Tests: `--garage-test <zone> [--garage-mode drive|inside|list] [--garage-screen …]`. Details:
  [doc 07](../docs/en/07-driving-and-garages.md) and [doc 17](../docs/en/17-interface.md).

## Races and the Blacklist (2026-10-15)

- **Data**: `races` step in `tools/` → `races.json` (254 events, 20 bins, 94 challenges, TrackPath barriers from `L2RA.BUN`);
  data format 4. Collision of hidden groups (barriers, padlocks) now lives in `collision/groups/`: it used to be invisible walls
  in free roam.
- **Engine** (`Race/`, `Career/`): route on the road network closed by each event's barriers (median 0.997 of the game's length),
  barriers drawn and solid, opponents with the game physics and the game's AI driver (curvature speed, throttle/steering PID,
  skill, "glue" rubber band, NOS), all 7 event types, countdown, positions, laps, knock-outs, speed traps, tollbooths, drag with
  manual gears and lanes, wrong way, reset, per-event police and traffic, results and rewards.
- **Career**: Blacklist 15 → 1 with `RequiredRacesWon` / `RequiredChallenges` (milestones + open-world speed traps) /
  `RequiredBounty`, boss races, pink slips, district padlocks per bin, save in `~/Library/Application Support/Rockport/save.json`.
  World race markers (Return / ✕ to start).
- **Menu API**: `Career.shared.start()` / `newGame()` / `showBlacklist()`, `QuickRace.shared.start(eventID:)`,
  `RaceSystem.shared?.abandon()`. The HUD belongs to the UI (`UI/RaceHUD.swift`).
- **Tests**: `--race-test <ID> --autodrive --screenshot base.png`, `--career-test`, `--race-audit`. Details and results:
  [doc 18](../docs/en/18-races-and-blacklist.md).

## Quick Race and split screen (2026-10-15)

- **Quick Race with the game's screens** (`UI/QuickRace*.swift`, doc 19): menu (Quick play / Custom race / Split screen), race
  type, **Track_Select with each event's map** (`TRACK_MAP_<id>` from `TrackMaps.bin`, zoomed to the route like
  `UITrackMapStreamer`), region, length and best time; **Track_Options** (direction, laps, traffic, opponents, skill, catch-up
  and police); **Car_Select** per player with stock cars (unlocked by `frontend.UnlockedAt`), the story car and the Blacklist
  cars according to the save; results and back to the menu.
- **Original split screen** (2 players, horizontal, player 1 on top): the disc's `HUD_Player1/2` HUD (`INGAMESPLITSCREEN.BUN`),
  bar tachometer, shared radar with the other car, split-screen `camerainfo` cameras. **Extension**: 3 and 4 players in
  quarters (with 3, an aerial view in the free quarter), optional AI opponents, traffic and police, **several displays** (one
  window per display, 4 on 2 = 2 + 2).
- **One controller, one player** (`Multiplayer/PlayerDevices.swift`): "Press START" (`PressStart.fng`) assigns controllers; the
  first one is player 1; each car reads only its controller (or the keyboard); light bar and player LED in the player's colour;
  per-controller rumble; unplugged controller = pause with `ControllerUnplugged.fng` until START is pressed.
- **Rendering**: several views in the same texture with a single PS2-grade pass; streaming around every camera. Measured at
  2940×1912 in the city: 2 players GPU 3.5 ms, 4 players 5.2 ms (median) [V].
- Tests: `--split-test 2|3|4`, `--split-test 4 --displays 2`, `--split-test 2 --unplug-test`, `--quickrace-test [--split 2]`.
  Details: [doc 19](../docs/en/19-quick-race-and-multiplayer.md).

## Game physics, controllers and camera (2026-10-12)

- **Physics**: the game's `SuspensionRacer`, `EngineRacer`, `Chassis` and `RigidBody` in Swift (`Physics/`), at a **fixed 60 Hz** like the game
  (`Scheduler::Init(1/60)` [V]) and interpolated for rendering. Values from `physics.json` (`physics-attribs` step in `tools/`).
  Friction-circle grip, weight transfer through the suspension, handbrake drifts, NOS, automatic gearbox. Details: [doc 13](../docs/en/13-driving-physics.md).
- **Measured** (`--physics-test`, BMW M3 GTR, flat plane) [V]: 0–60 mph 3.03 s · 0–100 km/h 3.12 s · top 390 km/h (limiter in 6th) · 100→0 braking 14.5 m.
  Game reference: 0–60 mph ≈ 3.9 s [H].
- **Controllers**: Xbox One/Series, DualShock 4, DualSense and MFi through GameController; DualShock 3 (USB), PS2 adapters and generic HID through IOKit; Xbox 360 notice (needs 360Controller).
  Light bar, touchpad, adaptive triggers and rumble. Details: [doc 15](../docs/en/15-controllers.md).
- **Camera**: the car's `camerainfo` views (bumper, hood, close, far); own motion [H] (the game's is not decompiled).
- **PS2 look always on**: the G key was removed.
- Shots: `.build/shots/drive-physics.png` (cornering with body roll and steered wheels) and `.build/shots/drive-cameras.png` (all 4 views).

## Game sound: engines, effects and sirens (2026-10-15)

- **Disc banks** (`tools/src/cli/sound.ts` → `sound/`, `DATA_FORMAT` 5): 301 AEMS `ABKC` banks and 160 `.GIN` granular engines copied
  as they are; the app decodes PS-ADPCM, EA-XA v2 and EA-XAS (`Audio/SFXBank.swift`, `EngineGinsu.swift`), identical to vgmstream.
- **Engine** (`Audio/EngineSound.swift`): the game's chain —audio RPM through the car's curve, gear shifts with their RPM curves,
  on/off-throttle mix of two .GIN (`SFXCTL_HybridMotor`), the Ginsu granular synthesizer ported line by line—, turbo with charge and
  blow-offs, nitrous, pops. Every car with its game sound (the BMW M3 GTR sounds like the TVR Cerbera, as on PS2).
- **World** (`Audio/SFXWorld.swift`, `SFXMixer.swift`): skids, wind, road noise, impacts with the game's "stitches", race rivals with a
  full engine, police with siren and engine in 3D (Doppler, pan, distance filter), traffic hum and horns. A single audio node;
  0.2 % of one core. Split screen: `localCarsProvider` / `listenersProvider`.
- Details and tags: [doc 16 §7–10](../docs/en/16-audio-and-voices.md). Missing: the AEMS layer (MIPS modules) and the game's mix maps.

## Movies and music (2026-10-15)

- **Movies** (`Movies/`, doc 22 §13): the disc's 32 movies are read **straight from the ISO** (nothing is copied); MPEG-2 video through
  VideoToolbox (reordered to presentation order), own EA ADPCM R3 audio, synced to the audio clock, 4:3 with bars, no PS2 grade, subtitles
  with the game's rule (in Spanish the story is dubbed; tutorials and Blacklist captions have text). Boot like the original (EA logo → PSA →
  attract → "Press START", and the attract movie again after 30 s without input); story in the career (`STORYFMV_SAF25` and `BLACKLIST_15`
  at the start, `BLACKLIST_<no.>` after beating each rival, the rap sheet on reaching 13, each event's `IntroMovie` / `OutroMovie`, tutorials
  the first time). Start / ✕ / Return / Esc skip. Without the ISO the game goes on without movies.
- **Music** (`Audio/Music*.swift`, doc 25 §10): PathFinder player with the `.MPF` graph and the decomp's `MusicFlow` and `SFXObj_PFEATrax`
  logic: EA Trax songs in menus and free roam (FE/IG/AL lists), interactive music in pursuits with gapless transitions and router stingers,
  per-zone ambiences, the game's mix-map levels and ducking under the police radio. Pauses during movies. Settings in `settings.json → "music"`.

## Light bar and police radio (2026-10-15)

- **Light bar** (`Input/LightBarConfig.swift`): per-car tuning option —paint, custom colour, police, heat, off— saved in
  `settings.json`; on top, pursuit colours with the game's patrol-car light pattern (red/blue), amber/blue in cooldown,
  red when busted, green when you escape. `LightBar.shared` API for the tuning menu. Details: [doc 15 §7](../docs/en/15-controllers.md).
- **Police radio** (`Audio/`): the disc's lines (Spanish on PAL, English on NTSC), decoded by the app itself (MicroTalk),
  picked per event with the game's `.EVT/.IDX` tables and triggered by the pursuit (`PursuitFX.swift`). It plays through the pad speaker
  over USB, through HID reports (Opus / SBC) over Bluetooth —untested with a real pad— and otherwise on the Mac with a scanner filter.
  Details: [doc 15 §8](../docs/en/15-controllers.md) and [doc 16 §5–6](../docs/en/16-audio-and-voices.md). Needs data converted with format 3 (step "Police radio").

## Collisions, damage, breakables and helicopter (2026-10-16, docs 13 §12 and 14 §8)

- **Game collisions** between the player, racers, traffic and police with the `bounds.json` volumes and the `RigidBody::ResolveObjectCollision` response (friction, elasticity and `rigidbodyspecs` scales) [D]; no more overlapping. Rams, PIT manoeuvres and spin-outs; hit traffic slides and stays crashed.
- **Damage** as `DamageVehicle` [D]: zones, hit points (`damagespecs`), `DAMAGE0_*` dent layer and `WINDOW_DAMAGE0` glass on race cars; `DAMAGE1_*` panels and broken light bar on cops. **Destroyed** cops: game message and "taken out" counter on the original HUD, +5000 cost, damaged +250.
- **Breakables**: 5,952 objects (signs, lamp posts, fences, cones, barrels…) knocked loose with physics; **37 pursuit breakers** that immobilize the police.
- **Helicopter** at heat 4–5 with its model, its flight (`SimpleChopper` + `AIVehicleHelicopter` [D]), the disc's height sheet, blade chops and radar icon.
- Tests: `--crash-test all --screenshot .build/shots/crash/crash.png` and `--heli-test 75 --screenshot .build/shots/crash/h.png`. Cost: 0.04–0.1 ms per frame with 20 cars. `--no-crash`, `--no-heli`.
- Needs format-11 data (`smackables/`, `crash/`, DAMAGE1 panels, `physics.json` with damage): the app reconverts by itself.

## Traffic and police (2026-10-12)

- **Traffic** like the game's `AITrafficManager`: per-district vehicle pattern (`TRAFFIC_PATTERN` zones from `L2RA.BUN`), rates, caps and percentages from
  `trafficpattern`, spawning 200 ± 50 m ahead, type-1 lanes on the right of travel, one-way and no-traffic rules, random junction turns,
  35/55 mph street/highway, braking behind the car ahead, accident when hit. 20 cars at once (PS2: 10 vehicles in total) [D][V].
- **Police** like `AICopManager` + `AIPursuit`: patrols, line-of-sight detection, heat 1–5 (`pursuitlevels` heat_01…05), backup,
  formations (BOX_IN, PIT, ROLLING_BLOCK, HERD, FOLLOW, STAGGER), ramming, busted (5 s below `BustSpeed` with a cop within 15 m),
  cooldown and evade, roadblocks from the decomp's setup table with spike strips. Red/blue light bar using the `CarRender` formula.
- Minimal MW-style **HUD**: heat, EVADE/BUSTED bar, COOLDOWN, BUSTED/EVADED. No menus. The controller light goes red/blue during pursuits.
- Data: `ai.json` (new `ai-attribs` step in `tools/`) + `roads.json` + `collision/`. Cars use their real liveries from the disc, drawn instanced.
- Headless test: `--traffic-test N [--heat H] [--test-plan busted|run|flee] [--screenshot x.png]` → screenshots and stats (`x.json`).
  Options: `--traffic-max N`, `--no-traffic`, `--no-police`.
- Measured [V]: 19 traffic + 12 cops at 2940×1912: GPU 4.3 ms, CPU 1.0 ms; 100 % of cars on the ground, 0 lane jumps.
- Details, VLT tables and sources: [doc 14](../docs/en/14-traffic-and-police.md). Shots: `.build/shots/traffic-*.png`, `heat5-control.png`.

## Road to a playable DMG (next steps)

1. ✅ **First-launch installer** and `scripts/make-dmg.sh` (see above).
2. **Developer ID signing and notarisation**: needs a (paid) Apple Developer account. Without it the `.dmg` works but macOS warns on first open (right-click → Open).
3. ✅ **Gamepad** (GameController + IOKit HID) — wheels and video settings (scale, FOV) still to do.
4. ✅ **Game physics** from the decomp and each car's VLT attributes (doc 13) — game collisions, damage and tunings still to do.
5. ✅ **Audio, movies and music** (docs 16, 22, 25) — the engines' AEMS layer and NIS scenes still to do.
6. ~~Seamless garages and car selection~~ (done: doc 07). The career map and the rap sheet are still missing.
7. **Races and Blacklist** from `gameplay.json` + `roads.json`.
8. More performance: compressed textures (ASTC/BC7), the game's section occlusion, argument buffers.
9. More faithful car shadow and lights; environment reflections.

## Purpose

Show that the open data in `map-data/` is enough for a native engine.
Give a clean Swift + Metal base towards a playable `.dmg`, with no emulator and no PS2 binary.
