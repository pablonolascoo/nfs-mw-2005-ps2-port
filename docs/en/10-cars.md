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
| Viewer assembly | — | `viewer/src/drive.ts` (`applyCarConfig`, `mountWheels`, `paintCar`, `skinCar`, `presetSkin`, `carHolder`) | — |

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
- Player car: defaults to the game preset `M3GTRCAREERSTART` (silver + blue stripes, section 8); `?preset=BL5` picks another; `?pintura=1f6fd1` goes back to plain paint. Showroom cars: the mod's `paint` field.

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
- `USEMARKER2` spoilers (marker `SPOILER2`), damage overlays, `ExtraRearTireOffset`, paint environment maps (the PS2 reflects the sky; here PBR) and shop decals (section 8).
- Unknown hashes listed in section 3.

## 8. Preset cars (Blacklist), vinyls and composite skins (2026-10-15)

### Where they live [V][D]
All in `GLOBAL\GLOBALB.BUN` (not in the VLT: the `presetride` class of `ATTRIBUTES.BIN` only holds performance levels [D: `presetride.h`]).

| Chunk | Contents | Size |
|---|---|---|
| `0x00030220` | `PresetCar[82]` [D: `CarInfo.hpp`]: `+0x08` car type (char[32]), `+0x28` preset name (char[32]), `+0x48` FEKey u64, `+0x50` VehicleKey u64, `+0x58` FilterBits, `+0x5C` PhysicsLevel, `+0x60` `PartNameHashes[139]` (one per `CARSLOTID`) | 0x290 B (0x28C + u64 alignment) [V: 53,792 = 82 × 0x290] |
| `0x80034602` | `CarPartPack`: `0x34603` header (60 B; 11,925 parts, 1,751 attributes, 99 types, 487 model tables) · `0x34606` strings (offset ×4) · `0x3460c` attribute tables (int16) · `0x34605` attributes (8 B: hash + value) · `0x3460a` models (0x18 B) · `0x3460b` types · `0x34604` parts (0xE B) | [V] |
| `0x00034600` | `CarTypeInfo[84]` (0xD0 B, 16-aligned) | [V] |
| `0x00034607` | per-slot types `u32[139×2]` (0xFFFFFFFF = the car itself) + 10 `CarSlotTypeOverride` | [V] |
| `0x00135200` | light materials (156): `+0x0C` hash, `+0x14` name (`WINDSHIELD_TINT_L2_RED`, `METPAINTSILVER`…) | [V] |

- Per slot: `0` = empty, `1` = stock (level 0), anything else = part name hash, looked up by `PartID` (`CarPartSlotMap`) and type (`GetTypesFromSlot`) [D: `FillWithPreset`, `NewGetCarPart`].
- Part attributes (bStringHash) [V]: `RED GREEN BLUE GLOSS` (paint), `TEXTURE` (string: vinyl name), `NUMCOLOURS`, `REMAP`, `NUMREMAPCOLOURS`, `BRAND_NAME` (`GLOSS`/`METAL`/`PEARL`/`VINYL`/`RIM`), `TEXTURE_NAME` (rim), `LIGHT_MATERIAL_NAME`, `KITNUMBER`, `CARBONFIBRE`, `USEMARKER2`, `NAME`, `SPOKE_COUNT`, `INNER/OUTER_RADIUS`… Unresolved: `0x311151f8`, `0x4732da07`.
- Solid of each part: `CarPart::GetModelNameHash` [D] = `bStringHash("_B", bStringHash(name, bStringHash(middle, base)))`, base = car type, brand or 0xFFFFFFFF. Matches the GLB nodes: `MUSTANGGT_KIT04_BODY_B`, `SPOILER_STYLE15_CF_B`, `WHEELS:OZ_STYLE01_20_25_B` [V].
- 82 presets: `RAZORMUSTANG` and `BL2…BL15` (Blacklist), `M3GTRCAREERSTART` and `E3_DEMO_BMW` (story BMW), `CS_CAR_*` (cutscenes), `CE_*`/`BONUS_*` (collector's edition), cutscene cops.
- In `gameplay.json` the `race_bin_01` boss (Razor) uses `E3_DEMO_BMW`, which looks the same as `M3GTRCAREERSTART` [V].

### Vinyls and compositing (CarSkin.cpp) [D][V]
- Each car has `CARS\<CAR>\VINYLS.BIN` (~276 PSMT8 textures, **512×512**) with `<BASE>_<TEXTURE>` and `<BASE>_<TEXTURE>_MASK`, in the same UV space as `<BASE>_SKIN1` [V]. `PREVINYL.BIN` only has 3 256×256 tests (`_PRECOM_`).
- Blacklist vinyls are `NNNAME` (`01RAZORCALLAHAN`…`15TONYHO`); the BMW's is `PSRTEST` (the blue stripes) [V].
- `CompositeSkin` (8-bit, PS2) [D]: canvas = base colour (paint RGB, alpha = `GLOSS`); per pixel `m` = R byte of the mask palette: `m ≥ 0x80` → vinyl pixel, `0 < m < 0x80` → blend `m/128`. Vinyl alpha is gloss (matte areas). With `REMAP` the vinyl is recoloured with `VINYL_COLOUR0_0…2` (weights alpha/B/G [H]); **no preset on the disc uses REMAP** [V].
- The same skin is used for `SPOILER_SKIN1`, `ROOF_SKIN` and `GLOBAL_SKIN1` [D: `ReplaceSpoilerHash`].
- Rims: `CompositeRim` tints `<RIM>_WHEEL` with `PAINT_RIM` through `<RIM>_WHEEL_INNER_MASK` from `CARS\WHEELS\TEXTURES.BIN` [D][V].
- Windows: tint swaps the light material (`WINDSHIELD_TINT_*`), not a texture; the colour is inferred from the name [I].
- Decals (`DECAL_*_TEXn`): no Blacklist preset uses them [V]; the `DECAL_*` zones stay hidden.

### Converter and engines
- `tools/src/lib/car-presets.ts` (readers) and `tools/src/cli/presets.ts` → `map-data/<ID>/presets.json` (per preset: `solids` with the exact node for each slot, `kit`, `paint`, `vinyl` with colours, `rim`, `rimPaint`, `windowTint`, `decals`) and `vinyls/*.png` (42 vinyls + masks + 18 rim masks; local only). Installer step "Coches de la Lista Negra"; `DATA_FORMAT` = 3. ~6 s.
- Native engine: `CarSkin.swift` composites the skin on the CPU **at 1024×1024** (twice the PS2 size, bilinear sampling of image and mask: smooth edges, no invented detail) and uploads it with mipmaps; `Car.swift` mounts only the preset's solids, `WHEELS` rims, and the pack spoiler/roof scoop on the `SPOILER`/`ROOF_SCOOP` markers. The player defaults to `M3GTRCAREERSTART`; `--car-preset RAZORMUSTANG` (or `BL2…BL15`, `ninguno`).
- Viewer: `?preset=RAZORMUSTANG` (defaults to the story BMW); `presetSkin`/`skinCar` in `viewer/src/drive.ts` do the same compositing on a canvas.
- Broken solid on the disc: `CAYMANS_KIT00_REAR_LEFT/RIGHT_WINDOW` has vertices 9 m away from the car [V]; both engines drop parts that leave the car's bounds.

### The Blacklist (disc presets) [V]
| # | Preset | Car | Body | Hood | Spoiler | Roof | Rim | Paint | Vinyl | Rim paint | Windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| — | `M3GTRCAREERSTART` | BMWM3GTRE46 | KIT00_BODY | — | — | — | KIT00_FRONT_TIRE | METAL_L1_COLOR41 `#b7b7b7` | PSRTEST | — | STOCK WINDOW TINT |
| 1 | `RAZORMUSTANG` | MUSTANGGT | KIT04_BODY | STYLE04_HOOD | SPOILER_STYLE15_CF | ROOF_STYLE01 | OZ_STYLE01_20_25 | GLOSS_L1_COLOR62 `#000000` | 01RAZORCALLAHAN | `#c0cfd4` | DARK RED |
| 2 | `BL2` | SLR | KIT00_BODY | KIT00_HOOD | — | — | ADR_STYLE05_20_25 | GLOSS_L1_COLOR62 `#000000` | — | — | DARK RED |
| 3 | `BL3` | DB9 | KIT05_BODY | STYLE03_HOOD | SPOILER_STYLE43_CF | — | OZ_STYLE02_20_25 | METAL_L1_COLOR27 `#f8ca00` | 03RONNIEMCCREA | — | DARK BLUE |
| 4 | `BL4` | VIPER | KIT03_BODY | STYLE21_HOOD | SPOILER_STYLE43_CF | — | BBS_STYLE02_20_25 | PEARL9_PAINT `#3ca03c` | 04JOEVEGA | `#303030` | DARK BLACK |
| 5 | `BL5` | CORVETTE | KIT01_BODY | KIT00_HOOD | SPOILER_STYLE02_CF | — | BBS_STYLE05_20_25 | GLOSS_L1_COLOR45 `#5f2700` | 05WESALLEN | — | DARK ORANGE |
| 6 | `BL6` | GALLARDO | KIT00_BODY | KIT00_HOOD | SPOILER_STYLE42_CF | — | OZ_STYLE03_20_25 | METAL_L1_COLOR62 `#000000` | 06HECTORDOMINGO | — | DARK PEARL ORANGE |
| 7 | `BL7` | CLK500 | KIT03_BODY | STYLE07_HOOD | SPOILER_STYLE15_CF | ROOF_STYLE18_CF | OZ_STYLE02_20_25 | METAL_L1_COLOR61 `#7d7d7d` | 07KIRANAZAKATO | `#6e6e6e` | DARK BLACK |
| 8 | `BL8` | MUSTANGGT | KIT05_BODY | STYLE21_HOOD | SPOILER_STYLE16_CF | — | ADR_STYLE03_20_25 | GLOSS_L1_COLOR03 `#fffceb` | 08JADEBARRETT | — | DARK BLACK |
| 9 | `BL9` | LANCEREVO8 | KIT04_BODY | STYLE26_HOOD | SPOILER_STYLE11_CF | ROOF_STYLE18_OFFSET_CF | ENKEI_STYLE04_20_25 | GLOSS_L1_COLOR01 `#ffffff` | 09PIERREDUPONT | — | DARK YELLOW |
| 10 | `BL10` | CAYMANS | KIT04_BODY | STYLE07_HOOD | SPOILER_STYLE43_PORSCHES_CF | ROOF_STYLE01 | BBS_STYLE04_20_25 | GLOSS_L1_COLOR62 `#000000` | 10KARLSMIT | `#6e6e6e` | DARK RED |
| 11 | `BL11` | ECLIPSEGT | KIT05_BODY | STYLE13_HOOD | SPOILER_STYLE16 | ROOF_STYLE02 | ROJA_STYLE03_20_25 | METAL_L1_COLOR62 `#000000` | 11LOUPARK | `#000000` | DARK PEARL GOLD |
| 12 | `BL12` | RX8 | KIT03_BODY | STYLE17_HOOD | SPOILER_STYLE15_CF | — | ROJA_STYLE01_20_25 | METAL_L1_COLOR02 `#4f4f4f` | 12ISABELDIAZ | — | DARK PEARL AQUA |
| 13 | `BL13` | SUPRA | KIT03_BODY | STYLE20_HOOD | SPOILER_STYLE02 | — | OZ_STYLE03_20_25 | GLOSS_L1_COLOR76 `#0b0e2e` | 13VICTORVASQUEZ | `#856a35` | DARK ORANGE |
| 14 | `BL14` | IS300 | KIT03_BODY | STYLE26_HOOD | SPOILER_STYLE36_CF | ROOF_STYLE15_CF | VOLK_STYLE01_20_25 | GLOSS_L1_COLOR46 `#5f4200` | 14VINCEKILIC | `#d10707` | MEDIUM RED |
| 15 | `BL15` | GTI | KIT01_BODY | STYLE07_HOOD | KIT00_SPOILER | ROOF_STYLE03 | BBS_STYLE04_20_25 | GLOSS_L1_COLOR03 `#fffceb` | 15TONYHO | `#6e6e6e` | DARK PEARL RED |

Native-engine contact sheet of all 15: they match the in-game liveries (Razor black with flames, Ronnie yellow, JV pearl green, Kaze grey, Jewels white, Earl blue and white, Baron black with flames, Sonny white and blue…).
