# NFS Most Wanted (2005) · PS2 → macOS

Investigación, extracción y port nativo a partir de **SLES-53559** (PAL España). Referencia de código: **SLUS-21351** + [dbalatoni13/nfsmw](https://github.com/dbalatoni13/nfsmw).

## Estado
| Hito | Estado |
|---|---|
| 1 · Identificación e inventario | Hecho: `inventory/`, `docs/00`, `docs/01` |
| 2 · Primeros formatos | Hecho: contenedor, bChunk, HUFF/JDLZ, sólidos VIF, texturas PSMT4/8 (`docs/02`) |
| 3 · Visor de recursos | Hecho: coches con texturas en Three.js/WebGPU |
| 4 · Rockport navegable | Hecho: 718 secciones, 5,8 M triángulos, plano cenital (`docs/03`) |
| Compilar la decomp en el M4 | Hecho: compila en 1 min 34 s; 22,7 % del código PS2 idéntico (`docs/01`) |

## Uso
```bash
cd tools && bun install
bun src/cli/inventory.ts ../original/SLES-53559.iso SLES-53559        # inventario
bun src/cli/convert.ts ../original/SLES-53559.iso SLES-53559 car BMWM3GTRE46
bun src/cli/convert.ts ../original/SLES-53559.iso SLES-53559 world    # Rockport entero (~1 min, ~600 MB)
bun src/cli/topdown.ts ../original/SLES-53559.iso SLES-53559 4096     # plano cenital PNG
cd ../viewer && bun install && bunx vite                             # visor en http://localhost:5181
```
`original/` contiene enlaces a las ISO (nunca se modifican). `map-data/` y `extracted/` son derivados y no se versionan.

## Estructura
`tools/` lectores y conversores (TypeScript/Bun) · `viewer/` visor Three.js (WebGPU → Metal) · `docs/` investigación con nivel de evidencia · `inventory/` inventarios por disco · `experiments/` decomp y ELF (no versionado).
