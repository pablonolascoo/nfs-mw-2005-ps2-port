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
`*.sdf.png`, `strings/<lang>.json`. Part of `build-all.ts` and the installer ("Interfaz del juego" step; `DATA_FORMAT` = 3).
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
| HUD | `HUD_SingleRace` | Tachometer (needle, redline, gear, shift light), 3-digit speedometer (km/h in Spanish), nitrous, heat meter, pursuit board (BUSTED/EVADED, cops, time, bounty), cooldown |

It replaces the custom HUD (`HUDPursuit.swift` stays as a fallback). Start/Esc pauses; ⌘Q quits.
`--no-ui` starts as before; `--drive` goes straight to driving with the HUD.

### Headless tests
```bash
.build/release/Rockport --screenshot .build/shots/ui/mainmenu-2940.png --size 2940x1912 --ui-test MainMenu
#  --ui-test Splash | MainMenu | Career | Pause | HUD | Dialog | <package>   --ui-time <ms>   --ui-hud-demo
```
Screenshots in `native-engine/.build/shots/ui/` (1920×1080 and 2940×1912).

## 7. To do
- Movies (EA logos, intro) and the garage-with-car background in menus.
- Minimap (`TRACKMAPS.BIN`, 36 MB of textures), milestones, infractions, countdown and HUD messages.
- Generic button navigation (`FEButtonMap`) and other screens (options, quick race, shops).
- UI sounds (sound messages are ignored).
- 63 textures named by packages are not on the PS2 disc (PC keys, Xbox, demo).
