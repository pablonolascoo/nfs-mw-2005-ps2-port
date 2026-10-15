# 20 · Lighting and effects: PS2 colour space, cars, sky, shadows, visual treatment, particles and flares

Tags: **[V]** verified on SLES-53559 bytes or measured · **[D]** decomp · **[I]** inferred · **[H]** hypothesis.
Converter step: `bun src/cli/fx.ts <iso> <ID>` → `map-data/<ID>/fx/` (`fx.json` + 32 PNGs, < 1 s). `DATA_FORMAT` = 8.
Engine: `native-engine/Sources/Rockport/SceneShading.swift` (shared MSL prelude, `FXData`, `SceneLighting`), `Shaders.swift`,
`Renderer.swift`, `AIRender.swift`, `Garage/GarageRender.swift`. What the `effects` step exports (particles, world flares,
per-zone fog and tint) is in doc 24; how the engine uses it (particles, flares, per-zone fog and tint, `Effects/`) is in §9.

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
- Live street environment map (the game draws the sky into `EVIEW_ENVMAP`), projected "Keith" shadow, world `SKYDOME` geometry.
  Particles, flares, per-zone fog and tint: done (§9); what is left of them is in §9.7.

## 9. Particles, flares, per-zone fog and tint (native engine, `Effects/`, 2026-10-15)
Code: `native-engine/Sources/Rockport/Effects/` (`EffectsLibrary`, `Particles`, `CarEffects`, `LightFlares`, `ZoneFog`,
`GarageShafts`, `EffectsGPU`, `EffectsSystem`, `EffectsTests`). Data: `effects.json` + `effects/particles/` (`effects` step,
doc 24) and `fx/fx.json` (`light_flares_cg`). The data format does not change. It hooks into the Renderer as one more layer
(`RenderOverlay`): it simulates once per frame and draws in every view inside the scene pass, in the PS2 colour space (§2).
`ROCKPORT_FX=0` removes it; `ROCKPORT_FX=hide` simulates without drawing ("before" shots).

### 9.1 Particles: `EmitterSystem.cpp` ported [D][V][I]
| Part | How [tag] |
|---|---|
| Lifetime curves | `CalculateBases`: colour (4 RGBA byte keys) and size/rotation (`Size`/2, `RelativeAngle`×182.04) are a cubic polynomial through the 4 values at `KeyPositions`/3 (`hermite_basis` = U⁻¹·P) [D]. t = 1 − remaining life / the emitter's `Life`; colour clamped to 0…255 [D] |
| On/off | `EmitterControl::Update`: delay, on/off cycles with variance, one-shot [D] |
| How many | `SpawnParticles`: `NumParticles` × intensity × dt (accumulated when < 1); a one-shot uses `Life` instead of dt [D] |
| Emission | volume (`VolumeCenter` ± `VolumeExtent`/2), cone (emitter Z axis ± `SpreadAngle`/2) or disc with `Speed`; otherwise `VelocityStart` ± `VelocityDelta` along the emitter axes and acceleration in world axes [D] |
| Motion | drag `v += v·max(−1, −dt·Drag·|v|)`; with `Gravity` ≠ 0 only z falls, else `v += a·dt`; inherited car velocity (`MotionInherit`) [D]. `MotionLive`: particles follow the emitter [I] |
| Death | life, or alpha ≤ `AlphaToKillAt` unless `NoKillAtAlpha` [D] |
| Animation | N×N grid (`ParticleAnimationInfo`), frame from FPS and random start (`GetAnimatedUVs`) [D] |
| World | 1,535 emitters (0x0003BC00): created at `FarClip` + 20 m ahead (cosine 0.55) and deleted when left behind; particles beyond `FarClip` die (`ServiceWorldEffects`, `UpdateParticles`) [D]. 23 are triggered by a nearby car (radius, reset) and give one burst [D][I] |
| Front-end garages | 41 emitters from `FRONTEND\PLATFORMS\*.BIN` in interior space: low fog and steam in the menu yard (`fxenv_fog_fe1`, `fxenv_small_steam1`), safehouse steam (`fxenv_small_steam2` ×7), shop, car lot [V]. In world garages only those inside the interior box. Created warm (up to 10 s simulated) [I] |
| Drawing | camera-facing billboards rotated by `mAngle`, or in an XY/XZ/YZ plane (`AxisConstraint`, `GetConstraintBasis`) [D]; half side = `mSize` [D]. One instanced call for normal-blend particles (sorted far to near) and one for additive ones; the 42 used textures in a 64×64 array [I] |
| Colour | texture × vertex colour/128 in gamma (like every PS2 vertex colour, doc 02) and alpha/128 [I: the PS2 `PlatAddParticle` code is not decompiled]. Normal or additive blending from the TPK texture's `AlphaBlendType` [V] |
| Cap | the PS2 has 1,024 particles and 500 emitters [D]; here 2,048 particles [I] |

Cars (`CarEffects.swift`):
- Tyres (`TireState::DoFX`, `SetSurface`, `Effect::Update` [D]): three effects per grounded wheel with intensity
  `Ramp(value, minSpeed, maxSpeed)` from the surface record: sideways slide (`TireSlideEffects`), wheelspin (`TireSlipEffects`)
  and rolling (`TireDriveEffects`). The exported collision has no surface material: "asphalt" [I] (`fxtd_sk_asphalt` 1–2,
  `fxtd_sl_asphalt` 0.125–5 [V]). `SlipFX`/`SkidFX` (`ecar` attribute, not exported) = 0.5 [I]; slip = `Tire.slip` (m/s),
  slide = `Tire.lateralSpeed` (m/s). A standing burnout (throttle + brake) spins at ~22 m/s: 80–95 smoke particles, like the game
  (10 per second per wheel, 2.4 s life, alpha 12–40 of 128) [V: measured].
- Nitrous: `NOSEffect` = `carexhaustnos` → `fxcar_nos` (`emcar_nos_fire` + `emcar_nos_glow`) on every `*_EXHAUST` marker of the
  model, direction = its Z axis [D][V] (the M3 GTR has them on the right-hand side).
- Impacts: a burst of `carhitwall` → `fxcar_impactl` (sparks and glow) on the hit side when the velocity changes by more than
  4 m/s in one frame [I: the game fires it from the collision; the engine does not publish contacts yet].
- Dust, dirt and water: they come out on their own for non-asphalt surfaces (`dirt`, `grass`, `water`…), but the ground
  material is still missing.

### 9.2 Flares (`LightFlares.swift`) [D][V][I]
- World: the 2,242 solid markers (doc 24 §4) [V]: 955 amber, 340 red (`XO_TRAFFICLIGHT*` traffic lights), 199 green, 748
  cat's eyes. **There are no street-lamp flares** on PS2: no marker is `ELF_LAMPPOST` and `lamppost_outer` has colour 0 [V].
- Blinkers (`eResestLightFlarePool` [D]): three clocks of 0.5 / 0.4 / 0.45 s; amber uses the one at |x| mod 3, red the first and
  green the third.
- Cars (`CreateCarLightFlares`, `RenderFlaresOnCar` [D]): markers `LEFT/RIGHT/CENTRE_HEADLIGHT` (headlight, 1), `*_BRAKELIGHT`
  (0.5, +16 when braking, capped at 1; traffic uses `brakelight_traffic_inner`), `*_REVERSE` (reverse gear) and the police light
  bar (`COPLIGHT*`, hashes `1e4150b4` red, `e662c161` blue, `b4348dba` white [V]) with `coplightflicker2`: alternating red and
  blue (cos(8t) > 0.2), cos²(24t) pulse, white = sin(3·flicker) [D]. Player, rivals, split screen, traffic and police.
- Light-bar halo: `RenderFlaresOnCar` with `renderFlareFlags & 1` redraws only the police lights at ×10 [D]; here ×6 with
  `HEADLIGHTGLOW` and weight 0.15 [I]. The `fxcar_coplight*` groups (0.01 s life) are used by nothing in the decomp: not used.
- Sun: `ELF_SUN_FLARE` with `sun_flare` in the `SunChunkInfo` direction [V], intensity 1 above the horizon [I].
- `light_flares_cg` parameters [V]: colour, `MinSize`/`MaxSize`, `MinScale`/`Maxscale`, `Power`, `ZBias`, `flare_texture`.
  `eRenderLightFlare` is undecompiled PS2 code, so drawing is [I]: diameter in pixels of a 480-line screen =
  `MaxSize` × (0.35 + 0.65·k) × min(1, max(0.35, 30 m / distance)); k = intensity × (facing)^`Power` for head and tail lights;
  Cs = texture × colour×2 (saturating like the GS) added with weight alpha×2·k; pulled `ZBias` m towards the camera and depth
  tested (occlusion); fades out between 500 and 800 m. Textures 0/1/2 = `HEADLIGHTGLOW` / `HEADLIGHTFLAREOUTER` /
  `HEADLIGHTFLAREINNER` [H: order of `eLightFlareTextureNameHashes`].

### 9.3 Per-zone fog and tint (`ZoneFog.swift`) [V][D][I]
- Layers `Normal Fog` (3 sets of 8 values), `Screen Tint Midday` (219, 206, 87 all over Rockport) and `Fog Blend Distance` (50 m)
  [V], looked up by the camera's (x, y) in their quadtree.
- The game's blending (`ParameterAccessorBlendByDistance::CaptureData` [D]): the value moves towards the new zone's in the ratio
  distance travelled / 50 m, one accessor per view (`FogAccessor[2]` [D]).
- Fog fields [I]: [0] maximum density (0.5 / 0.6 / 0.2), [1] start (200 / 202 / 243 m), [2…4] colour (greys 128 and 135),
  [5] falloff → scale 2,600 m × 0.75 / falloff; [6] and [7] unknown [H] (`FogQuery::CalculateFogInfo` is empty).
- Tint: replaces the fixed amber of the PS2 grade with the zone colour normalised by its luminance, strength 0.3 (with 219, 206, 87
  it gives (1.035, 1.015, 0.833), close to the previous (1.07, 1.03, 0.86)) [I]. Not used in the front-end garages.

### 9.4 Garages: the safehouse dark strip, threshold light and window shafts
- **Dark strip at the bottom when entering the safehouse** (the "inside" shot of `--garage-test zone_safehouse_1`): it was not the
  street ground nor the door's baked `SHD_*` shadow [V: still there with `ROCKPORT_WORLD_HIDE=SHD`] but two things: (1) the interior
  clip box started 0.3 m inside the roller door, and between it and the door line the world ground showed, dark from the building's
  baked light; (2) the scene's threshold (`APRON`, colour measured inside) is much darker than the lit interior floor [V: it vanished
  without the scene]. Fix: the world no longer draws the ground under the door gap (`GarageCutout.threshold`, a third box in the
  shaders' `Cutout`), the interior box reaches 0.8 m further towards the street (`GarageRenderer.doorReach`) and the threshold gets
  the interior light spilling through the door (×6 next to the door, fading over 1.8 m: `GarageDrawItem.spill`) [I]. Measured:
  the 22 px band (35–77 of 255) is gone; the floor reaches the edge [V].
- **Window light shafts** on our walls (`*WINDOW*` decals from `garage-scenes`, currently the shop's): two crossed additive planes
  per window going down and inwards at 50°, with a gradient and dust [I] (`GarageShafts.swift`). The interiors' own rays from the
  disc (`CRIB1_LIGHTRAYS*`, `SFX_LIGHTRAY`, `CSHOP_LIGHTRAYS01`…) were already drawn (§1).
- The haze of the references (menu yard, safehouse) now comes from the game's own particles (`fxenv_fog_fe1`,
  `fxenv_small_steam1/2`); our low haze in the menu (`fogHeight`, §6) stays for the yellow tone of the ground [I].

### 9.5 Tests
- `Rockport --fx-test burnout|street|pursuit --screenshot base.png [--size WxH]`: standing burnout and nitrous (`base-quemada`,
  `base-nitro`), the junction with the most traffic lights (`base-calle`), three patrol cars with their light bars on
  (`base-persecucion`), with GPU time with and without effects in the same process. `--fx-test stats`: curves and counts, no drawing.
- Menu, safehouse and garages with the usual tests (`--ui-test MainMenu`, `--garage-scene career_safehouse --fe-angle
  career_car_select`, `--garage-test zone_safehouse_1`, `--garage-test zone_customshop_1`).
- Debug: `ROCKPORT_WORLD_HIDE=TEXT,…` (skips world materials; `*` = all), `ROCKPORT_DEBUG_CAM=1` (camera position).
- Before/after shots in `native-engine/.build/shots/fx/` (`cmp-*.png`, `cmp-resumen.png`).

### 9.6 Performance [V: M4, machine shared with other jobs: noisy numbers]
| Test | Without effects | With effects |
|---|---|---|
| Fly-through 12 s, 2940×1912 (GPU median) | 5.98–6.01 ms | 5.90–6.67 ms |
| 2-player split screen, 2940×1912 (GPU median) | 6.28–6.70 ms | 6.44–6.74 ms |
| Same process, 1920×1080, burnout / pursuit / street | 1.36 / 1.20 / 2.25 ms | 1.76 / 1.40 / 2.28 ms |

Cost: +0.1–0.4 ms GPU and < 0.1 ms CPU (≤ 2,048 particles, ≤ 4 calls per view). Far from 16.7 ms.

### 9.7 Remaining
- Ground material in the collision (dust, dirt and water from the tyres) and real contacts for sparks and scrapes
  (`OnScrapeGround`, `carscrapewall`); tyre blow-out and police car death (`carblowtire`, `cardeath1`).
- Breakables (`smokeables`) with their effects; sound triggers; per-zone rain and clouds (no rain in free roam on PS2 [I]).
- What exactly `eRenderLightFlare` (sizes and scale) and `PlatAddParticle` (colour scale) do on PS2: undecompiled code.
