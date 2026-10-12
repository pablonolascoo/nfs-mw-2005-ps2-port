# Cars: models, replacement textures, paint and wheels

Tags: [V] verified on SLES-53559 bytes · [D] from the decomp · [I] inferred · [H] hypothesis.

## 1. Where everything lives

| What | Disc source | Code | Output |
|---|---|---|---|
| Geometry | `CARS\<CAR>\GEOMETRY.BIN` | `tools/src/cli/convert.ts` (`car` mode) | `map-data/<ID>/cars/<CAR>.glb` |
| Own textures | `CARS\<CAR>\TEXTURES.BIN` | `tools/src/lib/tex-ps2.ts` | inside the GLB |
| Shared textures | `CARS\TEXTURES.BIN`, **`GLOBAL\GLOBALB.BUN`**, `GLOBAL\INGAMEA.BUN` | same | inside the GLB |
| Textures swapped by the game | none (built at runtime) | `tools/src/lib/car-textures.ts` | materials with `extras.role` |
| Part metadata | solid name + markers chunk `0x0013401A` | `tools/src/lib/car-parts.ts` | node `extras.pieza`, `extras.marcadores` |
| Wheels (position, size, camber) | `GLOBAL\ATTRIBUTES.BIN`, class `ecar` + `tires` | `tools/src/cli/car-attribs.ts` | `map-data/<ID>/cars.json` |
| Viewer assembly | — | `viewer/src/drive.ts` (`applyCarConfig`, `mountWheels`, `paintCar`, `carHolder`) | — |

SLES-53559 has **91 models** [V]: 40 cars, 11 police, 27 traffic, 6 trailers and 7 tuning-part sets (`WHEELS`, `SPOILER`, `ROOF`, `BRAKES`…).
`cars.json` holds **92** attribute collections [V].

Regenerate only the cars:

```bash
cd tools && awk -F'\\' '/^CARS\\[A-Z0-9_]+\\GEOMETRY\.BIN,/{print $2}' ../inventory/SLES-53559.csv | xargs bun src/cli/convert.ts ../original/SLES-53559.iso SLES-53559 car
bun src/cli/car-attribs.ts ../original/SLES-53559.iso SLES-53559
```

## 2. Parts, kits and slots [V][D]
Slot list: `CarPartID.h` (76 model slots). Stock car = upgrade level 0 in every slot (`SetStockParts`, `CarInfo.cpp`) [D].

| Solid name | Meaning | Stock |
|---|---|---|
| `<CAR>_BASE_<LOD>` | base (window frame); carries the SPOILER / ROOF_SCOOP / light markers | yes |
| `<CAR>_KIT00_<SLOT>` | stock part (BODY, HOOD, FRONT_TIRE, FRONT/REAR_BRAKE, DRIVER, lights, windows, mirrors, SPOILER…) | yes |
| `<CAR>_KITnn_BODY` (nn 01–05) | body kit: **one whole BODY** (no separate bumpers or skirts in MW) [D] | no |
| `<CAR>_STYLEnn_HOOD` | tuning hood (17 styles, 33 cars) | no |
| `<CAR>_KITnn_UNIVERSAL_SPOILER_BASE` | spoiler mount: only with a tuning spoiler [D: CarRender.cpp 1894] | no |
| `<CAR>_(KITnn_)DECAL_*` | vinyl/decal zones, empty when stock | no |
| `KITnn_DAMAGE0_<PANEL>` | **intact** panel: cops and traffic are built this way (BODY, HOOD, doors, bumpers, COP_LIGHTS) | yes |
| `KITnn_DAMAGE0_FRONT/REAR/…LEFT/RIGHT` | damage overlay (texture `DAMAGE0` 0x236bd9ce) [I] | no |
| `KITnn_DAMAGE1_*` | broken panels (not exported) | — |

- The converter now keeps **every** part (best LOD; `B` on PS2, like the game's player LOD [D]). Each glTF node has `extras.pieza = {slot, kit, style, stock, kind}` (`carPartInfo`).
- Before, every kit body and every hood was drawn at once: A3 showed 6 bodies and 18 hoods on top of each other. Cops had no body (their `DAMAGE0` panels were dropped).
- Viewer rule (`applyCarConfig`): one part per slot; the requested kit replaces KIT00 only in the slots it has; a `STYLEnn_HOOD` hides the kit hood; a normal part wins over a `DAMAGE0` panel of the same slot.
- Model axes: X forward, Y left, Z up; origin on the ground under the body [V].

## 3. Textures
The model asks for "wildcard" names that the game swaps at runtime (`CarRenderInfo::MasterReplacementTextureTable`) [D]. Many generic ones are real textures in **`GLOBAL\GLOBALB.BUN`** [V]; the converter now loads it.

| Hash | Name [V] | Where | Result |
|---|---|---|---|
| `03c906ef` / `1a268b3c` | `TREAD` / `TREAD_N` | tyre | GLOBALB (tread) / normal map (not drawn on PS2) |
| `e38806e3` | `TIRE_BACK` | flat card on the **inner** side of the wheel | GLOBALB |
| `7811c146…49` | `ROTOR1…4` | brake disc | GLOBALB |
| `721aff7c` | `CARBONFIBRE` | spoilers, carbon parts | GLOBALB |
| `1b049702` | `WINDOW_MASK` | BASE, windows | GLOBALB |
| `bd1f0e0a` · `cc772afb` · `69c032b9/ba` · `68100815` · `427b4565` · `8c283c65` · `bf30889b` | `CARBOTTOM` · `DOORLINE` · `GRILL_01/02` · `RADIATOR` · `INTERCOOLER` · `RUBBERACCORDIAN` · `METAL_SWATCH` | body, hoods | GLOBALB |
| `30e7076e` / `bf19330c` | `DRIVER_CUTOUT` / `DRIVER_COP` | driver | GLOBALB / INGAMEA |
| `896efc91` | `TRAFFIC_TIRE` | traffic: `<CAR>_TIRE` → `TRAFFIC_TIRE` [D: CarRender.cpp 1206] | aliased in the converter |
| `<CAR>_BADGING_N`, `<CAR>_MISC_N`, `<CAR>_TIRE_N` | normal maps (Xbox) | listed, not used by PS2 strips | — |
| `<CAR>_KIT00_HEADLIGHT_GLASS_OFF` | headlight glass | glass parts | placeholder `cristal` |
| `910e6654…`, `445a675d`, `d0161a90` | `DUMMY_DECAL1…`, `DUMMY_NUMBER_LEFT/RIGHT` | decal zones | hidden |
| `<CAR>_SKIN1`, `GLOBAL_SKIN1`, `SPOILER_SKIN1`, `ROOF_SKIN` | paint | body, spoiler, roof scoop | placeholder `pintura` |

Names found with `bStringHash` over `Hash.hpp`, ELF strings and the `%s_…` formats of `CarInfo.cpp`, then confirmed by scanning every texture pack on the disc: **115 of 137** car hashes resolved [V].
Still unknown: `13ccf4d8` (in tyre/rim texture tables, not used by any PS2 strip), `5ef7bdee` (tyres of 911GT2, BMWM3GTR, CORVETTEC6R), `c6ede248` (body, spoiler, mirrors, hood), `4e8cf857` (BMWM3GTRE46 driver), `c6578694…97` (`BRAKES` pack), `1366865e` (`TRAFDMPTR_BADGING`, not on the disc).

### Paint in the viewer
- `paintCar(model, "#rrggbb")` changes only materials with `role = "pintura"`.
- Player car: URL `?pintura=1f6fd1` (default silver `aeb7c2`). Display cars: `paint` in the mod.

## 4. Wheels and brakes [D][V]
The game places **one wheel model** four times (`CarRender.cpp` 1855-1999, 3330-3460) [D]:
- Wheel model = `FRONT_TIRE` part (rear uses it too unless `REAR_TIRE` exists). Rim face at model **y = 0**; `TIRE_BACK` card at y = width (inner side) [V].
- Scale: radius `TireOffsets.w / (bbox.x / 2)`; width `TireSkidWidth[i] × TireSkidWidthKitScale[kit] / bbox.y`.
- Chain: pivot (y −= width/2) · left flip (Z 180°, or y mirror if `WheelSpokeCount & 0x80`) · camber about X (`Camber × 7°`, + front-left/rear-left, − right) · axle.
- Axle: x = `TireOffsets.x`; y puts the **rim face at |TireOffsets.y|** (+ `KitWheelOffset × 0.001` outward); z = `TireOffsets.z + FECompressions − Camber × 0.03`.
- Brakes (`FRONT_BRAKE`/`REAR_BRAKE`): y from the wheel's `FRONT_BRAKE`/`REAR_BRAKE` marker (BMW: 0.061 m), not scaled by radius, mirrored on the left.
- The old viewer had the wheel inside out (inner card outward, hidden as "a square"), no brakes and wheels about 30 cm too low. Fixed in `mountWheels`.
- `cars.json` now carries `skidWidth`, `kitWidthScale`, `kitOffsetFront/Rear`, `camber`, `feCompression`, `rimSize` (inches, class `tires`, `RIM_SIZE`).
- Odd entries with rear x = 3 or 5 m (`default`, `traffic`, `racers`, `cops`, `street`, `van`, `truck`, `choppers`, `trailers`, `copheli`) are **template parent collections**, not cars [V]. `BMWM3` has no `ecar` collection: the viewer borrows `bmwm3gtr`.

## 5. Tuning: rims, spoilers, roof scoops [D][V]
- **Aftermarket rims are whole wheels**, not a texture on the tyre: `WHEELS.glb` has 164 models `<BRAND>_STYLEnn_<17-20>_25` (rim + `TREAD` + `TIRE_BACK`), with their own `<BRAND>_STYLEnn_WHEEL` texture [V].
  The game measures and scales them like the stock wheel [D]. `_WHEEL_INNER_MASK` is only used to tint the rim (`CompositeRim`, `CarSkin.cpp`) [D].
- Spoilers (`SPOILER*.glb`, `SPOILER_STYLEnn[_CF]`) go on the **`SPOILER` marker** of the BASE solid; roof scoops (`ROOF.glb`, `ROOF_STYLEnn[_DUAL|_OFFSET][_CF]`) on **`ROOF_SCOOP`** [D: CarRender.cpp 3262-3316, V: A3 markers].
- Markers are parsed from chunk `0x0013401A` (`ePositionMarker`, 0x50 B: hash, 2 params, 4×4 matrix) and written to `extras.marcadores` [V].
- Viewer (player car and preview), URL: `?kit=2&capo=5&llanta=BBS_STYLE01&aleron=SPOILER_STYLE03&techo=ROOF_STYLE01`. Rim size follows the car's `RIM_SIZE`.

## 6. Results (91 models, 2026-10-12)
- All 91 models checked in the preview (contact sheet): 40 cars, 11 cops, traffic, trucks and the helicopter look complete, with tread, brakes and calipers.
- Missing textures after conversion: only `4e8cf857` (BMWM3GTRE46 driver), `c6578694…97` (BRAKES pack) and `1366865e` (TRAFDMPTR badging).

## 7. Open
- Trailers: the `ATTACHMENTn` cargo pieces are all shown; some sit far from the trailer (they probably need markers or one per variant) [H].
- `USEMARKER2` spoilers (marker `SPOILER2`), rim paint, vinyls and composite skins, damage overlays, `ExtraRearTireOffset`.
- Unknown hashes listed in section 3.
