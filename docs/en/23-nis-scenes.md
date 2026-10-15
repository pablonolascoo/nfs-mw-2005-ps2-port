# NIS scenes (in-engine cut-scenes)

Tags: [V] verified on SLES-53559 bytes (and SLUS-21351, same result) · [D] decomp `dbalatoni13/nfsmw` (source or assembly) · [I] inferred · [H] hypothesis.

NIS scenes are the cut-scenes the game plays **with its own engine**: the roll-up to every race start, the Blacklist rival intros, the arrests, the ending, the intro fly-through, the free-roam "moments" (WM*) and the car parts of the story movies (FMV*). They are not video: cameras + car and character animation + events (nitrous, lights, effects, overlays) + audio.

Reader: `tools/src/lib/nis.ts`. Exporter: `tools/src/cli/nis.ts`.

## 1. Running it

```bash
cd tools && bun src/cli/nis.ts ../original/SLES-53559.iso SLES-53559
```

About 4 s of CPU. Output goes to `map-data/<ID>/nis/` (not committed; `.gitignore`: `map-data/**/nis/`):

| File | Contents |
|---|---|
| `index.json` | The 87 scenes (from the game's own table), NIS audio banks, candidates, camera groups without a scene, bytes per chunk |
| `<Scene>.json` | Header, duration, actors, cameras (keys + 30 fps samples), events, engine revs, audio |
| `<Scene>.glb` | Animated nodes (cars, character skeletons with their bind-pose mesh) and animated glTF cameras |

Result [V]: 87 scenes · 83 camera tracks (824 keys) · 271 animated cars · 64 characters · 805/805 animations decoded · 1365 timed events · 58 scenes with audio · 86 valid GLBs (glTF Validator: 0 errors, 0 warnings).

## 2. Data map

| Chunk | Name | Where | Status | Notes |
|---|---|---|---|---|
| `0x80037020` | NisScene (container) | `NIS\SCENE_*_BUNDLEB.BUN` | decoded + exported | Holds 0x37030 and 0x37040 [D: `LoaderAnimSceneData`] |
| `0x00037030` | NisScene header | NIS | decoded + exported | §3 [V] |
| `0x00037040` | Entities (characters/props) | NIS (arrests) | decoded + exported | §4 [D][V] |
| `0x00E34010` | EAGLAnimations | NIS, INGAMEB, L2RA | decoded + exported (NIS) | ELF holding an `AnimBank`; types 10, 11, 20, 21 decoded; 17 (DeltaQ) not decoded (INGAMEB only) §5 |
| `0x00E34009` | EAGLSkeletons | NIS (arrests), INGAMEB (`ROOT`) | decoded + exported | ELF holding `SkeletonData` §6 |
| `0x0003B811` | EventSequence "CARP" | NIS, L2RA | decoded + exported (NIS) | State machine + actions with events §8 |
| `0x8003B200`–`0x8003B203` + `0x0003B210` | ICE cameras per context | `GLOBAL\INGAMEB.BUN` | decoded + exported | NIS, FMV, REPLAY, GENERIC §7 |
| `0x0003B211` | ICEShakeTracks | INGAMEB | decoded, unused | 4 tracks, all 11 556 B accounted for [V] |
| `0x00037060` | AnimDirectory | INGAMEB | decoded + exported | Scene → BUN §9 |
| `0x00037070` | CAnimCandidateData | INGAMEB | partial | Counts, moments, special car lists; race-start candidates raw §9 |
| `0x80134000` / `0xB3300000` | Solids and textures | NIS (arrests) | exported (bind-pose mesh) | Cops, perps and cuffs; no skin weights |
| `SOUND\NISREVDATA\*.BIN` | Engine revs | 29 files | decoded + exported | §10 |
| `SOUND\STREAMS\NISAUDIO.IDX/.EVT/.BIG` | NIS audio | — | decoded + linked | Scene → track `audio/escenas/NNN.flac` §11 |

## 3. Scene header `0x00037030` [D: `NisScene`, `AnimScene.hpp`] [V]

| Off. | Type | Field |
|---|---|---|
| 0x00 | u32 | `mSceneNameHash` = bStringHash(name) — also the `handle` of the camera group |
| 0x04 | char[16] | name (`IntroNis01`, `ArrestM01`…) |
| 0x14 | ptr | description (0 on disc; the text follows at 0x40) |
| 0x18 | s32 | `SceneType` |
| 0x1C | s32 | `HaveLayout` |
| 0x20 | s32 | `HaveCarAnimation` |
| 0x24 | s32 | `NumberOfCars` |
| 0x28 | s32 | `StartFrame` (30 fps frames) |
| 0x2C | s32 | `VanishFrame` → **duration = VanishFrame / 30 s** [D: `BindToGame`] |
| 0x30 | char[16] | "Seeulator" overlay (always empty) |
| 0x40 | char[] | description ("Cars rolling up to start", "Career Racestart Number 05"…) |

`SceneType` [D: `CAnimScene::Init`, `SetCarAnimationPositions`] [V: 25/26/4/32 scenes]:

| Value | Scenes | Coordinate origin |
|---|---|---|
| 0 | IntroNis01–09, GenericStart, IntroNisToll01, WM* | start line |
| 2 | Arrest* | activity position (the bust) |
| 3 | Replay* | start line, player forced into car 1 |
| 4 | IntroNis10, IntroNisBL*, IntroNisDD*, Ending*, Flythrough, FMV* | **world** (0,0,0): coordinates are absolute |

For 0, 2 and 3 the scene matrix is `translate(origin, z = ground) · rotZ(angle − 90°)` [D: `CAnimLocator::GetInitialAnimMatricies`]; origin and angle come from the activity (`NISActivity::StartLocation`): for race starts it is the race grid (`races.json` → `start.pos`/`yaw`).

Check [V]: the IntroNisBL05 cars end at (4794, 973, 13.8) and the `race_bin_05/5_2_2_sprint` grid is at (4792.6, 994.2, 11.7): the scene is world-space and lands on its race. In IntroNis01 the cars drive from y = −28 to y = −3 (local scene, start line at the origin).

Coordinates: the game's render space, Z up, metres (like `world.json` and `races.json`). Simulation space (Y up) = (−y, z, x) [D: `NISActivity::GetNISStartLocation`].

## 4. Entities `0x00037040` [D: `AnimEntity_BasicCharacter.hpp`, `AnimEntity_Prop.hpp`] [V]

Preceded by `0x11` padding. Character (`mTypeID` = 1, 0x90 B; prop = 2, 0x60 B):

| Off. | Field |
|---|---|
| 0x00 | `mTypeID` |
| 0x04 / 0x08 | instance / parent hash |
| 0x0C | `mPlayFlags` |
| 0x10 | `mLocalMatrix` (4×4, placement in the scene) |
| 0x50 | `mLODNameHash[4]` = solid hash (`MCOP01`, `PERP01`, `CUFFS01`…) [V] |
| 0x60–0x6C | translation, rotation, scale and skeleton animation hashes |
| 0x70 | skeleton hash (`Bip20`, `Bip23`, `Bip24`…) |
| 0x74 / 0x78 | play speed and delay |
| 0x7C–0x8C | world object type, loop range, padding |

Only characters exist (64, in the arrests). With a skeleton the speed is `playSpeed × 0.5` → 15 fps [D: `AnimEntity_BasicCharacter.cpp`].

## 5. Animations `0x00E34010` [D: `EAGL4Anim/*`] [V]

The chunk is a **relocatable MIPS ELF32 image** (after `0x11` padding): `.data`, `.symtab`, `.rel.data` (only `R_MIPS_32` against the section, so pointers are offsets inside `.data`). Symbol `__AnimationBank:::bank` points to:

```
AnimBank { s32 size, s32 numAnims, ptr attributeDict, ptr csisDict, ptr anims[], ptr names[], ptr stat }
```

Every animation starts with `u16 type, u16 checksum`. In NIS bundles all of them are **15 = Compound** `{type, cs, ptr attributes, u16 nChannels, u16 nFrames, ptr channels[]}` with sub-channels [V: 805 animations]:

| Type | Name | Format | Used for |
|---|---|---|---|
| 10 | DeltaLerp | `{type, cs, ptr data, u16 nFrames, u16 dofIdx[]}` + DeltaCompressedData | car translation and scale |
| 11 | DeltaQuat | same, 4 values per index | car and bone rotation |
| 20 | DeltaF3 | bins of 2^p frames: u16 physical ×3 + u8 deltas ×3 | bone translation |
| 21 | DeltaF1 | same with 1 component | single bone DOFs |
| 17 | DeltaQ | — | only `Rotate_360_q` in INGAMEB: **not decoded** |

DeltaCompressedData [D: `DeltaCompressedData.cpp`]: `u16 nDofs, u8 bits (4/8/16), pad`, `DofInfo {f32 min, f32 range, f32 start}[nDofs]` and per-frame deltas: `value(f) = start + Σ_{i<f} (q_i · range + min)`.

DeltaF1/F3 [D: `FnDeltaF3.cpp`, `InitBuffersAsRequired` in assembly]: header `{type, cs, ptr dofIdx, ptr times, u16 nKeys, u16 nBones, u8 p, u8 nConst, pad}`, `DofInfo {f32 physMin[c], f32 physRange[c], u16 qMin[c], u16 qRange[c]}`; physical = `q·range/65535 + min`; delta = `q · range·2·qRange/65535/255 + range·(2·qMin/65535 − 1)`. With `times ≠ 0` they are keys at those frames. Constant bones follow the last bin.

DOF indices address the SQT buffer of 12 floats per bone: **0–2 scale, 4–7 quaternion (x, y, z, w), 8–10 translation** [D: `/0xC` in `DeltaChan.cpp`] [V: 2811 curves at 4, 2438 at 8, across NIS, L2RA and INGAMEB].

Check [V]: every quaternion of the 2811 rotation curves (NIS, L2RA and INGAMEB), frame by frame, has norm 1 ± 0.004.

**Cars**: `<Scene>ZPM_Car1…8` / `ZPM_Cop1…8` with `_t`, `_q` (and `_s`) suffixes, on INGAMEB's `ROOT` skeleton (2 bones; the car is bone 1) [D: `CreateCarAnimationControllers`]. They play at time scale 0.5 → **frame = t · 15** [D]. Car forward axis = +X [V: the quaternion heading follows the direction of travel]. The game then snaps the car to the ground and hands it to physics (`SetNISPosition`).

## 6. Skeletons `0x00E34009` [D: `SkeletonData.h`] [V]

Same ELF image. `__Skeleton:::<name>` → `{u32 AnimationTarget, u16 checksum, u16 flags, s32 nBones, ptr invScales}` + `BoneData[n]` of 0x70 B: `S(3), s32 parent, Q(4), T(3), s32 left/right, inverse base matrix (16)`. Every `__Bone:::<skeleton>.<bone>` points to a u32 holding the bone index (`Bip20 L Thigh`…).

Present: `ROOT` (2 bones, cars), bipeds `Bip20`–`Bip23` (48 bones), handcuffs `Bip24` (3 bones).

## 7. ICE cameras [D: `ICEData.hpp`, `ICEMover`/`ICEManager` assembly] [V]

All of them live in `GLOBAL\INGAMEB.BUN`: one container per context (`0x8003B200` NIS, `…01` FMV, `…02` REPLAY, `…03` GENERIC) with 85 `0x0003B210` groups:

```
group:  u32 handle (NIS/FMV: scene hash) · u32 nTracks · tracks
track:  ptr next, ptr prev, ptr group, f32 Start, f32 Length, s16 nKeys, s8, char[14] name, nKeys × ICEData
```

ICEData (0x84 B):

| Off. | Field | Off. | Field |
|---|---|---|---|
| 0x00 | u8 type (12/13/14) | 0x10 | f32 `fParameter` (segment start, 0–1) |
| 0x01 | u8 smooth | 0x14 | f32 tangent[2] |
| 0x02 / 0x03 | u8 cubic eye / look | 0x1C | f32 eye[2][3] (start, end) |
| 0x04 / 0x05 | u8 eye / look space: 0 car, 1 world, 2 hybrid, 3 scene | 0x34 | f32 look[2][3] |
| 0x06 / 0x07 | u8 constrain to cars / world | 0x4C | f32 dutch[2] (radians [I]) |
| 0x08 / 0x09 | u8 ignore orientation / car-space lag | 0x54 | f32 lens mm[2] |
| 0x0A | u8 overlay | 0x5C | f32 near clip[2] |
| 0x0C | u32 shake type | 0x64 / 0x6C | f32 noise amplitude / frequency[2] |
| | | 0x74 | f32 focal distance[2] |
| | | 0x7C / 0x7E / 0x80 | u8 aperture[2], letterbox[2], sim speed %[2] |

Each key is a **segment** of the parameter `[fParameter, next fParameter]` (the last one up to 1) with start and end values; the next key starts where the previous one ends [V].

Evaluation [D]:
- NIS: `p = (t − start) / (duration − start)` with the scene duration (`ICETrack::GetParameter`). FMV/GENERIC: `(clock − Start) / Length`.
- Local `t` is linear inside the segment (`ICEMover::Update`).
- Eye and look: Hermite (`ICE::Cubic1D`: `a = s0+s1−2Δ, b = 3Δ−s1−2s0`) when `bCubicEye`/`bCubicLook`, otherwise linear. Dutch and FOV: Hermite with the eye flag.
- Slopes (`ICEManager::GetSlope`): if the neighbour shares the end point, `w = tc/(tc+tn)`, slope = `Δneighbour · w · tc/tn · tangent + Δown · (1−w) · tangent`; otherwise `Δown · tangent`.
- FOV = `2 · atan(15.96 / lens)` [D: constant `0x417F5C2A`], interpolated as an angle. Horizontal [I]; the GLB converts it to vertical with a 4:3 aspect [I].

Check [V]: in race starts the look point is within 1–5 m of an animated car every second; in arrests within ~1 m of the characters.

Not applied yet: noise, shakes (`0x3B211`), car-space lag, and keys in **car** space (29 NIS and 41 FMV keys: the JSON carries the space of every key so the engine can resolve them with the car matrix).

Groups without a scene: REPLAY (6 groups, car-space replay cameras), GENERIC (36 tracks) and one NIS group `0x020DE420` (8 tracks) whose name is in no list [?].

## 8. "CARP" events `0x0003B811` [D: `EventSeq*` types, `bChunkCarpHeader`] [V]

```
bChunkCarpHeader {s32 size, s32 section, s32 flags, ptr}                16 B
"PRAC" {u32 ?, u32 nEntries+1, u32 1}                                   16 B
"srtS" {u16 ?, u16 text bytes, u32 nStrings, u32 offset from srtS}      16 B
entry × n: {u16 index, char[2] type, u8 3, u24 size, u32 hash, u32 offset relative to the entry}
```

Names are hashed with `attribHash` (Jenkins, seed 0xABCDEF00) and the string table holds all of them. Internal references are `{u16 index, char[2] type}`.

| Type | Structure |
|---|---|
| `Ee` | EventSeqEngine `{ref name, u32 nSystems, u32 ids[], ref systems[]}` |
| `Se` | EventSeqSystem `{u32 initial state, u32 default, u32 nStates, ids[], refs[]}` — one system per actor: `car1`, `cop1`, `GLOBAL`… |
| `Te` | EventSeqState `{u32 nStimuli, ptr filter, u32 stimuli[], {u32 end state, ref action}[]}` |
| `Ae` | EventSeqAction `{u32 name, u32 nTags, u32 nTimes, f32 duration, tags[], f32 times[], ref lists[]}` |
| `le` | EventList `{u32 n, pad[3]}` + `{u32 id, u32 size, u32 offset, pad}[n]` + data |
| `Ni` / `Sc` | strings (engine name / event texts) |

Event id = `attribHash("E" + name)` [V: all 33 types resolve]. The data (`Event::StaticData`) is read with the fields from `Generated/Events/*.hpp`. Most common: `ENISDetach`/`ENISReattach` (release/attach the car to the animation), `ENISCarShake`, `ENISNitro`, `ENISPixelate`, `ENISCarPitch`/`Roll`, `ENISLights`, `ENISBrakelock`, `ENISBurnout`, `ENISOverlayMessage` (`BUSTED_OVERLAY.fng`, `BLACK_FADE_OUT.fng`…), `ENISPlayEffect` (`env_leafblast1`, `dustbillow_md1`…), `ENISTimeOfDay`, `ENISRain`.

In every scene each system goes from `Begin*` to `End*` on the `START` stimulus and fires its action; the JSON timeline assumes `START` arrives at t = 0 [I].

## 9. Directory and candidates (INGAMEB)

`0x00037060` AnimDirectory (0x4808 B) [D] [V]: `u32 nScenes` · `AnimSceneLoadInfo[256] {u32 hash, u8 nShared, u8 first, u8 nOwn, u8 first}` · `u32 nFiles` · `char[256][64]` paths (`NIS\Scene_IntroNis01_BundleB.bun`). 87 scenes = the 87 BUNs on the disc.

`0x00037070` CAnimCandidateData (0x1054 B) [D]: 1 race-start candidate, 41 "moments" (scene → type: arrests 12, WM* 1–20, toll 13) and 53 special car lists (arrests `ONE_COP`, Blacklist `TRAFFIC_MIX1–5`…). Per-track masks are empty.

## 10. Engine revs `SOUND\NISREVDATA\<SCENE>.BIN` [D: `NIS_RevManager::OpenNISRevData`] [V]

16 sets in a row (car 1–8, cop 1–8): `u32 n` and, if n > 0, `n × {f32 time s, s32 RPM, s32 throttle 0–100}`. Whatever follows is recorder garbage (e.g. 7 452 B in IntroNis02). 28 scenes + `OPMRivalIntro` (no BUN): nearly always only car 1; RPM 1000–10 000. This is how your engine sounds during the scene.

## 11. Audio `SOUND\STREAMS\NISAUDIO.*` [D: `SFXObj_NISStream.cpp`, `NISAudio.hpp`] [V]

`.IDX` is a CLUMP_IDX like the police radio one: 4 banks. Bank header: `u16 phrase, u16, u8 nParams, u8 nClips, u8, u8 unit, u32`; per clip `u16 BE offset × (unit+1)·256 B` + parameters [V: all 140 clips land on an SCHl header].

| Phrase | Csis event | Clips | Parameters |
|---|---|---|---|
| 0x4023 | `NIS_Select_Start` | 30 | scene bit, camera-track bit (13 = Track00, 14/15 = garage enter/exit), section (0 complete, 2 end) |
| 0x4025 | `NIS_Select_Blacklist` | 34 | rival bit (0 = BL01… 15 = BL16, 16/17 = BL06End/BL07End), track, section |
| 0x4024 | `NIS_Select_End` | 18 | arrest/ending bit, track, section |
| 0x400E | `SoundFX_Select` | 58 | 2 parameters (stand-alone effects) |

Scene → bit: the game's `uNIS_STRINGHASHMAP` table (68 entries). GenericStart has one track per camera (`audio.cameraTrack1`). "Complete" is the whole track; "end" is what plays when you skip the scene. Tracks run longer than the animation (IntroNis01: 6 s of scene, 11.2 s of audio that carries on over the countdown) [V: FLAC durations]. No audio: IntroNis09, IntroNisBL01 (no clip with their bit), WM*, Replay*, FMV* (those use the movie audio). BL06End and BL07End use the BL06/BL07 audio (that is what the game's table says) although the bank has clips of their own.

## 12. Scene JSON schema

```jsonc
{
  "scene": "IntroNis01", "nameHash": "0x0d0e57f6", "description": "...", "sceneType": 0,
  "origin": "...", "coordinates": "Z up, metres...", "startSeconds": 0, "duration": 6,
  "bundle": { "solids": 0, "texturePacks": 0, "models": [...], "textures": [...], "skeletons": [{ "name", "bones": [{ "name", "parent", "t", "q", "s" }] }] },
  "actors": {
    "cars": [{ "slot": "car1", "channel": "car1", "anims": [...], "frames": 91, "fps": 15, "seconds": 6, "start": [x,y,z], "end": [x,y,z],
               "startRotation": [x,y,z,w], "track": { "t": [x,y,z,...], "q": [x,y,z,w,...], "s": [...] } }],
    "characters": [{ "typeName": "character", "model": "MCOP01", "skeleton": "Bip20", "skelAnim": "ArrestM01_MCop_s", "frames", "fps", "localMatrix": [16], ... }]
  },
  "animations": [{ "name", "frames", "channels": [{ "type", "typeName", "decoded", "dofs" }] }],
  "cameras": [{ "context": "NIS", "track": 0, "name": "Track 0", "start", "length", "spaces": ["scene"],
                "keys": [ICEData as in §7 + "fovDeg"], "sampleFormat": ["time","eyeX","eyeY","eyeZ","lookX","lookY","lookZ","fovDeg","dutch"], "samples": [[...] at 30 fps] }],
  "events": { "engine", "systems": [{ "name", "initialState", "states": [{ "name", "responses": [{ "stimulus", "endState", "action" }] }] }],
              "actions": [{ "name", "duration", "tags": [...], "timed": [{ "time", "events": [{ "id", "name", "data", "raw" }] }] }],
              "timeline": [{ "time", "actor", "action", "event", "data" }] },
  "engineRevs": { "sets": [{ "slot": 0, "points": [[t, rpm, throttle], ...] }] },
  "audio": { "csisEvent", "sceneBit", "complete": { "clip", "file": "audio/escenas/060.flac", "seconds" }, "buttonThroughEnd": {...} }
}
```

GLB: root `NIS_<scene>` rotated −90° about X (Z-up → Y-up), child `scene_origin` (place it on the race grid unless the scene is world-space), nodes `car1…`/`cop1…`, characters (`MCOP01`… with the bone hierarchy and the bind-pose mesh as a child) and `camera_<context>_<track>` with a glTF camera. Animations: `actors` plus one per camera track (they are alternatives: the game picks one with `ChooseGoodSceneCameraTrackIndex`).

## 13. Scenes

| Group | Scenes | What they show |
|---|---|---|
| Race starts | GenericStart, IntroNis01–10, IntroNisToll01 | Cars rolling up to the grid, spins, nitrous; 6–15 s |
| Blacklist | IntroNisBL01–16, BL06End, BL07End | Rival intro before their race, with cops; 15–32 s, world-space |
| D-Day | IntroNisDD, IntroNisDDEnd | Start of the D-Day race (43 s) |
| Arrests | ArrestF02…M19 (+ "b" variants) | Cop (M = male, F = female) and cuffed perp by the patrol car |
| Ending | EndingNis03, EndingNis04 | Last rival race start and the game ending |
| World | WM* (14) | Cameras for the free-roam "moments" (exploding gas station, water tower…) |
| Movie | FMV17to21, FMVroc02, FMV20T1, FMVBLIntro, FMVPIN11X06, FMVPSA, FMVTest, FMVNoCars | Engine-rendered parts of the movies (cars and FMV-context cameras) |
| Replay | ReplaySpeed/Corner/Burnout/Slide | Short car animations for replays |
| Fly-through | Flythrough | Flight over Rockport (45 s, 42 keys) |

## 14. Still missing

- DeltaQ (type 17), used by a single INGAMEB animation [H: compressed quaternion with recovered W, `DeltaQRecoverW`].
- Character skinning: meshes are exported in bind pose; which bone drives each strip is unknown.
- Car/hybrid-space cameras, noise, shakes (`0x3B211` read but not applied) and `ICEMover` lag.
- The exact time of CARP stimuli other than `START` (tagged events) [I].
- `0x00037070`: meaning of the race-start candidate fields.
- Unnamed NIS camera group `0x020DE420`.
- Units of the dutch angle (radians [I]) and whether FOV is horizontal [I].
