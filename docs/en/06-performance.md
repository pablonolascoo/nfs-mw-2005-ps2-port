# Viewer performance: from 27 to 60 fps (2026-10-11)

Mac16,12 (Apple M4, 16 GB), Chrome with WebGPU on Metal, 1920×1080. Measured with `__rockport.bench()` (waits for the GPU every frame) and with real fly-throughs.

| Technique | Effect |
|---|---|
| Merge by material inside each section | 200,000+ → 33,030 draw calls |
| 400 m tiles with two detail levels (HLOD) | Whole distant city in 214 draws |
| Far level uses the game's lightest LOD + 3 m vertex clustering | 5.18 M → 0.93 M triangles |
| Distance streaming (650 m) with memory release | Only ~16 detailed tiles at once |
| Loading and decoding in Web Workers | Main thread never parses GLB or PNG |
| Per-tile texture arrays (`layer` attribute) | ~60 → 2 draws per near tile |
| Mipmaps computed in the worker, written with `writeTexture` | No hundreds of GPU passes on upload |
| Progressive reveal, one new tile per frame | Spreads first-draw cost |
| Dynamic resolution driven by GPU time | Holds 60 fps, full quality when there is headroom |

## Results
- Before: whole city at **27 fps** (33,030 draws).
- Now, static views (aerial, street, mid-height, downtown): **median 16.7 ms, p95 16.8 ms (60 fps)** at 100 % resolution at 1080p and Retina ×2.
- Flying at 250 km/h across the city: median and p95 16.7 ms; 1–2 % of frames miss one vsync while new tiles stream in.
- Measured with other heavy processes running (load average 10–50); residual hitches are not reliably reproducible under those conditions.

## Next, for the native engine
Geometry upload on a dedicated transfer thread, texture compression (BC7/ASTC), and section-based occlusion (the game's `VisibleSectionManager`, chunk `0x80034150`).
