# Audio and voices

Tags: [V] verified on SLES-53559 / SLUS-21351 · [D] decomp · [I] inferred · [H] hypothesis.

## 1. Where the voices are

| What | Disc file | Format | Languages |
|---|---|---|---|
| Story and Blacklist movies (live actors) | `MOVIES\*.MPC` (32) | MPEG-2 512×416 25 fps (PAL) + EA-XA v2 / EA R3 ADPCM audio, 48 kHz stereo, in `SCHl` blocks [V] | **English only** on both discs [V] |
| Movie subtitles | `SUBTITLES\STORYFMV_*` | bChunk `0x00870000`: (time in tenths of a second, phrase hash) pairs [V] | The text is not in `LANGUAGES\SPANISH.BIN` (those entries are zeroed) [V]. To do |
| Police radio | `SOUND\SPEECH\COPSPEECH_<EN\|SP\|IT>.BIG` (+ `.IDX`, `.CSI`, `.EVT`) | Thousands of `SCHl` clips back to back [V] | PAL: Spanish (Spain), English, Italian · NTSC-U: English |
| In-engine cut-scene audio | `SOUND\STREAMS\NISAUDIO.BIG` | EA R2 ADPCM, 32 kHz stereo, 27 min in one block [V] | — |
| Engine, turbo, skid sounds… | `SOUND\ENGINE`, `TURBO`, `SKIDS`… (`.ABK`, `.BIN`) | EA banks | — |

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
- `.ABK` effect banks (engines, sirens) for the native engine.

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
