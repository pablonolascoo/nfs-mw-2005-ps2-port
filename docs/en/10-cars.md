# Cars: models, replacement textures, paint and wheels

Tags: [V] verified on SLES-53559 bytes · [D] from the decomp · [I] inferred · [H] hypothesis.

## 1. Where everything lives

| What | Disc source | Code | Output |
|---|---|---|---|
| Geometry | `CARS\<CAR>\GEOMETRY.BIN` | `tools/src/cli/convert.ts` (`car` mode) | `map-data/<ID>/cars/<CAR>.glb` |
| Own textures | `CARS\<CAR>\TEXTURES.BIN` | `tools/src/lib/tex-ps2.ts` | inside the GLB |
| Shared textures | `CARS\TEXTURES.BIN` | same | inside the GLB |
| Textures swapped by the game | none (built at runtime) | `tools/src/lib/car-textures.ts` | materials with `extras.role` |
| Wheels (position, radius) | `GLOBAL\ATTRIBUTES.BIN`, `TireOffsets` | `tools/src/cli/car-attribs.ts` | `map-data/<ID>/cars.json` |
| Viewer assembly | — | `viewer/src/drive.ts` (`mountWheels`, `paintCar`, `carHolder`) | — |

SLES-53559 has **91 models** [V]: 40 cars, 11 police, 27 traffic, 6 trailers and 7 tuning-part sets (`WHEELS`, `SPOILER`, `ROOF`, `BRAKES`…).
`cars.json` holds **92** attribute collections [V].

Regenerate only the cars:

```bash
cd tools && awk -F'\\' '/^CARS\\[A-Z0-9_]+\\GEOMETRY\.BIN,/{print $2}' ../inventory/SLES-53559.csv | xargs bun src/cli/convert.ts ../original/SLES-53559.iso SLES-53559 car
bun src/cli/car-attribs.ts ../original/SLES-53559.iso SLES-53559
```

## 2. Parts and levels of detail
- Each part is a solid `<CAR>_KIT00_<PART>_<LOD>`; LOD `A` is the best [V].
- The converter keeps the best LOD per part and drops `_DAMAGE*` (`bestLod` in `convert.ts`).
- On PS2 the best tyre is usually `_B` (e.g. `BMWM3GTRE46_KIT00_FRONT_TIRE_B`) [V].
- Model axes: X forward, Y left, Z up; origin at the car floor [V on the BMW body: Z 0…1.23 m].

## 3. Replacement textures
The model asks for "placeholder" texture names. The game swaps them at runtime through
`CarRenderInfo::MasterReplacementTextureTable` (`CarRender.cpp`) and `UsedCarTextureInfo` (`CarInfo.cpp`) [D].
They are not in any `TEXTURES.BIN` on the disc [V], so the converter gives them a stand-in material.

| Name (bStringHash) | Role (`extras.role`) | Stand-in |
|---|---|---|
| `<CAR>_SKIN1`, `<CAR>_SKIN1B`, `GLOBAL_SKIN1`, `SPOILER_SKIN1`, `ROOF_SKIN` | `pintura` (paint) | light grey; the viewer paints it |
| `0xA7366AE6` CARBONSKIN, `0x3C84D757` GLOBAL_CARBONSKIN | `carbono` | near black |
| `WINDOW_*`, `REAR_DEFROSTER` | `cristal` (glass) | dark, translucent |
| `0xA7E6EA53` / `0xA532FC46` headlights, `HEADLIGHT_GLASS_*` | `faro` / `cristal` | white / clear glass |
| `BRAKELIGHT_*`, `BRAKELIGHT_GLASS_*` | `piloto` / `cristal` | red |
| `LICENSEPLATE` | `matricula` | white |
| `0x5799E60B` DRIVER | `piloto_conductor` | dark grey |
| `BRAKE_GLOBAL*`, `0x7811C149` | `freno` | metal grey |
| `0xE38806E3` (outer square card) and `0x03C906EF` (inner barrel) on the TIRE part | `llanta` | **hidden** with stock rims |

Still unnamed on the BMW: `1b049702 cc772afb bd1f0e0a 721aff7c 4e8cf857` → neutral dark grey.
To name more: `experiments/decomp/.../Generated/Hash.hpp` and `bStringHash` trials (`tools/src/lib/hash.ts`).

### Paint in the viewer
- `paintCar(model, "#rrggbb")` changes only materials with `role = "pintura"`.
- Player car: URL parameter `?pintura=1f6fd1` (default silver `aeb7c2`).
- Display cars: `paint` field in each mod `display` entry (`mods/garajes-unicos/mod.json`).

### Rims
- The `<CAR>_TIRE` texture already paints **tyre and stock rim** together [V: BMW M3 GTR].
- The TIRE part also carries a square card on the outer face and an inner barrel.
  They are for **aftermarket rims**: texture `<BRAND>_STYLEnn_WHEEL` (face) and mask `<BRAND>_STYLEnn_WHEEL_INNER_MASK` [D: `CarSkin.cpp`, V: `CARS\WHEELS\TEXTURES.BIN`, 82 textures].
- With stock rims the viewer hides them (`hideAftermarketRimCards` in `viewer/src/drive.ts`); otherwise a square shows.

## 4. Wheels
The model ships **one wheel** (the front one). The game draws it four times [D].

`TireOffsets[i] = (x, y, z, radius)` for i = 0 FL, 1 FR, 2 RR, 3 RL [D].
BMW M3 GTR: front x = 1.6, rear x = −1.13, y = ±0.91, radius 0.33 m [V].

Mounting rule (`CarRender.cpp`, `WheelPivotTranslationAmount = 0.5`) [D]:
- The TIRE part spans y = 0 (inner) to y = width (outer, rim face) [V].
- The **outer face** sits at |y| = `TireOffsets.y`; the rubber extends inward.
- Wheels on the other side are mirrored (scale y = −1).
- `z = 0` in `TireOffsets` = axle at the part's centre height.
- The game also scales width and radius (`TireSkidWidth`, `KitWheelOffsetFront/Rear`) and applies camber (`CamberFront/Rear`). **Not applied in the viewer yet.**

Oddities: some `cars.json` collections (class `ecar`) have rear x of 3 or 5 m [V]; they look like template values, not a real car [H].

## 5. To do
- Aftermarket rims from `WHEELS.glb` (165 parts: 5ZIGEN, BBS, OZ…) mounted on the tyre.
- Real composite paint (vinyls, composite `CARSKIN`), width scaling and camber.
- Names for the remaining hashes.
