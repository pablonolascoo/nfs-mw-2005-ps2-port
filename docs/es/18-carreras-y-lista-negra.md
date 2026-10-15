# Carreras y Lista Negra

Etiquetas: [V] verificado con bytes de SLES-53559 o medido · [D] sacado de la decomp · [I] inferido · [H] hipótesis.

Las 254 pruebas del juego se pueden correr en el motor nativo, con sus rivales, sus vallas y sus reglas, y la carrera
profesional recorre la Lista Negra del 15 al 1 con partida guardada. Todo sale de los datos del disco y de la lógica de la
decomp (`src/Speed/Indep/Src/Gameplay/`, `AI/Actions/AIActionRace.cpp`, `AI/Common/AIVehicleRacecar.cpp`,
`AI/Common/AIVehicle.cpp`, `World/TrackPath.cpp`).

## 1. Datos: `races.json` (paso «Carreras y Lista Negra»)

`tools/src/cli/races.ts <iso> <ID>` → `map-data/<ID>/races.json` (no se sube a git). Va en `build-all.ts` y en el
instalador (`install.ts`), y sube `DATA_FORMAT` a 4 (`Config.dataFormat`): una instalación anterior se reconvierte sola.

| Fuente | Qué se saca |
|---|---|
| `GLOBAL\GAMEPLAY.BIN` (vía `gameplay.json`, paso «vlt-dump») | Pruebas, bins, rivales, hitos, disparadores del mundo [V] |
| `TRACKS\L2RA.BUN` chunk `0x80034147` → `0x0003414D` | 1 376 vallas `TrackPathBarrier` en 751 grupos [V] |
| `world.json` (paso «convert») | GLB y caja de cada grupo de escenario |
| `collision/groups/<n>.bin` (paso «collision») | Colisión real de los objetos de cada grupo (ver §5) |

### 1.1 Herencia
Cada colección guarda solo lo que cambia respecto a su padre. `races.ts` resuelve la cadena completa
(`race_bin_15/15_1_1_circuit` → `circuit` → `basicrace` → `engaged` → `race` → `activity` → `baseelement`) [V].
El tipo de prueba sale de la plantilla de la que hereda (GRace::Type [D]):

| Plantilla | Tipo | Nº |
|---|---|---|
| `p2p`, `multipoint` | Sprint | 49 |
| `circuit` | Circuito (vueltas) | 39 |
| `lapknockout` | Eliminación | 18 |
| `drag` | Drag | 11 |
| `speedtraprace` | Radares | 32 |
| `tollboothrace` | Peaje (contrarreloj) | 68 (35 de la Serie de desafíos) |
| `challengerace_*` | Desafío de persecución | 37 |

Una más (`16_nis_rog_razor`, plantilla `nis_shell`) es una escena, no una prueba.

### 1.2 Campos de cada prueba [V]
- Salida `racestart` (startgrid), meta `racefinish` (finishline, caja `Dimensions` = [fondo, ancho, alto]),
  puntos de control `Checkpoint[]` (checkpoint, `time_bonus_checkpoint` con `TimeBonus` en los peajes), radares
  `SpeedTrapList[]` (`Radius` 20 m), atajos `Shortcuts[]`, plano de reinicio `resetplayertrigger` (`Width` 150).
- Reglas: `NumLaps`, `KnockoutsPerLap`, `TimeLimit`, `CopsInRace`, `ForceHeatLevel`, `MaxHeatLevel`, `TrafficLevel` (%),
  `DoCountdown`, `RollingStart`, `InitialPlayerSpeed`, `RankPlayersByPoints`, `CashValue`, `Reputation`, `BossRace`,
  `CatchUp`, `CatchUpSkill`, `CatchUpSpread`, `CatchUpIntegral`, `CatchUpDerivative`.
- Rivales `Opponents[]` → `character` / `boss`: `PresetRide` (coche del juego, doc 10), `CarType`, `SkillLevel` (0–100),
  `MinimumAIPerformance`.
- Vallas `Barriers[]`: nombres de grupos de escenario; con `*` delante el grupo va invertido
  (`GetBarrierIsFlipped` [D]).
- Disparador del mundo: `engagetrigger_*` con `TargetActivity` = la prueba y `Radius` 25 m (146 pruebas lo tienen; las
  del rival y los desafíos se arrancan desde menús) [V].
- Rumbo de los marcadores: grados desde +X hacia +Y, igual que el yaw del motor. Comprobado en las 255 pruebas: la salida
  apunta al primer punto de control con ±30º (lo que se desvía es la curva de la calle) [V].

### 1.3 Lista Negra (race_bin_NN) [V]
`WorldRaces[]`, `BossRaces[]`, `Boss` (con su `PresetRide` BL15…BL2), `RequiredRacesWon`, `RequiredBounty`,
`RequiredChallenges`, `Barriers[]` (candados), `BaseOpenWorldHeat`/`MaxOpenWorldHeat`, recompensas (`rewards/`: pink slip,
`cash_bonus` con `CashReward`…).
**Desafíos del bin** = hitos de persecución (`milestones/bin_NN/*`, `MilestoneName`, `GoalEasy`/`GoalHard`, `Bounty`) **más
los radares de la zona libre** (`speedtraps/bin_NN/speedtrapN`, `OpenWorldSpeedTrap`, `ThreshholdSpeed`, `Bounty`).
Solo así cuadra `RequiredChallenges` en todos los bins: los bins 1–4 piden 5 y tienen 4 hitos + 3 radares [V].

Candados por bin [V]: bins 15–13 cierran `BARRIER_LOCKED_11…15`; bins 12–9 cierran `10`, `12` y `13`; del 8 al 1, ninguno.

## 2. Ruta de cada prueba
En el juego los corredores buscan camino por la red de carreteras (WRoadNav en modo kLaneRacing con «race filter») hacia el
siguiente punto de control, sin cruzar las vallas activas (`TrackPathBarrier`, `EnableBarriers(grupo)`) [D]. El motor hace
lo mismo una vez al empezar (`Race/RaceRoute.swift`):
1. Se activan las líneas de los grupos de la prueba.
2. Tramo a tramo (salida → punto 1 → … → meta; en circuitos, más la vuelta meta → … → meta) se busca el camino más corto
   (Dijkstra) por segmentos que no crucen una valla (`DoLinesIntersect` del juego [D]).
3. Cada puerta se pasa en el sentido de su rumbo; de las dos formas de cruzar su segmento se queda la más corta y se
   penaliza la que va contra el rumbo [I]. Se quitan bucles de menos de 80 m [I].
4. La línea va por el centro de los carriles del sentido de la marcha (tipos 1, 4 y 10), no por el eje: en las avenidas
   con mediana el eje pasa encima de los muros de la mediana [V].

Validación con `Rockport --race-audit` (las 217 pruebas con salida y puertas, 0,9 s) frente a `RaceLength` del juego [V]:
mediana ruta/dato **0,997** (p10 0,94, p90 1,16), 146 de 171 dentro del ±10 %, 13 tramos sin camino en total (se unen en
recta). Ejemplos: 15.2.1 sprint 5 581 m (dato 5 555), 1.5.1 radares 7 712 m (7 729), 1.7.3 drag 1 500 m (1 499).
En los circuitos `RaceLength` no cuenta siempre las vueltas igual (4.1.1: una vuelta de 8 551 m con `NumLaps` 4; muchos de
3 vueltas valen 2 vueltas) [H]; la ruta del motor sí recorre todas.

## 3. Rivales: física del juego y conductor de la IA
Cada rival es un `Car` completo con la física del juego (PVehicle, doc 13) y la piel del preset (BL15…BL2 para los jefes).
Los genéricos (`CarType` vacío) llevan un coche de la categoría del bin con pintura al azar [I].
`Race/RaceAI.swift` reproduce:
- **Velocidad** (AIActionRace::Update) [D]: `GetSpeedLimit(curvatura, f0, f1, punta)` con el agarre estático y aerodinámico
  del coche (`GripTor`), `AiSpeedScaleTable`, `AICorneringScaleTable`, subida de `fSpeedLimit` limitada por la aceleración
  potencial (`AiAccelScaleTable` × `AiCatchupAcceleration`) con exponente `Lerp(1,5, 2, habilidad)`.
  Margen propio [I]: frenada anticipada (v² = v_curva² + 2·a·d) y 90 % del agarre, porque esta física no da todo el agarre que
  supone la IA del juego.
- **Gas y freno** (AIVehiclePid::OnGasBrake) [D]: `mThrottleBrake += −0,4·e − 0,01·∫e − 0,1·de/dt`.
- **Dirección** (AIVehiclePid::OnSteering) [D]: PID del error de rumbo con las tablas por velocidad por debajo de 10 m/s;
  por encima, coeficientes fijos en el centro de los límites del controlador adaptativo [I]. Dirección directa de la IA
  (`SuspensionRacer.aiDriver`, sin DoHumanSteering) [D].
- **Habilidad** (AIPerpVehicle::ComputeSkill) [D]: carrera = `SkillLevel/100`; carrera rápida = `Tweak_QuickRaceSkills`
  {0,15; 0,4; 1,0} por dificultad.
- **Rubber-banding** («glue», AIPerpVehicle::Update) [D]: cada 1 s, error = `RaceLength/100 × (%jugador − %rival)` en un PID
  de 10 términos de integral y 5 de derivada; `ComputeCatchUpSkill` no está decompilado: aquí
  `x = e/CatchUpSpread + ∫e·CatchUpIntegral + de·CatchUpDerivative`, recortado a ±1 y × `CatchUpSkill` [I]; luego
  × `CatchupGlueTable` / `SlowDownGlueTable` [D]. Trampa de alcance = `Clamp(base + glue − 1, 0, 1) × 0,5` [D].
- **NOS** con los umbrales de diferencia de velocidad y aceleración y los tiempos `Lerp(20, 4)` / `Lerp(2, 4)` [D].
- Evitan coches (rivales, jugador, tráfico) cambiando de lado dentro de la calzada y frenan si no hay hueco [I].
- Atascados más de 4 s: se recolocan en la ruta [I: idea de AIActionGetUnstuck].
- Choques entre coches de la carrera (cajas en planta con impulso por masas) [I]: la física del juego no trae choques entre
  coches todavía.

## 4. Reglas de cada tipo (`Race/RaceSession.swift`)
| Tipo | Reglas |
|---|---|
| Sprint | Puertas en orden; gana el primero en la meta |
| Circuito | `NumLaps` vueltas; la vuelta se cierra en la meta; «Última vuelta» |
| Eliminación | Al cerrar cada vuelta, los `KnockoutsPerLap` últimos quedan fuera; si es el jugador, pierde [D: KnockOut] |
| Drag | Cambio manual; izquierda/derecha cambian de carril y el juego lleva la dirección [D: STYLE_DRAG, kLaneDrag]; temperatura del motor en la zona roja → motor roto; frenazo de más de 14 m/s en 0,1 s → siniestro total [I]; luz de cambio (perfecto/bueno) [I] |
| Radares | Cada radar guarda la velocidad al pasar; clasifica la suma (`RankPlayersByPoints`) |
| Peaje | Tiempo `TimeLimit`; cada `time_bonus_checkpoint` suma `TimeBonus`; a 0 se pierde |
| Desafío | Persecución forzada (`PoliceManager.forcePursuit`, MForcePursuitStart [D]); se cumple al llegar a `ThreshholdValue` del hito (`MilestoneName`); la evasión cuenta si es más rápida que el objetivo; arresto = derrota |

Comunes: cuenta atrás 3-2-1-¡YA! (`DoCountdown`), salida lanzada (`RollingStart`, `InitialPlayerSpeed` en mph [I]),
parrilla de dos en fondo con el jugador detrás [I], puertas por cruce del plano dentro de la caja (o 80 m por delante en la
ruta) [I], sentido contrario (flecha del HUD tras 1,5 s), reinicio en la ruta (R / botón, fuera de ruta 6 s, plano
`resetplayertrigger`), tráfico al `TrafficLevel` %, policía si `CopsInRace` con `ForceHeatLevel`/`MaxHeatLevel`, arresto =
DNF. Al terminar el jugador, 6 s de espera; los rivales sin terminar reciben un tiempo estimado con su velocidad media [I].
Recompensa en la carrera profesional: `CashValue` (dinero) y `Reputation` (recompensa/bounty) si se gana [I: reparto].

## 5. Vallas en el mundo (`Race/RaceWorld.swift`) y colisión de grupos
- Los grupos activos (prueba + bin) se dibujan con su GLB y añaden sus muros a `CollisionWorld.dynamicWalls`.
- **Arreglo de colisión** [V]: 891 instancias de colisión de `STREAML2RA.BUN` llevan el `GroupNumber` de un grupo oculto
  por defecto (u16 @0x18). Antes se mezclaban con la ciudad y eran **muros invisibles** en la zona libre (p. ej. en
  (1574, 2256), en mitad de la calle). Ahora `collision.ts` las deja aparte en `collision/groups/<n>.bin` y el motor solo
  las usa con su grupo activo.
- Grupos «drive through» (`DriveThroughBarrierFlag`): cierran la ruta de la IA pero el jugador los atraviesa
  [I: PlayerBarrier].
- La red de carreteras recalcula los tramos cerrados al cambiar las vallas (`RoadNet.resetBlocked`, CrossesBarrier [D]).

## 6. Carrera profesional (`Career/`)
`Career.shared.start()` (continuar) / `newGame()`; partida en `~/Library/Application Support/Rockport/save.json`
(`CareerSave`: bin actual, dinero —30 000 $ al empezar [I]—, recompensa, pruebas ganadas, hitos, rivales vencidos, coches,
mejores tiempos).
- En la zona libre se ven los marcadores del bin actual y de los anteriores; se entra en el círculo y se pulsa Intro / ✕.
- Persecución evadida: la recompensa (coste para el estado) se suma y se comprueban los hitos del bin con `GoalEasy` [I].
- Radar de la zona libre del bin por encima de `ThreshholdSpeed` (km/h [I]) = desafío cumplido.
- Rival disponible con pruebas ≥ `RequiredRacesWon`, desafíos ≥ `RequiredChallenges` y recompensa ≥ `RequiredBounty`.
- Se vence al rival ganando sus `BossRaces` en orden: coche ganado (pink slip = `PresetRide` del jefe), `cash_bonus`, y
  el bin baja; se aplican los candados del nuevo bin.

## 7. API para la interfaz
```swift
QuickRace.shared.events                     // pruebas con AvailableQR
QuickRace.shared.start(eventID: "15.1.1")
Career.shared.start(); Career.shared.newGame()
Career.shared.showBlacklist()               // RaceHUD.showBlacklist con los 15 rivales
Career.shared.challengeRival()
RaceSystem.shared?.abandon()                // salir de la prueba desde la pausa
```
El HUD es de la interfaz (`UI/RaceHUD.swift`): el sistema de carreras solo llama a `beginRace`, `showCountdown`,
`setPosition`, `setLap`, `setTimer`, `setRacers`, `setRoute`, `setNextCheckpoint`, `setRacerBlips`, `setSpeedtrap`,
`setDrag`, `showMessage`, `showResults`, `showCarWon`, `endRace`.

## 8. Pruebas sin ventana
```bash
Rockport --race-test 15.2.1 --autodrive --screenshot salida.png [--seconds N] [--opponents N] [--no-traffic]
Rockport --career-test [--save ruta.json]
Rockport --race-audit          # ruta de las 217 pruebas frente a RaceLength
```
`--race-test` corre la prueba con piloto automático (el mismo conductor de la IA, habilidad 0,75), escribe puntos de control,
posiciones y tiempos, capturas `-start`, `-mid`, `-results`, `-finish` y un JSON. `--career-test` recorre la Lista Negra
entera con resultados sintéticos y comprueba requisitos, candados, coches ganados y la partida guardada.

Resultados (2026-10-15, Mac Apple Silicon, 1280×720, compilación release):

| Prueba | Tipo | Resultado del piloto automático | Rivales | CPU med / p95 por fotograma |
|---|---|---|---|---|
| 15.2.1 | Sprint | 1.º en 139,2 s (11 puertas) | 3 (CLIO, GTI, A3) a 50–56 s | 0,72 / 1,03 ms |
| 15.1.1 | Circuito 2 vueltas | 1.º en 156,5 s | 3 | 0,59 / 0,78 ms |
| 15.3.1 | Eliminación | 1.º en 231,8 s; eliminados RIVAL 1 (v1) y RIVAL 3 (v2) | 3 | 0,71 / 0,93 ms |
| 14.3.1 | Eliminación | 1.º en 277,4 s | 3 | 0,80 / 0,98 ms |
| 10.2.1 | Sprint del rival (Karl Smit, BL10 Cayman) | 1.º en 228,6 s | 1 | 0,66 / 0,84 ms |
| 1.7.3 | Drag contra Razor | con tráfico: siniestro total contra un coche de tráfico; con `--no-traffic`: 1.º en 30,8 s | 1 | 0,64 / 1,09 ms |
| 1.5.1 | Radares | 2.º por suma de velocidades (7 radares) | 3 (SLR, 911 GT2, M3 GTR) | 0,79 / 0,98 ms |
| 19.8.32 | Peaje de la Serie | ganado en 142,9 s en una pasada; en otra se agotó el tiempo | — | 0,52 / 0,70 ms |
| 19.8.1 | Desafío «duración de persecución» | cumplido: 60 s de persecución | policía | 0,53 / 0,89 ms |

`--career-test`: los 15 rivales vencidos en orden, coches BL15…BL2 y el BMW de Razor ganados, candados correctos en cada bin
(5 → 3 → ninguno) y partida guardada y leída igual.

## 9. Pendiente
- Arte invertido de las vallas con `*` (el GLB de grupo no guarda la matriz por objeto).
- Atajos (`Shortcuts`, probabilidad por rival) y salida en parrilla exacta del juego.
- Escenas (NIS), películas, cámaras de foto-finish, nombres aleatorios de corredores.
- Dificultad adaptativa (`GetAdaptiveDifficulty`), `ComputeCatchUpSkill` exacto, `cops_destroyed` (falta el daño).
- Garaje, tienda y compra de coches; elegir coche ganado.
