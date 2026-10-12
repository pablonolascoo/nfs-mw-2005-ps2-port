# Tráfico y policía

Etiquetas: [V] verificado con bytes de SLES-53559 o medido · [D] sacado de la decomp · [I] inferido · [H] hipótesis.

Rockport ya tiene vida en el motor nativo: tráfico que circula por sus carriles y policía que patrulla, persigue,
embiste, monta controles y te arresta. Todo sale de los datos del juego (`roads.json` y `ai.json`) y de la lógica de
la decomp (`src/Speed/Indep/Src/AI/`).

## 1. De dónde salen los datos

| Archivo | Lo genera | Qué trae |
|---|---|---|
| `roads.json` | `tools/src/cli/roads.ts` | Nodos, tramos Bézier, perfiles de carril y banderas (doc 09) |
| `ai.json` | `tools/src/cli/ai-attribs.ts` (nuevo) | Tablas de tráfico y policía de `GLOBAL\ATTRIBUTES.BIN` y zonas de `TRACKS\L2RA.BUN` |
| `collision/*.bin` | `tools/src/cli/collision.ts` | Suelo y muros: altura de los coches, línea de visión, muros que cortan calles |
| `cars/*.glb`, `cars.json` | `convert.ts car`, `car-attribs.ts` | Modelos de tráfico y policía, ruedas (doc 10) |

`ai-attribs.ts` ya va en `build-all.ts` y en el instalador (`install.ts`, paso «Tráfico y policía»).
`ai.json` no se sube a git (datos del juego).

### 1.1 Tablas VLT usadas [V]

| Clase (ATTRIBUTES.BIN) | Campos | Para qué |
|---|---|---|
| `trafficpattern` (10) | `SpawnTime`, `SpeedStreet`/`SpeedHighway` (mph), `Vehicles[]` = `TrafficPatternRecord {RefSpec Vehicle, Rate, MaxInstances, Percent}` | Qué coches salen en cada barrio, cada cuánto y a qué velocidad |
| `pursuitescalation` (1) | `heattable[10]`, `supporttable[10]`, `racetable`, `supportracetable` | Nivel de calor N → `heat_0N` |
| `pursuitlevels` (21) | `cops[]` = `CopCountRecord {StringKey CopType, Count, Chance}`, `CopFormations[]`, `NumPatrolCars`, `FullEngagementCopCount`, `evadetimeout`, `BustSpeed`, `frontLOSdistance`, `rearLOSdistance`, `TimePerHeatLevel`, `ScaleEscalationPerBucket[15]`, `roadblockprobability`, `roadblockspikechance`, `SearchMode*`, `Collapse*`, `Boxin*`, `MeterDeadZone*`, `HiddenZoneTimeMultiplier`… | Toda la persecución |
| `pursuitsupport` (21) | `MinimumSupportDelay`, `Air/Heavy/LeaderSupportOptions` | Espera antes de controles y apoyos |
| `aivehicle` (23) | `MAXIMUM_AI_SPEED`, `TopSpeedMultiplier`, `AccelerationMultiplier` | Velocidad de cada policía |
| `pvehicle` (113) | `MODEL`, `MASS` | Colección → modelo GLB |
| `infractions` (8) | `amount` | Multas (speeding 150, racing 350, reckless_driving 1000, assault 350, hit_and_run 300, damage 100, resisting_arrest 300, off_road 75) |
| `world` | `TRAFFIC_TYPES` | `trafha`, `semilog` |

Nombres de colección sin texto en el disco, sacados por hash Jenkins (`0xABCDEF00`) [V]: `heat_01`…`heat_10`,
`copmidsize`, `copghost`, `copgto`, `copgtoghost`, `copsport`, `copsportghost`, `copsporthench`, `copsuvpatrol`,
`copheli` y las 8 infracciones.

Estructuras de los registros: `MWAttribUserTypes.h` y `AI/aireflectedtypes.h` [D]. `StringKey` = `u64 hash64 · u32 hash32 · char*`;
el `hash32` es el hash Jenkins del nombre [V].

### 1.2 Calor en libre (heat_01…05) [V]

| Calor | Policía | Patrullas | A por ti (máx.) | Evasión (s) | BustSpeed | Control % | Pinchos % | Formaciones |
|---|---|---|---|---|---|---|---|---|
| 1 | copmidsize ×4 | 1 | 5 | 20 | 9 | 0 | 0 | ROLLING_BLOCK |
| 2 | copghost ×5 | 1 | 10 | 45 | 12 | 10 | 0 | BOX_IN |
| 3 | copgto ×7 | 1 | 15 | 75 | 19 | 25 | 0 | BOX_IN, PIT, ROLLING_BLOCK, HERD |
| 4 | copgtoghost ×8 + copheli | 1 | 20 | 90 | 20 | 30 | 70 | PIT, BOX_IN, HERD, ROLLING_BLOCK |
| 5 | copsporthench ×10 + copheli | 1 | 25 | 120 | 25 | 40 | 80 | ROLLING_BLOCK, BOX_IN, PIT, HERD |

`heat_06…10` son de eventos (persecuciones de carrera, la final). Tiempo por nivel = `TimePerHeatLevel × ScaleEscalationPerBucket[tramo]`:
en calor 1–3 y al principio de la historia, 120 s por nivel [V].

### 1.3 Patrones de tráfico por barrio [V]

Las zonas `TRAFFIC_PATTERN` (tipo 9) de `TrackPathManager` (chunk `0x0003414A` dentro de `0x80034147`, en `L2RA.BUN`)
son polígonos en X, Y del mundo; `Data[0]` = `bStringHash` del patrón [V]. Hay 11: collegesouth, downtown, collegenorth,
collegehighway (×4), cityhighway (×2), coastalsouth, coastalnorth. Fuera de ellas, `default`.
Formato de zona [D: `World/TrackPath.hpp`]: `s32 Type · f32 Position[2] · f32 Direction[2] · f32 Elevation · s8 · s8 · s16 ·
u32 · f32 BBoxMin[2] · f32 BBoxMax[2] · s32 Data[4] · s16 NumPoints · s16 MemoryImageSize · f32 Points[n][2]`.
También se exportan los escondites (`HIDDEN`, 34), `NO_COP_SPAWN` (3), `PURSUIT_START` (3) y barrios (8).

Ejemplo, `downtown`: taxi (25 %), camión de basura (máx. 1), furgoneta de noticias (máx. 1), bomberos (máx. 1),
sedán A (25 %), juzgado (20 %). Todos los patrones: 35 mph en calle y 55 mph en autopista.

## 2. Carriles: cómo se conduce por la red [D][V]

Igual que `WRoadNav` (`World/Common/WRoadNetwork.cpp`):

- El tramo es una Bézier cúbica (o recta si no tiene `curved`). Cada nodo tiene un perfil de calzada.
- Zonas `[middleZone, numZones)` = sentido nodo 0 → 1; `[0, middleZone)` = sentido contrario. `n = 0` es el carril del centro.
- `StartInverted` / `EndInverted` reflejan el perfil en ese extremo.
- Con esas tres reglas, el carril queda **siempre a la derecha del sentido de marcha** a `|offset|` m del eje: conducción por la derecha.
  Comprobado en las capturas: el tráfico de cara va por la izquierda.
- Tráfico: solo zonas de tipo 1 (`drivable_lanes[kLaneTraffic] = 2`) [D].
- Desplazamiento lateral = interpolación entre el perfil del nodo de salida y el de llegada.
- Sentido único (`oneWay`): solo de nodo 0 a 1. `noTraffic`: sin tráfico. Policía: tráfico permitido XOR `copsXorTraffic` [D].
- En un nodo: primero la continuación que no es de decisión; si no, un tramo de cruce (decision) al azar cuya salida siga [D: `GetNextTraffic`].
- Velocidad: autopista si el tramo tiene 4 o más carriles de tráfico (contando los dos sentidos), si no, calle [D].
- Curvas: `v = √(μg / |κ|)` con μ = 0,6 para tráfico y 1,6 para policía [D: `AIActionRace.cpp`].
- Frenada tras otro coche: distancia de parada `Lerp(3, 50)` según la velocidad; velocidad ≤ la del de delante × hueco / parada [D].
- Aceleración del tráfico: como mucho +2 m/s² [D].
- **Muros que cortan una calle** [V]: `collision/*.bin` tiene muros de 11 m en algunos cruces (vallas de la historia, `BARRIER_LOCKED`).
  En el juego esos tramos se marcan `CrossesBarrier` al cargar [D]. Aquí se calcula al primer uso: si el eje del tramo cruza un muro, ni tráfico ni policía entran.

## 3. Tráfico [D: `AI/Activities/AITrafficManager.cpp`]

| Regla | Valor |
|---|---|
| Revisión | cada 0,5 s |
| Densidad | 1,0 en libre; ×0,75 con persecución |
| Ritmo de aparición (densidad 0…1, 11 pasos) | 0, 0,05, 0,1, 0,125, 0,2, 0,4, 0,6, 1, 3, 5, 8 |
| Un coche del patrón sale si | temporizador > `Rate`, menos de `MaxInstances` (0 = sin límite) y dentro de su `Percent` |
| Punto de aparición | 200 ± 50 m por delante (+ velocidad), girado ±45°; de cara con probabilidad `Lerp(1, 0,5, v/50)` |
| Rechazo | a menos de 150 m del jugador, a menos de 20 m de otro coche, sin suelo |
| Carril | al azar entre los de tráfico de ese sentido |
| Velocidad inicial | `min(calle, autopista) × 0,75` |
| Borrado | fuera de pantalla más de 4 s y a más de 40 m (densidad 1) |
| Máximo | PS2: 10 vehículos en total [D]. Aquí 20 de tráfico (`--traffic-max`) |
| Golpe del jugador (≥ 5 mph) | el coche gira un instante y se queda frenado (`ACCIDENT_OVER`) [D] |

## 4. Policía [D: `AICopManager.cpp`, `AIPursuit.cpp`, `AIVehicleCopCar.cpp`]

### 4.1 Estados
`none` (patrulla) → `chase` → `cooldown` → `evaded`, o `busted`.

- **Patrulla**: `NumPatrolCars` coches que conducen como el tráfico. Se recolocan fuera de pantalla a más de 375 m del punto 75 m por delante.
- **Te ven** (cada 0,25 s): a menos de `frontLOSdistance` si estás delante del policía (dot > −0,3), o de `rearLOSdistance`;
  sin muros de colisión entre los dos; nunca dentro de un escondite.
- **Empieza** si te ven y: vas a 65 mph o más, chocaste con el tráfico hace menos de 1 s, el calor es mayor que 3 o embistes a un policía.
  También en una zona `PURSUIT_START`.
- **Calor**: `+dt / (TimePerHeatLevel × ScaleEscalationPerBucket[tramo])` mientras te persiguen (no en enfriamiento). Máximo 5 en libre.
- **Refuerzos**: uno cada `TimeBetweenCopSpawn` s hasta `min(Σ cops.Count, FullEngagementCopCount, 8)`; tipo al azar por `Chance`.
  Salen en la red a 150–320 m, fuera de la vista, de cara a ti y a 60 mph.
- **Arresto**: te ven, vas por debajo de `BustSpeed` (km/h) y hay un policía a menos de 15 m (± 1,5 m de altura):
  el contador sube 1/s y baja 2/s. A 5 s (`kBustedTimeout`): **BUSTED**. Tras 3 s el coche vuelve al refugio 1 [I].
- **Enfriamiento**: 7 s sin que te vea nadie. La evasión crece con el tiempo sin verte (más deprisa, × `HiddenZoneTimeMultiplier`, en un escondite)
  sobre `evadetimeout`, y baja × 0,93 cada 0,25 s si te ven; visto 2,5 s seguidos, vuelve la persecución. Los policías buscan tu última
  posición a `SearchModeCityMPH` / `SearchModeHwyMPH`. A 1: **EVADED**, calor × `EvadeSuccessHeatAdjust` (0,95) y 60 s sin policía nueva.
- **Medidor** (barra de la HUD) [D: P:2068-2093]: verde si el policía más cercano está a más de `MeterDeadZoneEvadeDist`;
  rojo si está a menos de `MeterDeadZoneBustedDistance` y vas despacio.

### 4.2 Conducción
- Lejos (> 60 m o sin camino directo): por la red de carreteras hacia ti, con un Dijkstra inverso desde tu nodo (se rehace cada segundo).
- Cerca (< 60 m y sin muros en medio): en directo (`AIActionPursuitOffRoad`), con giro limitado por μ = 1,6.
- Velocidad: `min(MAXIMUM_AI_SPEED, tu velocidad × TopSpeedMultiplier + alcance)`; aceleración × `AccelerationMultiplier`.
- **Formaciones** (posiciones respecto a ti, x a la derecha, z delante) [D: P:179-439]:
  FOLLOW (0,−13) (±3,5,−13) (0,−17)…, STAGGER (0,∓13) (±3,5,∓13), BOX_IN (0,14) (±3,5,0) (0,−7,5),
  ROLLING_BLOCK (0,14) (±2,5…5,10…14), PIT (±4,−2,7), HERD (−3,0) (−3,±5).
  Se elige una alternando la tabla `CopFormations` (por `Frequency`) y STAGGER. En BOX_IN y PIT, a los 4 s embisten.
- **Colapso**: si vas por debajo de `CollapseSpeed`, los cercanos te rodean a `CollapseInnerRadius`.
- **Desatasco**: más de 1,5 s contra un muro → vuelven a la red 3 s (`AIActionGetUnstuck`).

### 4.3 Controles de carretera [D: `AIRoadBlockSetups.cpp`, CM:1100-1307]
- Tirada cada 8–12 s tras `MinimumSupportDelay` (60 s en calor 1–3, 45 en 4, 35 en 5) con `roadblockprobability`
  (sin verte: `SearchModeRoadblockChance` según la distancia).
- 250 m por delante por la red, en un tramo apto (tráfico, sin cruce, ≥ 30 m).
- Ancho de calzada del perfil → el montaje con el menor `ancho − minWidth` positivo (15 normales y 9 con pinchos de la tabla de la decomp).
- Coches de policía parados con luces, caballetes y tiras de pinchos (cajas: el modelo `XO_Sawhorse` no se exporta aún [I]).
- Al pasarlo («esquivado») sus policías se suman a la persecución. Pinchos: el coche frena en seco [I: el juego revienta las ruedas].

### 4.4 Luces
- Destellos en los marcadores del modelo `COPLIGHTRED`, `COPLIGHTBLUE`, `COPLIGHTWHITE` (bStringHash `1e4150b4`, `e662c161`, `b4348dba`) [V].
- Rojo cuando `cos(8t) > 0,2`, azul en contrafase, pulso `cos²(24t)`, blancos `sin(pulso · cos(12(t + 1,5 i)) · 3)` [D: CarRender.cpp 2364-2423].
- Encendidas en persecución y en controles; apagadas al arrestar o al retirarse. Las patrullas no las llevan [D].
- El mando (DualShock 4 / DualSense) se pone rojo y azul durante la persecución (`Controllers.shared.setPursuit`).

## 5. Motor nativo

| Archivo | Qué hace |
|---|---|
| `AIRoads.swift` | Red de carreteras: Bézier, tabla de longitudes, carriles, reglas, siguiente tramo, Dijkstra, rejilla espacial |
| `AIData.swift` | Lee `ai.json` (patrones, niveles de calor, zonas) |
| `AIModels.swift` | Monta los modelos de tráfico y policía (una pieza por ranura, ruedas de `cars.json`) en hilos de fondo; marcadores de luces |
| `AIVehicle.swift` | Seguidor cinemático propio: carril o directo, altura de la colisión real, empujón tras un golpe |
| `AIWorld.swift` | Orquesta todo; curvas, frenada, choques (rectángulos SAT) y estadísticas |
| `TrafficManager.swift` | Aparición, patrón por barrio, borrado |
| `PoliceManager.swift` | Patrulla, persecución, calor, arresto, evasión, formaciones, controles |
| `AIRender.swift` | Dibujo instanciado (una llamada por modelo y material), pilotos de freno, destellos, caballetes |
| `HUDPursuit.swift` | HUD de MW: calor, barra EVADE/BUSTED, COOLDOWN, BUSTED/EVADED |
| `AIEngine.swift` | Enganche al motor y prueba `--traffic-test` |

Enganches pequeños: `Engine.swift` (`ai`, `aiRenderer`, `setupAI`, `updateAI` antes de dibujar), `Renderer.swift` (`overlays`: tres puntos de dibujo),
`main.swift` (opciones). Los golpes contra la IA frenan al coche del jugador multiplicando su velocidad (la física del juego aún no tiene choques entre coches).

## 6. Prueba sin ventana

```bash
cd native-engine && swift build -c release
./.build/release/Rockport --traffic-test 90 --screenshot .build/shots/traffic.png --size 1920x1080
./.build/release/Rockport --traffic-test 150 --heat 5 --test-plan run --screenshot .build/shots/heat5.png
ROCKPORT_DEBUG_AI=1 …   # estado de cada policía cada 2 s, muros cruzados, solapes, controles
```

Un coche de prueba recorre la red (a 125 km/h, luego 70 y luego parado; `--test-plan run` = siempre a 130; `flee` = 300 km/h en cuanto le persiguen). Guarda tres capturas
(30 %, 60 %, final), una del control si lo hay (`-control.png`) y un `.json` con las cifras.

Resultados (MacBook Air M4, 2026-10-12) [V]:

| Prueba | Resultado |
|---|---|
| 90 s, calor 1, 1920×1080 | 73 coches de tráfico (máx. 17 a la vez), 1 persecución, **BUSTED** a los 74 s; 100 % sobre el suelo, 0 saltos de carril, 52 pasos sobre muro (0,07 %) |
| 150 s, calor 5, 1600×900 | Corvette de policía (copsporthench), 11 policías a la vez, 1 control esquivado; 99,96 % sobre el suelo |
| 150 s, calor 1, `flee` (300 km/h al empezar) | enfriamiento a los 28 s, **EVADED** a los 41 s, 60 s sin policía y nueva persecución a los 147 s |
| 90 s, calor 5, 2940×1912 (Retina) | 19 de tráfico + 12 policías: GPU mediana 4,3 ms (p95 5,7), CPU 1,0 ms, 124 llamadas de la IA |

## 7. Pendiente
- Helicóptero (`copheli`, `HeliFuelTime`, `AirSupportOptions`), apoyos pesados (SUV que embisten) y líder (`copcross`).
- Caballetes y pinchos con su modelo real (`XO_Sawhorse_1b_00`, `XO_SpikeBelt_1b_DW_00`) y ruedas pinchadas de verdad.
- Choques físicos entre coches (la física del jugador aún no los tiene: ahora se pierde velocidad).
- Bocina y sonidos (sirenas `Siren*`, `HornType`), voces de radio (`nSpeechId` de `RNrd`).
- Cambios de carril voluntarios (el juego tampoco los hace en el tráfico [D]).
- En algunos cruces el desplazamiento lateral corta una esquina con muro (≈ 0,1 % de los pasos).
- Cuenta de recompensas (`RepPointsPerMinute`, coste para el estado) en la HUD.
