# 20 · Lighting and effects: PS2 colour space, cars, sky, shadows and visual treatment

Tags: **[V]** verified on SLES-53559 bytes or measured · **[D]** decomp · **[I]** inferred · **[H]** hypothesis.
Converter step: `bun src/cli/fx.ts <iso> <ID>` → `map-data/<ID>/fx/` (`fx.json` + 32 PNGs, < 1 s). `DATA_FORMAT` = 8.
Engine: `native-engine/Sources/Rockport/SceneShading.swift` (shared MSL prelude, `FXData`, `SceneLighting`), `Shaders.swift`,
`Renderer.swift`, `AIRender.swift`, `Garage/GarageRender.swift`. What the `effects` step exports (particles, world flares,
per-zone fog and tint) is in doc 24.

## 1. What looked wrong and why

| Defect | Cause | Fix |
|---|---|---|
| Big hard-edged translucent green boxes in the safehouse | The additive light shafts (`CRIB1_LIGHTRAYS01/02`, `SFX_LIGHTRAY`) were summed in **linear** space: vertex colour 255 (= 4.55 linear) × texture × alpha 0.05 ≈ +0.17 linear ≈ +115/255 on screen. The garage shader also ignored vertex alpha | The scene is written **encoded** and blended in gamma like the GS: Cs (clamped to 255) × As added on screen ≈ +12/255. Alpha = texture × vertex (`fs_gadd`, `fs_additive`) |
| Weak baked shadows (`SHD_*`), everything "flattened" | Normal blending in linear: with alpha 0.5 the street ended at 0.73 on screen (the PS2 leaves it at 0.5) | Gamma blending (§2) |
| Grey band at the bottom when entering the safehouse | The door gap (`corridor` in `WorldGarage.swift`) went 10 cm below the street and cut the street floor ±2.5 m around the roller door, where the interior does not reach: the sea showed through | The gap now starts 12 cm above the street |
| Flat cars | The viewer's PBR light, no environment map | Game light material per strip + spherical environment map (§3) |
| Home-made sky gradient | The sky textures were believed missing from the disc | They are in `GLOBAL\DYNTEX.BIN` (§5) |
| Car shadow: home-made blob | — | `CARSHADOW` from the disc, on the car box, pushed away from the sun (§4) |
| No yellow, contrasty "look" | Only our PS2 grade | The game's visual treatment (`visuallook`) before the PS2 grade (§6) |
| Streaks in the main menu sky | **Not a UV bug** [V]: the `QRACE_MIDDAYSKY` dome of `PLATFORMCRIB` is an octagon with a planar projection (u = 0.5 ± 0.5·x/r, top ring at 0.707 of the equator) and the texture stretches edge-on. `wrap` 0 (clamp) is correct | No change; the menu scene composition is being reworked separately (garage scenes) |

## 2. Scene colour space = the PS2's [D][V]
- The GS blends `(Cs − Cd)·As + Cd` on the 8-bit framebuffer, i.e. in display space. Textures and vertex colour are multiplied in
  that space too (128 = 1.0; the converter stores `COLOR_0 = (c/128)^2.2`, doc 02).
- The engine still samples in linear (sRGB textures) and multiplies in linear, which is identical for products, but now
  **every scene shader writes its colour encoded** (`sceneRGB`/`ps2Encode` in `scenePreludeMSL`) into the `rgba16Float` scene
  texture, so hardware blending happens in gamma like on the PS2. `fs_post` no longer encodes.
- Fog is blended in gamma as well (the GS applies fog after texturing).
- Rule for any new shader drawing into the scene: include `scenePreludeMSL` and return `sceneRGB(F, linearColour, world)`
  (or `ps2Encode(...)·k` for additive).

## 3. Cars: light material and environment map
### 3.1 Light material per strip [V][D]
- Each strip of a solid points to a light material (`eStripEntry +15` → the solid's hash table `0x00134013`) [V: solid-ps2.ts].
- Materials live in `GLOBAL\GLOBALB.BUN` chunk `0x00135200` (`eLightMaterial`, 0xA8 B, 156): name and `eLightMaterialData`
  (30 floats: diffuse min/max RGB × scale and alpha, specular power, specular min/max, envmap power, envmap min/max,
  `MetallicScale`, `SpecularHotSpot`) [D: Ecstasy/eLight.hpp][V: `fx.json` → `lightMaterials`].
- The converter now splits car materials by (texture, light material) and writes `extras.luz` [V: BMW M3 GTR: `WINDSHIELD`,
  `CHROME`, `MOLDINGS`, `RUBBER`, `MAGSILVER`, `BRAKEDISC`, `HEADLIGHTGLASS`, `CARBONFIBER2`…].
- The skin (`<CAR>_SKIN1`) carries an unnamed material (`d6d6080a`): the game uses `LightMaterial_CarSkin`, taken from the preset
  paint's `LIGHT_MATERIAL_NAME` (`METPAINTSILVER`, `REGPAINTBLACK`, `PEARL8`…) [D: CarRender.cpp][V: presets.json]. Tinted windows
  use `WINDSHIELD_TINT_*` (their diffuse already is the tint: L2_RED = (1, 0, 0) × 0.5, alpha 0.75) [V]. Traffic and police:
  `TRAFFIC` when the paint has no known material [I].
- Sample values [V]:

| Material | Diffuse min/max | Specular (power, min/max) | Envmap (power, min/max) |
|---|---|---|---|
| `METPAINTSILVER` | 0.75 / 1 | 3 · 0.7 / 0.3 | 0.15 · 3.5 / 0.2 |
| `REGPAINTBLACK` | 1 / 1 | 8 · 0.1 / 0 | 0.2 · 3 / 0.3 |
| `PEARL8` | (0.04, 0.32, 1.68)·0.74 / (0, 1.5, 0)·0.91 | 3.54 · … | 0.15 · 3.5 / 0.1 |
| `WINDSHIELD` | alpha 0.4 | 2.5 · 0 | 1 · 3 / 0.5 |
| `CHROME` | 1 / 1 | 1.5 · 0 | 0.5 · 2 / 2 |

### 3.2 How it is used (`carShade` shader) [I]
The PS2 code that consumes `eLightMaterialData` is not decompiled (`eLightE.cpp` is empty). Interpretation:
- t = N·V. Diffuse and specular go from **Min (edge-on) to Max (facing)**; envmap with `t^EnvmapPower`. So `METPAINTSILVER`
  reflects ×0.2 facing and ×3.5 at the edges: the game's Fresnel.
- Specular exponent `2^(SpecularPower+2)`; `MetallicScale` tints the reflection with the paint colour (50 %).
- The composited skin alpha is gloss (`GLOSS` ×2, `CompositeSkin` [D]): it scales specular and reflection (matte vinyl areas).
- Reflection: `ec² × 1.6 × strength` (`Config.envStrength` = 0.6; street ×0.5): contrast so ceiling lights and sky stay while
  the garage mid-tones do not wash the paint out [I: tuned against game captures].

### 3.3 Environment maps [V][D]
| Where | Texture | Projection |
|---|---|---|
| Safehouse | `CAREER_CARSELECTENVMAP` (128×128, `GLOBAL\DYNTEX.BIN`) | View-space sphere map (`elSetupEnvMap`: local → view matrix, eye at 2.78–8 m) [D] |
| Customization shop | `CSHOP_CARSELECTENVMAP` | same |
| Car lot | `CARLOT_CARSELECTENVMAP` | same |
| Main menu / quick race | `QRACE_CARSELECTENVMAP` | same |
| Street | `SMALLENVMAP` (64×64, `GLOBALB.BUN`): sky on top, black below | Azimuth/elevation [I] |

In game the street maps are rendered live (`EVIEW_ENVMAP*` draws the sky dome, `SkyRender.cpp`); `SMALLENVMAP` is the static
version on disc [I].

### 3.4 Lights [I]
- Street: two-colour ambient + sun. Sun direction = `SunChunkInfo` "MIDDAY" from `GLOBALB.BUN` chunk `0x00034202`
  (position 5300, −3550, 3000) [V] minus the camera.
- Garages: the game uses "shaper rigs" (`ShaperLightsSafehouse`, `…CShop`, `…CarLot`, `…QRace`; `eShaperLightRig`: 4 lights with
  mode, θ, φ, colour and scale) [D]. They are BSS, filled at run time: their values were not found on the disc.
  `SceneLighting.frontEnd` uses a warm key light from the windows, cool fill and rim, tuned against captures [I].

## 4. Car shadow [D][V]
- `CarRenderInfo::DrawAmbientShadow`: `CARSHADOW` texture (64×32, `GLOBALB.BUN`) over the car box × 1.05, a 4×4 grid on the
  ground; stretched away from the sun by `SunScale = (1 − sun.z)·0.5` m.
- Alpha: `CarBaseShadowAlphaMaxIG` = 100 (0x80 = opaque) in the street, 255 in the front end [D].
- Engine: player, rivals and showroom cars (`Renderer`), instanced traffic and police (`AIRender.shadowQuads`, drawn by the
  `Renderer` in the same pass).
- The projected "Keith" shadow (`DrawKeithProjShadow`, convex hull) is not done.

## 5. Sky and sun
- `SkyRender.cpp` [D]: the `SKYDOME` swaps textures per layer (`SKY_MIDDAY_A_GRADIENT_A`, `…_CAP_A`, `…_CLOUDS_A`,
  `…_ENVIRONMENT_A`, `…_REFLECTION`). They are in `GLOBAL\DYNTEX.BIN` with names truncated to 23 letters; `fx.ts` resolves them
  by hash [V]. Doc 03 said they were not on the disc: that was wrong.
- Engine (`fs_sky`) [I]: gradient by elevation, an alpha cloud band from the horizon to ~35° (slowly scrolling) and a cap above.
  The world `SKYDOME` geometry is still skipped by the converter.
- Sun: `SunChunkInfo` MIDDAY layers [V]: centre (`SUNCENTER`, 60 m, colour 255/200/100) and halo (`SUNHALO`, 320 m,
  130/110/25 ×0.5), as quads at its position, additive and occluded by the scene. Ray layers (textures 2–4) have no texture on disc.

## 6. Visual treatment (`visuallook`) [V][D][I]
- `GLOBAL\ATTRIBUTES.BIN`, classes `visuallook` (5), `visuallookeffect` (7), `visualrgbtweaker`, `visuallooktransition` [V] →
  `fx.json`. `IVisualTreatment` [D: World/VisualTreatment.cpp] uses Midday `0xEEC2271A` (not on the PAL disc; the VLT falls
  back to "default"), Sunset `0xCEDA4E4F`, Uves, CopCam `0xEE6074A3`. Curves = Bézier on the y of 4 points (`GetValueFromSpline`).
- "default": `ColourBloomTint` (0.87, 0.68, 0.04), intensity 0.32; `BlackBloomIntensity` 0.38; `Desaturation` 0.25.
- PS2: `eVisualTreatment.cpp` is in the PS2 source list but empty in the decomp [H: exactly what it does].
- Engine: quarter-res bright pass (`ColourBloomCurve` on luminance), separable 9+9 blur, then in `fs_post`: "black bloom" as an
  S-curve from `BlackBloomCurve` (more contrast in shadows), tinted bloom with screen blending (× `Config.bloomGain` 1.6),
  desaturation (× 0.6), then the usual always-on PS2 grade.
- `ROCKPORT_LOOK=0` disables it (debug); `ROCKPORT_ENV=<n>` changes reflection strength.

## 7. Performance
See the table in the engine README (§ Lighting and effects). The visual treatment is 3 quarter-resolution passes.

## 8. Remaining
- Real values of each garage's shaper rig (BSS: find who fills them in the ELF).
- Live street environment map (the game draws the sky into `EVIEW_ENVMAP`), projected "Keith" shadow, sun rays and lens flares,
  street-lamp and car light flares (`light_flares_cg` + doc 24 §4), per-zone screen tint and fog from the ParameterMaps
  (doc 24 §6.2), world `SKYDOME` geometry.
