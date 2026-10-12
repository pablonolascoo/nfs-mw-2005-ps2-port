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
- Free-fly camera (WASD + mouse) and **driving** the BMW M3 GTR with a chase camera.
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
| E / Space, Q / Ctrl | Up and down (free camera). Space = handbrake in the car |
| Shift | Fast (×5) |
| C | Switch between free camera and car |
| R | Put the car back on the ground |
| G | PS2 look on / off |
| Tab | Release or capture the mouse |
| Esc or ⌘Q | Quit |

### Launch options

| Option | Purpose |
|---|---|
| `--data <folder>` / `--disc <ID>` | Choose data and disc |
| `--grade <n>` | PS2 look strength (0 = neutral, 1 = default). Also `ROCKPORT_GRADE` |
| `--cam x,y,z,heading,pitch` | Start camera (metres and degrees) |
| `--drive` / `--car` | Start driving / with the car parked |
| `--scale <f>` | Fixed render scale (no dynamic resolution) |
| `--quit-after <s>` | Quit by itself (tests) |
| `--screenshot <png> [--size WxH] [--frames N]` | Window-less: load, render, save a screenshot |
| `--bench [--seconds N] [--size WxH]` | Window-less: 250 km/h flight with frame timings |
| `--autodrive <s>` | With `--drive` and `--screenshot`: accelerate for s seconds on real collision and summarise |
| `--near <m>` | Debug: near-level radius (`--near -1`: far level only) |
| `--carcam ox,oy,oz,tx,ty,tz` | Camera fixed to the car (X forward, Y left, Z up) |
| `--audit` | Loads every tile and checks geometry and textures |

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
│  ├─ Car.swift             car: wheels, paint, arcade driving
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
1. Sky: gradient by view height (viewer colours).
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
It works in display (gamma) space, in three steps:
1. **Lifted blacks** with a warm touch (PS2 analogue output rarely gave pure black [I]).
2. **Yellow/amber tint** in mid-tones and highlights, not in shadows.
3. **Saturation** slightly lower, keeping warm tones.

One number controls it all: `Config.ps2GradeStrength` (default 1).
0 = neutral image. 1 = default look. Above 1 = exaggerated.
Change it without rebuilding with `--grade <n>` or `ROCKPORT_GRADE`, and with the G key while running.

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
- Lighting: the viewer's (`HemisphereLight` + `DirectionalLight`, `MeshStandardMaterial`). Paint: metalness 0.45, roughness 0.32.
- Arcade driving, same as `viewer/src/drive.ts`. **Not the game's physics.**
- Ground: collision triangles in 8 m cells. Walls: vertical segments.

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
- Some distant backdrop objects seem to float above the horizon (far-level background props) [I].
- The far level uses average texture colour: the switch to a near tile is visible.
- Car lighting is the viewer's, not the game's: the game uses environment maps [D].
- Aftermarket rims, spoilers and roof scoops (`WHEELS`, `SPOILER`, `ROOF` packs) are not mounted yet: the car is stock.
- The BMW driver texture (`4e8cf857`) is not on the disc: it shows dark grey, as in the viewer [V].
- No gamepad, sound, traffic, police, races or menus yet.
- Driving is an arcade prototype, not the decomp physics.

## Road to a playable DMG (next steps)

1. ✅ **First-launch installer** and `scripts/make-dmg.sh` (see above).
2. **Developer ID signing and notarisation**: needs a (paid) Apple Developer account. Without it the `.dmg` works but macOS warns on first open (right-click → Open).
3. **Gamepad** (GameController) and wheel; video settings (PS2 look, scale, FOV).
4. **Real physics** from the decomp (`zPhysics`, `zDynamics`) and each car's VLT attributes.
5. **Audio** (EA SCHl/MPC) and music.
6. **Seamless garages** (already in the viewer) and car selection.
7. **Races and Blacklist** from `gameplay.json` + `roads.json`.
8. More performance: compressed textures (ASTC/BC7), the game's section occlusion, argument buffers.
9. More faithful car shadow and lights; environment reflections.

## Purpose

Show that the open data in `map-data/` is enough for a native engine.
Give a clean Swift + Metal base towards a playable `.dmg`, with no emulator and no PS2 binary.
