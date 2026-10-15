# Interfaz original del juego (FEng): menús, HUD, fuentes y textos

Etiquetas: [V] verificado con bytes de SLES-53559 o medido · [D] sacado de la decomp · [I] inferido · [H] hipótesis.

El motor nativo dibuja **la interfaz del propio juego**: los paquetes `.fng` de EA (FEng), sus texturas, sus fuentes y los
textos del disco en castellano (PAL) o inglés (NTSC-U). No hay menús propios alrededor. Todo se dibuja a la resolución de
la pantalla del Mac.

Código: `tools/src/lib/feng.ts` (lector), `tools/src/cli/frontend.ts` (conversor), `native-engine/Sources/Rockport/UI/`
(motor). Decomp: `src/Speed/Indep/Src/FEng/` y `src/Speed/Indep/Src/Frontend/`.

## 1. Dónde está en el disco [V]

| Archivo | Qué trae |
|---|---|
| `FRONTEND\FRONTB.LZC` (JDLZ) | 147 paquetes de menús (MainMenu, MainMenu_Sub, MW_LS_Splash, Dialog, Options…), 2 fuentes, 1 pack de texturas |
| `GLOBAL\INGAMEB.LZC` | 32 paquetes de la partida: `HUD_SingleRace`, `Pause_Main`, `HUD_Drag`, resultados… + fuente `tac_numbers` |
| `GLOBAL\GLOBALA.BUN`, `GLOBAL\GLOBALB.LZC` | fuente `font_mw_body`, logotipo MW, `FadeScreen`, iconos comunes |
| `GLOBAL\WIDESCREEN_GLOBAL.BUN` | variantes panorámicas (`WS_*`) de pantallas de carga y películas |
| `LANGUAGES\<IDIOMA>.BIN` | tabla de textos (chunk `0x00039000`) y 6 fuentes por idioma |
| `LANGUAGES\LANGUAGETEXTURES.BIN` | atlas de las fuentes de idioma |
| `GLOBAL\HUDS_CUSTOM_00…10.BIN` | cuentarrevoluciones del HUD (agujas, fondos, líneas 7000–10000) |
| `GLOBAL\HUDTEX*.BIN`, `GLOBAL\DYNTEX.BIN` | texturas del HUD; rótulos por idioma (BUSTED_SPA, EVADED_ENG…) y consejos |

bChunks: `0x00030203` paquete, `0x00030210` paquete comprimido (`u32 hash` + JDLZ), `0x00030201` fuente [D: SpeedChunks.hpp][V].

## 2. Formato del paquete (FEng) [D][V]

- En PS2 todo va en **little-endian** [V]. La decomp da la vuelta a los bytes en `FEngGetu32` porque viene de GameCube.
- `FEChunk = {u32 id, u32 tamaño}`; el id son cuatro letras y el bit `0x80000000` marca contenedor:

```
FEng ─ PkHd {u32 versión ≥ 0x20000, u32, u32 recursos, u32 objetos, u32 largoNombre, u32, nombre, archivo}
     ├ TypS {u32 tipo, u32 bytes de datos}[]       Image 0x54 · String/Group 0x44 · Multi 0x90 · Colored 0x94
     ├ ResL ─ RsNm (nombres) · RsRq {u32 n; n × {id, offNombre, tipo, flags, handle, param}}
     ├ ObjL ─ Butn {u32} · FObj ─ ObjD (etiquetas) · Scrp (etiquetas) · MsgR (etiquetas)
     ├ PkgR (respuestas del paquete) · Targ (mensaje → objetos que lo escuchan)
```

- Etiqueta = `{u16 id, u16 tamaño}` + datos; id de dos letras: `Ot` tipo, `OP` {guid, hash del nombre, flags, recurso},
  `PA` guid del grupo padre, `SA` bloque de datos inicial, `St` texto UTF-16, `SH` etiqueta del idioma, `Sj` justificación,
  `Sl` interlineado, `Sw` ancho máximo, `If` flags de imagen, `M1–M3` texturas de multi-imagen.
- Los nombres de objeto **no están** (paquetes «Stripped»): solo el hash `FEHashUpper` (h·33+c, inicio 0xFFFFFFFF, mayúsculas).
  Los nombres `__X__` del editor se guardan sin los guiones bajos: `PAD_ACCEPT` = `0x406415E3` [V].
- Bloque de datos (palabras de 32 bits) [D: FEObjData]: 0–3 color **b, g, r, a** (enteros 0…255; puede pasar de 255),
  4–6 pivote, 7–9 posición, 10–13 cuaternión, 14–16 tamaño, 17–20 UV (imágenes), 21–36 UV y giro de la máscara (multi-imagen)
  o 4 colores de vértice (imagen de color).
- Recurso → textura: `bStringHash` del nombre del archivo sin ruta ni extensión, en mayúsculas [D: LoadResources].
- `If` (flags de imagen): bit 0 repetir U, bit 1 repetir V [I: coincide con UV > 1 en 880 de 882 casos].
- Banderas de objeto: bit 0 invisible, bit 1 sin traducción, bit 3 solo PC, bit 28 botón [D].

### Scripts (animación)
- `Sh` {id, duración, flags, nº pistas}; `FI` {tipoParámetro, bytes, interpolación, acción, duración}; **`To`/`Tt`/`Ta`: el valor
  es el primer byte** de la etiqueta [V] (la decomp hace `Getu16 >> 8` con bytes ya girados); `Kd` fotogramas {i32 tiempo, valores};
  `EV` eventos {mensaje, destino, tiempo}; `Sc` script siguiente.
- Fotograma 0 = valor **base** (tiempo −1); el resto son **deltas**: valor = base + lerp(anterior, siguiente) [D: FEInterpLinear].
- Tipos: 1 entero, 2 float, 3 vec2, 4 vec3, 5 cuaternión (base · slerp), 6 color.
- Tiempo en ms (16 por fotograma de 60 Hz) [D]. Fin del script: encadena (`Sc`), o una vez / bucle / ida y vuelta (flags & 3).
- Mensajes: `MR_SetScript`, `MR_PostMessageToFEng`, `MR_PostMessageToGame`, `MR_SetActiveButton`, `If/Else/EndIf` [D].

### Dibujo [D][V]
- Lienzo de 640×480 con el origen en el centro. Imagen = cuadrado unidad × tamaño. Matriz: T(pos)·T(pivote)·R·T(−pivote)·S.
- Los grupos multiplican matriz y color ((c·g + 128) >> 8). Un objeto con alfa 0 no se dibuja.
- Orden: por Z de mayor a menor; con la misma Z, primero el último del archivo (radix estable recorrido al revés en
  `RenderObjectList`, asm SLUS-21351 `0x2507C8` [V]).
- Multi-imagen: la textura 1 es una **máscara** con UV girados (`rotate_uvs`); así se llenan los arcos de calor y nitro.

## 3. Fuentes [D][V]
Chunk `0x30201`: `nombre[256]` · `textura[256]` · `RealFontOld::Font` «FNTS» {versión, nº glifos, flags, ascenso, descenso,
offset de glifos, de kerning, estados[24]}. Altura de línea = `estados[1]` [V]. Glifo de 16 bytes {unicode, ancho, alto, u, v,
avanceY, offX, offY, nKern, índiceKern, avanceX}; kerning {u16 carácter anterior, s8 ajuste, u8}. El atlas es blanco con 16 niveles
de alfa (PSMT4). Maquetación como `FEngFont::RenderString`: justificación, `^` = salto de línea, ajuste de palabras, ancho máximo.

## 4. Textos [D][V]
Chunk `0x00039000`: `{i32 posHistograma = 0x10, i32 nTextos = 4464, i32 posRegistros, i32 posTextos}` (no es «tamaño de cabecera»).
Registros `{u32 hash, u32 offset}` ordenados. Textos empaquetados con histograma (`WideCharHistogram::UnpackString`): byte < 0x80 =
ASCII; ≥ 0x80 → tabla; si la tabla da 1…0x7F, es un par de bytes. PAL: castellano; NTSC-U: inglés.

## 5. Conversión (`tools/src/cli/frontend.ts`, ~4 s)
`map-data/<ID>/frontend/`: `index.json`, `packages/*.json` (191), `textures/<hash>.png` (910, tamaño original), `fonts/*.json` +
`*.sdf.png`, `strings/<idioma>.json`. Además `minimaps/<MAPA>.png` + `minimaps/index.json` (radar, §8.4), las texturas de `GLOBAL\RIVALS.BIN` y `wrap` (TilableUV) por textura. Va en `build-all.ts` y en el instalador (paso «Interfaz del juego»; `DATA_FORMAT` = 4).
No se sube a git (`.gitignore`).

## 6. Motor (`native-engine/Sources/Rockport/UI/`)

| Archivo | Qué hace |
|---|---|
| `FEAssets.swift` | Carga bajo demanda: paquetes, texturas premultiplicadas, fuentes, textos |
| `FERuntime.swift` | Objetos, scripts, eventos y mensajes como `FEPackage`/`FEngine` |
| `FERenderer.swift` | Dibujo con Metal a resolución nativa; maquetación de texto |
| `FEScreens.swift` | Flujo de pantallas y carrusel de iconos (`IconScroller`) |
| `FEHud.swift` | HUD original con la lógica de `Frontend/HUD/*` |
| `EngineUI.swift` | Enlace con el motor (cámara de menús, empezar, reiniciar, datos del HUD) |
| `RaceHUD.swift` | API `RaceHUD` para carreras y carrera profesional (§8.7) |
| `FERaceHUD.swift` | Resultados, Lista Negra, coche ganado, fin de persecución y escenarios de prueba |
| `FEDebug.swift` | `ROCKPORT_FE_DUMP`: lista de lo que se dibuja |
| `Input/MenuInput.swift` | Cruceta/stick, ✕ aceptar, △/○ atrás, Start; teclado: flechas, Intro, Esc |

### Escala y nitidez
- El lienzo se escala con su aspecto 4:3 y se centra; lo que el paquete pone fuera (fondos de 854 px) se dibuja igual.
- **Imágenes**: Catmull-Rom (bicúbica de 9 lecturas) sobre la textura original y premultiplicada; al reducir, trilineal.
  Se descartó xBR/ScaleFX: las texturas de MW son ilustraciones con antialias, no pixel art, y esos filtros las «pintan».
- **Letras**: el conversor hace un **campo de distancias (SDF) ×4** de cada atlas (bicúbica + corte en 0,5 + distancia euclídea
  exacta). El motor lo dibuja con suavizado de un píxel: bordes limpios a 4K. No es un vectorial real (las curvas salen del
  mapa de bits de 4 bits), pero a 2940×1912 no se ven escalones ni borrosidad.
- **Color**: la interfaz se dibuja **después** del tono PS2, sobre la imagen final y en espacio de pantalla, como el GS del PS2
  dibujaba la interfaz encima de la escena. Así sus colores son los del juego.

### Pantallas que funcionan
| Pantalla | Paquete | Estado |
|---|---|---|
| Pulsa START | `MW_LS_Splash` | Logotipo, «Pulsa START» con su animación de sello y parpadeo. Fondo: la ciudad en 3D girando (el juego mostraba el garaje) |
| Menú principal | `MainMenu` | Carrusel de iconos del juego: Modo carrera, Serie desafío, Carrera rápida, Mis coches, Opciones. Solo Modo carrera sigue; el resto abre el cuadro `Dialog.fng` con «Próximamente.» |
| Modo carrera | `MainMenu_Sub` | Continuar / Empezar nuevo → zona libre |
| Pausa | `Pause_Main` | Volver a la zona libre, Reiniciar (al refugio 1), Opciones (próximamente), Salir al menú |
| HUD | `HUD_SingleRace` / `HUD_Drag` | Todo el HUD del juego con su lógica: ver §8 (radar, persecución, carreras, mensajes) |
| Resultados, Lista Negra, coche ganado | `PostRace_Results`, `InGameReputationOverview`, `Showcase` | §8.7 |
| Fin de persecución | `BUSTED_OVERLAY`, `PostRace_MilestoneRewards` | §8.5 |

El HUD propio (`HUDPursuit.swift`) solo sale con `--debug-hud` (§8.5). Start/Esc abre la pausa; ⌘Q sale.
`--no-ui` arranca como antes; `--drive` entra directo a conducir con el HUD.

### Pruebas sin ventana
```bash
.build/release/Rockport --screenshot .build/shots/ui/mainmenu-2940.png --size 2940x1912 --ui-test MainMenu
#  --ui-test Splash | MainMenu | Career | Pause | HUD | Dialog | <paquete>   --ui-time <ms>   --ui-hud-demo
```
Capturas en `native-engine/.build/shots/ui/` (1920×1080 y 2940×1912).

## 7. Pendiente
- Películas (logos EA, presentación) y fondo del garaje con el coche en los menús; NIS del arresto (solo está su capa de cámara).
- Navegación genérica por botones (`FEButtonMap`) y el resto de pantallas (opciones, carrera rápida, tiendas, hoja de carreras, hitos).
- Sonidos de la interfaz (los mensajes de sonido se ignoran).
- Datos que el HUD ya sabe enseñar pero el juego aún no produce: refuerzos, escondites, policías destruidos/dañados, helicóptero,
  infracciones en directo, hitos de persecución, detector de radares (cámaras de velocidad), NOS/speedbreaker reales, temperatura del motor.
- Elección del mapa del radar según la Lista Negra (`MINI_MAP_UNLOCK_1/2` desde la carrera profesional).
- 63 texturas que nombran los paquetes no están en el disco PS2 (teclas de PC, Xbox, demo).

## 8. HUD original al 100 % (FEngHud) [D][V]

Código: `UI/FEHud.swift` (elementos), `UI/RaceHUD.swift` (API para carreras), `UI/FERaceHUD.swift` (pantallas y escenarios de
prueba), `UI/EngineUI.swift` (datos del juego). Decomp: `Frontend/HUD/FEPkg_Hud.cpp` y un archivo por elemento.

### 8.1 Cómo enciende y apaga el juego cada pieza
- Al crear el HUD **todos** los objetos del paquete quedan invisibles (`FEngSetAllObjectsInPackageVisibility(false)`). Cada
  elemento registra sus objetos (`RegisterGroup` registra las hojas del grupo, no el grupo) y solo esos se encienden con
  `HudElement::Toggle` según la máscara de rasgos de `DetermineHudFeatures`. **Lo que ningún elemento registra no se ve nunca**
  (antes se veían restos del editor: datos online, cajas de prueba).
- La bandera de invisible de un **grupo** no oculta a sus hijos: `FEngine::RenderGroup` solo mira el alfa; la visibilidad se mira
  hoja a hoja y solo se dibujan objetos con z > 0 (`Sorter.AddObject`) [D: FEngine.cpp]. El motor hace igual.
- Objetos «solo PC» (bandera 8): se pasa la bandera a los hijos y quedan invisibles al cargar (`FEngTransferFlagsToChildren`,
  `FEngHidePCObjects`); `FEngSetVisible` no los enciende. Así desaparecen los botones de teclado y ratón.
- Repetición de texturas: la de la **textura** (`TextureInfo::TilableUV`, bit 0 U, bit 1 V); si no repite, se recorta al borde.
  El conversor la guarda en `index.json` (`wrap`).

### 8.2 La barra naranja rayada bajo el medidor de persecución
Es `OUTRUN_BACKING` (objeto `0x8C20A763`), el **fondo del temporizador de refuerzos** («REFUERZOS: 0:24») de `PursuitBoard`.
El juego la saca solo si `mTimeUntilBackup > 0` (APPEAR, o parpadeo `0x26DED57` en los 10 últimos segundos) y si no, `LEAVE`.
Se veía siempre por un fallo nuestro: el `LEAVE` barre la textura llevando el UV de 1 a 2, y el motor repetía la textura en vez de
recortarla, así que quedaban las rayas. Con `TilableUV` = 0 (recortar) la barra se va como en el juego. Nuestra policía aún no
tiene refuerzos programados, así que en partida no aparece.

### 8.3 Elementos y rasgos (máscara de `DetermineHudFeatures`)
| Elemento (decomp) | Bits | Qué hace aquí |
|---|---|---|
| `Speedometer` | 0x8000000 | 3 dígitos, km/h en castellano y mph en inglés |
| `Tachometer` | 0x2 | Aguja 66°–294°, marcha (gris al cambiar), luz de cambio; HUD de serie `HUDS_CUSTOM_00` (TACH_FILL_00, TACH_NEEDLE_00, líneas 7000–10000) |
| `NitrousGauge` / `SpeedBreakerMeter` | 0x800 / 0x40000 | Arcos con máscara girada (175° → 0°) e icono que parpadea al gastar |
| `HeatMeter` | 0x4000 | Arco del calor, llama y «x N» (sale grande al subir de nivel: script `0x41E1FEDC`) |
| `Minimap` | 0x10000 | Radar con el mapa del juego, ver 8.4 |
| `RadarDetector` | 0x200000 | Detector de radares arriba en el centro (zona libre y enfriamiento; se va en persecución) |
| `PursuitBoard` | 0x100000 | Tiempo (`Timer::PrintToString`: « 1:23.40»), recompensa con separador de miles, policías implicados/dañados/inutilizados con su destello, barra ARRESTADO/EVADIDO de 5 trozos, ZONA SEGURA (enfriamiento), escondite y refuerzos |
| `CostToState` | 0x1000 | «C.P.E. PERSECUCIÓN» 120 fotogramas cada vez que sube el coste |
| `MilestoneBoard`, `Infractions` | 0x400000000 / 0x200000000 | Sin hitos ni infracciones en la zona libre: ocultos |
| `GenericMessage` | 0x1000000 | Mensajes centrales con su animación (ARRESTADO `0x9D73BC15`, vuelta, peaje…) |
| `Countdown` | 0x400 | 3 (`0x3C3C2F7`), 2 (`0xE479`), 1 (`0xCE01`), ¡YA! (`0x535`, texto `0x61223AB5`) |
| `RaceInformation` | 0x4000000 | Posición X/Y, vuelta X/Y o «COMPLETO NN %», tiempo; peaje: icono y peaje X/Y |
| `LeaderBoard` | 0x18 | 4 filas: nombres y, cada 90 fotogramas, distancias (o km/h acumulados en radares) |
| `WrongWIndi` | 0x20 | «Sentido contrario» a los 2 s (versión panorámica `0x908E787E`) |
| `TimeExtension` | 0x2000000 | Peaje: «tiempo extra» con el icono del reloj |
| `DragTachometer`, `ShiftUpdater`, `EngineTempGauge` | solo `HUD_Drag` | Cuentarrevoluciones grande −43°…44,5°, luces de cambio, temperatura |

Opciones de fábrica [I]: indicadores, posición y tabla encendidos; tiempos parciales activos; radar que gira con el coche.

### 8.4 Radar (minimapa) [D: FeMinimap.cpp][V]
- Texturas: `TRACKS\L2RA\MINI_MAP.BIN` (zona libre; `MINI_MAP_UNLOCK_1/2` según la Lista Negra) y un mapa por prueba
  `MINI_MAP_<id del evento con «_»>` (267 en total, con la ruta pintada). Cada archivo trae 64 chunks `0x3A100` = cabecera LZ +
  pack con un trozo `MINI_MAP_CHOPn` de 128×128 (rejilla 8×8). El conversor los junta en `frontend/minimaps/<MAPA>.png`
  (1024×1024) y el motor los vuelve a trocear como texturas `<MAPA>_CHOPn`, igual que `ChoppedMiniMapManager`.
- Calibración: `TrackInfo` del circuito 2000 (chunk `0x34201` de `GLOBALB.LZC`, 0x120 B por pista): esquina (−1224,9, −1591,1),
  ancho 6659,3 m [V]. `ConvertPos`: x = (X − esquina.x)/ancho; y = (esquina.y − Y)/ancho + 1. Comprobado: el mapa coincide con
  las calles alrededor del coche (vista con el norte arriba, `ROCKPORT_MM_NORTH=1`).
- Se dibujan los 4 trozos alrededor del coche (`TRACK_MAP1…4`, 128 unidades cada uno = 832 m); la rejilla se desplaza y gira
  sobre el coche; la máscara redonda (`MINIMAP_MASK`) se desplaza con UV. **Sin zoom por velocidad**: la decomp calcula
  `1 − v/MinimapMaxSpeed` y lo limita a un mínimo de 1, así que siempre vale 1.
- Iconos (`UpdateElementArt`): radio 0,06 del mapa (≈ 400 m), los de más lejos se quedan en el borde y se desvanecen entre
  0,125 y 0,23. Policía: gris; en persecución parpadea azul/rojo (ciclo de 8 fotogramas). Rivales `MMICON_AIRACER_n`, punto de
  control `MMICON_CHECKPOINT`, helicóptero.

### 8.5 Fin de persecución
- **Arresto**: mensaje «ARRESTADO» del HUD al instante; 1 s después [I], `BUSTED_OVERLAY.fng` (cámara de la policía: GRABANDO,
  «POLICÍA DE ROCKPORT · CÁMARA 01», ficha del sospechoso con el texto `0x626AC043` del juego) 3 s, con el HUD apagado como
  durante el NIS del arresto. Se dibuja estirado a todo el ancho, como el modo panorámico anamórfico del PS2.
- **Evasión**: `PostRace_MilestoneRewards.fng` (`PostRaceMilestonesScreen::StartBountyAnimations`): «BOLSA CONSEGUIDA», duración
  de la persecución, recompensa y total; ✕ para seguir (la simulación se para mientras).
- `HUDPursuit.swift` (HEAT/COPS/BUSTED con letra del Mac) **ya no se usa**: solo con `--debug-hud`. Sin datos de `frontend/` no
  hay HUD. `--traffic-test` también dibuja el HUD original (el coche de prueba hace de jugador; `--no-ui` lo quita).

### 8.6 Pantalla panorámica
Con la opción panorámica el juego manda `0x62ED04EC` al HUD: el grupo del radar (`0x1603009E`) va 120 unidades a la
izquierda y el del cuentarrevoluciones (`0x5D0101F1`) 120 a la derecha [V], y el radar mueve su centro. Está pensado para 16:9
(media anchura visible 426,7 unidades); en 16:10 (2940×1912) el desplazamiento se reduce en proporción para que nada se salga [I].

### 8.7 API para carreras y carrera profesional (`RaceHUD`)
`engine.raceHUD` (nil sin interfaz). Métodos: `beginRace(RaceHUDSetup)` (tipo, vueltas, corredores, `eventID` → mapa del radar
de la prueba), `endRace`, `showCountdown(3…0)`, `setPosition`, `setLap`, `setTimer`, `setProgress`, `setRacers`,
`setNextCheckpoint`, `setRoute`, `setRacerBlips`, `setSpeedtrap`, `setDrag`, `showMessage`, `showResults` (`PostRace_Results`),
`showBlacklist` (`InGameReputationOverview` con retrato `RIVAL_nn_IG`, firma `RIVAL_nn_IG_GRAF` de `GLOBAL\RIVALS.BIN`,
nombre `BLACKLIST_RIVAL_nn_AKA`, desafío y requisitos; ↑/↓ cambia de rival), `showCarWon` (`Showcase` con la firma del rival y la
marca), `dismissScreens`. Las pruebas de aceleración usan `HUD_Drag`.

### 8.8 Pruebas y depuración
```bash
R=".build/release/Rockport --data ../map-data/SLES-53559 --size 2940x1912 --frames 1"
$R --screenshot hud.png --ui-test HUD-chase      # HUD-free | HUD-chase | HUD-cooldown | HUD-busted | HUD-evaded
$R --screenshot race.png --ui-test Race-circuit  # Race-sprint | Race-drag | Race-knockout | Race-speedtrap | Race-tollbooth | Race-countdown
$R --screenshot res.png --ui-test Results        # Blacklist | CarWon
ROCKPORT_FE_DUMP=dump.txt $R …                    # lista de lo dibujado: hash, textura/texto, rectángulo 640×480, alfa, script, padres
ROCKPORT_MM_DEBUG=1 ROCKPORT_MM_NORTH=1 $R …      # radar: posición y trozos; norte arriba
```
Capturas en `native-engine/.build/shots/hud/` (1920×1080 y 2940×1912).
