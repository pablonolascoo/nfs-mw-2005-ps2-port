# Driving and garages without loading screens

Tags: [V] verified against SLES-53559 bytes or measured · [D] from the decomp · [I] inferred · [H] hypothesis.

## Driving (viewer prototype) — `viewer/src/drive.ts`
- Arcade handling (the native engine already uses the game physics: doc 13).
- Ground and collisions by rays against the real geometry of nearby tiles. The BVH (acceleration structure) is built in the loader thread and arrives serialized: driving holds 60 fps.
- Keys: W/S, A/D, Space (handbrake), R (back to the road), E (garage), Esc (exit).

## 1. Garages in the original game [D]
- The `menu_gate_*` zone (safehouse, car lot, customization shop) calls `EQuitToFE(GARAGETYPE_*)`: it leaves the world and loads the front end.
- `FEManager::GetGarageNameFromType`: each garage type is a scene from `FRONTEND\PLATFORMS\`:

| Type | Scene | Scene rotation (`GetGeometryZAngle`) | Car rotation (`GetCarRotationZ`) |
|---|---|---|---|
| `GARAGETYPE_MAIN_FE` (main menu, quick race) | `PLATFORMCRIB.BIN` (night industrial yard: water towers, corrugated sheds, forklift, graffiti; `QRACE_*` textures) | 134.4125° | 304.96979° |
| `GARAGETYPE_CAREER_SAFEHOUSE` | `CAREER_SAFEHOUSE.BIN` | 302.85309° | 304.96979° |
| `GARAGETYPE_CUSTOMIZATION_SHOP` / `…_BACKROOM` | `CUSTOMIZATION_SHOP(_BACKROOM).BIN` | 0° | 304.96979° |
| `GARAGETYPE_CAR_LOT` | `CAR_LOT.BIN` | 0° (Y +0.075) | 340° (X −0.38°) |

- The car sits at the origin at wheel height (`mean radius − mean wheel z − 0.025`) with the front wheels turned
  `CarSelectTireSteerAngle` = 21.6723° (`GarageMainScreen::UpdateRenderingCarParameters`) [D].
- `FEGeometryModels` draws the scene solids except `NEXTGEN` ones; `BACKDROP_CURRGEN` is the current-gen backdrop (sky dome
  `…_SKY`, the safehouse outer box `CRIB1_OFFICE_TEXTURE`) [D][V].

### 1.0 What each scene contains (`FRONTEND\PLATFORMS\*.BIN`) [V]
`FEGeometryModels::Init("BACKDROP")` takes **every** solid whose name starts with `BACKDROP` and `Render` skips the `NEXTGEN` ones
on current gen; `CAST_SHADOW_MAP` ones also go to the shadow pass [D: `FEPkg_GarageMain.cpp`]. The `BACKDROP_CAST_SHADOW_MAP*`
solids **are not shadows**: they are the scene props that also cast shadows, and they do not repeat `BACKDROP_CRIB` geometry
(45 of 7,714 vertices shared in the menu scene). Until now the converter only exported `BACKDROP_CRIB`, so most of the props seen
in the game's screenshots were missing.

| Scene | Solids the game draws | Contents |
|---|---|---|
| `PLATFORMCRIB` (main menu) | `BACKDROP_CRIB`, `BACKDROP_CAST_SHADOW_MAP`, `BACKDROP_CURRGEN` | Corrugated sheds, `QRACE_WATERTOWER` water towers (two sets), `QRACE_FORK` forklift, lamps, tyre stack, rail car, trees; `QRACE_MIDDAYSKY` sky |
| `CAREER_SAFEHOUSE` (safehouse, My cars) | `BACKDROP_CRIB`, `…CAST_SHADOW_MAP`, `…MAP2`, `…MAP3`, `BACKDROP_REFLECTION`, `BACKDROP_CURRGEN` (not `…MAP_NEXTGEN`) | Warehouse with trusses and windows; `MAP2`: tyre stacks with rims `CRIB1_WHEEL_TREAD`, couch, bench, red `CRIB1_TOOLBOX`es, barrels, boxes, TV, fridge; `MAP3`: pipes and beams; `REFLECTION`: mirrored copy under the semi-transparent floor (`CRIB1_FLOOR`, alpha ≈ 0.96) |
| `CUSTOMIZATION_SHOP` / `_BACKROOM` | `BACKDROP_CRIB`, `BACKDROP_CAST_SHADOW_MAP`, `BACKDROP_CURRGEN` | `CSHOP_CARCOVER` car covers, capes, crates, extinguisher, jack, barrels, red tool chests |
| `CAR_LOT` | `BACKDROP_CRIB`, `BACKDROP_CAST_SHADOW_MAP`, `BACKDROP_CURRGEN` | Car park with pillars, signs, trees; `OBJECT01` (car shadow) does not start with `BACKDROP`: the game does not draw it |

Reference screenshots (PC/X360) matched to scenes [V by textures and framing]:
- Night yard with two water towers, sheds, graffiti and forklift → `PLATFORMCRIB` (main menu).
- Car select inside the warehouse with tyres and rims, barrels, red tool chests, boxes, corrugated wall with windows and light
  shafts → `CAREER_SAFEHOUSE` with the `career_car_select` camera (`angle4_d`): the safehouse "My cars".
- Unnamed textures: `0x00163C76` = `GREY` (only in the `CAR_LOT` pack; used by all) [V]; `0x578BC664` (1,520 menu vertices)
  still not found.

### 1.1 Front-end camera (`SelectCarCameraMover`) [D][V]
- The parameters live in the `frontend` class of **`GLOBAL\FE_ATTRIB.BIN`** (schema in `GLOBAL\ATTRIBUTES.BIN`) [V]: 108 angles
  with `cam_orbit_vertical`, `cam_orbit_horizontal`, `cam_orbit_radius`, `cam_lookat_x/y/z`, `cam_roll_angle`, `cam_fov`,
  `cam_anim_speed`, `cam_damping`, `cam_periods`, `cam_user_rotate`, and 186 screens pointing to an angle through `cam_angle`
  (`mainmenu` → `angle3`, `career_mainmenu_sub` → `angle10`, `customize_customizemain` → `angle13`, `carlot_car_select` →
  `angle_carlot_car_select`…). Each garage has `angle_entry_<garage>` and `angle_final_<garage>`. `FindScreenInfo` prefixes the
  package name with the mode (`career_`, `carlot_`, `customize_`…).
- `CreateCameraMatrix` (SLUS 0x1772B0, assembly) [V]: `M = RotZ(H)·RotX(V)·Trans(0, 0, R)`; eye = translation of `M⁻¹`;
  up = `ComputeBankedUpVector(eye, lookAt, roll)`; view = `eCreateLookAtMatrix`. With `bMatrix4` row conventions that gives
  eye = (−R·sinV·sinH, −R·sinV·cosH, −R·cosV) [I: signs checked on screen: front three-quarter view of the car, camera 0.7 m
  above the floor, as in the game].
- `cam_fov` is taken as the 4:3 horizontal field; widescreen keeps the vertical one [I].
- `cam_user_rotate` is false on the main menu: the game does **not** turn the car by itself there [V].
- Transitions between angles (`anim_speed` s, `damping`, `periods`) use a damped spring [I: the mover is not decompiled].
- The same class holds the car lot cars: `Cost`, `UnlockedAt` (Blacklist bin) and `manufacturer` (34) [V].

## 2. Data (`tools/src/cli/garages.ts`, `tools/src/cli/fe-cameras.ts`, `tools/src/cli/garage-scenes.ts`, `DATA_FORMAT` 10)

| Step | How |
|---|---|
| Zone | 15 zones from `GAMEPLAY.BIN` (doc 05) [V] |
| Building | Nearest of its kind: `XB_CT_SafehouseA` (safehouse 1), `XB_SafeHouse` (2), `XB_FishSafehouse` (4), `XB_TC_SafeHouse` (5), `XB_CarParkDealership`, `XB_ChopShopA` (oriented box from the instance matrix) [V] |
| Real door | Building triangles using `ARC_HOSPITAL_GARAGEDOOR` (all of them use it), grouped; the group closest to the zone gives centre, normal and size: 5.7–8 m × 3.3–6 m [V] |
| No building | None left: safehouses 2, 4 and 5 have their own building with a roller door (their names were simply not recognised before). As a fallback, the nearest real roller door of any building within 160 m, then a door facing the respawn point [H] |
| Cameras | `fe-cameras.json`: angles, screens and car lot cars from `FE_ATTRIB.BIN` [V] |
| Interiors | `convert.ts interior`: every `BACKDROP*` except `NEXTGEN` → `interiors/<NAME>.glb`; `BACKDROP_REFLECTION` separately in `interiors/<NAME>.reflection.glb` (not used for placement or collision) [D][V] |
| Drivable scenes | `garage-scenes.ts` → `garage-scenes/<zone>.glb/.json/.bin` (§5) |

**Converter fix** [V]: strips whose positions are **V4-32** (floats; VIF header `[nv, packs, 9, …]`) are already in metres; they
used to be scaled by 1/256 and collapsed into a point. Pieces larger than ±128 m use them: the garages' sky dome and outer box,
and **5,071 world strips** (`SKYDOME`, `SKY_SPECULAR`, `XB_CITYMODERN*`, `XB_CITYTOWERA*`, `XB_BENTALLTOWERA`… skyscrapers: the
downtown skyline). `tools/src/lib/solid-ps2.ts`.

## 3. Native engine — `native-engine/Sources/Rockport/Garage/`

| File | What it does |
|---|---|
| `GarageSystem.swift` | Hooks into the engine: draw layer, `Engine.frameOverrides`, `Engine.frameHooks` and collision hooks |
| `GarageRender.swift` | Interiors (`InteriorLibrary`), clip-boxed draw layer and the world cut-out (`GarageCutout`, buffer 3 of the world shaders) |
| `FEGarage.swift` | Front-end scene (`FEStage`) and camera (`FECameraMover`, `FECameraAngle`) |
| `WorldGarage.swift` | World garages: placement, roller door, cut-out, collision, phases |
| `GarageMenus.swift` | Each place's menus with the original packages |
| `CarTuning.swift` | Tuning (paint, vinyl, rims, spoiler, body kit) and light bar |
| `GarageScenes.swift` | Drivable scenes (§5): our walls, ceiling, frame and apron, their collision, the menu scene reflection and the animated car swap |
| `GarageTests.swift` | Headless `--garage-test` |
| `GarageScenesTests.swift` | Headless `--garage-scene` (front-end scene with any camera) and `--garage-swap-test` (car swap) |

### 3.1 Menu background
`Press START`, the main menu and the career menu no longer show the city: the `PLATFORMCRIB` scene (industrial yard with water
towers, sheds, forklift and the sky dome) with the player's car (the career preset with its tuning; by default the story BMW M3 GTR), the
entry → final camera and then each screen's camera. The scene is drawn far from the map (−30 km, −30 km) with no world around;
the engine camera stays over the safehouse so the city is still loaded when the game starts.

### 3.2 Seamless garages
1. Within 150 m of a zone its interior (without the front-end `BACKDROP_CURRGEN` backdrop) is placed inside the building,
   oriented by its open side (16 rays) and clipped to a box of the inner volume.
2. Arriving slowly in front of the door (inside the zone or within 14 m of the door, under 45 km/h and approaching; only after
   having been outside the zone) turns on the world cut-out —door opening + inner volume— and the new roller door (slats with the
   original texture) lifts with easing.
3. Collision: building walls crossing the opening or inside the volume are ignored; the facade beside the door, the interior
   walls (near-vertical triangles at car height) and a wall across the door while it is not open are added; the interior
   floor is a plane at street level.
4. Stopped on the bay (under 4 m, under 2 km/h for 0.5 s): the door comes down, the simulation pauses and the camera blends from
   the chase camera to `angle_final_<garage>` around the car (in the car's frame, like the front end). If a display car or a
   wall blocks the view the camera turns just enough (or moves closer) [I].
5. "Back to free roam": the door goes up, you reverse out and, once 2 m past the door, it closes and the cut-out is removed.

### 3.3 Menus of each place
| Place | Package | Options [D] |
|---|---|---|
| Safehouse | `MainMenu_Sub` (`uiCareerCrib`, title 0xE596C4A3, `CAREER_DATA`/`BOUNTY_DATA`/`CASH_DATA`) | Back to free roam · Blacklist (`InGameReputationOverview`) · My cars (`Car_Select` with the career cars) · Save |
| Car lot | `Car_Select` (`UIQRCarSelect` in car lot mode) | ← → `FE_ATTRIB.BIN` cars by price, brand logo `CARSELECT_MANUFACTURER_*` and model logo `SECONDARY_LOGO_<collection>`, n/N, cash and price, lock with "Unlock this car by beating … #N" (string 0x4EF2A115, `UnlockedAt + 1`); ✕ buys (string 0x40FA955D if short of money) |
| Customization shop | `CustomizeMain` → `CustomizeCategory` → `CustomizeParts` | Parts (body kits, spoilers, rims) · Performance (greyed) · Visual (paint, vinyls, **controller light bar**); ← → fits the part on the car at once, ✕ installs it, △ keeps the old one |

- Game strings and titles (lower case like `CustomizationScreenHelper::DrawTitle`); each screen's camera from `fe-cameras.json`
  (`career_mainmenu_sub`, `carlot_car_select`, `customize_customizemain`, `customize_customizeparts_257`…).
- Parts: the 48 paints of the disc presets, vinyls from presets of the same car, rims from the `WHEELS` packs (one per model) and
  spoilers from the `SPOILER*` packs; tuning is saved per car in `~/Library/Application Support/Rockport/garage.json` and applied
  when the career starts. Part prices: 0 [I].
- Mods: `mods/garajes-unicos/mod.json` (name, interior, tint and display cars) is read from the repo `mods/`,
  `~/Library/Application Support/Rockport/mods/` or `ROCKPORT_MODS`.

### 3.4 Headless tests
```bash
R=".build/release/Rockport --data ../map-data/SLES-53559 --size 1920x1080"
$R --garage-test zone_safehouse_1 --screenshot g.png                    # drives in: g-1-fuera, g-2-dentro, g-3-aparcado
$R --garage-test zone_customshop_2 --garage-mode inside --garage-screen paint --garage-select 3 --screenshot t.png
$R --garage-test x --garage-mode list                                     # places the 15 garages and prints their sizes
#   --garage-screen blacklist | carlot | mycars | customize | parts | visual | paint | rims | spoiler | vinyl | kit | lightbar
ROCKPORT_FE_CAM="V,H,R,lx,ly,lz[,fov]" …   # debug: fixed front-end camera
ROCKPORT_GARAGE_NOCLIP=1 …                 # debug: interior without its clip box
```
```bash
$R --garage-scene career_safehouse --fe-angle career_car_select --scene-car MUSTANGGT --screenshot r.png   # menu scene
$R --garage-swap-test zone_safehouse_1 --scene-car MUSTANGGT --screenshot s.png   # My cars: s-swap-0…6
$R --garage-swap-test zone_carlot_1 --screenshot s.png                            # car lot: next car
ROCKPORT_SCENE_OFF=1 …                     # debug: without the drivable scene (clipped interior only)
```
Result (2026-10-15, with the §5 scenes): 13 of the 15 garages are entered by the test autopilot and open their menu. Missing:
safehouse 4 (a wooden world beam crosses in front of the door at 1 m) and shop 4 (the straight-line autopilot starting 18 m away
gets stuck on the kerb); with `--garage-mode inside` all 15 open their menu.

Before the scenes: 12 of the 15 garages are entered by the test autopilot and open their menu (safehouses 1, 2 and 5, the 3 car
lots and shops 2, 3, 5, 6, 7 and 8). At safehouse 4 and shops 1 and 4 the door opens but the (straight-line) autopilot gets stuck on
lobster pots or the kerb; with `--garage-mode inside` all 15 open their menu.

## 4. To do
- Front-end car reflections: done with `<GARAGE>_CARSELECTENVMAP` (doc 20). Missing: the real garage light values ("shaper rigs", in BSS).
- Scene particles (`FX_*_EMITTER`, birds) and the shadow pass of the `BACKDROP_CAST_SHADOW_MAP*` (already drawn as props).
- Scenes: windows with real light, own light shafts and signs; safehouse 4 (world beam in front of the door); menu texture `0x578BC664`.
- Part prices and heat, shopping cart, performance, decals, window tint, rim paint.
- Career map (`WorldMap_Main`), rap sheet (`RapSheet*`) and the save-slot screen.

## 5. Drivable garage scenes (ours)
In the game the `menu_gate_*` zone cuts to a loading screen and the garage is only a menu scene [D]: there is **no** path from the
street into the interior. We build it ourselves, data-driven:

| What | Original (disc) | Ours |
|---|---|---|
| Building, roller door, street | `STREAML2RA.BUN` (world), `ARC_HOSPITAL_GARAGEDOOR` texture | Building cut-out and animated door (§3.2) |
| Interior and props | `FRONTEND\PLATFORMS\*.BIN` (`BACKDROP*`) | Placement inside the building |
| Volume walls, ceiling, beams, pillars, floor and signs | Only the **textures** (`CRIB1_BRICK1`, `CSHOP_CORUGATEDMETAL`, `CARLOT_WALLCONCONCRETE`…) | Geometry, size and placement |
| Door frame (jambs, lintel) | Textures (`CRIB1_PIPE`, `CSHOP_METALYELLOW`, `CARLOT_YELLOWPILLAR`) | Geometry |
| Apron / ramp from street to door | Interior floor texture | Geometry and collision, from the real street height (world collision) |
| Car swap without a loading screen | Car models and physics | Animation (camera tilts up, the car rolls in) |

**`garage-scenes` step** (`tools/src/cli/garage-scenes.ts`, after `collision`):
1. Door frame from `garages.json`: x out, y left, z up, origin at the centre of the roller door at ground level.
2. **Real volume** behind the door from the world collision [V]: rays from inside to the back and sides against `collision/`
   walls, never leaving the building box. Example: safehouse 1 = an 8 × 22.5 m bay behind the "FLEA MARKET" arch (the facade
   wings sit 6 m further back; with the 30 m building box the cut-out ate them). With no walls nearby the building box is used,
   as before (safehouses 2 and 4).
3. Geometry with the interior's disc textures. Each texture's **size** (m per repeat) and **baked light** (mean vertex colour)
   are measured on the interior solids that use it, so they match what is next to them.
4. **Apron**: the street is sampled with the world collision on three lines in front of the opening; if it is higher or lower
   than the door (safehouse 1: +0.31 m; shop 1: −0.58 m) or has a step, a ramp bridges it (visual + collision triangles).
5. Output: `garage-scenes/<zone>.glb` (nodes `SHELL`, `FRAME`, `APRON`), `<zone>.bin` (NFSC v1 in world space: apron tris, volume
   walls), `<zone>.json` (frame, volume, apron) and `index.json`. Textures in `garage-scenes/textures/` (never committed).

**Engine** (`GarageScenes.swift`): the scene volume drives `WorldGarages.place` (cut-out 8 cm inside the scene walls, interior
clip box inside them); the apron is drawn whenever the garage is placed and its floor goes before the garage floor; walls and
frame only with the facade cut; walls are added to `CollisionWorld.garageWalls`. The interior orientation now looks for a
car-wide clear lane (±1 m) at 0.45 and 1.2 m (parapets and car lifts used to block it).

**Car swap** (My cars and car lot): the front-end camera tilts up to the beams (0.45 s; only the look-at height changes, so the
garage camera's wall check does not jump), the new car appears a few metres behind the bay (towards the door, off screen) and
rolls in with its own physics to the bay while the camera returns (~3 s). On confirm the player car is swapped in place.

**How to edit the scenes**: `tools/data/garage-layouts.json` (ours: only numbers and texture names). Per kind (`safehouse`,
`customshop`, `carlot`): `floor`, `walls`, `wallsTop` (upper band from `from` m), `ceiling`, `beams` (`every`, `size`), `pillars`,
`frame` (`width`), `apron` and `decals` (`texture`, `wall` back/left/right/front, `at` 0…1, `z`, `size`). `shade` = [bottom,
top] darkens the wall towards the floor; `repeat` and `color` force size and light instead of measuring them. Per zone
(`zones`): `apronLength`, `noApron`, `extraDecals`. Then: `bun src/cli/garage-scenes.ts <iso> <ID>` (under 1 s).
