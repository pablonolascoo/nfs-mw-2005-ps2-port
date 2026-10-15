# Catálogo de datos generados (`map-data/<ID>/`)

Todo sale de **una sola ISO** con `bun run build-all /ruta/a/tu.iso` (carpeta `tools/`).
Nada de esto se sube a GitHub salvo los JSON pequeños de metadatos. Cifras de SLES-53559 [V].

## 1. Qué archivo responde a qué pregunta

| Pregunta | Archivo | Generador | Doc |
|---|---|---|---|
| ¿Qué archivos hay en el disco y qué son? | `inventory/<ID>.csv` | `src/cli/inventory.ts` | 00, 02 |
| ¿Dónde está cada sección del mapa? | `world.json` → `sections[718]` | `convert.ts tiles` | 03 |
| ¿Qué casilla de 400 m cargo? | `world.json` → `tiles[212]`, `tiles/*.glb` (424) | `convert.ts tiles` | 03, 06 |
| ¿Dónde están las vallas de carrera y los candados? | `world.json` → `groups[752]`, `groups/*.glb` | `convert.ts tiles` | 03 |
| ¿Dónde están garajes, concesionarios y talleres? | `zones.json` (15), `garages.json` (15) | `vlt-dump.ts`, `garages.ts` | 05, 07 |
| ¿Cómo es la cámara de cada menú y garaje? ¿Precio de los coches del concesionario? | `fe-cameras.json` (108 ángulos, 186 pantallas, 34 coches) | `fe-cameras.ts` | 07 |
| ¿Qué carreras, Lista Negra e hitos hay? | `gameplay.json` → `summary` | `vlt-dump.ts` | 05 |
| ¿Ruta, puertas, rivales, vallas y reglas de cada prueba; bins y desafíos? | `races.json` (254 pruebas), `collision/groups/<n>.bin` | `races.ts`, `collision.ts` | 18 |
| ¿Cualquier valor de la base de datos del juego? | `gameplay.json` → `collections[6287]` | `vlt-dump.ts` | 05 |
| ¿Por dónde van las calles y carriles? | `roads.json` | `roads.ts` | 09 |
| ¿Dónde hay suelo y muros (colisión)? | `roads.json` → `collisionPacks[390]` (resumen) | `roads.ts` | 09 |
| ¿Cómo son los coches y sus ruedas? | `cars/*.glb` (91), `cars.json` (92) | `convert.ts car`, `car-attribs.ts` | 10 |
| ¿Cómo va cada coche de la Lista Negra (piezas, pintura, vinilo)? | `presets.json` (82), `vinyls/*.png` (112, solo local) | `presets.ts` | 10 §8 |
| ¿Cómo conduce cada coche (física, cámaras, zonas muertas del mando)? | `physics.json` (113 `pvehicle`) | `physics-attribs.ts` | 13, 15 |
| ¿Qué tráfico sale en cada barrio y cómo actúa la policía según el calor? | `ai.json` (10 patrones, 21 niveles de persecución, 59 zonas) | `ai-attribs.ts` | 14 |
| ¿Qué dice la radio de la policía en cada momento? | `radio/radio.json` + `radio/COPSPEECH.BIG` (9854 clips, 559 bancos, 139 eventos) | `radio.ts` | 16 |
| ¿Cómo suena cada coche, el turbo, los derrapes, la sirena, los golpes? | `sound/sound.json` + `sound/<CARPETA>/*.ABK, *.GIN` (301 bancos, 2350 sonidos, 160 motores, 103 coches, 608 golpes) | `sound.ts` | 16 |
| ¿Cómo son los interiores de garaje? | `interiors/*.glb` (5, todos los `BACKDROP*`) + `interiors/CAREER_SAFEHOUSE.reflection.glb` | `convert.ts interior` | 07 |
| ¿Cómo se entra conduciendo en cada garaje? | `garage-scenes/<zona>.glb/.json/.bin` + `index.json` | `garage-scenes.ts` (+ `tools/data/garage-layouts.json`) | 07 §5 |
| ¿Vista cenital del mapa? | `rockport-plano.png` + `.json` (escala) | `topdown.ts` | 03 |
| ¿Qué películas hay, en qué idioma, con qué subtítulos y dónde están en la ISO? | `movies.json` (32 películas × 3 idiomas, 169 frases en 12 idiomas) | `movies.ts` | 22 |
| ¿Cajas y esferas de colisión de cada coche y de los objetos rompibles? | `bounds.json` (83 coches, 405 objetos) | `bounds.ts` | 22 |
| ¿Dónde salen partículas, destellos, rompibles, disparadores; altura del helicóptero; clima? | `effects.json` + `effects/` | `effects.ts` | 24 |
| ¿Cómo son las escenas NIS (cámaras, coches, personajes, eventos, audio)? | `nis/index.json`, `nis/<ESCENA>.json` + `.glb` (87) | `nis.ts` | 23 |
| ¿Qué música suena y cómo cambia en las persecuciones? ¿Mezcla y reverbs? | `music/music.json`, `mixmaps.json`, `reverbs.json` + `.MPF/.MUS` | `music.ts` | 25 |
| ¿Qué parte del disco está descifrada? | `coverage.json` + doc 21 | `coverage.ts` | 21 |
| ¿Qué se puede abrir en el visor? | `index.json` → `items[814]` | todos | 04 |

## 2. Rockport en números
- **718 secciones** de mundo, 106 714 instancias, 5,84 M triángulos, 2565 texturas.
- **212 casillas** de 400 m (cerca con textura + lejos con color de vértice).
- **752 grupos** de escenario: 745 de carrera (`BARRIER_SPLINE_n`), 6 candados de historia (`BARRIER_LOCKED_10…15`), 1 de puertas.
- **15 zonas**: 4 refugios, 3 concesionarios, 8 talleres.
- **Red de carreteras**: 4385 nodos, 6538 tramos, 710 perfiles de calzada, 1308 carreteras. Un solo grafo conectado.
  Caja: X −1404…4857, Y −987…4569, Z −13…265 m.
- **Colisión**: 243 418 triángulos de suelo, 45 793 muros.
- **Base de datos**: 272 vaults, 6287 colecciones, 255 eventos, 20 grupos de Lista Negra, 55 hitos.
  Eventos por tipo: 68 peajes, 49 sprints, 39 circuitos, 37 desafíos, 32 radares, 18 eliminatorias, 11 drag.

## 3. Ejes y unidades
- Mundo y visor: **Z arriba**, metros. X este, Y norte [I].
- Carreteras y colisión vienen en espacio "Bond" (Y arriba): **X = z, Y = −x, Z = y** [D][V].
- Coches: X adelante, Y izquierda, Z arriba.
- Rotación de instancias: `s16 / 8192`; escenario con `ExcludeFlags` (0x10 oculto, 0x400 espejo) [V].

## 4. Campos clave (resumen)
- `world.json.tiles[]`: `id "x_y"`, `x`, `y`, `size`, `near`, `far`, `tris`, `farTris`, `zMin`, `zMax`.
- `world.json.groups[]`: `name`, `hash`, `kind` (carrera/candado/puerta), `barrier`, `driveThrough`, `glb`, `min`, `max`.
- `garages.json.garages[]`: `collection`, `zoneType`, `zone`, `radius`, `building` (caja del edificio), `out` (dirección de salida), `door` (centro, normal, tamaño).
- `roads.json`: `nodes[] {pos, profile, segments}`, `segments[] {nodes, length, road, flagNames, startControl, endControl}` (Bézier cúbica), `profiles[] {lanes[] {type, width, offset}}`, `roads[]`, `grid`.
- `cars.json.cars[nombre]`: `tires` = 4 × `[x, y, z, radio]`, `className`, `spokes`, `skidWidth`, `kitWidthScale`, `kitOffsetFront/Rear`, `camber`, `feCompression`, `rimSize` (ver doc 10).
- `ai.json`: `trafficPatterns`, `heatTable` (heat_01…10), `pursuitLevels`, `pursuitSupport`, `aiVehicle`, `vehicles` (pvehicle → modelo), `infractions`, `zones` (escondites, patrón por barrio, sin policía, inicio de persecución) (ver doc 14).
- `radio/`: `COPSPEECH.BIG` (clips MicroTalk del disco) y `radio.json` con `clips` [desplazamiento, bytes, muestras], `banks` (frase, clips, valores de parámetro) y `events` (alternativas → piezas → condiciones) (ver doc 16 §5–6). No se sube.
- `sound/`: bancos `ABKC` y motores `.GIN` del disco tal cual (33 MB) y `sound.json` con `banks` (por sonido: índice, códec, Hz, muestras, canales, desplazamientos, bucle), `gins`, `engines`/`turbos`/`shifts`/`acceltrans` (VLT), `cars` (pvehicle → sonidos), `surfaces`, `global`, `stitches` y `roles` (ver doc 16 §7–9). No se sube.
- `cars/*.glb`: cada nodo lleva `extras.pieza` (ranura, kit, estilo, de serie) y, si tiene, `extras.marcadores`.

## 5. Cómo regenerar una sola parte
```bash
cd tools
bun src/cli/vlt-dump.ts   ../original/SLES-53559.iso SLES-53559   # zones.json + gameplay.json
bun src/cli/roads.ts      ../original/SLES-53559.iso SLES-53559   # roads.json
bun src/cli/car-attribs.ts ../original/SLES-53559.iso SLES-53559  # cars.json
bun src/cli/physics-attribs.ts ../original/SLES-53559.iso SLES-53559  # physics.json
bun src/cli/ai-attribs.ts ../original/SLES-53559.iso SLES-53559   # ai.json (tráfico y policía)
bun src/cli/radio.ts ../original/SLES-53559.iso SLES-53559      # radio/ (radio de la policía)
bun src/cli/sound.ts ../original/SLES-53559.iso SLES-53559      # sound/ (motores, efectos, sirenas) · --check contra vgmstream
bun src/cli/garages.ts    ../original/SLES-53559.iso SLES-53559   # garages.json
bun src/cli/movies.ts   ../original/SLES-53559.iso SLES-53559   # movies.json (--srt, --wav)
bun src/cli/bounds.ts   ../original/SLES-53559.iso SLES-53559   # bounds.json
bun src/cli/effects.ts  ../original/SLES-53559.iso SLES-53559   # effects.json + effects/
bun src/cli/nis.ts      ../original/SLES-53559.iso SLES-53559   # nis/
bun src/cli/music.ts    ../original/SLES-53559.iso SLES-53559   # music/ (--audio, --check)
bun src/cli/coverage.ts ../original/SLES-53559.iso SLES-53559 --docs   # coverage.json + doc 21
```
