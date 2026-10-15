# Audio and voices

Tags: [V] verified on SLES-53559 / SLUS-21351 · [D] decomp · [I] inferred · [H] hypothesis.

## 1. Where the voices are

| What | Disc file | Format | Languages |
|---|---|---|---|
| Story and Blacklist movies (live actors) | `MOVIES\*.MPC` (32) | MPEG-2 512×416 25 fps (PAL) + EA-XA v2 / EA R3 ADPCM audio, 48 kHz stereo, in `SCHl` blocks [V] | **English only** on both discs [V] |
| Movie subtitles | `SUBTITLES\STORYFMV_*` | bChunk `0x00870000`: (time in tenths of a second, phrase hash) pairs [V] | The text is not in `LANGUAGES\SPANISH.BIN` (those entries are zeroed) [V]. To do |
| Police radio | `SOUND\SPEECH\COPSPEECH_<EN\|SP\|IT>.BIG` (+ `.IDX`, `.CSI`, `.EVT`) | Thousands of `SCHl` clips back to back [V] | PAL: Spanish (Spain), English, Italian · NTSC-U: English |
| In-engine cut-scene audio | `SOUND\STREAMS\NISAUDIO.BIG` | EA R2 ADPCM, 32 kHz stereo, 27 min in one block [V] | — |
| Engine, turbo, skid sounds… | `SOUND\ENGINE`, `TURBO`, `SKIDS`… (`.ABK`, `.GIN`) | AEMS `ABKC` banks + `Gnsu` granular engines (§7) [V] | — |

- Radio clips on SLES-53559 [V]: **Spanish 9854**, English 13,562, Italian 9986. From 0.1 s to ~22 s long.
- Radio codec: EA MicroTalk. vgmstream only opens a clip saved as `.asf` [V]. The port decodes it itself (§5).
- `NISAUDIO.BIG`: 140 SCHl tracks back to back (EA-XA v2) [V].
- Extracted FLAC size: movies 161 MB, scenes 108 MB, radio 706 MB (es) + 1 GB (en) + 762 MB (it). About 22 min on an M4.
- Radio clips are sentence fragments the game chains (unit, direction, street name…) [D].
- Which clip plays when is driven by `.IDX` (banks) and `.EVT` (events): now read, see §6. `.CSI` (`MOIR`) is the Csis interface and is not needed.

## 2. Extract everything (local use)

```bash
brew install ffmpeg vgmstream
cd tools && bun src/cli/audio.ts ../original/SLES-53559.iso SLES-53559
```

Output goes to `map-data/<ID>/audio/` (never committed):

```
audio/
├─ peliculas/<MOVIE>.flac           32 tracks, original English voices
├─ radio-policia-castellano/NNNNN.flac
├─ radio-policia-ingles/NNNNN.flac
├─ radio-policia-italiano/NNNNN.flac
├─ escenas/NNN.flac                140 NIS scene tracks
└─ indice.json                      what each file is and who speaks [I]
```

Lossless FLAC: the same samples as on the disc.

## 3. Voices and cloning
- The voices belong to **real actors**. Their voice is not part of the game licence.
- **No voice is cloned without each actor's written consent.** ElevenLabs requires that too.
- For the expansion: newly **designed** voices (not copies), hired actors, or clones only with consent.
- Playing the player's own disc audio inside the port is fine, just like the textures.

## 4. To do
- Subtitle text (find where the movie strings live).
- Radio: which bank of each phrase is which voice [H], and exactly when the game fires each event (`SoundAI`, `PursuitFlow`).
- ~~`.ABK` effect banks (engines, sirens) for the native engine~~ → done (§7–10). Left: the engines' AEMS layer (MIPS modules), `SOUND\MIXMAPS` (mix maps), which exact sample plays some roles ([H] in §8), music (`PFDATA`).

## 5. Our own MicroTalk decoder (in-game radio)

The app ships neither vgmstream nor FFmpeg: it decodes the radio itself.

| Piece | File |
|---|---|
| TypeScript decoder (converter and tests) | `tools/src/lib/microtalk.ts` |
| The same in Swift (the app, on the fly) | `native-engine/Sources/Rockport/Audio/MicroTalk.swift` |
| Converter step | `tools/src/cli/radio.ts` → `map-data/<ID>/radio/` (`install.ts` step "Police radio", `build-all.ts`) |
| Check against vgmstream | `bun src/cli/microtalk-check.ts ../map-data/<ID>/radio [n]` and `Rockport --radio-test` |

Format [V on SLES-53559 and SLUS-21351]:
- EA SCHl container: `SCHl` header with `PT` tags (0x80 version = 3, 0x85 samples, 0xA0 codec = 4 "MT10", 0x82 channels;
  no 0x84 → 22,050 Hz on PS2), `SCCl` (block count), `SCDl` (u32 block samples, u32 per-channel offset, 1 byte, data), `SCEl`.
- Version 3: each frame starts with one byte; `0xEE` = the frame carries uncompressed PCM samples that replace decoded ones.
- 432-sample frame = 4 subframes of 108: 12 quantised reflection coefficients (6 bits for the first 4, 5 for the rest),
  pitch predictor (8-bit lag, 4-bit gain) and fixed excitation (RELP or multipulse with two Huffman codebooks); reduced bandwidth
  interpolates odd samples. LSB-first bit reader; a new block resets the reader, not the decoder state.
- Some clips are stereo (97 in Spanish, 177 in NTSC English: the `CellCall` phone calls): one decoder per channel; the app mixes to mono.

Result [V]:
- 300 random clips from SLES-53559 (16.3 M samples) and 150 from SLUS-21351: **identical to vgmstream r2117 except ±1** on 0.7–0.8 % of samples, no length mismatch.
- The ±1 comes from vgmstream built for arm64 fusing multiply-add (FMA); our decoder does the same
  (`addingProduct` in Swift, double-precision product in TypeScript). Without FMA the difference reaches ±35.
- Speed: ~5 ms per clip in TypeScript; the app decodes on the fly and caches the last 64.

Output of the `radio` step (never committed: `map-data/**/radio/` is in `.gitignore`):
```
radio/COPSPEECH.BIG   the disc's clips as they are (Spanish 128 MB; NTSC English 172 MB)
radio/radio.json      index: clips [offset, bytes, samples], banks and events
```
Language: PAL (SLES) → Spanish (`SP`), NTSC (SLUS) → English; force with `bun src/cli/radio.ts <iso> <ID> IT` or `ROCKPORT_RADIO_LANG`.
`--wav 0,100` also writes those clips to `radio/wav/` for listening.

Credits: the format was studied in vgmstream (`src/coding/libs/utkdec.c`, `src/layout/blocked_ea_schl.c`, ISC licence), itself based on
Andrew D'Addesio's work (Niotso) on EA's `sx.exe`. The code is our own; the tables (coefficients, codebooks) are format data.

## 6. Radio event tables (`.IDX` / `.EVT`)

| | Spanish (SLES) | English (SLUS) |
|---|---|---|
| Clips | 9854 (391 min) | 13,562 (528 min) |
| Banks | 559 | 579 |
| Distinct phrases | 144 | 152 |
| Events | 139 | 139 |

`COPSPEECH_<L>.IDX` = `CLUMP_IDX_FILE` [D: `EAXSound/Clump.h`; V]: `numtypes`, `numbanks[20]`, `count` at 0x54 and `count` 16-byte entries
`{key = type << 24 | number, size, header, sample}`. `header` is the bank header inside the `.IDX` itself; `sample`, where it starts in the `.BIG`.
Bank header [V, deduced]: u16 phrase number · u16 · u8 `dims` (0, 1 or 2) · u8 clip count · u16 · u32 size/256 · then per clip:
big-endian u16 offset/256 + `dims` bytes with the clip's value for each parameter. Each bank's clips are consecutive in the `.BIG` [V: the 559 banks cover all 9854 clips].

`COPSPEECH_<L>.EVT` [V, deduced; ids from `SND_GEN/P2temp.h`, D]: u32 event count at 0x10 and a table of u16 × 4 from 0x18.
Each event: u16 id (`SPCHType_1_EventID`), u16 priority (200), u16 500, u16 number of alternatives, u8 number of parameters (byte 11).
Each alternative: pieces `{u16 phrase, u16 0x0101 = spoken by the current cop / 0 = fixed voice, u32 condition count, conditions}`,
condition = `{u32 mask of allowed values, u8 parameter number}`. Parameters are the event's `Csis::*Struct` fields in order
(1 = `speaker_id`, 2… the rest) [D: `SND_GEN/COPSPEECH.hpp`]; values are bits (`Type_intensity_High = 2` → index 1).
Examples [V]: `InitPursuit` = phrase 299; `Arrest` = phrase 154; `Disp911Report` = 6 pieces (dispatch tone 269 + type + suspect + direction + street…).

How the port builds a line [I]: event → alternative whose conditions match → for each piece, the bank of the speaking voice
(bank number within the phrase = voice [H]) → the clip whose parameter value matches (intensity, yes/no, number of suspects…) or a random one.
Which event plays when: `native-engine/Sources/Rockport/Audio/PursuitFX.swift` (start, backup, heat, roadblocks, lost visual,
escape, arrest, background reports) and doc 15 §8 (where it plays). What the game does exactly
(`SoundAI`, `PursuitFlow`, `SPCH_Choose`) is not decompiled: the SPCH library only exists as assembly.

## 7. Game sound: disc formats [V with SLES-53559 and SLUS-21351]

| Folder | Contents | Format |
|---|---|---|
| `SOUND\ENGINE` | 160 granular engines `GIN_*.GIN` (on throttle and `_DCL` off throttle), 76 `CAR_NN_ENG_MB_EE/SPU.ABK` banks (AEMS layer), 76 `SWTN_CAR_NN_MB.ABK` (pops), `CAR_TRANNY`, `CAR_WHINE_00` | Gnsu · ABKC |
| `SOUND\TURBO` (32) · `SHIFTING` (16) · `SKIDS` (4) · `NOS` (2) | turbos and superchargers, gear shifts, skids, nitrous | ABKC |
| `SOUND\IG_GLOBAL` (13) | siren, traffic, wind, road noise, impacts (`STICH_COLLISION`), whooshes, ambience, helicopter, rain | ABKC |
| `SOUND\FE`, `GLOBAL` | menu sounds | ABKC |
| `SOUND\MIXMAPS`, `FXEDIT`, `EVT_SYS`, `NISREVDATA` | mix maps, reverbs, Csis interfaces, cutscene revs | not decoded (not needed to play) |

**ABKC** (AEMS bank): 0x5C-byte header (`ABKC`, 0x14 size, 0x18 offset of the `BNKl`, 0x24 size of the sample area).
Between the header and the `BNKl` sit the **AEMS modules: EE MIPS code** (`addiu sp,…`) that picks which sample plays for each
parameter. They are not run: the port uses the decomp's logic (§9) and the role table (§8).

**BNKl** v5: `u16` entry count at 0x06 and a table of relative offsets from 0x18; each entry is a `PT` header of
{tag, n, n big-endian bytes} tags: 0x84 rate, 0x85 samples, 0x86/0x87 loop, 0x88/0x89 per-channel data (relative to the `BNKl`),
0x82 channels, 0xA0 codec (0x0A = EA-XA v2; absent = PS-ADPCM). The last entry is a terminator.
`_EE` (main memory) banks use **EA-XA v2** (15-byte frames or 61-byte `0xEE` PCM frames); everything else **PS-ADPCM**.

**Gnsu** (`.GIN`, the decomp's `GinsuDataLayout` [D]): `Gnsu` `20`, f32 min and max RPM, segment/cycle/sample counts,
rate (32 000 Hz), RPM → sample table (`segCount+1`), cycle start table (`cycleCount+1`) and **EA-XAS** data (19-byte blocks =
32 samples, two 12-bit samples carrying filter and shift). A "cycle" is two engine revolutions: RPM = 120 × rate / cycle period
[D: `GetCurrentPitch() × 120`; V: the cycle table spans the file's min to max RPM].

Converter: `tools/src/lib/abk.ts` (readers and decoders) and `tools/src/cli/sound.ts` → `map-data/<ID>/sound/` ("Sound" step of
`install.ts` and `build-all.ts`, `DATA_FORMAT` 5). It copies the 461 files as they are (33 MB) and writes `sound.json`.

Check (`bun src/cli/sound.ts <iso> <ID> --check`, with vgmstream r2117 locally only):
- **2350 / 2350 sounds from 301 ABK banks identical sample for sample** to vgmstream. 94 of them need the PS-ADPCM history kept
  unclamped, as vgmstream does; the app keeps it clamped like the SPU [I: psx-spx] (only clipping samples change).
- **160 / 160 `.GIN` identical** with the integer decoder (truncated history). The game uses the decomp's floating-point one
  (`GinsuSynthData::DecodeBlock`), which the app and `--wav` use: it differs by rounding inside each block (RMS ≈ 47 / 32 768).
- Same figures with SLUS-21351.

## 8. What plays with what (VLT database and decomp)

`GLOBAL\ATTRIBUTES.BIN` [V]:
- **`engineaudio`** (69): `Filename_GinsuAccel` / `Filename_GinsuDecel`, `BankName_mainRAM`/`auxRAM` (AEMS), `SweetBank`,
  `MinRPM`/`MaxRPM` (.GIN range), `GINSUMix_*`, `DECEL_GINSUMix_*`, `AEMSMix_*` mixes, volumes, ΔRPM thresholds,
  `GINSU_Decel_Min/MaxRPM` + fades, `PhysicsRPM_Map` (RPM curve), `Master_Vol`.
- **`pvehicle`** → `engineaudio[]` per engine level (`UpgradeIntervals`), `TurboSND[]` and `ShiftSND[]` = `UpgradeSpecs {RefSpec, Level}`
  per induction / transmission level, `HornType`, `TrafficEngType`, `WooshType` [D: `EAXCar::Attach`]. E.g. the BMW M3 GTR
  (`bmwm3gtre46`) sounds as **`tvr_cerb`** = `GIN_TVR_CERBERA.GIN` + `GIN_TVR_CERBERA_DCL.GIN` [V].
- **`turbosfx`** (18): bank, `ChargeTime`, `Leak_Rate`, spool and blow-off volumes. **`shiftpattern`** (25): bank,
  `stShiftPair {i16 RPM, i16 Time}` and Bézier curves for the RPM drop/engage, delays and volumes.
- **`audiosystem.mostwanted`**: global banks (skids, nitrous, road noise, wind, siren/traffic/misc, impacts, ambience, menus).
- **`simsurface`**: `Aud_Roadnoise_LOOP` (road-noise loop: asphalt 5, dirt 0, concrete 1, cobbles 2, water 3, blown tyre 6)
  and `Aud_Skid_Type` (0 asphalt, 1 dirt).
- **Impacts**: `GLOBAL\INGAMEB.BUN`, bChunk `0x8003B500` (`BCHUNK_SND_STICHBUNDLE`): 608 "stitches", one per `STICH_COLLISION_TYPE`
  (`CRSH_CAR_2_WALL_FRNT_MED2`…), each a list of `STICH_COLLISION_MB` samples with Q15 volume, Q12 pitch (4096 = 1),
  delay in ms and random variation [D: `STICH_Struct.h`; V: 608 stitches, samples 0–170].

Role of each sample in the banks (the AEMS modules are not run; `sound.json → roles`):

| Bank | Samples | Tag |
|---|---|---|
| Turbo | 0 spool (loop, PSI), 1 small blow-off, 2–3 big blow-offs at random (PSI > 75 %), 4 second loop | [D] `FX_TURBO_01` ids in `CARSFX_Turbo.cpp`; 4 [H] |
| Shifting | 0 down, 1 up, 2 braking | [D] `AEMS_SHIFTING_SAMPLES` |
| Skids | 0–2 tonal asphalt squeals, 3 long drift, 4 dirt noise | [I] from spectra; side/forward split [H] |
| Nitrous | 0 loop, 1 start, 2 stop | [I] |
| Siren | 0 yelp (0.36 s), 2 wail (3.78 s), 1 and 3 the same at 14 kHz (far), 4 short loop | [I] |
| Traffic | 0–1 engine hum, 2 horn, 3 truck horn | [I] |
| Wind | 0 left, 1 right, 2 fast, 3 rumble (1 kHz) | [I] |
| Road noise | 0–6 loops per surface (`Aud_Roadnoise_LOOP`), 7–14 transitions | [D] loop index; transitions [I] |

## 9. Sound in the native engine

| Piece | File |
|---|---|
| Index and decoders (PS-ADPCM, EA-XA v2) | `native-engine/Sources/Rockport/Audio/SFXBank.swift` |
| Ginsu granular engine (data + synthesis, line by line from the decomp) | `Audio/EngineGinsu.swift` |
| Engine logic: audio RPM, gear shifts, on/off-throttle mix, turbo | `Audio/EngineSound.swift` |
| Mixer (a single `AVAudioSourceNode`, ramps, low-pass, soft limiter) | `Audio/SFXMixer.swift` |
| World: cars, 3D, police, traffic, impacts, settings | `Audio/SFXWorld.swift` |
| Headless tests | `Audio/SFXTests.swift` |

One car's engine [D unless stated]:
1. Physics RPM % (idle…redline) → `PhysicsRPM_Map` (Bézier, player only) → **audio RPM** 1000–10 000.
2. `SFXCTL_Shifting`: on upshift the RPM drops along `Up_DisengageFall` and returns along `Up_Engage` with a volume punch
   (`Up_Engaging_Attack_Vol`); on downshift it falls, rises (`Down_Engaging_Rise`), falls and re-attaches. The shift sample plays after `*_Shift_Sound_Delay`.
3. `SFXCTL_HybridMotor` (two .GIN): torque = throttle × 100 (3-sample average); 4-step mean ΔRPM → % of `AccelDeltaRPMThreshold`;
   on-throttle mix `GINSUMix_S…L`, off-throttle `DECEL_GINSUMix_S…L` × `DecelCrossfadeMix`, low-pass `GINSU_LowPassCutoff` when
   lifting; volumes with a max step of 7000 per update.
4. .GIN RPM = (audio − 1000) / 9000 × (MaxRPM − MinRPM) + MinRPM; below the file's minimum the pitch is lowered.
5. `GinsuSynthesis`: 11 ms packets; before each one it jumps whole cycles towards that RPM's position with a 0.5 ms crossfade
   and 60 ms latency. The pitch is the real recording's at any RPM.
6. Turbo (`CARSFX_Turbo`): charges with torque, leaks at `Leak_Rate`, RPM-dependent ceiling, blow-off on lift (small or big at random).
   Nitrous: start + loop + stop. Pops (`SWTN_CAR_NN`, `Vol_Sputters`) when lifting at high RPM [H: own trigger].

What is **not** the game's (port decisions, [H]):
- Everything at **30 Hz** (one update per PS2 frame). With that, the ΔRPM thresholds and the turbo charge give sensible times
  (full boost in ~0.7 s).
- The **AEMS** layer (`CAR_NN_ENG_MB_*` loops): its modules are MIPS code. Its volume (computed like the game from `AEMSMix_*`)
  is shared between the two .GIN so idle keeps its body. No rev-limiter sample: the limiter sounds as an 11 Hz volume chop.
- Per-category mix (`SFXMix`) instead of `SOUND\MIXMAPS`. Skids from wheel slip, wind and road noise from speed.
- Own 3D: 1/distance gain, equal-power pan, half-strength Doppler, and the engine's distance low-pass
  (`UpdateFilterFX`: 24 kHz down to 725 Hz between 6.5 and 50 m). The player's car is unpositioned (camera behind).
- Police: wail/yelp alternating every 4–8 s, at most 4 sirens and 3 engines. Traffic: 6 hums; horn when the player
  brushes past above 65 km/h. Race rivals: the 4 nearest with their full engine.
- Impacts: physics has no crash callback; they are detected from velocity jumps and pick `CRSH_CAR_2_{CAR|WALL}_{FRNT|SIDE}_{VLIT…HRD}`.

Split screen: `SFXWorld.shared.localCarsProvider = { [car1, car2] }` and `listenersProvider = { [listener1, listener2] }`.
Each player car is unpositioned, slightly to its side (−0.35 / +0.35); every other sound is placed against the nearest listener.

Settings: `settings.json → "sound": {"enabled": true, "master": 0.8}`, `SFXWorld.shared.setMasterVolume(_:)`, `setEnabled(_:)`;
at launch `--sound-off` and `--volume 0…1`. Everything goes quiet while paused.

Measured cost (M4, `release` build): **0.15–0.2 % of one core** with 8–10 voices (logic 0.2 ms + mixing 1.4 ms per second of audio).

## 10. Tests

```bash
cd tools && bun src/cli/sound.ts ../original/SLES-53559.iso SLES-53559 --check   # banks and .GIN against vgmstream (local)
bun src/cli/sound.ts ../original/SLES-53559.iso SLES-53559 --wav IG_GLOBAL/SIREN_MB.ABK,ENGINE/GIN_TVR_CERBERA.GIN
cd native-engine && swift build -c release
.build/release/Rockport --sound-dump                 # everything decoded by the app (52 M samples) + vgmstream comparison
.build/release/Rockport --sound-test BMWM3GTRE46     # → .build/sound-test/BMWM3GTRE46.wav (35 s) · --sound-trace: RPM/mix every 0.5 s
.build/release/Rockport --sound-live 3 --volume 0    # the same node through the real output (real-time AVAudioEngine)
```

`--sound-test` [V]: idle, full-throttle run with five shifts, engine braking, nitrous, braking, handbrake and a police pass-by
with siren and impacts. The synthesizer follows the requested RPM within ~1 % (BMW M3 GTR: 0.7 % from the table and 0.1 % measured on the output by autocorrelation; Supra: 0.8 % and 1.3 %).
