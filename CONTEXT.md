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
| 12 | Expansión «Rust Belt»: plano, bocetos, historia | [es](docs/es/12-expansion-rust-belt.md) | [en](docs/en/12-rust-belt-expansion.md) |
| 13 | Física de conducción (decomp) | [es](docs/es/13-fisica-conduccion.md) | [en](docs/en/13-driving-physics.md) |
| 14 | Tráfico, policía y persecuciones | [es](docs/es/14-trafico-y-policia.md) | [en](docs/en/14-traffic-and-police.md) |
| 15 | Mandos | [es](docs/es/15-mandos.md) | [en](docs/en/15-controllers.md) |
| 16 | Audio y voces | [es](docs/es/16-audio-y-voces.md) | [en](docs/en/16-audio-and-voices.md) |
| 17 | Interfaz original (FEng): menús, HUD, fuentes, textos | [es](docs/es/17-interfaz.md) | [en](docs/en/17-interface.md) |
| 18 | Carreras y Lista Negra (rutas, vallas, IA de carrera, carrera profesional) | [es](docs/es/18-carreras-y-lista-negra.md) | [en](docs/en/18-races-and-blacklist.md) |
| 19 | Carrera rápida y multijugador (pantallas del juego, pantalla partida, mandos por jugador, varias pantallas) | [es](docs/es/19-carrera-rapida-y-multijugador.md) | [en](docs/en/19-quick-race-and-multiplayer.md) |
| 21 | Cobertura del disco: qué está descifrado (generado por `coverage.ts`) | [es](docs/es/21-cobertura.md) | [en](docs/en/21-coverage.md) |
| 22 | Películas (MPC, doblajes), subtítulos, colisión del juego, suavizado de normales, ocultación del escenario | [es](docs/es/22-peliculas-subtitulos-y-colision.md) | [en](docs/en/22-movies-subtitles-and-collision.md) |
| 23 | Escenas NIS (cámaras ICE, animaciones EAGL, eventos, revoluciones, audio) | [es](docs/es/23-escenas-nis.md) | [en](docs/en/23-nis-scenes.md) |
| 24 | Partículas, destellos, rompibles, disparadores, helicóptero, clima, datos del mundo | [es](docs/es/24-efectos-luces-y-mundo.md) | [en](docs/en/24-effects-lights-and-world.md) |
| 25 | Música interactiva (PathFinder), mapas de mezcla, reverbs, Csis | [es](docs/es/25-musica-y-mezcla.md) | [en](docs/en/25-music-and-mixing.md) |

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
- Coches: pintura `<COCHE>_SKIN1` y cristales/faros son texturas de sustitución (no están en el disco). La piel sale de pintura + vinilo (`VINYLS.BIN`, 512×512, máscara R ≥ 128 opaca) y los presets de `GLOBALB.BUN` chunk `0x00030220` (0x290 B). Una rueda por modelo; cara exterior en |y| = `TireOffsets.y`.
- Carreteras en espacio "Bond": X = z, Y = −x, Z = y. Tramos = Bézier cúbicas.

## 7. Estado y pendientes (2026-10-12)
Hecho:
- Todo el mapa a 60 fps. Texturas revisadas: paredes y edificios completos, transparencias y repetición como el juego (doc 03, «Auditoría de texturas»).
- 91 coches completos: una pieza por ranura, ruedas y frenos de la decomp, llantas de tuneo, alerones, pintura (doc 10).
- Garajes sin pantalla de carga (15), base de datos, red de carreteras, colisión, mods.
- **Motor nativo macOS** (Swift + Metal) a pantalla completa, 60 fps, tono PS2, coche conducible con colisión real.
- **Instalador**: la app pide la ISO, detecta PAL/NTSC-U y convierte en ~4,6 min, sin repo ni decomp [V con las dos ISOs]. `native-engine/scripts/make-dmg.sh` monta el `.dmg`.

- **v0.2**: física de conducción del juego (decomp), 4 cámaras, mandos con barra de luz/táctil/gatillos, tráfico y policía con persecuciones, controles y HUD; tono PS2 fijo; datos versionados (`DATA_FORMAT` en `tools/src/cli/install.ts` = `Config.dataFormat`): si la app es más nueva que los datos, reconvierte con la misma ISO.
- **Coches del juego (presets)**: los 82 presets de `GLOBALB.BUN` (Lista Negra 1–15, BMW de la historia) → `presets.json` + vinilos; la piel se compone como `CarSkin.cpp` en el motor nativo (`CarSkin.swift`) y en el visor. El jugador sale con el BMW M3 GTR plata y azul; `--car-preset` / `?preset=` (doc 10 §8).
- **Interfaz original** (doc 17): paquetes FEng descifrados; «Pulsa START», menú principal, carrera, pausa y HUD del juego a resolución nativa (SDF para letras, bicúbica para imágenes).
- **HUD 100 % original** (doc 17 §8): lógica de `FEngHud` (todo invisible y cada elemento enciende lo suyo), radar con los mapas `MINI_MAP*.BIN` del disco calibrados con `TrackInfo` 2000, persecución completa (la barra naranja rayada era el fondo de «REFUERZOS» mal recortado), arresto con la cámara de la policía, evasión con «BOLSA CONSEGUIDA», modo panorámico; API `RaceHUD` para carreras (cuenta atrás, posición, vueltas, tabla, resultados, Lista Negra con retratos de `RIVALS.BIN`). `HUDPursuit.swift` solo con `--debug-hud`.
- Audio del disco extraído (doc 16). Las voces de la historia solo existen en inglés; la radio de la policía, en castellano/inglés/italiano. No se clonan voces sin permiso de los actores.
- **Radio de la policía en el juego**: decodificador MicroTalk propio (TS + Swift, igual a vgmstream ±1), tablas `.IDX/.EVT` leídas, frases por evento de la persecución, paso `radio` del conversor → `radio/` (doc 16 §5–6). Suena por el altavoz del mando (USB; Bluetooth por informes HID Opus/SBC sin probar con hardware) o el Mac con filtro de escáner. **Barra de luz** como opción de tuneo con colores de persecución (doc 15 §7–8).

- **Carreras y Lista Negra** (doc 18): paso `races` → `races.json` (254 pruebas, bins, hitos + radares de la zona libre, 1 376 vallas `TrackPathBarrier` de `L2RA.BUN` 0x0003414D), `DATA_FORMAT` 4. Ruta por la red cerrada por las vallas (mediana 0,997 de `RaceLength`), rivales con la física y la IA de carrera del juego (AIActionRace/AIVehiclePid, «glue»), los 7 tipos de prueba, carrera profesional 15 → 1 con partida `save.json`, candados por bin. **Colisión**: los objetos de grupos ocultos (891 instancias con `GroupNumber`) eran muros invisibles; ahora van en `collision/groups/`. Pruebas: `--race-test`, `--career-test`, `--race-audit`.
- **Sonido del juego** (doc 16 §7–10): paso `sound` → `sound/` (301 bancos AEMS `ABKC` + 160 motores granulares `.GIN` tal cual, `sound.json` con VLT `engineaudio`/`turbosfx`/`shiftpattern`, coche → sonidos, 608 «stitches» de golpes de `INGAMEB.BUN`), `DATA_FORMAT` 5. Códecs PS-ADPCM, EA-XA v2 y EA-XAS propios: 2350/2350 sonidos y 160/160 `.GIN` iguales a vgmstream. En la app: sintetizador Ginsu y lógica del motor de la decomp (RPM de audio, cambios, mezcla acelerando/desacelerando), turbo, nitro, derrapes, viento, golpes, sirenas 3D, tráfico y rivales; 0,2 % de un núcleo. Pruebas: `--sound-test`, `--sound-dump`. Falta: capa AEMS (módulos MIPS) y `MIXMAPS`.
- **Garajes sin carga y fondo de los menús** (doc 07, doc 17): los menús muestran el garaje del frontend (`PLATFORMCRIB`) con el coche del jugador y la cámara de `GLOBAL\FE_ATTRIB.BIN` (paso `fe-cameras` → `fe-cameras.json`: 108 ángulos, 186 pantallas, 34 coches del concesionario). Los 15 garajes se entran conduciendo por su persiana real (recorte del edificio en los shaders, interior colocado dentro, colisión) y abren los menús originales: refugio (Lista Negra, Mis coches, Guardar), concesionario (comprar) y taller (pintura, vinilos, llantas, alerones, kit, barra de luz). Refugios 2, 4 y 5: su edificio real (`XB_SafeHouse`, `XB_FishSafehouse`, `XB_TC_SafeHouse`). **Conversor**: posiciones V4-32 (float) en metros; salen la cúpula de los garajes y 5 071 tiras del mundo (rascacielos, cielo, montañas). **Carrusel**: centro en `OPTION_MASTER` [V: ensamblador]. Pruebas: `--garage-test`.
- **Carrera rápida y multijugador** (doc 19): pantallas del juego (MainMenu_Sub, Track_Select con `TRACK_MAP_<id>` de `TrackMaps.bin`, Track_Options, PressStart, Car_Select) con la lógica de `quickrace/*.cpp`; desbloqueo de coches con `frontend.UnlockedAt` (FE_ATTRIB.BIN) y de pruebas con la partida. **Pantalla partida original** para 2 (horizontal, `HUD_Player1/2` de `INGAMESPLITSCREEN.BUN`, cámaras de pantalla partida) y extensión a 3–4 jugadores y a varias pantallas (`--displays`, `--players`); un mando por jugador sin mezclas, luz y LED de jugador, desconexión con `ControllerUnplugged.fng`. Medido a 2940×1912: 4 jugadores GPU 5,2 ms. Pruebas: `--split-test N`, `--quickrace-test`.

- **Auditoría de cobertura** (doc 21, `tools/src/cli/coverage.ts`): cada archivo y cada bChunk del disco clasificado. Entendido **49,35 % → 99,94 %** de 3 862 MB (sin películas: 72,45 % → 99,86 %); usado por el juego nativo: 23 %. Hallazgos: las 64 películas `_UNKNOWN` son las versiones **dobladas al castellano e italiano**; subtítulos en `LANGUAGES\<IDIOMA>.BIN` (vacíos donde hay doblaje); películas reproducibles con VideoToolbox (MPEG-2) + decodificador R3 propio, leyendo de la ISO (doc 22). Nuevos pasos del conversor: `movies`, `bounds`, `effects`, `nis`, `music` → `DATA_FORMAT` 9. Queda parcial: módulos AEMS (código MIPS), acciones de la música, una animación DeltaQ, un overlay de código.

Siguiente, por orden:
1. Garaje, tienda, NIS y atajos de carrera (la carrera rápida ya va por sus pantallas: doc 19); probar la pantalla partida con mandos reales.
2. Garajes: reflejos y luces del coche en el frontend, partículas del escenario, precios de piezas, rendimiento, calcomanías, mapa de la carrera y hoja de antecedentes (doc 07 §4).
3. Audio y vídeo en el motor nativo: películas (VideoToolbox + R3 + subtítulos, doc 22), música PathFinder (doc 25), escenas NIS (doc 23); capa AEMS de los motores; probar el altavoz del mando con hardware.
4. Choques del juego original (coche contra coche y muros), daños, pinchos; helicóptero.
5. Probar mandos con hardware real; firma Developer ID (necesita cuenta de pago: decisión del dueño).
6. Expansión «Rust Belt» como mod ([ROADMAP.md](ROADMAP.md), doc 12).

Dudas abiertas: tipos de carril 2/3/4/7/10, escala de longitud de `RNrd`, 8 hashes de textura de coche y 5 del mundo sin nombre o fuera del disco (doc 03 y 10).

---

## English summary
- Goal: native port of NFS Most Wanted (2005, PS2), macOS/Metal first; **one PAL ISO (SLES-53559) is enough**; SLUS-21351 only as decomp reference.
- Layout: `tools/` readers and converters (Bun/TS), `viewer/` Three.js WebGPU prototype, `mods/` data-only mods, `docs/en` research 00–11 (table above), `map-data/<ID>/` generated output (not committed).
- Build everything: `cd tools && bun run build-all ../original/SLES-53559.iso`; then `cd viewer && bun run dev`.
- What each generated file answers: [docs/en/11-data-catalog.md](docs/en/11-data-catalog.md).
- Races and Blacklist playable in the native engine (doc 18): `races.json`, barrier-closed routes, game racer AI, 7 event types, career 15 → 1 with save; hidden-group collision moved to `collision/groups/` (was invisible walls).
- Game sound in the native engine (doc 16 §7–10): `sound` step → `sound/` (ABKC banks + Ginsu `.GIN` engines, `sound.json`), own decoders identical to vgmstream, the decomp's Ginsu synth and engine logic, turbo, nitrous, skids, impacts, 3D sirens; `DATA_FORMAT` 5.
- Seamless garages and menu background (doc 07): front-end garage scene with the player's car and the `FE_ATTRIB.BIN` cameras (`fe-cameras.json`); the 15 garages are entered through their real roller door and open the original safehouse / car lot / shop menus with live tuning; converter fix for float (V4-32) positions (downtown skyline, sky, mountains); icon carousel centred on `OPTION_MASTER`.
- Quick Race with the game's own screens and split screen (doc 19): original 2-player horizontal split (`HUD_Player1/2`), extension to 3–4 players and several displays, one controller per player with no input mixing, unplug pause.
- Coverage audit (doc 21): understood 49.35 % → 99.94 % of the disc (used by the native game: 23 %). New converter steps `movies`, `bounds`, `effects`, `nis`, `music` (docs 22–25), `DATA_FORMAT` 9. Spanish/Italian dubbed movies found; subtitles decoded; movies play natively via VideoToolbox.
- Next steps: real collision in driving (road layer already in the viewer), front-end car reflections and garage lights, game physics and audio from the decomp, native Metal engine, road/district editor, story/sequel mods.
