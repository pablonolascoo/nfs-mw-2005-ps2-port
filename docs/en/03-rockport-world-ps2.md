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
718 sections with scenery · 106,714 instances · 18,156 unique solids · 5.84 M triangles · 2,627 textures · 4 instances without a model · 7 textures not found.
Top-down map: `map-data/<disc>/rockport-plano.png` (1.49 m/px; calibration in `rockport-plano.json`).
