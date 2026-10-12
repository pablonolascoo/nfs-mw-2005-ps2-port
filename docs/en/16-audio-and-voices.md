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

- Spanish police radio: **9854 clips** on SLES-53559 [V]. They are sentence fragments the game chains (unit, direction, street name…) [D].
- Which clip plays when is driven by `.IDX`, `.CSI` (`MOIR`) and `.EVT`. Not decoded yet [H].

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
├─ escenas-NISAUDIO.flac
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
- Police radio event table (`.IDX` / `.CSI` / `.EVT`) to play it like the game.
- `.ABK` effect banks (engines, sirens) for the native engine.
