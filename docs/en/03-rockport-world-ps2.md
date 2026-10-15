# The Rockport world on PS2 (SLES-53559)

- `TRACKS\L2RA.BUN` (1.38 MB): permanent data. Section table `0x00034110`, road network `0x0003B800`, triggers, events `0x8003B810`… [V]
- `TRACKS\STREAML2RA.BUN` (191 MB): 1,023 streaming sections [V].
- Section entry (92 B) [V]: `+0 name[8]` · `+8 number` · `+16 type` · `+20 offset` · `+24 size` (×3) · `+36 priority` · `+40 centre X,Y (f32)` · `+48 radius` · `+52 checksum`.
- A typical section holds a texture pack + solid lists + scenery `0x80034100` + lights `0x80036000` + road data `0x0003B801`.
- **SceneryInfo** (0x48): name[24] + 4 model hashes (LODs) + radius [D][V].
- **PS2 SceneryInstance** (0x40) [V]: `f32 bbMin[3]`, `f32 bbMax[3]`, …, `f32 pos[3] @0x20`, `s16 rot[9]/8192 @0x2C`, `s16 info @0x3E`. (On PC/GC the box is s16; on PS2 it is float.)
- Large buildings are already in world space (identity instance); props use position + rotation.
- Coordinates: Z up [D]. Units: metres [H] (a car is ≈4.5 m long).

## Full conversion figures
718 sections with scenery · 106,714 instances · 18,156 unique solids · 5.75 M visible triangles · 2,627 textures · 4 instances without a model · 5 textures not found (of 7: `HEADLIGHTGLOW` and `GRAY_MID_A` are in `GLOBAL\GLOBALB.BUN` / `INGAMEA.BUN`).
Top-down map: `map-data/<disc>/rockport-plano.png` (1.49 m/px; calibration in `rockport-plano.json`).

## Scenery groups and lane blockers [V]
- `ExcludeFlags` (u32 @0x18 of the PS2 instance): bit `0x10` = hidden by default, `0x400` = flipped artwork [D: `SceneryGroup::EnableRendering`].
- `L2RA.BUN` → `0x00034108` SceneryOverrideInfo[] (6 B: section, instance, flags) and `0x00034109` SceneryGroup (`NameHash`, `GroupNumber`, `NumObjects`, `BarrierFlag`, `DriveThroughBarrierFlag`, u16 indices; size `(n·2+0x17)&~3`).
- 754 groups: 675 `BARRIER_SPLINE_n` (per-race chevron blockers), 6 `BARRIER_LOCKED_10..15` (story padlocks), `SCENERY_GROUP_DOOR` (junk piles and diggers closing streets; enabled at load), 71 more blockers named by brute force, and one large unnamed group (#1, 7,353 objects, visible).
- The game enables groups by name with `EnableBarrierSceneryGroup` (races and progression).

## Garage and shop zones [V]
15 zones in `GAMEPLAY.BIN` (see doc 05): 4 safehouses, 3 car lots, 8 custom shops. Each has its building nearby: `XS_SafeGarage` / `XB_CT_SafehouseA` (safehouse 1), `XB_CarParkDealership` (car lots), `XB_ChopShopA` (all 8 shops, same model).
In the original game, pressing the button in a zone calls `EQuitToFE(GARAGETYPE_*)`: it leaves the world and loads the menu with the interior backdrop (`FRONTEND\PLATFORMS\*.BIN`).

## Shadows, water and sky [V]/[H]
- **Baked shadows** `SHD_*` (1,026 textures): black RGB, alpha = density. Blended over the ground; excluded from the far level [V].
- **Animated water** `ANM_WATERA_000…013` (14 frames) on `TRN_Ocean_*` and shoreline pieces, vertex alpha 0.5 [V]. Those meshes only cover shorelines; the viewer draws the water body as a plane at z = 0 [H: not yet located in the game code].
- **Sky** `SKYDOME`/`SKY_SPECULAR`: the dome swaps its textures per layer (`SkyRender.cpp`) and those textures **are** in `GLOBAL\DYNTEX.BIN` (`SKY_MIDDAY_A_GRADIENT_A`, `…_CLOUDS_A`, `…_CAP_A`…, names truncated to 23 letters) [V, corrects the earlier claim]. The native engine uses them (doc 20 §5); the viewer keeps its gradient.

## Scenery visibility and levels of detail [D][V]
Game code: `SetupSceneryCullInfo` (`Ecstasy.cpp`) and the culling in `Scenery.cpp`. Our code: `tiles` mode in `tools/src/cli/convert.ts`.
- Low byte of `ExcludeFlags`: the game skips an instance if `((flags & 0xFF) ^ 0x60) & view`. The player view is `0x10 | 0x02`.
  - `0x10` hidden (disabled groups) · `0x02` **excluded from the player view** · `0x20` / `0x40` only drawn in the mirror and reflection/shadow views.
  - 2,232 instances have `0x02` [V]. They are copies about 20 m lower of freeway gantries and signs, bridges and overpasses. They used to be drawn: duplicated signs and structures showed under the road.
- `0x200`: model already in world coordinates (no matrix). All 10,438 instances with that bit have an identity matrix [V].
- `0x400000` marks the 9,147 instances with a mirrored matrix (determinant < 0) [V]. The converter flips their winding.
- The overrides in `0x00034108` copy the value the instance already has [V]: nothing changes at load.
- LOD: on PS2 `pModel[0]` does not exist; the game copies it from `pModel[1]` [D: `Scenery.cpp` 416-420]. Near = `NameHash[1]`; far = `NameHash[2]` (or 1). `NameHash[3]` is for reflections and shadows: not used in the normal view.

## Texture audit (2026-10-12)
Tools: `tools/src/lib/tex-ps2.ts` (now also reads `TilableUV`, `ApplyAlphaSorting`, `RenderingOrder`). Before/after screenshots at 8 street spots (doors from `garages.json`).

| What looked wrong | Cause | Fix |
|---|---|---|
| Whole tiles without walls or buildings (only the grey far level) | Texture arrays with more than 256 layers: WebGPU rejects them and the tile is not drawn | `viewer/src/tile-worker.ts`: arrays per exact size, at most 256 layers |
| Blurry textures | Everything was resized to 128×128 once a tile had more than 32 | Original size, no resizing |
| Black fringes on leaves, fences, graffiti | Mipmaps and filtering mixed in the black of empty texels | Colour bled into transparent texels, alpha-weighted mipmaps |
| Grilles, branches, thin railings eaten away | Cut-out threshold 0.5 | Game threshold `0x28` (`materials.ts`) |
| Graffiti and glass with hard cut-out | `MODULATED + BLEND` was treated as cut-out | Normal blending, no depth write |
| Lines along sign edges | Everything repeated | `TilableUV` → clamp (glTF sampler and `wrapc` attribute in the viewer) |
| Flat baked light, washed-out colours | Vertex colour used as linear | `COLOR_0 = (c/128)^2.2` (`mesh-build.ts`) |
| Signs and bridges duplicated ~20 m lower | `0x02` instances were drawn | Dropped in `convert.ts` |
| Solid slabs floating in the sky (distant trees) | The far level drew cut-out strips without alpha | Far level keeps only opaque strips and uses `NameHash[2]` |
| Grey asphalt in the far level | The mean colour ignored texels with alpha ≈ 0 | Opaque textures count every texel |
| Street lights and signs untextured | `HEADLIGHTGLOW`, `GRAY_MID_A` live in `GLOBALB`/`INGAMEA` | Those packs are loaded |

Not bugs [V]: UVs outside 0…1 (43 % of vertices, repeating textures), no active `0x400` flip, and the backdrop panels `TRN_CT_PROPS_HIGHWAY1_*_CHOP_*` at 200-340 m (the game's horizon scenery: up close they look like loose slabs).

Open: 5 world textures are still missing (`7e2734a8`, `7e2734a9`, `8b335c76`, `6dc61680`, `61a56b42`); water is still our own plane; no pixel-by-pixel comparison with PCSX2 captures yet.
