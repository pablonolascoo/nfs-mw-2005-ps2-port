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
| Cars with textures | ✅ (paint is generated at runtime by the game; placeholder colour) |
| Web viewer (Three.js, WebGPU → Metal) | ✅ |
| Decompilation (dbalatoni13/nfsmw) builds on Apple Silicon | ✅ with Rosetta 2 |
| Gameplay database (VLT): 6,287 collections, 255 events, Blacklist, 15 garage/shop zones | ✅ |
| Frontend interiors (garages, car lot, tuning shop) | ✅ exported |
| Whole city at 60 fps (HLOD tiles, texture arrays, workers, dynamic resolution) | ✅ |
| Road network, collisions, physics | 🔜 |

## Quick start
```bash
# requirements: Bun, your own ISO (SLES-53559 / SLUS-21351 tested)
mkdir -p original && ln -s /path/to/your.iso original/SLES-53559.iso
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
| Gameplay database (VLT): zones, races, Blacklist | [docs/en/05](docs/en/05-vlt-attributes.md) | [docs/es/05](docs/es/05-vlt-atributos.md) |
| Viewer performance | [docs/en/06](docs/en/06-performance.md) | [docs/es/06](docs/es/06-rendimiento.md) |

Every claim is tagged **[V]** verified on real data, **[D]** from the decomp's debug types, **[I]** inferred, or **[H]** hypothesis.

## Layout
`tools/` format readers and converters (TypeScript/Bun, platform-independent) · `viewer/` Three.js viewer · `docs/` research · `inventory/` per-disc inventories (hashes and sizes only).

## Credits
- [dbalatoni13/nfsmw](https://github.com/dbalatoni13/nfsmw) (CC0): PS2 debug types, chunk IDs, LZ/HUFF source.
- [TsyVM/MWEncyclopedia](https://github.com/TsyVM/MWEncyclopedia): PC format reference.
- GS memory tables follow the public GS documentation (same as PCSX2).

## License
MIT (code and docs). See [LICENSE](LICENSE).
