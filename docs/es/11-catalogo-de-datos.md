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
| ¿Qué carreras, Lista Negra e hitos hay? | `gameplay.json` → `summary` | `vlt-dump.ts` | 05 |
| ¿Cualquier valor de la base de datos del juego? | `gameplay.json` → `collections[6287]` | `vlt-dump.ts` | 05 |
| ¿Por dónde van las calles y carriles? | `roads.json` | `roads.ts` | 09 |
| ¿Dónde hay suelo y muros (colisión)? | `roads.json` → `collisionPacks[390]` (resumen) | `roads.ts` | 09 |
| ¿Cómo son los coches y sus ruedas? | `cars/*.glb` (91), `cars.json` (92) | `convert.ts car`, `car-attribs.ts` | 10 |
| ¿Cómo son los interiores de garaje? | `interiors/*.glb` (5) | `convert.ts interior` | 07 |
| ¿Vista cenital del mapa? | `rockport-plano.png` + `.json` (escala) | `topdown.ts` | 03 |
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
- `cars.json.cars[nombre]`: `tires` = 4 × `[x, y, z, radio]`, `className`, `spokes`.

## 5. Cómo regenerar una sola parte
```bash
cd tools
bun src/cli/vlt-dump.ts   ../original/SLES-53559.iso SLES-53559   # zones.json + gameplay.json
bun src/cli/roads.ts      ../original/SLES-53559.iso SLES-53559   # roads.json
bun src/cli/car-attribs.ts ../original/SLES-53559.iso SLES-53559  # cars.json
bun src/cli/garages.ts    ../original/SLES-53559.iso SLES-53559   # garages.json
```
