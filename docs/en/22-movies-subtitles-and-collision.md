# Movies, subtitles, game collision and other formats from the audit

Tags: [V] verified on bytes with SLES-53559 · [D] decomp · [I] inferred · [H] hypothesis.
All of this came out of the coverage audit (doc 21). Nothing exported here goes into git.

## 1. Movies: what is on the disc

- 32 movies × 3 audio languages on the PAL disc: `MOVIES\<NAME>_<ENGLISH|SPANISH|ITALIAN>_PAL.MPC` [V].
- The 64 Spanish and Italian ones were `_UNKNOWN` inventory entries. Their names were found by hash and are in
  `tools/data/filenames-extra.list` [V].
- **The story and tutorials are dubbed** in Spanish and Italian [V]. In `STORYFMV_BLA134` music and effects are identical
  (correlation 1.000) and the voice changes (0.1–0.5) exactly where there is dialogue.
- The 15 Blacklist movies and the attract movie are byte-identical in all three languages. The EA logo and the PSA differ.
- Game rule [D: `FEObjectCallbacks.cpp CalculateMovieFilename`]: `MOVIES\<name>_<LANGUAGE>_<PAL|NTSC>`; if missing in the current
  language, English. On this disc a French or German player gets the English movie without subtitles (their text is empty) [I].

| Kind | Movies | Length | Notes |
|---|---|---|---|
| Story `STORYFMV_*` | 9 | 32 s – 3 min 9 s | Dubbed; subtitles in 6 languages |
| Blacklist `BLACKLIST_01…15` | 15 | ~30 s | Rival portraits; captions ("From: …") translated |
| Tutorials `*_TUTORIAL` | 5 | 24–52 s | Dubbed; two text lines per phrase in 10 languages |
| `EALOGO`, `PSA`, `ATTRACT_MOVIE` | 3 | 3 s, 11 s, 61 s | — |

## 2. MPC format [V: compared with ffmpeg]

Consecutive blocks `{char tag[4], u32 LE size (including the 8 B)}` until the end of the file:

| Block | Contents |
|---|---|
| `MPCh` | **One MPEG-2 picture** per block. The first one also carries the sequence header (`00 00 01 B3`), its extension and the comment "Encoded with MPEG Gimex module" |
| `SCHl` | Audio header: `GSTR`, 12 B and EA tags from `0xFD` to `0xFF`. `0x80` = 3 (revision → ADPCM R3, 48 kHz by default), `0x85` = sample count, `0x82` = channels |
| `SCCl` | u32 number of audio blocks |
| `SCDl` | Audio: u32 BE sample count, u32 BE offset of each channel (relative to that header) and 28-sample frames |
| `SCEl` | End |

- Video: 512×416, 25 fps, aspect code 1, 13-picture GOP with B pictures (`I P B B P B B …`) [V].
- Audio: EA ADPCM "R3", 48 kHz stereo. Frame: 1 B {coefficient | shift} + 14 B of nibbles, or `0xEE` + 2 history samples +
  28 big-endian PCM samples. History carries over from one block to the next [D: ffmpeg `adpcm.c`].
- **Our decoder** (`tools/src/lib/mpc.ts decodeMpcAudio`) produces **1,615,852 samples × 2 channels identical to ffmpeg**
  for `STORYFMV_BLA134_SPANISH` (0 differences), in 45 ms [V].

## 3. Subtitles [V][D]

`SUBTITLES\<movie>` = `SubtitleInfo[]` of 8 B [D: `Frontend/SubtitleInfo.hpp`, `SubTitle.cpp`]:

| Offset | Field |
|---|---|
| +0 | u16 `startTime` in tenths of a second; `0xFFFF` = end |
| +2 | u16 padding (always `0x0087`: tool garbage) |
| +4 | u32 `stringHash` = `bStringHash` of the label; `0x001A20BA` = `bStringHash("")` = clear the text |

- The text lives in each language table (`LANGUAGES\<LANG>.BIN`, chunk `0x00039000`, doc 17). `LABELS.BIN` gives each label's
  name: `SUBTITLE_STORY_<n>_<m>` [V].
- **English, Dutch, Swedish, Danish, Finnish and Polish** have the story text. In **Spanish, Italian, French and German**
  those entries exist but are **empty**, because those movies are dubbed [V]. This answers the open question in doc 16.
- When the game shows them [D: `SubTitler`]: story subtitles only if the language is not English and the text is not empty.
  Tutorial subtitles always.
- Tutorials: each entry is two lines, `bStringHash("_A", hash)` and `bStringHash("_B", hash)` (the string is chained onto the hash) [V].
- `^` in the text is a line break [V]. `LARGEST.BIN` is, for each text, the longest translation (to size boxes) [V].
- Result: 30 subtitle files, 169 phrases, 12 languages with text.

## 4. Playback in the native engine: decision

**Decision: play the MPC files directly, without ffmpeg and without converting them at install time.**

| Piece | How | Status |
|---|---|---|
| MPEG-2 video | **macOS VideoToolbox** (`kCMVideoCodecType_MPEG2Video`): a software decoder that ships with the OS. Each `MPCh` block is passed as-is as one sample | [V] 807/807 pictures of `STORYFMV_BLA134` without errors, ~900 pictures/s on an M4 (36× real time) |
| Picture order | VideoToolbox returns pictures in **decode order** even with `EnableTemporalProcessing` [V]. Reorder with the picture header's `temporal_reference` (PTS = GOP start + reference; `parseMpc().pictures`): hold the last I/P until the next one | [V] output PTS 0, 3, 1, 2, 6, 4, 5, 9… |
| Audio | Own R3 decoder (port `decodeMpcAudio` to Swift, ~40 lines) → AVAudioEngine at 48 kHz | TS [V] identical to ffmpeg |
| Data | `movies.json` stores each file's `isoOffset` and size: the app reads the movie **from the player's ISO** without copying it (0 s install time, 0 MB) | Done in the converter |
| Language | Game rule: app language → file; if missing, English. Subtitles follow `SubTitler`'s rule | Data in `movies.json` |
| Display | 512×416 shown at 4:3 with bars [I] (the PS2 stretched the picture to 4:3) | — |

- Why not convert at install: an MPEG-2 decoder in TypeScript would be a lot of code and take minutes for 2.3 GB; ffmpeg
  cannot ship inside the app (licence and size). VideoToolbox already does it in the OS.
- If the player moves the ISO: the app warns and runs without movies (or, optionally, copies only the chosen language, ~0.76 GB).
- Other platforms [I]: Windows has an MPEG-2 decoder in Media Foundation (Windows 8+); iOS has the same VideoToolbox.
- **Done in the native engine** (`native-engine/Sources/Rockport/Movies/`): see §13.

## 5. Game collision: `CollisionGeometry::Bounds` [V][D]

`0x8003B900` (container) → one `0x0003B901` per object [D: `Physics/Bounds.h`]:

- `0x11` padding to 16 · `BoundsHeader` 16 B {UCrc32 name, i32 count, i32 resolved (0), pad} · `Bounds[n]` of 0x30 B ·
  optional `PCloudHeader` + point clouds (Vector4).
- `Bounds`: +0x00 quaternion s16 / 32767 · +0x08 position s16 / 1000 m · +0x0E flags (`Box` 0x40, `Sphere` 0x80,
  `PrimVsWorld` 0x2, `PrimVsObjects` 0x4, `MeshVsGround` 0x10…) · +0x10 half-dimensions s16 / 1000 · +0x16 child count ·
  +0x17 point cloud · +0x18 pivot · +0x1E first child · +0x20 radius f32 · +0x24 UCrc32 surface · +0x28 UCrc32 name.
- `GLOBAL\GLOBALB.BUN`: **83 cars**, 10–14 volumes each. First example: root box 0.99 × 0.58 × 2.24 m (half sizes), two body
  boxes, a `MeshVsGround` floor box and spheres at the corners. All 83 names are `attribHash(<CAR>)` [V].
- `TRACKS\L2RA.BUN`: **405 world objects** (2,141 volumes, 332 point clouds): lamp posts, signs, breakable fences.
  Their name is `attribHash` of the scenery model name (179 of 405 resolved, e.g. `XS_Speed35_1b_00`, `XO_LightPostB_1b_00`)
  and is the UCrc32 the breakables in `effects.json` point to (`smokeables[].collision`, doc 24) [V].
- Surfaces resolved by hash: `carbody`, `metal`, `glass`, `wood`, `stone` [V].
- Useful for the original car-vs-car and car-vs-object crashes (today the port uses an approximate box). Reader `lib/bounds.ts`,
  exporter `cli/bounds.ts` → `bounds.json`.

## 6. Drivable-area outlines ("troughs") [V][D]

`TRACKS\L2RA\TROUGHBOUNDARY.BIN`: 563 `0x00034190` chunks, one per outline [D: `TroughBoundary` in the PS2 types]:
+0x08 name[80] (`TRN_CP_<zone>_Road_A_nn`, `…_Terrain_…`, `…_Segment`, `…_Hole`) · +0x58 type (regular / hole / anti) ·
+0x5C number · +0x5E parent · +0x60 2D box · +0x70 point count · +0x74 points (x, y). The size adds up on all 563.
484 regular outlines and 79 holes, inside Rockport's bounds. Likely use: knowing whether the car left the drivable area and
resetting it [I]. Exported by `effects.ts` (`effects/troughs.json`, reader `lib/world-extra.ts`, doc 24 §9).

## 7. Car normal smoothing [V][D]

Inside every solid of `CARS\<CAR>\GEOMETRY.BIN` (30 MB in total, the largest missing piece of the cars):

- `0x00134017` `eNormalSmoother`: 12 B header, **zero on disc** (filled at load time).
- `0x00134018` `eSmoothVertex[]` (8 B): u32 position hash · u8 group · normal s8×3 / 127. 99.7 % with |n| ≈ 127.
- `0x00134019` `eSmoothVertexPlat[]` (12 B): u32 hash · u32 group mask [I] · u16 strip | u16 vertex << 16.
  165,846 of 165,846 indices valid on 5 cars; all vertices with the same hash are at the same place (±1 cm).
- Use [D: `CarRender.cpp eSmoothNormals`]: when the car is assembled with tuning parts, the seam normals are averaged.
  Reader `lib/smooth-normals.ts`. The port does not apply it yet.

## 8. "MEMO" bundles (`GLOBAL\*MEMORYFILE.BIN`) [V]

Copies of other files to read them in one go: header {0, 0, `0x53219999`, count} + 20 B entries {path hash, offset, size,
stored bytes, [H]}. `GLOBALMEMORYFILE` has 25 (attributes, `GLOBALB.LZC`, English, `.CSI`, the resident part of the car
TPKs…); `INGAMEMEMORYFILE` 29 (radio tables, `.FX`, mix maps). All 54 are byte-identical to the original (or to its start).
Reader `lib/memfile.ts`.

## 9. Memory-card strings (`MEMCARD\LOCALE_*.LOC`) [V]

`LOCH` + `LOCI` (id → index) + `LOCL` (40 UTF-16LE strings). 19 languages, plus `LOCALE_ENGLISH_ASIAN.LOC` (new name).
Reader `lib/loc.ts`. The port saves to `save.json` and does not need them.
The `MEMCARD\*.ICO` icons are the standard PS2 format (1,074 vertices, 128×128 RLE texture: a Rockport "NFSMW" licence
plate). Reader `lib/ps2icon.ts` [V].

## 10. Per-section scenery culling [V][D]

Inside each `STREAML2RA.BUN` section (0x80034100), 9.4 MB that were missing [D: `World/Scenery.cpp`]:

| Chunk | What | Format |
|---|---|---|
| `0x00034105` | Box tree (`SceneryTreeNode`) | 0x24 B: f32 min/max box · s16 child count · s16 children[5]. Child ≥ 0 = instance; < 0 = node −child. Root = node 0 |
| `0x00034107` | Precomputed occlusion (`tPrecullerInfo`) | 128 B = 1,024 bits. Bit set = the instance is not visible with the camera in cell `((int)x >> 5 & 31) + ((int)y & 0x3E0)` (32 × 32 cells of 32 m, repeating every 1,024 m) |
| `0x00034106` | Instance → override (`SceneryOverrideInfoHookup`) | u16 override number · u16 instance number |

- Each instance points to its occlusion table with an s16 at +0x1C (+0x1E = lighting context, −1).
- Checked: all 137,503 children are valid; the 110,954 instances are reached exactly once from the root and fit inside their
  node's box; the highest occlusion index is the last of its table in all 1,476 sections; the 18,902 hooks point to
  instances and overrides that exist.
- The decomp's PS2 types give the node an s16 box (0x18 B); on disc it is float (0x24 B) [V].
- The game only uses the occlusion above 40 mph and outside the cells listed in `PRECULLERBOOBOOSCRIPT.HOO` [D].
- Reader `lib/scenery-cull.ts`. The native engine draws HLOD tiles and does not need it yet; it could draw less in the city.

## 11. How to generate

```bash
cd tools
bun src/cli/movies.ts ../original/SLES-53559.iso SLES-53559 [--srt] [--wav]   # movies.json (+ SRT, + check WAVs)
bun src/cli/bounds.ts ../original/SLES-53559.iso SLES-53559                   # bounds.json
bun src/cli/coverage.ts ../original/SLES-53559.iso SLES-53559 --docs          # doc 21
```

`movies.json`: `movies[]` with `name`, `kind` (historia = story, lista-negra = blacklist, tutorial, otro = other), `video`
(pictures, fps, GOP), `audioByLanguage.<LANG>` (`path`, `isoOffset`, `size`, `identicalToEnglish`, audio),
`differentFromEnglish` and `subtitles` (`cues[]` with `start`, `end`, `label`, `text.<LANG>` and, for tutorials, `textB`).

## 12. To do

- "D-Day" prologue (events 16.x): its movies are mapped (§13.3) but the events do not exist in the port yet.
- Exact trigger of the pursuit and bounty tutorials (the code that launches them is not in the decomp).
- Use `bounds.json` for crashes and the trough outlines for resets.
- Apply normal smoothing when assembling cars with tuning parts.
- Names for 226 of the 405 world objects in `bounds.json` (the full name is not on the disc: doc 24).

## 13. Movie player in the native engine (`Movies/`)

| Piece | File | What it does |
|---|---|---|
| Catalogue and ISO | `MovieLibrary.swift` | `movies.json`; the ISO is memory-mapped (4 GB of address space, only what plays is read) and each MPC is a slice of it. Looks for the ISO in `install.ok` ("iso"), `--iso`, `ROCKPORT_ISO` and the repo's `original/<ID>.iso`. Without an ISO: one warning and the game goes on without movies |
| Container and audio | `MPCFile.swift` | MPCh/SCHl/SCDl blocks; each picture's PTS = GOP base (header `00 00 01 B8`) + `temporal_reference`; EA ADPCM R3 audio ported from `lib/mpc.ts` |
| Video | `MPEG2Decoder.swift` | VideoToolbox (`kCMVideoCodecType_MPEG2Video`, Metal-compatible BGRA). Each sample carries its PTS; the output (in decode order) is reordered with a small window |
| Playback | `MoviePlayer.swift` | Background load, a video thread 12 pictures ahead, audio through AVAudioEngine at 48 kHz. **Audio is the master clock**: each frame shows the last picture with PTS ≤ clock (pictures are dropped when late; video is never waited for) |
| Drawing | `MovieRenderer.swift` | Black, the picture at 4:3 with bars, subtitle at the bottom (white text on a dark box, like `SubTitler`) |
| Director | `Movies.swift` | Queue, skipping, game moments (§13.3), settings `settings.json → "movies": {"enabled", "intro"}` |
| Tests | `MovieTests.swift` | `--movie-test` (§13.4) |

### 13.1 Decisions

- **No PS2 grade** [I]: the game draws movies with its movie player (FEng `FEMovie`), outside the scene and its visual
  treatment; there is no evidence they went through the world's grade. They are shown as encoded in the MPEG-2.
- **4:3 with bars** [I]: 512×416 is stretched to 4:3 as on a TV; on wide screens, side bars. The movies already carry black
  bars inside the picture (letterboxed widescreen inside 4:3) [V: screenshots].
- While a movie plays, `Engine.frame` hands over the whole frame: simulation, UI and engine hooks wait; game sound is muted and
  music pauses where it was ("Is Movie Playing" / "NIS Play Mute" in the mix map, `ESndGameState` FMV [D]).
- **Language**: the UI's (`frontend/index.json`, `spanish` on the PAL disc) or `--lang`. Audio: that language's dub if it exists,
  otherwise English [D]. Subtitles follow `SubTitler` (§3): with the PAL disc in Spanish the story is dubbed and has no text; the
  tutorials and the Blacklist captions ("Procedencia: Beacon Point") do show [V].
- **Volume** per movie: the game's `MovieVolumeArray` [D] (story 0x50, attract 0x41, logo 0x3C, tutorials 0x37, PSA 0x32,
  Blacklist 0x2D, out of 0x7F).
- **Skip** with Start / ✕ (A) on the pad or Return / Space / Esc. The EA logo cannot be skipped [D: `MovieData.Bypassable`];
  D-Day movies only after 5 s [D: `MoviePlayer_Bypass`].
- Dubbed audio runs a bit longer than the video in some movies (`STORYFMV_BLA134`: 33.66 s of audio vs 32.28 s of video,
  `PSA` 12.47 / 11.24 s) [V]: the movie ends when both end; the last picture holds.

### 13.2 Boot

`sBootFlowPAL` [D: `FEBootFlowManager.cpp`]: `LS_EAlogo` → `LS_PSA` → `MW_LS_AttractFMV` → `MW_LS_Splash` ("Press START").
The app does the same before "Press START" (`--skip-intro` or `settings.json → movies.intro = false` turn it off). On "Press START",
30 s without input goes back to the attract movie [D: `SplashScreenMovieTimeout` = 30, `DoAttract`]. `INTRO_MOVIE` and
`EAHD_BUMPER` are not on the PAL disc [V].

### 13.3 When each movie plays in the career

| Moment | Movie | Source |
|---|---|---|
| New career (after the prologue) | `STORYFMV_SAF25` → `BLACKLIST_15` | [D] `FEAnyMovieScreen::PlaySafehouseIntroMovie` → `SafeHouseRivalBio` → `uiRepSheetRivalFlow` stage 5 |
| Rival beaten | `BLACKLIST_<new bin>` (introduces the next rival) | [D] `uiRepSheetRivalFlow::Next` stage 5: `blacklist_%02d` with the current bin |
| Reaching bin 13 (once) | `STORYFMV_RAP30` (the rap sheet) | [D] stage 6: `!HasRapSheet() && GetCurrentBin() == 13` |
| Event 1.5.2 (bin 1 boss) | `STORYFMV_BLA134` before | [V] `gameplay.json` IntroMovie |
| 1.8.1 (epic pursuit) | `STORYFMV_HER136` before | [V] IntroMovie |
| 16.1.0 / 16.2.1 / 16.2.2 / 16.2.3 (D-Day) | `RAC01` / `PIN11` (and `BUS12` on winning) / `CRO06_COH06A` / `RAZ08` | [V] IntroMovie / OutroMovie |
| Challenge 19.8.32 (tollbooth) | `TOLLBOOTH_TUTORIAL` before | [V] IntroMovie |
| First drag / speedtrap / tollbooth event | `DRAG_` / `SPEEDTRAP_` / `TOLLBOOTH_TUTORIAL` | [D] `InGameAnyTutorialScreen` + `HasDone*Tutorial`; exact trigger [I] |
| First pursuit / first bounty | `PURSUIT_` / `BOUNTY_TUTORIAL` | [H] (the game also offers them with △ in menus, `FEAnyTutorialScreen`) |

- In the Blacklist menu the game also lets you watch each rival's movie with △ (`uiRepSheetRivalBio`, `__PAD_BUTTON4__`) [D];
  the port does not have that screen yet.
- What was watched is stored in the save (`save.json → moviesSeen`), so the rap sheet and tutorials do not repeat.
- `STORYFMV_DDA01`, `EPI138`, `POL17_MOT21` and `ROC02` are in the game's volume table but **not on the disc** [V].

### 13.4 Tests and results [V: M4, SLES-53559]

```bash
cd native-engine && swift build -c release
.build/release/Rockport --movie-test all                       # 32 movies: video + audio, VideoToolbox output order, IntroMovie table
.build/release/Rockport --movie-test BLACKLIST_01               # simulated clock: screenshots every 2 s, audio.wav and stats.json in .build/movie-test/
.build/release/Rockport --movie-test BOUNTY_TUTORIAL --lang dutch --seconds 16
.build/release/Rockport --movie-test STORYFMV_SAF25 --realtime --mute --seconds 8   # real AVAudioEngine, audio clock
.build/release/Rockport --movie-test EALOGO --engine            # inside the engine: "Press START", movie, back to the UI
```

- `all`: **32/32 movies, 37,877 pictures (1,515 s) without a single error**, in presentation order, at 1,640–2,050 pictures/s
  (reading from the ISO). VideoToolbox output `0,3,1,2,6,4,5,9…` for all of them (decode order) [V].
- Simulated clock (`BLACKLIST_01`): 777/777 pictures, none dropped, mean offset 12.6 ms (showing 25 pictures/s on a 60 Hz
  display), maximum +20 ms. Real time (`STORYFMV_SAF25`): 202 pictures in 8 s, 0 dropped, mean offset 10.2 ms, maximum lead
  19.9 ms and maximum lag 9.4 ms.
- `--engine`: 167 movie frames with no game hook running; afterwards "Press START" is back [V: screenshot].
- Without an ISO: a warning and a clean exit ("the app would go on without movies").
