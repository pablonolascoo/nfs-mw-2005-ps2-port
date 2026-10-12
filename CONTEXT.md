# Contexto del proyecto · Project context

> Ficha para retomar el trabajo en cualquier momento (personas o asistentes de IA).
> Resume **qué hay, dónde está, cómo se regenera y qué falta**. El detalle vive en `docs/es` y `docs/en`.
> A one-page brief to resume work at any time. English summary at the end.

## 1. Objetivo
- Port nativo de **Need for Speed: Most Wanted (2005)** de PS2, primero macOS (Metal), reutilizable en cualquier plataforma.
- **Una sola ISO PAL (SLES-53559) basta** para todo: mundo, coches, garajes, mods y ampliaciones.
- SLUS-21351 (Black Edition US) solo sirve de referencia: su ELF coincide byte a byte con la decomp `dbalatoni13/nfsmw`.
- Futuro: nuevas carreras y eventos, continuación de la historia, secuela con nueva Lista Negra, mapa ampliado, más coches.
- Público y abierto (MIT). **Nunca** se suben ISOs, datos del juego ni GLB/PNG convertidos.

## 2. Mapa del repositorio
| Carpeta | Qué hay |
|---|---|
| `tools/src/lib/` | Lectores de formatos (TypeScript/Bun, sin dependencias de plataforma) |
| `tools/src/cli/` | Conversores; `build-all.ts` lo hace todo desde la ISO |
| `tools/data/` | Listas de nombres propias (rutas, atributos) verificadas por hash |
| `native-engine/` | **El juego**: app nativa de macOS en Swift + Metal (en construcción) |
| `viewer/` | Visor web de **investigación** (Three.js): inspeccionar el mapa y probar ideas. No es el juego |
| `site/` | Página pública estática: https://rockport-native.vercel.app (`vercel deploy --prod` desde `site/`) |
| `.github/` | Plantillas de issues y PR, `CODEOWNERS`: todo PR necesita la aprobación de @pablonolascoo |
| `mods/` | Mods de solo datos que se aplican sobre tu ISO |
| `docs/es`, `docs/en` | Investigación: 00–11, ver índice abajo |
| `inventory/` | Inventario por disco (hashes y tamaños) |
| `map-data/<ID>/` | Salida generada (no se sube salvo JSON pequeños) |
| `experiments/decomp/` | Decomp clonada (no se sube) |
| `original/` | ISOs del usuario (no se sube) |

## 3. Índice de documentos
| # | Tema | ES | EN |
|---|---|---|---|
| 00 | Identificación del disco | [es](docs/es/00-identificacion-disco.md) | [en](docs/en/00-disc-identification.md) |
| 01 | Compatibilidad SLES ↔ decomp | [es](docs/es/01-compatibilidad-sles53559.md) | [en](docs/en/01-sles53559-compatibility.md) |
| 02 | Formatos PS2 (bChunk, compresión, VIF, texturas, transparencia) | [es](docs/es/02-formatos-ps2.md) | [en](docs/en/02-ps2-formats.md) |
| 03 | Mundo de Rockport (secciones, escenario, grupos, sombras, agua, cielo) | [es](docs/es/03-mundo-rockport-ps2.md) | [en](docs/en/03-rockport-world-ps2.md) |
| 04 | Arquitectura del port | [es](docs/es/04-arquitectura-port.md) | [en](docs/en/04-port-architecture.md) |
| 05 | Base de datos VLT (zonas, carreras, Lista Negra) | [es](docs/es/05-vlt-atributos.md) | [en](docs/en/05-vlt-attributes.md) |
| 06 | Rendimiento (60 fps) | [es](docs/es/06-rendimiento.md) | [en](docs/en/06-performance.md) |
| 07 | Conducción y garajes sin carga | [es](docs/es/07-conduccion-y-garajes.md) | [en](docs/en/07-driving-and-garages.md) |
| 08 | Mods | [es](docs/es/08-mods.md) | [en](docs/en/08-mods.md) |
| 09 | Red de carreteras y colisión | [es](docs/es/09-red-de-carreteras.md) | [en](docs/en/09-road-network.md) |
| 10 | Coches: texturas, pintura, ruedas | [es](docs/es/10-coches.md) | [en](docs/en/10-cars.md) |
| 11 | Catálogo de datos generados | [es](docs/es/11-catalogo-de-datos.md) | [en](docs/en/11-data-catalog.md) |

## 3b. Producto final (lo que queremos entregar)
- Un `Rockport.dmg` en *Releases* de GitHub. Al abrirlo pide la ISO, detecta PAL (SLES-53559) o NTSC-U (SLUS-21351) por `SYSTEM.CNF` y convierte los datos en `~/Library/Application Support/Rockport/<ID>/`.
- El conversor va dentro de la app como un solo binario (`bun build --compile`).
- El juego arranca a pantalla completa, sin menús alrededor, a la resolución de la pantalla y con el tono cálido de PS2.
- Plan completo y expansión: [ROADMAP.md](ROADMAP.md). Cómo colaborar: [CONTRIBUTING.md](CONTRIBUTING.md).

## 4. Comandos
```bash
cd tools && bun install && bun run build-all ../original/SLES-53559.iso   # ~6–7 min, todo map-data/
cd viewer && bun install && bun run dev                                   # visor en http://localhost:5181
```
Visor: `?pintura=1f6fd1` cambia el color del coche. Depuración en consola: `window.__rockport`.

## 5. Cadena de datos (de la ISO al visor)
ISO9660 → `NFS/ZDIR.BIN` (índice por `bStringHash`) → `ZZDATA0-3.BIN` → bChunks (HUFF/JDLZ/RAWW)
→ sólidos VIF + texturas TPK → glTF (GLB) en casillas HLOD de 400 m → visor (workers, arrays de texturas, BVH en worker).
Base de datos: `GLOBAL\ATTRIBUTES.BIN` (esquema) + `GLOBAL\GAMEPLAY.BIN` (datos) → `gameplay.json`, `zones.json`, `cars.json`.
Carreteras: `L2RA.BUN` chunk `0x0003B800` (RNgp). Colisión: `STREAML2RA.BUN` chunks `0x0003B801`.

## 6. Hechos clave que no hay que volver a investigar
- Hash de nombres: `h = h*33 + c`, inicio `0xFFFFFFFF`, rutas en mayúsculas con `\`. Atributos: Jenkins lookup2, semilla `0xABCDEF00`.
- Geometría: posición = `int16 × 0.0002 +` desplazamiento entero por eje sacado del AABB; regla de reinicio de tiras ADC validada al 100 %.
- PSMT8 se sube como PSMCT32 (W/2×H/2); PSMT4 como PSMCT16. CLUT con intercambio de bits 3↔4. Alfa ×2.
- Transparencia por `AlphaUsageType` + `AlphaBlendType`; `SHD_*` son sombras horneadas; `ANM_WATERA_*` agua animada.
- Escenario PS2: instancia 0x40 B, `ExcludeFlags` 0x10 oculto / 0x400 espejo, rotación `s16/8192`.
- Grupos: `BARRIER_SPLINE_n` vallas de carrera, `BARRIER_LOCKED_10…15` candados de historia.
- Garajes: puerta real = triángulos con textura `ARC_HOSPITAL_GARAGEDOOR`. En el juego, la zona llama a `EQuitToFE(GARAGETYPE_*)`.
- Coches: pintura `<COCHE>_SKIN1` y cristales/faros son texturas de sustitución (no están en el disco). Una rueda por modelo; cara exterior en |y| = `TireOffsets.y`.
- Carreteras en espacio "Bond": X = z, Y = −x, Z = y. Tramos = Bézier cúbicas.

## 7. Estado y pendientes (2026-10-12)
Hecho:
- Todo el mapa a 60 fps. Texturas revisadas: paredes y edificios completos, transparencias y repetición como el juego (doc 03, «Auditoría de texturas»).
- 91 coches completos: una pieza por ranura, ruedas y frenos de la decomp, llantas de tuneo, alerones, pintura (doc 10).
- Garajes sin pantalla de carga (15), base de datos, red de carreteras, colisión, mods.
- **Motor nativo macOS** (Swift + Metal) a pantalla completa, 60 fps, tono PS2, coche conducible con colisión real.
- **Instalador**: la app pide la ISO, detecta PAL/NTSC-U y convierte en ~4,6 min, sin repo ni decomp [V con las dos ISOs]. `native-engine/scripts/make-dmg.sh` monta el `.dmg`.

Siguiente, por orden:
1. Publicar `Rockport.dmg` en *Releases* (versión 0.1).
2. Física real del juego desde la decomp (`zPhysics`, `zDynamics`) y mando.
3. Tráfico y policía sobre la red de carreteras; persecuciones con la IA original.
4. Carreras, Lista Negra e hitos jugables (rutas: `TrackPathManager` + datos de evento).
5. Garajes sin carga en el motor nativo; refugios sin edificio (2, 4, 5).
6. Audio.
7. Expansión «Rust Belt» como mod ([ROADMAP.md](ROADMAP.md)).

Dudas abiertas: tipos de carril 2/3/4/7/10, escala de longitud de `RNrd`, 8 hashes de textura de coche y 5 del mundo sin nombre o fuera del disco (doc 03 y 10).

---

## English summary
- Goal: native port of NFS Most Wanted (2005, PS2), macOS/Metal first; **one PAL ISO (SLES-53559) is enough**; SLUS-21351 only as decomp reference.
- Layout: `tools/` readers and converters (Bun/TS), `viewer/` Three.js WebGPU prototype, `mods/` data-only mods, `docs/en` research 00–11 (table above), `map-data/<ID>/` generated output (not committed).
- Build everything: `cd tools && bun run build-all ../original/SLES-53559.iso`; then `cd viewer && bun run dev`.
- What each generated file answers: [docs/en/11-data-catalog.md](docs/en/11-data-catalog.md).
- Next steps: real collision in driving (road layer already in the viewer), garages for building-less safehouses, aftermarket rims, playable races, game physics and audio from the decomp, native Metal engine, road/district editor, story/sequel mods.
