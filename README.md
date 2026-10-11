# NFS Most Wanted (2005) · PS2 → native

[Español](README.es.md) · English

Open research and tools to turn your own **PlayStation 2** copy of *Need for Speed: Most Wanted* (2005) into open formats (glTF/PNG/JSON), as a base for **native ports to any platform**, macOS first.

> **No game data is included.** You need your own disc. Everything here reads your ISO and writes derived files locally. This project is not affiliated with Electronic Arts.

## What works today
| Area | Status |
|---|---|
| Disc container (ZDIR/ZZDATA), file names | ✅ 95 % of files named |
| Compression HUFF / JDLZ / RAWW | ✅ byte-exact |
| PS2 geometry (VIF packets, strip restarts) | ✅ 181,535 strips decoded, 0 errors |
| PS2 textures PSMT8 / PSMT4 (GS swizzle) | ✅ |
| Whole Rockport: 718 sections, 106,714 objects, 5.8 M triangles | ✅ exported to glTF |
| Cars with textures, paint, glass, lights and 4 wheels (TireOffsets) | ✅ |
| Web viewer (Three.js, WebGPU → Metal) | ✅ |
| Decompilation (dbalatoni13/nfsmw) builds on Apple Silicon | ✅ with Rosetta 2 |
| Gameplay database (VLT): 6,287 collections, 255 events, Blacklist, 15 garage/shop zones | ✅ |
| Frontend interiors (garages, car lot, tuning shop) | ✅ exported |
| Whole city at 60 fps (HLOD tiles, texture arrays, workers, dynamic resolution) | ✅ |
| Drivable car on the real city (arcade prototype, 60 fps) | ✅ |
| Garages without loading screens: real door opens, interior already loaded, park, showcase, drive out | ✅ |
| Mods: original data layered over your ISO (`mods/`), example "Unique garages" | ✅ |
| Road network (4385 nodes, 6538 Bézier segments, lanes) and collision (243k triangles) | ✅ decoded and validated |
| Game physics, playable races, audio | 🔜 |

## Quick start
**One PAL ISO (SLES-53559) is enough for the whole project** (SLUS-21351 also works).
```bash
# requirements: Bun and your own ISO
cd tools && bun install
bun run build-all /path/to/your.iso        # everything in ~6 min → map-data/<disc>/
cd ../viewer && bun install && bunx vite    # http://localhost:5181 → «Cargar ciudad completa» → «Conducir»
```
Step by step:
```bash
cd tools && bun install
bun src/cli/inventory.ts ../original/SLES-53559.iso SLES-53559
bun src/cli/convert.ts   ../original/SLES-53559.iso SLES-53559 tiles 400 3   # all of Rockport as 60-fps tiles (~1 min)
bun src/cli/convert.ts   ../original/SLES-53559.iso SLES-53559 interior CAREER_SAFEHOUSE CAR_LOT CUSTOMIZATION_SHOP
bun src/cli/vlt-dump.ts  ../original/SLES-53559.iso SLES-53559                # gameplay.json + zones.json
bun src/cli/convert.ts   ../original/SLES-53559.iso SLES-53559 car BMWM3GTRE46
bun src/cli/topdown.ts   ../original/SLES-53559.iso SLES-53559 4096          # top-down PNG map
cd ../viewer && bun install && bunx vite                                    # http://localhost:5181
```

## Documentation
| Topic | English | Español |
|---|---|---|
| Disc identification | [docs/en/00](docs/en/00-disc-identification.md) | [docs/es/00](docs/es/00-identificacion-disco.md) |
| Decomp compatibility | [docs/en/01](docs/en/01-sles53559-compatibility.md) | [docs/es/01](docs/es/01-compatibilidad-sles53559.md) |
| PS2 formats | [docs/en/02](docs/en/02-ps2-formats.md) | [docs/es/02](docs/es/02-formatos-ps2.md) |
| Rockport world | [docs/en/03](docs/en/03-rockport-world-ps2.md) | [docs/es/03](docs/es/03-mundo-rockport-ps2.md) |
| Porting architecture | [docs/en/04](docs/en/04-port-architecture.md) | [docs/es/04](docs/es/04-arquitectura-port.md) |
| Driving and garages | [docs/en/07](docs/en/07-driving-and-garages.md) | [docs/es/07](docs/es/07-conduccion-y-garajes.md) |
| Mods and expansions | [docs/en/08](docs/en/08-mods.md) | [docs/es/08](docs/es/08-mods.md) |
| Gameplay database (VLT): zones, races, Blacklist | [docs/en/05](docs/en/05-vlt-attributes.md) | [docs/es/05](docs/es/05-vlt-atributos.md) |
| Viewer performance | [docs/en/06](docs/en/06-performance.md) | [docs/es/06](docs/es/06-rendimiento.md) |
| Road network and collision | [docs/en/09](docs/en/09-road-network.md) | [docs/es/09](docs/es/09-red-de-carreteras.md) |
| Cars: replacement textures, paint, wheels | [docs/en/10](docs/en/10-cars.md) | [docs/es/10](docs/es/10-coches.md) |
| Generated data catalog (which file answers what) | [docs/en/11](docs/en/11-data-catalog.md) | [docs/es/11](docs/es/11-catalogo-de-datos.md) |
| **Project context: start here to resume work** | [CONTEXT.md](CONTEXT.md) | [CONTEXT.md](CONTEXT.md) |

Every claim is tagged **[V]** verified on real data, **[D]** from the decomp's debug types, **[I]** inferred, or **[H]** hypothesis.

## Layout
`tools/` format readers and converters (TypeScript/Bun, platform-independent) · `viewer/` Three.js viewer · `docs/` research · `inventory/` per-disc inventories (hashes and sizes only).

## Credits
- [dbalatoni13/nfsmw](https://github.com/dbalatoni13/nfsmw) (CC0): PS2 debug types, chunk IDs, LZ/HUFF source.
- [TsyVM/MWEncyclopedia](https://github.com/TsyVM/MWEncyclopedia): PC format reference.
- GS memory tables follow the public GS documentation (same as PCSX2).

## License
MIT (code and docs). See [LICENSE](LICENSE).
