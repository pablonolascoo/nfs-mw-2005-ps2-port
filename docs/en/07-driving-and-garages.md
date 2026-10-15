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
| `GARAGETYPE_MAIN_FE` (main menu) | `PLATFORMCRIB.BIN` (industrial rooftop with cranes) | 134.4125° | 304.96979° |
| `GARAGETYPE_CAREER_SAFEHOUSE` | `CAREER_SAFEHOUSE.BIN` | 302.85309° | 304.96979° |
| `GARAGETYPE_CUSTOMIZATION_SHOP` / `…_BACKROOM` | `CUSTOMIZATION_SHOP(_BACKROOM).BIN` | 0° | 304.96979° |
| `GARAGETYPE_CAR_LOT` | `CAR_LOT.BIN` | 0° (Y +0.075) | 340° (X −0.38°) |

- The car sits at the origin at wheel height (`mean radius − mean wheel z − 0.025`) with the front wheels turned
  `CarSelectTireSteerAngle` = 21.6723° (`GarageMainScreen::UpdateRenderingCarParameters`) [D].
- `FEGeometryModels` draws the scene solids except `NEXTGEN` ones; `BACKDROP_CURRGEN` is the current-gen backdrop (sky dome
  `…_SKY`, the safehouse outer box `CRIB1_OFFICE_TEXTURE`) [D][V].

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

## 2. Data (`tools/src/cli/garages.ts`, `tools/src/cli/fe-cameras.ts`, `DATA_FORMAT` 7)

| Step | How |
|---|---|
| Zone | 15 zones from `GAMEPLAY.BIN` (doc 05) [V] |
| Building | Nearest of its kind: `XB_CT_SafehouseA` (safehouse 1), `XB_SafeHouse` (2), `XB_FishSafehouse` (4), `XB_TC_SafeHouse` (5), `XB_CarParkDealership`, `XB_ChopShopA` (oriented box from the instance matrix) [V] |
| Real door | Building triangles using `ARC_HOSPITAL_GARAGEDOOR` (all of them use it), grouped; the group closest to the zone gives centre, normal and size: 5.7–8 m × 3.3–6 m [V] |
| No building | None left: safehouses 2, 4 and 5 have their own building with a roller door (their names were simply not recognised before). As a fallback, the nearest real roller door of any building within 160 m, then a door facing the respawn point [H] |
| Cameras | `fe-cameras.json`: angles, screens and car lot cars from `FE_ATTRIB.BIN` [V] |

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
| `GarageTests.swift` | Headless `--garage-test` |

### 3.1 Menu background
`Press START`, the main menu and the career menu no longer show the city: the `PLATFORMCRIB` scene (rooftop with the industrial
skyline and the sky dome) with the player's car (the career preset with its tuning; by default the story BMW M3 GTR), the
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
Result (2026-10-15): 12 of the 15 garages are entered by the test autopilot and open their menu (safehouses 1, 2 and 5, the 3 car
lots and shops 2, 3, 5, 6, 7 and 8). At safehouse 4 and shops 1 and 4 the door opens but the (straight-line) autopilot gets stuck on
lobster pots or the kerb; with `--garage-mode inside` all 15 open their menu.

## 4. To do
- Car reflections in the front end (the game uses an environment map) and the garage's own lights (`SetSelectCarLighting`).
- Scene particles (`FX_*_EMITTER`, birds) and the `BACKDROP_CAST_SHADOW_MAP` shadow map.
- Part prices and heat, shopping cart, performance, decals, window tint, rim paint.
- Career map (`WorldMap_Main`), rap sheet (`RapSheet*`) and the save-slot screen.
