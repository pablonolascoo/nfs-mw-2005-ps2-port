# Music and mixing

Tags: [V] verified in bytes on SLES-53559 (and SLUS-21351 where stated) · [D] decomp · [I] inferred · [H] hypothesis.

The game's music is **interactive**: EA PathFinder 5. A `.MPF` file describes a graph of audio pieces (nodes), how they
chain (branches) and what each game command does (events). The audio lives in a separate `.MUS`.

## 1. Files

| File (`SOUND\…`) | Bytes | What |
|---|---|---|
| `PFDATA\MW_MUSIC.MPF` + `.MUS` | 8,936 + 257,105,024 | EA Trax songs, ambiences and musical stingers (project 0) |
| `PFDATA\MW_MUS_1…4.MPF` + `.MUS` | 14–18 KB + 30–42 MB | Pursuit music: 4 projects, one active at a time |
| `MIXMAPS\MAPOUTPUT{,DRG,2CR,2DR}.MXB` | 10,008 | Mix maps loaded by the game |
| `MIXMAPS\MAPOUTPUT{,DRG,2CR,2DR}.DYN` | 43,656–43,784 | The same map with names (editor file) |
| `FXEDIT\*.FX` (15) | 160–336 | Reverb presets |
| `EVT_SYS\*.CSI` (7), `SPEECH\COPSPEECH_*.CSI` (3) | 64–5,136 | Csis interfaces ("MOIR") |

Totals [V]: **1363 samples**, 3.2 h of audio. The 10 `PFDATA` files, the mix maps and the reverbs are **byte-identical on
SLES-53559 and SLUS-21351** [V]; the NTSC disc only has the English radio `.CSI`. 26 songs (91 min), 14 ambiences, 8 stingers, 1310 pursuit pieces.

## 2. Extract (local use)

```bash
cd tools && bun src/cli/music.ts ../original/SLES-53559.iso SLES-53559            # fast: copy + JSON
bun src/cli/music.ts ../original/SLES-53559.iso SLES-53559 --audio                # + every sample as FLAC (ffmpeg)
bun src/cli/music.ts ../original/SLES-53559.iso SLES-53559 --check                # compare with vgmstream-cli
bun src/cli/music.ts ../original/SLES-53559.iso SLES-53559 --dump                 # print the graph
```

Output in `map-data/<ID>/music/` (not committed):

```
music/
├─ MW_MUSIC.MPF/.MUS, MW_MUS_1…4.MPF/.MUS   verbatim from the disc (~400 MB). The app decodes them itself.
├─ music.json        projects (nodes, branches, events, samples), songs, ambiences, stingers and game logic
├─ mixmaps.json      4 maps × 13 states with names
├─ reverbs.json      15 presets + the zone that uses each
├─ csi.json          Csis interfaces
└─ audio/<PROJECT>/NNN[ Artist - Title].flac   only with --audio (1363 FLAC)
```

Code: `tools/src/lib/pathfinder.ts` (MPF + MUS + decoder), `tools/src/lib/mixmap.ts` (MXB/DYN, CSI, FX),
`tools/src/cli/music.ts`.

## 3. MPF format (PathFinder 5) [V]

Little endian. The first 4 bytes read `xDFP` ("PFDx" reversed).

| Offset | Type | What |
|---|---|---|
| 0x04 | u8, u8 | version 5, subversion 1 |
| 0x06 | u16 | 0x01B0 [?] |
| 0x0C | u8 | 0 in MW_MUSIC, 1 in MW_MUS_n [?] |
| 0x0D–0x11 | u8 × 5 | number of tracks (1), sections, events, routers, variables |
| 0x12 | u16 | number of nodes |
| 0x14 | u32 | node index (u16 per node, × 4 = position) |
| 0x18 | u32 | node data |
| 0x1C / 0x20 | u32 | event index (u16 × 4) / event data |
| 0x24 | u32 | variables (20 B each) |
| 0x28 | u32 | router index (u32 × 4, one more than routers) |
| 0x2C / 0x30 | u32 | track index / track data |
| 0x34 | u32 | sample table (8 B each) |
| 0x38 | u32 | end of file (= size) |

**Node**: 16 B + 4 B per branch. Every node size matches the index across all 1664 nodes [V].

| Offset | What |
|---|---|
| 0x00 i16 | wave: `N > 0` = sample N−1 · `0` = silent node (part header) · `−1` = end · `−3` = fire the event at 0x0C |
| 0x02 u8 | section × 0x20 (MW_MUSIC: 1 songs, 2 ambiences, 3 stingers) [I] |
| 0x03 u8 | 0x00, or 0xF8 on end nodes with two branches [?] |
| 0x04 u8 | 13–34 on pursuit waves, 0 in MW_MUSIC [?] |
| 0x05 u8 | high nibble = number of branches |
| 0x06 u8 | 0x40 = has a wave · 0x10 = no wave |
| 0x08 u16 | on waves: node of the **part** it belongs to. It is the `nodeparm` passed to `SongProgressCallback` [D]. Elsewhere, a counter |
| 0x0B u8 | 4 on waves (notify the game) [I] |
| 0x0C u32 | on −3 nodes: event id (24 bits) |
| 0x10 | branches `{u8 min, u8 max, u16 target}`: when the wave ends, go to target if `min < control ≤ max` (min 0xFF = −1) |

The **control** is the 0–127 intensity that `MusicFlow::Update` sends with `PATH_control` [D].
Typical branch ranges: ≤20, ≤65, ≤85/100/110, ≤127 [V].

**Event**: 20 B + 12 B per action. 0x0C = id (low 24 bits) | action count << 24 [V]. The game code uses a different top byte
(e.g. 0x01C53FC7 in the decomp vs 0x02C53FC7 on disc): only the low 24 bits are compared [V].

| Action (type/code) | Parameters | What |
|---|---|---|
| 4/3 | node, 0xFF | go to node [V: reaches every song and part] |
| 4/0x0F | 0xFFFF, 0x1FF | flush the queue / stop what plays [I] |
| 0x0D/0x0F | parameter, id | game callback `EventActionCallback(id, parameter)` [D]: 1 = song finished, 2 = InteractiveDone, 3/0 and 3/1 = switch project (EVT_SWAP1/2) |
| 5/0x0C | 0x100 \| volume, ms | fade [H] (0x100 → 0 over 1750–3500 ms; 0x17F → 127) |
| 2/0x0C | ms, 0 | wait [H] |
| 8/0x0D | 127, 23 | volume [H] |
| 8/6, 0x0E/0x0A, 0x0E/0x0E, 4/2 | — | variables and routers [H] |
| 1/0x9D, 0x9E, 0xAD, 0xAE, 0x11D, 0x12D | variable, value | "if variable == value" and variants [H]; 1/0x40 closes the block |
| 9/0 | low id, high id | fire another event [H] |

In conditions, MW_MUSIC variable 0 is `rapsheet` (1–3, set by the game with `PATH_setnamedvalue`) [D+V]; in the pursuit
projects variable 3 holds the current part node (compared with 0, 0x6A, 0xD5, 0x132…) [I].

**Variable**: name[16] + initial i32. MW_MUSIC: `rapsheet`, `partnode`, `newnode`, `ambstate`; pursuit: `partnode`, `newnode`.
**Router**: list of u16 pairs (node, node); 26–34 per pursuit project, none in MW_MUSIC [?].
**Track**: u32 first sample, u16 sub-banks (0 = stream), big-endian u32 = first 4 bytes of the `.MUS` [V].
**Sample**: u32 offset/0x80 in the `.MUS` · u32 length in ms [V: matches each stream header].

## 4. MUS format [V]

Consecutive `SCHl` streams aligned to 0x80, one per sample:

- `SCHl` {LE u32 size} `GSTR` (generic platform) + u32 and tags `{tag, n, n BE bytes}` up to 0xFF:
  0x06 priority (101), 0x80 version (3), 0x82 channels (2), 0x84 rate (32,000), 0x85 sample count.
- `SCCl` (block count, BE), `SCDl` × n, `SCEl`.
- `SCDl` {LE u32 size} **BE** u32 block samples (6412 = 229 frames) · BE u32 offset of each channel · data.
- **EA-XA v2** codec per channel: 15-byte frames (28 samples) or 0xEE + histories + 28 PCM samples (61 B).
  ADPCM history **carries over** from one block to the next.
- 36,216 B/s (the decomp's `PATH_TRACK_BYTESPERSEC`) [D].

Own decoder: `decodeMusStream()` in `pathfinder.ts`. **All 1363 samples are sample-exact against vgmstream r2117**
(239 M stereo samples in MW_MUSIC + 130 M in MW_MUS_1…4) [V]. Speed: ~3.5 s for the 2 h of songs on an M4.

## 5. Songs (EA Trax)

Titles live in the attribute database (`GLOBAL\ATTRIBUTES.BIN`, class `music`: `Artist`, `SongName`, `Album`, `PathEvent`,
`DefPlay`), the order in `audiosystem.mwlicensedmusic.PFMapping` [V]. `PathEvent` is the MW_MUSIC event that plays it.
`DefPlay`: FE = menus, IG = in game, AL = both.

| # | Artist – Title | DefPlay | Sample | Length |
|---|---|---|---|---|
| 0 | Styles Of Beyond – Nine Thou (Superstars Remix) | AL | 16 | 3:48 |
| 1 | T.I. Presents The P$$C – Do Ya Thang | FE | 14 | 4:06 |
| 2 | Rock – I Am Rock | FE | 8 | 3:24 |
| 3 | Suni Clay – In A Hood Near You | FE | 13 | 3:43 |
| 4 | The Perceptionists – Let's Move | FE | 2 | 2:55 |
| 5 | Juvenile – Sets Go Up | FE | 17 | 3:52 |
| 6 | Hush – Fired Up | FE | 1 | 3:19 |
| 7 | DJ Spooky and Dave Lombardo – B-Side Wins Again feat. Chuck D | FE | 3 | 4:27 |
| 8 | Celldweller feat. Styles Of Beyond – Shapeshifter | AL | 15 | 3:17 |
| 9 | Lupe Fiasco – Tilted | FE | 5 | 3:24 |
| 10 | Ils – Feed The Addiction | IG | 21 | 3:54 |
| 11 | Celldweller – One Good Reason | IG | 7 | 3:12 |
| 12 | Hyper – We Control | IG | 11 | 2:54 |
| 13 | Static-X – Skinnyman | IG | 12 | 3:21 |
| 14 | Diesel Boy + Kaos – Barrier Break | IG | 22 | 2:18 |
| 15 | Disturbed – Decadence | IG | 10 | 3:18 |
| 16 | The Prodigy – You'll Be Under My Wheels | IG | 6 | 3:53 |
| 17 | The Roots and BT – Tao Of The Machine (Scott Humphrey's Remix) | IG | 20 | 3:06 |
| 18 | Stratus – You Must Follow (Evol Intent VIP) | IG | 24 | 3:55 |
| 19 | Mastodon – Blood And Thunder | IG | 18 | 3:41 |
| 20 | Evol Intent, Mayhem & Thinktank – Broken Sword | IG | 23 | 2:33 |
| 21 | Bullet For My Valentine – Hand Of Blood | IG | 4 | 3:18 |
| 22 | Paul Linford and Chris Vrenna – The Mann | IG | 26 | 3:28 |
| 23 | Avenged Sevenfold – Blinded In Chains | IG | 9 | 5:27 |
| 24 | Jamiroquai – Feels Just Like It Should (Timo Maas Remix) | IG | 19 | 3:00 |
| 25 | Paul Linford and Chris Vrenna – Most Wanted Mash Up | IG | 25 | 3:34 |

Rest of MW_MUSIC [V unless stated]:
- Sample 0 (30 s): title screen (event 0x01C53FC7, `SPLASH`) [D].
- Samples 27–29: rap sheet, one per `rapsheet` value (1–3) [D+V]. 30: 0.3 s looping silence.
- Samples 31–39: ambience of map zones 0–8; 40 safehouse, 41 tuning shop, 42 other menus, 43 car lot
  (`AmbientCrossMap` [D]; zones 9–13 in `UpdateAmbience` [D]). 44: ambience of event 0x9DF7DA [?].
- Samples 45–52: 3–6 s stingers when switching pursuit project (EVT_SWAP1/2 of each of the 4 projects) [D+V].
- Each song: silent node → wave → −3 node (event 0x641F27, callback 1 = "finished") → end. The game picks the next one.
- Zone ambiences fade according to the `ambstate` variable and repeat (branch 1–127 back to the same node); with control 0
  they move on to the next [H].

## 6. Pursuit music (MW_MUS_1…4)

Each project has 9 **parts**, each a silent node followed by short waves (1.5–16 s) [V]. The node of each part comes from
`PFXMAP` in the decomp (`SFXCTL_Pathfinder5.cpp`) [D] and matches the file's headers [V]:

| Part | MW_MUS_1 | MW_MUS_2 | MW_MUS_3 | MW_MUS_4 |
|---|---|---|---|---|
| NEUTRAL | 0 (104 waves) | 0 (106) | 0 (71) | 0 (64) |
| LOSE (getting caught) | 106 (105) | 108 (76) | 73 (59) | 66 (98) |
| WIN (getting away) | 213 (91) | 186 (48) | 134 (100) | 166 (104) |
| ELUDE (hiding) | 306 (75) | 236 (40) | 236 (85) | 272 (38) |
| LOSE_END / WIN_END / ELUDE_END | 383 / 393 / 399 | 278 / 290 / 300 | 323 / 335 / 345 | 312 / 322 / 332 |
| ENDPAUSE_1 / END_PAUSE_2 | 409 / 412 | 310 / 313 | 355 / 358 | 342 / 345 |

How it plays (decomp, `Speech/MusicFlow.cpp` and `SFXObj_Pathfinder.cpp`) [D]:
1. When `SoundAI` is in an active or searching pursuit, `StartInteractiveMusic(0x026E7282)` switches from MW_MUSIC to the
   interactive project; MusicFlow waits 0.5 s and sends `EVT_START` → node 0 (NEUTRAL).
2. Every frame MusicFlow computes a 0–1 intensity (0.99/0.01 moving average) and sends it × 127. When each wave ends, the
   branch whose range holds the intensity picks the next one: more intensity = a more intense layer.
3. MusicFlow changes state and sends the event: NEUTRAL 10, LOSE 11, WIN 12, ELUDE 13, end 14 (`EVT_ENDWIN`) or 15
   (`EVT_ENDBUSTED`). The events test the current part (conditions) and jump to the new part.
   - LOSE: the player is below 12.5 % of top speed with a roadblock, or the police are within 32 m.
   - WIN: average speed > 50 % of top speed (or cooling down and ≥ 35 %).
   - ELUDE: searching, stopped and unseen for > 4 s.
   - Every state lasts at least 30–90 s before changing ("busy").
4. Every wave reports its part to the game (`SongProgressCallback`), so MusicFlow knows where it is.
5. At the end, the final part fires callback 2 (`InteractiveDone`) and songs come back after 40 s of ambience
   (`PURSUIT_TO_LIC_DELAY`).
6. Project: one of the 4 at random at start; `EVT_SWAP1/2` moves to the next one and plays the MW_MUSIC stinger.
   Split screen loads none (songs only).
7. Pursuit breaker: low-pass 65,535 → 630 Hz over 1 s, then 1800 Hz; back to 65,535 Hz on exit.

## 7. Mix maps (MIXMAPS) [D structure; V parsing]

`szMixMapFiles[eMapType]`: 0 `MAPOUTPUT` (normal), 1 `MAPOUTPUTDRG` (drag), 2 `MAPOUTPUT2CR`, 3 `MAPOUTPUT2DR`
(split screen [I from the names]). The game loads the `.MXB`; the `.DYN` is the same map with names.

- Header `stMixMapHeader` {MixMapID 0, NumStates 13, table at 0x10, −1} and 13 states (`eMAINMAPSTATES`: MAIN, MUSIC,
  PLAYERCAR, AIRACECAR, COPCAR, TRAFFIC, ENVIRONMENT, COLLISION, DRIVEBY, PLANE, TRAIN, HELICOPTER, TRUCK).
- State `stMixMapStateHdr` (0x20 B): offsets to MixCtl, 3DMixCtl, SubMix, MasterMix, Preset and EventCtl.
- Records (see `mixmap.ts`): MixCtl `{nINPUTID, nUScaleCntSwing}` + scales; 3DMixCtl `{nINPUTID}` + 24 B per camera state;
  SubMix `{MIXCHID, UpperLowerSwing}` + inputs; Master `{MIXCHID, MixData, SFXOBJID}` + inputs; Event
  `{nEVTCTLID, nUScaleCntSwing, nTriggerID, 3 params}` + scales (AR/ASR/ATR/LFO envelope); Preset per master channel.
- Every section ends exactly where the next begins in all 4 maps [V].
- `MAPOUTPUT`: MAIN state with 23 controls ("FE Music Slider", "IG Music Slider", "SFX Slider"…), 38 event controls
  ("NIS Play Ducker", "Pursuit Breaker", "Speech Ducker", "Jump Cam Duck"…), 24 master channels ("@Cop Speech", "@RADIO volume"…).
- Names: 1352 records named from the `.DYN`; 22 `.DYN` records of MAPOUTPUT/DRG have slightly different values
  (older editor revision: volumes and one input) [V]. 2CR/2DR match completely.

## 8. Reverbs (FXEDIT) and CSI

- `SFXObj_Reverb` loads 12 presets (`csfxedit[]`) and picks one from the "Reverb" ParameterMap zone
  (`ReverbZoneCrossMap`: CARSHOW_SML, CARSHOW_BASS, CARSHOW_BASS_2, GARAGE, GARAGE_SML, SIMPLE_TUNNEL, SIMPLE_TUNNEL_SML,
  HILLS_CLOSE, HILLS, CITYOPEN, CITYDENSE, ALLEY) [D]. There are 15 `.FX` on the disc.
- `.FX` is big endian: "FX" 0x0B00, u32 size (= file) [V], u32 4, u32 n [?], … u32 3, u32 m [?]. Then modules
  (`{u8 type, u8 index, u16, u16}`: type 7 with two values, type 1 with 5000–7500 [delay ms?]) and 12-byte connections
  `{u32 from, u32 to, u8, u8}` in two chains, padded with 0xCCCC [H]. Run by the IOP (`Snd::Hal::SetCustomFx`), not in the decomp.
- `.CSI` "MOIR": list of Csis interfaces `{name, id}` + file id. **452 of 454** match the `InterfaceId`s in
  `EAXSound/SND_GEN/*.cpp` [V+D]. The two that don't: `FX_ROADNOISE_TRANS` is not in the decomp and carries the id the
  decomp gives `FX_ROADNOISE` (0x1B49), and `FX_ROADNOISE` carries 0x2C48 (another revision of the interface). The
  `COPSPEECH_*.CSI` ones (139, one per radio event) use header version 1, with the count in the u16 at 0x0A.

## 9. To do

- Exact meaning of actions 1, 2, 5, 8, 9, 0x0E and 4/2 (conditions, fades, variables, routers) and of routers: needs the
  library's `PATH_*` functions (assembly only in the decomp).
- Node bytes 0x03 (0xF8) and 0x04; exact branch condition on end nodes with 0xF8.
- Sample 44 and events 0x9B7A50, 0xD2E818, 0x4F246E, 0xB29728, 0x6DD6BB: unnamed in the decomp.
- Player in the app (Swift): walk nodes and branches with the MusicFlow intensity; `music.json` + `.MUS` are enough.
- Full `.FX` format and per-zone reverb; use the mix maps instead of the port's own categories.
