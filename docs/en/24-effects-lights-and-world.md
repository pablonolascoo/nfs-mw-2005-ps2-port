# 24 · Effects, lights and world data

> Converter step `effects`: `bun src/cli/effects.ts <iso> <ID>` → `map-data/<ID>/effects.json` + `effects/`.
> Readers: `tools/src/lib/effects.ts` and `tools/src/lib/world-extra.ts`. Runs in under 1 s.
> Tags: **[V]** verified on SLES-53559 bytes · **[D]** decomp · **[I]** inferred · **[H]** hypothesis.
> What the `fx` step (doc 20) already exports is not repeated here: sun (`0x00034202`), `visuallook*`, `light_flares_cg`
> (car flares), `eLightMaterial` (`0x00135200`) and sky textures.

## 1. Summary: what is where

| Chunk | Name | Where | Status | Output |
|---|---|---|---|---|
| `0x0003BC00` | EmitterLibrary | `STREAML2RA.BUN` (290 sections), `FRONTEND\PLATFORMS\*.BIN` | decoded + exported | 1,535 world emitters + 41 in garages |
| — | `emittergroup` / `emitterdata` / `effects` / `simsurface` / `smackable` / `fuelcell_*` | `GLOBAL\ATTRIBUTES.BIN` (VLT) | decoded + exported | 128 groups, 205 emitters, 198 effects, 47 surfaces |
| — | TPK "PARTICLE" | `GLOBAL\INGAMEB.BUN` | exported | 46 particle textures (PNG) |
| `0x00034027` | SmokeableSpawnerPack | `STREAML2RA.BUN` (350 sections) | decoded + exported | 5,952 breakable objects |
| `0x00034026` | SmokeableInfo | — | not on the PAL disc | — |
| `0x0013401A` | solid markers → flares | `STREAML2RA.BUN` | decoded + exported | 2,242 world flares |
| `0x00034019/1A/1B`, `0x80135100/01/02` | flare packs | — | not on the disc | see §4 |
| `0x80036000/01/02/03` | EventTriggerPack | `STREAML2RA.BUN` (415 sections) | decoded + exported | 12,161 triggers (all sound) |
| `0x00034159` | HeliSheet | `STREAML2RA.BUN` (435 sections) | decoded + exported | 51,504 triangles |
| `0x00034250` | Weatherman (GenericRegion) | `L2RA.BUN` | decoded + exported | 61 regions (all bloom) |
| `0x8003B600…B608` | ParameterMaps | `L2RA.BUN` | decoded + exported | 14 layers (ambience, reverb, speech, fog, rain, clouds, wind, tint) |
| `0x00034201` | TrackInfo | `GLOBALB.BUN` | decoded + exported | 18 tracks |
| `0x00034146` | TrackPositionMarker | `L2RA.BUN` | decoded + exported | 328 markers |
| `0x00034191` | TrackOBB | `L2RA.BUN` | decoded + exported | 1 box |
| `0x00037080/90/110/150` | WorldAnim | `L2RA.BUN` | decoded + exported | 11 trees and instances |
| `0xB0300100` (`0x30300101/2/3`) | TextureAnimPack | `STREAML2RA`, `GLOBALB`, `INGAMEA`, garages | decoded + exported | 11 animated textures |
| `0x0003410C` | ModelHierarchy | `L2RA.BUN` | decoded + exported | 125 hierarchies |
| `0x00034190` | "Trough" | `TRACKS\L2RA\TROUGHBOUNDARY.BIN` | partial | 563 named polygons |
| `0x80034150` (`0x34151/52/53/55/58`) | VisibleSectionManager | `L2RA.BUN` | decoded + exported | 515 outlines, 435 visibility lists, 39 loading zones, 2 overlays |
| `0x00034113` / `0x00034111` / `0x00034112` | streaming: DiscBundle / Info / Barriers | `L2RA.BUN` | decoded + exported / empty | 75 bundles; info = {0, 0}; 0-byte barriers |
| `0x00034105/06/07` | scenery tree, hooks, preculler | `STREAML2RA.BUN` | not decoded | see §8 |

`L2RA_SUNSET.BUN` and `STREAML2RA_SUNSET.BUN` hold the same chunks with the same counts [V: census]. Only the daytime files are read.

## 2. Particle emitters

### 2.1 World placement: `0x0003BC00` [D: `Ecstasy/EmitterSystem.h`][V]
Data aligned to 16 (`0x11111111` padding in front).

```
EmitterLibraryHeader (0x10): i32 EndianSwapped, i32 Version (=5), i32 NumEmitterLibraries, i32 SectionNumber
per library:
  EmitterLibrary (0x50): u32 GroupKey @0x00 · u32 pad · u16 SectionNumber @0x08 · u16 NumTriggers @0x0A · ptr mGroup
                         · bMatrix4 LocalWorld @0x10 (rows; row 3 = position in metres, Z up)
  WorldFXTrigger × NumTriggers (0x30): bTNode · ptr · f32 radius @0x0C · bVector3 pos @0x10 · f32 reset @0x20
                         · u16 probability @0x24 (0xFFFF) · u8 state · u8 flags · f32 last end · pad
```
- Header + sum of libraries and triggers = chunk size for all 679 chunks [V].
- `GroupKey` is the Attrib key (`attribHash`) of an `emittergroup` collection: **1,535/1,535 resolved** [V].
- Every position lies inside Rockport [V]. The same packs appear in section N and N+40 (LOD): duplicates are removed by `SectionNumber`.
- 1,512 are continuous (no triggers) and 23 fire by proximity (42 triggers, 5 m radius, 3 s reset) [V].
- Most common: falling leaves (`fxenv_leaves1`, 627), fog (`fxenv_fog1/2/1thick`, 577), chimney and factory smoke (`fxenv_chimney1`, `fxenv_smokestack*`), fountains, birds, steam.
- Garages (`FRONTEND\PLATFORMS`): PLATFORMCRIB 11, CAREER_SAFEHOUSE 7, CAR_LOT 4, CUSTOMIZATION_SHOP 10, _BACKROOM 9.
- `0x0003BB00` (baked EmitterGroup) is not on the disc: the game builds groups from the VLT.

### 2.2 Definitions: `GLOBAL\ATTRIBUTES.BIN` [V][D]
- `emittergroup` (128): `Emitters[]` (references to `emitterdata`), `FarClip`, `IntensityRanges`.
- `emitterdata` (205): life, speed, cone, gravity, drag, keyed size (`Size`, `KeyPositions`), four colours, on/off cycle (`OnCycle`, `OffCycle`), `Texture` and `TextureAnimation`.
  - `Texture` is `ParticleTextureRecord {u32 enum, u32 index}`: the enum is the `bStringHash` of the texture name [V: 42 used, all resolved].
  - `TextureAnimation` is `ParticleAnimationInfo {u32 type (0, 2, 4, 8, 16 = N×N grid), u8 FPS, u8 random start}`.
- `effects` (198): effect name → `emittergroup` (`carexhaustnos → fxcar_nos`, `carhit → fxcar_impactl`, `carblowtire → fxcar_tireblow`…).
- `simsurface` (47): `TireSlideEffects`, `TireSlipEffects`, `TireDriveEffects` = `TireEffectRecord {RefSpec emitter, f32 minSpeed, f32 maxSpeed}` per surface [D: `MWAttribUserTypes.h`]. These are the tyre smoke and dirt.
- `smackable` (181): reaction of each breakable (mass, `EventSequencer`, `OnScrapeGround` = `EffectLinkageRecord {surface, effect, minSpeed, maxSpeed}`).
- `fuelcell_effect/emitter`, `emitteruv`: newer spark system (only 4/8/4 collections).

### 2.3 Car effects [D]
- Tyres: `TireState::Effect::LazyInit` creates the surface's `emittergroup` (`simsurface`) [D: `CarRenderConn.cpp`].
- Nitrous, exhaust, impacts, glass, blow-outs, cop car death: `VehicleRenderConn::Effect::Fire/Update` with the `emittergroup` key (`fxcar_nos` = `emcar_nos_fire` + `emcar_nos_glow`) [D].
- Cop lights as particles: `fxcar_coplightred/blue/white` [V].

### 2.4 Textures
46 `FX_*` textures in the "PARTICLE" TPK of `GLOBAL\INGAMEB.BUN` [V]. TPK names are cut to 23 characters; they are resolved by hash with the `eTEG_ParticleTextures` enum [D]. Written to `effects/particles/<NAME>.png`.

## 3. Breakable objects: `0x00034027` [D: `Physics/SmokeableInfo.hpp`][V]
```
SmokeableSpawnerPack: bTNode · s16 ScenerySectionNumber @0x08 · s16 FirstID · s16 NumSpawners @0x0C · u8 swapped · u8 pad
SmokeableSpawner (0x40): Quaternion @0x00 · Vector4 pos @0x10 · UCrc32 model @0x20 · UCrc32 collision @0x24
                         · UCrc32 attributes @0x28 · u32 SceneryOverrideInfo @0x2C · u32 id @0x30 · u32 ExcludeFlags @0x34 · ptr · pad
```
- 0x10 + n × 0x40 = chunk size for all 824 chunks [V].
- `UCrc32` = `attribHash` (Jenkins). All 88 `mAttributes` values are `smackable` collections [V].
- Position and rotation are in **simulation space** (Y up). World: `X = z, Y = −x, Z = y` [V].
- Check: `SceneryOverrideInfo` points to the object's scenery instance. **5,952/5,952** match in position within 5 cm [V].
- Model: 5,242 resolved through the full solid or instance name; 710 stay as hashes (the original name is mixed-case and only appears truncated to 23 chars on disc). `sceneryModel` always gives the instance name.
- Collision (`mCollisionName`) points to the `CollisionBody` entries of `0x0003B901` (reader `lib/bounds.ts`).
- `0x00034026 SmokeableInfo` is not on the PAL disc: reaction data lives in the `smackable` VLT class.

## 4. World flares (lamp posts, traffic lights, cat's eyes)
- On PS2 there are **no flare packs** (`0x00034019…`, `0x80135100…`) in any file [V: census of GLOBAL, TRACKS and FRONTEND].
- The game creates them every frame from **solid markers** (`0x0013401A`, 0x50-byte `ePositionMarker`) while drawing scenery [D: `Scenery.cpp`]:
  `position = (marker.row3 − PivotMatrix.row3) × instance matrix`, `type = iParam0 + ELF_CATSEYE_ORANGE (14)`.
- 20 models have markers. Output: 2,242 flares: 955 blinking amber, 340 red, 199 green, 748 orange cat's eyes [V].
- 2,216/2,242 fall inside their instance box (±1 m). The other 26 all belong to one model, `XS_MEDIANPOLER_1B_00`, whose second marker sits outside its box [V].
- Per-type textures and colours: `light_flares_cg` and `HEADLIGHTGLOW`, in the `fx` step (doc 20).

## 5. Triggers, helicopter and markers

### 5.1 EventTriggerPack `0x80036000` [D: `World/EventManager.*`][V]
- `0x00036001` header (0x20): bTNode · Version (=2) · ScenerySectionNumber · NumEventTriggers · swapped · 2 pointers.
- `0x00036002` `vAABBTree` (0x10) + `vAABB` × n (0x30).
- `0x00036003` `EventTrigger` (0x20): NameHash · EventID · Parameter · TrackDirectionMask · pos[3] · radius.
- All 12,161 are `TRIGGER_EVENT_SOUND` (0x10007): zone ambience sounds [V]. `Parameter` has 6 values; `Comment` (555) and `OVERPASS` (380) resolved via `bStringHash` of ELF strings; the other 4 are not.
- Race starts, garages and speed traps are **not** here: they live in the VLT (`gameplay.json`, doc 18).

### 5.2 HeliSheet `0x00034159` [D: `World/HeliSheet.cpp`][V]
`HeliSection` (0x18: bTNode, SectionNumber, NumPolys, swapped, ptr) + `HeliPoly` × n (18 B: s16 X[3], Y[3], Z[3]; X, Y × 0.25 m; Z × 0.0625 m).
Flight height = plane of the triangle containing (x, y), searched in the drivable section. Box: x −1,563…4,966, y −1,201…5,092, z −11…510 m.

### 5.3 TrackPositionMarker `0x00034146` [D][V]
0x30 B: bTNode · NameHash · Param · bVector3 · bAngle · TrackNumber (2000). 318/328 named (`bStringHash` of ELF strings): `BustedMomentMarker` 194, `IconMarker` 37, `TollboothMarker` 36, `GarageMarker` 14, plus the pursuit-breaker collapse "Moments" (gas station, water tower, scaffolding…).

### 5.4 TrackOBB `0x00034191` [D: `World/Track.hpp`][V]
One 0x60-byte box (type hash `0xA4E74294`, unnamed, at 2090, 1405, 153; 11.55 × 4.4 × 0.05 m).

## 6. Weather, fog, tint and zone sound

### 6.1 Weatherman `0x00034250` [D: `World/WeatherMan.hpp`][V]
`WeatherRegionPack` (0x10: bTNode, Version 2, NumRegions 61) + `GenericRegion` × 61 (0xA4: name, group, type, fog colour, position, radius, intensity, falloffs, shape, blend…). All 61 are `BLOOM` (`BLOOM_CP_*`): glow points, not rain or fog.

### 6.2 ParameterMaps `0x8003B600` [D: `World/ParameterMaps.cpp`][V]
Each layer `0x8003B601`: header `B602` (0x24) · types `B603` · offsets `B604` · sets `B605` · quadtree `B607` (u8, 4 B) or `B608` (u16, 8 B). No padding. Leaf: child0 = 0, data = child1. Looked up by world (x, y) [D]: done by the ambience (`Ambience`) and tunnel (`Reverb`) sound code.

| Layer | Fields | Sets | Use |
|---|---|---|---|
| Ambience | 1 int | 11 | zone ambience |
| Reverb | 3 | 19 | reverb (tunnels, streets) |
| Speech | 2 int | 26 | zone for police radio |
| Clouds, Rain | 2 float | 4 | cloud and rain density |
| Wind | 2 float | 2 | wind |
| Normal Fog, Rain Fog | 8 float | 3–4 | per-zone fog |
| Screen Tint SunRise / Midday | 3 float | 1 | screen tint (RGB 219, 206, 87) |
| Fog Blend Distance | 1 float | 1 | 50 m |
| 3 unnamed | 1–3 | 1 | two more tints (219, 186, 87) |

Names come from `bStringHash` of the decomp's `ParameterAccessor("…")` and ELF strings [V].

### 6.3 TrackInfo `0x00034201` (`GLOBALB.BUN`) [D][V]
18 × 0x120 B. 2000 is "Most Wanted World" (`L2RA`, minimap calibration, `SunInfoNameHash 0xB05E7F4C` unresolved). The rest are EA test tracks (Speedway, "CG Visual Target", "(5400) Carbon"…).

## 7. Animations and animated textures

### 7.1 WorldAnim [D: `Animation/AnimEntity_WorldEntity.cpp`][V]
- `0x37080` `WorldAnimEntityInfo` (0x70): type, instance, parent, model, LODs, tree and animation, local matrix.
- `0x37110` `WorldAnimEntityTreeMarker` (0x50): closes a tree (the entities read before it) with 4 named ranges.
- `0x37090` `WorldAnimInstance` (0xA0): id, tree, section, speed, delays, triggers, matrix and box.
- `0x37150` `WorldAnimInstanceEntryInfo` (0x10): id, tree, section, time.
- 11 trees and instances in Rockport. Curves are EAGL (`0x00E34010`), read by the NIS step.

### 7.2 TextureAnimPack `0xB0300100` [D][V]
`0x30300101` header (0x10) · `0x30300102` `TextureAnim` (0x34: name[24], hash, frames, FPS) · `0x30300103` frames (0x10: hash).
11 animations: water `ANM_WATERA_` (14 frames, 17 FPS), crossing signal, light-up billboards, Bob's Lobster sign, rotor, bulbs, safehouse TV and fan. Frame names come from the TPKs of the same file [V].

### 7.3 ModelHierarchy `0x0003410C` [D][V]
`ModelHeirarchy` (8 B) + `Node` × n (0x10: UCrc32 name, solid hash, ptr, flags, parent, child count, first child). 125 hierarchies of multi-part breakables (root + `_FRAG*`).

## 8. Visibility and streaming (`effects/visibility.json`) [D][V]
- `0x34151`: `LODOffset = 40` (hence each section N has its LOD in N+40) and the region's 373 drivable sections.
- `0x34152`: 515 outlines (0x24 + NumPoints × 8 on disc; box, centre, points).
- `0x34153`: 435 drivable sections with their visible-section list (0x12 + MaxVisible × 2, aligned to 4). This is the game's PVS.
- `0x34155`: 39 loading zones (`LoadingSection`, 0x4C).
- `0x34158`: overlays `FlyBy` (500 entries) and `E3Demo` (0).
- `0x34113`: 75 disc bundles (`DiscBundleSection`, 0x14 + n × 8).
- `0x34105` (scenery tree, 0x24 B per node on disc), `0x34106` (override hooks) and `0x34107` (preculler, 128 B per group): decoded in doc 22 §10 (`lib/scenery-cull.ts`).

## 9. "Troughs": `0x00034190` (`TROUGHBOUNDARY.BIN`) [V][I]
`TroughBoundary` struct in the decomp's PS2 types [D] (+0x58 `TypeRegularTrough`, +0x59 `TypeTroughHole`, +0x5A `TypeAntiTrough`, +0x5C `TroughNumber`, +0x5E `ParentTroughNumber`): 484 regular and 79 holes [V]. Checked on all 563 chunks:
`u32 ×2 (0) · char Name[80] · u32 type · u16 a · u16 b · bVector2 min · bVector2 max · u32 n · bVector2 points[n]`.
Names `TRN_CP_*_Road/Terrain_*`, `TROUGH_*`, `TroughNJ_*`, with `_Hole` and `_Segment`. They are 2D zone perimeters [I]. Their use (out-of-world or reset boundary) is a hypothesis [H].

## 10. What the port can use now
- World particles (`worldEmitters`) and garage particles with definitions and textures: smoke, fog, leaves, fountains, birds.
- Tyre smoke and dirt per surface, nitrous, impacts and blow-outs (`library.tireEffectsBySurface`, `library.effects`).
- Traffic-light and cat's-eye flares (`flares`).
- Breakables with model, position, rotation and reaction type (`smokeables`).
- Per-zone fog, clouds, rain and tint; per-zone ambience and reverb for audio (`parameterMaps`, query with `parameterSetAt`).
- Helicopter height (`heli-sheet.json`), pursuit and garage markers, per-section PVS.

## 11. Remaining
- 4 of the 6 sound-trigger `Parameter` values and the trigger `NameHash`.
- 3 unnamed parameter layers, the TrackInfo sun hash and the TrackOBB type.
- 710 breakable models with unknown full names (only truncated on disc).
- The exact use of troughs (`0x34105/06/07`: doc 22 §10).
- The particle simulation (spawn, keyed colour, grid textures) is in `EmitterSystem.cpp` [D]; it still has to be ported to the engine.
