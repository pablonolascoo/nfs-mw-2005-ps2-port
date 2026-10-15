# Original game interface (FEng): menus, HUD, fonts and text

Tags: [V] verified on SLES-53559 bytes or measured · [D] from the decomp · [I] inferred · [H] hypothesis.

The native engine draws **the game's own interface**: EA's `.fng` packages (FEng), their textures, fonts and the disc's text in
Spanish (PAL) or English (NTSC-U). There are no extra menus around it. Everything is drawn at the Mac's native resolution.

Code: `tools/src/lib/feng.ts` (reader), `tools/src/cli/frontend.ts` (converter), `native-engine/Sources/Rockport/UI/` (engine).
Decomp: `src/Speed/Indep/Src/FEng/` and `src/Speed/Indep/Src/Frontend/`.

## 1. Where it is on the disc [V]

| File | Contents |
|---|---|
| `FRONTEND\FRONTB.LZC` (JDLZ) | 147 menu packages (MainMenu, MainMenu_Sub, MW_LS_Splash, Dialog, Options…), 2 fonts, 1 texture pack |
| `GLOBAL\INGAMEB.LZC` | 32 in-game packages: `HUD_SingleRace`, `Pause_Main`, `HUD_Drag`, results… + `tac_numbers` font |
| `GLOBAL\GLOBALA.BUN`, `GLOBAL\GLOBALB.LZC` | `font_mw_body`, MW logo, `FadeScreen`, common icons |
| `GLOBAL\WIDESCREEN_GLOBAL.BUN` | widescreen (`WS_*`) loading/movie screens |
| `LANGUAGES\<LANG>.BIN` | string table (chunk `0x00039000`) and 6 fonts per language |
| `LANGUAGES\LANGUAGETEXTURES.BIN` | language font atlases |
| `GLOBAL\HUDS_CUSTOM_00…10.BIN` | HUD tachometer skins (needles, fills, 7000–10000 lines) |
| `GLOBAL\HUDTEX*.BIN`, `GLOBAL\DYNTEX.BIN` | HUD textures; per-language captions (BUSTED_SPA, EVADED_ENG…) and tips |

bChunks: `0x00030203` package, `0x00030210` compressed package (`u32 hash` + JDLZ), `0x00030201` font [D: SpeedChunks.hpp][V].

## 2. Package format (FEng) [D][V]

- On PS2 everything is **little-endian** [V]. The decomp byte-swaps in `FEngGetu32` because it comes from GameCube.
- `FEChunk = {u32 id, u32 size}`; four-letter ids, bit `0x80000000` = container:

```
FEng ─ PkHd {u32 version ≥ 0x20000, u32, u32 resources, u32 objects, u32 nameLen, u32, name, file}
     ├ TypS {u32 type, u32 data bytes}[]       Image 0x54 · String/Group 0x44 · Multi 0x90 · Colored 0x94
     ├ ResL ─ RsNm (names) · RsRq {u32 n; n × {id, nameOffset, type, flags, handle, param}}
     ├ ObjL ─ Butn {u32} · FObj ─ ObjD (tags) · Scrp (tags) · MsgR (tags)
     ├ PkgR (package responses) · Targ (message → listening objects)
```

- Tag = `{u16 id, u16 size}` + data; two-letter ids: `Ot` type, `OP` {guid, name hash, flags, resource}, `PA` parent group guid,
  `SA` initial data block, `St` UTF-16 text, `SH` language label, `Sj` justification, `Sl` leading, `Sw` max width,
  `If` image flags, `M1–M3` multi-image textures.
- Object names are **not** stored ("Stripped" packages): only the `FEHashUpper` hash (h·33+c, start 0xFFFFFFFF, upper-case).
  Editor names `__X__` are hashed without the underscores: `PAD_ACCEPT` = `0x406415E3` [V].
- Data block (32-bit words) [D: FEObjData]: 0–3 colour **b, g, r, a** (ints 0…255, may exceed 255), 4–6 pivot, 7–9 position,
  10–13 quaternion, 14–16 size, 17–20 UVs (images), 21–36 mask UVs and rotation (multi-image) or 4 vertex colours (coloured image).
- Resource → texture: `bStringHash` of the upper-case file name without path or extension [D: LoadResources].
- `If` image flags: bit 0 tile U, bit 1 tile V [I: matches UVs > 1 in 880 of 882 cases].
- Object flags: bit 0 invisible, bit 1 no translation, bit 3 PC only, bit 28 button [D].

### Scripts (animation)
- `Sh` {id, length, flags, track count}; `FI` {param type, bytes, interpolation, action, length}; **`To`/`Tt`/`Ta`: the value is
  the tag's first byte** [V] (the decomp does `Getu16 >> 8` on swapped bytes); `Kd` keys {i32 time, values}; `EV` events
  {message, target, time}; `Sc` chained script.
- Key 0 = **base** value (time −1); the rest are **deltas**: value = base + lerp(prev, next) [D: FEInterpLinear].
- Types: 1 int, 2 float, 3 vec2, 4 vec3, 5 quaternion (base · slerp), 6 colour.
- Time in ms (16 per 60 Hz frame) [D]. At the end: chain (`Sc`), or once / loop / ping-pong (flags & 3).
- Messages: `MR_SetScript`, `MR_PostMessageToFEng`, `MR_PostMessageToGame`, `MR_SetActiveButton`, `If/Else/EndIf` [D].

### Drawing [D][V]
- 640×480 canvas with the origin at the centre. Image = unit quad × size. Matrix: T(pos)·T(pivot)·R·T(−pivot)·S.
- Groups multiply matrix and colour ((c·g + 128) >> 8). Objects with alpha 0 are skipped.
- Order: Z descending; equal Z → last object in the file first (stable radix walked backwards in `RenderObjectList`,
  asm SLUS-21351 `0x2507C8` [V]).
- Multi-image: texture 1 is a **mask** with rotated UVs (`rotate_uvs`); this fills the heat and nitrous arcs.

## 3. Fonts [D][V]
Chunk `0x30201`: `name[256]` · `texture[256]` · `RealFontOld::Font` "FNTS" {version, glyph count, flags, ascent, descent,
glyph/kern offsets, states[24]}. Line height = `states[1]` [V]. 16-byte glyph {unicode, width, height, u, v, advanceY, offX, offY,
nKern, kernIndex, advanceX}; kerning {u16 previous char, s8 amount, u8}. Atlases are white with 16 alpha levels (PSMT4).
Layout follows `FEngFont::RenderString`: justification, `^` = newline, word wrap, max width.

## 4. Text [D][V]
Chunk `0x00039000`: `{i32 histogramPos = 0x10, i32 count = 4464, i32 recordsPos, i32 stringsPos}` (not a "header size").
Sorted records `{u32 hash, u32 offset}`. Histogram-packed strings (`WideCharHistogram::UnpackString`): byte < 0x80 = ASCII;
≥ 0x80 → table; if the table gives 1…0x7F it is a two-byte pair. PAL: Spanish; NTSC-U: English.

## 5. Conversion (`tools/src/cli/frontend.ts`, ~4 s)
`map-data/<ID>/frontend/`: `index.json`, `packages/*.json` (191), `textures/<hash>.png` (910, original size), `fonts/*.json` +
`*.sdf.png`, `strings/<lang>.json`. Plus `minimaps/<MAP>.png` + `minimaps/index.json` (radar, §8.4), the `GLOBAL\RIVALS.BIN` textures and a per-texture `wrap` (TilableUV). Part of `build-all.ts` and the installer ("Interfaz del juego" step; `DATA_FORMAT` = 4).
Not committed (`.gitignore`).

## 6. Engine (`native-engine/Sources/Rockport/UI/`)

| File | Role |
|---|---|
| `FEAssets.swift` | On-demand loading: packages, premultiplied textures, fonts, strings |
| `FERuntime.swift` | Objects, scripts, events and messages like `FEPackage`/`FEngine` |
| `FERenderer.swift` | Metal drawing at native resolution; text layout |
| `FEScreens.swift` | Screen flow and icon carousel (`IconScroller`) |
| `FEHud.swift` | Original HUD with the logic of `Frontend/HUD/*` |
| `EngineUI.swift` | Engine glue (menu camera, start, restart, HUD data) |
| `RaceHUD.swift` | `RaceHUD` API for races and the career (§8.7) |
| `FERaceHUD.swift` | Results, Blacklist, car won, end of pursuit and test scenarios |
| `FEDebug.swift` | `ROCKPORT_FE_DUMP`: list of what is drawn |
| `Input/MenuInput.swift` | D-pad/stick, ✕ accept, △/○ back, Start; keyboard: arrows, Enter, Esc |

### Scaling and sharpness
- The canvas keeps its 4:3 aspect and is centred; anything a package places outside (854-px backgrounds) is still drawn.
- **Images**: Catmull-Rom (9-tap bicubic) on the original premultiplied texture; trilinear when minifying. xBR/ScaleFX were
  rejected: MW textures are anti-aliased artwork, not pixel art, and those filters smear them.
- **Text**: the converter builds a **×4 signed distance field** of each atlas (bicubic + 0.5 threshold + exact Euclidean distance).
  The engine draws it with one-pixel smoothing: clean edges at 4K. Not true vectors (curves come from a 4-bit bitmap), but no
  stair-steps or blur at 2940×1912.
- **Colour**: the UI is drawn **after** the PS2 grade, on the final image in screen space, as the PS2 GS drew the UI over the scene.

### Working screens
| Screen | Package | State |
|---|---|---|
| Press START | `MW_LS_Splash` | Logo, "Press START" with its stamp and blink animation. Background: the 3D city slowly orbiting (the game showed the garage) |
| Main menu | `MainMenu` | The game's icon carousel: Career, Challenge Series, Quick Race, My Cars, Options. Only Career continues; the rest open `Dialog.fng` with "Coming soon." |
| Career | `MainMenu_Sub` | Resume / Start new → free roam |
| Pause | `Pause_Main` | Resume free roam, Restart (safehouse 1), Options (coming soon), Quit to menu |
| HUD | `HUD_SingleRace` / `HUD_Drag` | The whole game HUD with its logic: see §8 (radar, pursuit, races, messages) |
| Results, Blacklist, car won | `PostRace_Results`, `InGameReputationOverview`, `Showcase` | §8.7 |
| End of pursuit | `BUSTED_OVERLAY`, `PostRace_MilestoneRewards` | §8.5 |

The custom HUD (`HUDPursuit.swift`) only appears with `--debug-hud` (§8.5). Start/Esc pauses; ⌘Q quits.
`--no-ui` starts as before; `--drive` goes straight to driving with the HUD.

### Headless tests
```bash
.build/release/Rockport --screenshot .build/shots/ui/mainmenu-2940.png --size 2940x1912 --ui-test MainMenu
#  --ui-test Splash | MainMenu | Career | Pause | HUD | Dialog | <package>   --ui-time <ms>   --ui-hud-demo
```
Screenshots in `native-engine/.build/shots/ui/` (1920×1080 and 2940×1912).

## 7. To do
- Movies (EA logos, intro), the garage-with-car background in menus; the arrest NIS (only its camera layer exists).
- Generic button navigation (`FEButtonMap`) and other screens (options, quick race, shops, race sheet, milestones).
- UI sounds (sound messages are ignored).
- Data the HUD can already show but the game does not produce yet: backup, hiding spots, cops destroyed/damaged, helicopter,
  live infractions, pursuit milestones, radar detector (speed cameras), real NOS/speedbreaker, engine temperature.
- Picking the radar map from Blacklist progress (`MINI_MAP_UNLOCK_1/2` from the career).
- 63 textures named by packages are not on the PS2 disc (PC keys, Xbox, demo).

## 8. 100 % original HUD (FEngHud) [D][V]

Code: `UI/FEHud.swift` (elements), `UI/RaceHUD.swift` (race API), `UI/FERaceHUD.swift` (screens and test scenarios),
`UI/EngineUI.swift` (game data). Decomp: `Frontend/HUD/FEPkg_Hud.cpp` plus one file per element.

### 8.1 How the game turns each piece on and off
- When the HUD is created **every** object in the package is made invisible (`FEngSetAllObjectsInPackageVisibility(false)`).
  Each element registers its objects (`RegisterGroup` registers the group's leaves, not the group) and only those are switched
  by `HudElement::Toggle` from the `DetermineHudFeatures` mask. **Anything no element registers is never shown** (editor
  leftovers such as online data and test boxes used to show).
- A **group's** invisible flag does not hide its children: `FEngine::RenderGroup` only checks alpha; visibility is checked per
  leaf and only objects with z > 0 are drawn (`Sorter.AddObject`) [D: FEngine.cpp]. The engine now does the same.
- "PC only" objects (flag 8): the flag is copied to children and they are hidden on load (`FEngTransferFlagsToChildren`,
  `FEngHidePCObjects`); `FEngSetVisible` never shows them. This removes keyboard/mouse buttons.
- Texture wrapping comes from the **texture** (`TextureInfo::TilableUV`, bit 0 U, bit 1 V); otherwise it clamps to the edge.
  The converter stores it in `index.json` (`wrap`).

### 8.2 The striped orange bar under the pursuit meter
It is `OUTRUN_BACKING` (object `0x8C20A763`), the **backup timer backing** ("REFUERZOS/BACKUP: 0:24") of `PursuitBoard`. The
game shows it only while `mTimeUntilBackup > 0` (APPEAR, or blink `0x26DED57` in the last 10 s) and otherwise plays `LEAVE`. It
was always visible because of our bug: `LEAVE` wipes the texture by moving its UV from 1 to 2 and the engine repeated the
texture instead of clamping it, leaving the stripes. With `TilableUV` = 0 (clamp) the bar leaves like in the game. Our police
has no scheduled backup yet, so it does not appear in play.

### 8.3 Elements and feature bits (`DetermineHudFeatures`)
| Element (decomp) | Bits | What it does here |
|---|---|---|
| `Speedometer` | 0x8000000 | 3 digits, km/h in Spanish, mph in English |
| `Tachometer` | 0x2 | Needle 66°–294°, gear (grey while shifting), shift light; stock HUD `HUDS_CUSTOM_00` (TACH_FILL_00, TACH_NEEDLE_00, 7000–10000 lines) |
| `NitrousGauge` / `SpeedBreakerMeter` | 0x800 / 0x40000 | Arcs with a rotated mask (175° → 0°) and an icon that blinks while draining |
| `HeatMeter` | 0x4000 | Heat arc, flame and "x N" (pops when the level rises: script `0x41E1FEDC`) |
| `Minimap` | 0x10000 | Radar with the game's map, see 8.4 |
| `RadarDetector` | 0x200000 | Radar detector, top centre (free roam and cooldown; leaves during a chase) |
| `PursuitBoard` | 0x100000 | Time (`Timer::PrintToString`: " 1:23.40"), bounty with thousands separator, cops involved/damaged/destroyed with their flash, 5-piece BUSTED/EVADE bar, COOLDOWN, hiding and backup |
| `CostToState` | 0x1000 | "PURSUIT CTS" for 120 frames each time the cost rises |
| `MilestoneBoard`, `Infractions` | 0x400000000 / 0x200000000 | No milestones or infractions in free roam: hidden |
| `GenericMessage` | 0x1000000 | Centre messages with their animation (BUSTED `0x9D73BC15`, lap, tollbooth…) |
| `Countdown` | 0x400 | 3 (`0x3C3C2F7`), 2 (`0xE479`), 1 (`0xCE01`), GO! (`0x535`, text `0x61223AB5`) |
| `RaceInformation` | 0x4000000 | Position X/Y, lap X/Y or "COMPLETE NN %", time; tollbooth: icon and booth X/Y |
| `LeaderBoard` | 0x18 | 4 rows: names and, every 90 frames, gaps (or accumulated speed in speedtraps) |
| `WrongWIndi` | 0x20 | "Wrong way" after 2 s (widescreen version `0x908E787E`) |
| `TimeExtension` | 0x2000000 | Tollbooth "time extension" with the clock icon |
| `DragTachometer`, `ShiftUpdater`, `EngineTempGauge` | `HUD_Drag` only | Big tachometer −43°…44.5°, shift lights, temperature |

Factory options [I]: gauges, position and leaderboard on; split times on; radar rotates with the car.

### 8.4 Radar (minimap) [D: FeMinimap.cpp][V]
- Textures: `TRACKS\L2RA\MINI_MAP.BIN` (free roam; `MINI_MAP_UNLOCK_1/2` depending on the Blacklist) and one map per event
  `MINI_MAP_<event id with "_">` (267 in total, with the route painted in). Each file has 64 `0x3A100` chunks = LZ header + a pack
  with one 128×128 piece `MINI_MAP_CHOPn` (8×8 grid). The converter stitches them into `frontend/minimaps/<MAP>.png`
  (1024×1024) and the engine slices them back into `<MAP>_CHOPn` textures, like `ChoppedMiniMapManager`.
- Calibration: `TrackInfo` of track 2000 (chunk `0x34201` in `GLOBALB.LZC`, 0x120 B per track): corner (−1224.9, −1591.1),
  width 6659.3 m [V]. `ConvertPos`: x = (X − corner.x)/width; y = (corner.y − Y)/width + 1. Checked: the map matches the streets
  around the car (north-up view, `ROCKPORT_MM_NORTH=1`).
- The 4 pieces around the car are drawn (`TRACK_MAP1…4`, 128 units each = 832 m); the layout shifts and rotates around the car;
  the round mask (`MINIMAP_MASK`) moves through its UVs. **No speed zoom**: the decomp computes `1 − v/MinimapMaxSpeed` and
  clamps it to at least 1, so it is always 1.
- Icons (`UpdateElementArt`): radius 0.06 of the map (≈ 400 m); farther ones stick to the edge and fade between 0.125 and 0.23.
  Cops are grey; in a pursuit they flash blue/red (8-frame cycle). Racers `MMICON_AIRACER_n`, checkpoint `MMICON_CHECKPOINT`, helicopter.

### 8.5 End of a pursuit
- **Busted**: the HUD's "BUSTED" message at once; 1 s later [I], `BUSTED_OVERLAY.fng` (police camera: REC, "ROCKPORT POLICE ·
  CAMERA 01", suspect sheet with the game's string `0x626AC043`) for 3 s, with the HUD off as during the arrest NIS. It is drawn
  stretched to full width, like the PS2's anamorphic widescreen.
- **Evaded**: `PostRace_MilestoneRewards.fng` (`PostRaceMilestonesScreen::StartBountyAnimations`): "BOUNTY ACHIEVED", pursuit
  length, bounty and total; ✕ to continue (the simulation pauses meanwhile).
- `HUDPursuit.swift` (HEAT/COPS/BUSTED in a Mac font) is **no longer used**: only with `--debug-hud`. Without `frontend/` data
  there is no HUD. `--traffic-test` also draws the original HUD (the test car acts as the player; `--no-ui` removes it).

### 8.6 Widescreen
With the widescreen option the game sends `0x62ED04EC` to the HUD: the radar group (`0x1603009E`) moves 120 units left and the
tachometer group (`0x5D0101F1`) 120 right [V], and the radar moves its centre. It is meant for 16:9 (visible half width 426.7
units); on 16:10 (2940×1912) the offset shrinks proportionally so nothing is cut off [I].

### 8.7 Race and career API (`RaceHUD`)
`engine.raceHUD` (nil without UI). Methods: `beginRace(RaceHUDSetup)` (kind, laps, racers, `eventID` → the event's radar map),
`endRace`, `showCountdown(3…0)`, `setPosition`, `setLap`, `setTimer`, `setProgress`, `setRacers`, `setNextCheckpoint`,
`setRoute`, `setRacerBlips`, `setSpeedtrap`, `setDrag`, `showMessage`, `showResults` (`PostRace_Results`), `showBlacklist`
(`InGameReputationOverview` with portrait `RIVAL_nn_IG`, tag `RIVAL_nn_IG_GRAF` from `GLOBAL\RIVALS.BIN`, name
`BLACKLIST_RIVAL_nn_AKA`, challenge text and requirements; ↑/↓ changes rival), `showCarWon` (`Showcase` with the rival's tag and
the make), `dismissScreens`. Drag races use `HUD_Drag`.

### 8.8 Tests and debugging
```bash
R=".build/release/Rockport --data ../map-data/SLES-53559 --size 2940x1912 --frames 1"
$R --screenshot hud.png --ui-test HUD-chase      # HUD-free | HUD-chase | HUD-cooldown | HUD-busted | HUD-evaded
$R --screenshot race.png --ui-test Race-circuit  # Race-sprint | Race-drag | Race-knockout | Race-speedtrap | Race-tollbooth | Race-countdown
$R --screenshot res.png --ui-test Results        # Blacklist | CarWon
ROCKPORT_FE_DUMP=dump.txt $R …                    # what is drawn: hash, texture/text, 640×480 rect, alpha, script, parents
ROCKPORT_MM_DEBUG=1 ROCKPORT_MM_NORTH=1 $R …      # radar: position and pieces; north up
```
Screenshots in `native-engine/.build/shots/hud/` (1920×1080 and 2940×1912).
