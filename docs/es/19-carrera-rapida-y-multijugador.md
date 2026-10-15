# Carrera rápida y multijugador (pantalla partida)

Etiquetas: [V] verificado con bytes de SLES-53559 o medido · [D] sacado de la decomp · [I] inferido · [H] hipótesis.

La carrera rápida usa las pantallas del propio juego (paquetes FEng del disco) con la lógica de
`Frontend/MenuScreens/Safehouse/quickrace/*.cpp` de la decomp. La pantalla partida para 2 jugadores es la del juego
(paquetes `HUD_Player1/2`, cámaras de pantalla partida). Como extensión del port: 3 y 4 jugadores, varias pantallas a la vez
y rivales de la IA, tráfico y policía también en pantalla partida.

Código: `native-engine/Sources/Rockport/UI/QuickRace*.swift`, `UI/JoinScreen.swift` y `Multiplayer/`.

## 1. Datos nuevos del conversor (paso «frontend»)

| Archivo del disco | Qué trae | Uso |
|---|---|---|
| `GLOBAL\INGAMESPLITSCREEN.BUN` | Paquetes `HUD_Player1`, `HUD_Player2`, `HUD_Drag_Player1`, `HUD_Drag_Player2` [V] | HUD de pantalla partida. El juego lo carga solo en pantalla partida (`GameFlow.cpp`) [D] |
| `GLOBAL\HUDTEXSPLIT.BIN`, `HUDTEXDRAGSPLIT.BIN` | Texturas `2PLAYER_*` del HUD partido [V] | Ya se exportaban |
| `TRACKS\L2RA\TRACKMAPS.BIN` | 297 mapas `TRACK_MAP_<id>` de 512×512 con la ruta pintada [V] | Track_Select (`UITrackMapStreamer` [D]) |
| `GLOBAL\FE_ATTRIB.BIN` → `fe-cameras.json` | Clase `frontend`: `UnlockedAt`, `manufacturer` y coste de 34 coches [V] | Desbloqueo y marca de los coches (lo exporta el paso de garajes) |

`tools/src/cli/frontend.ts` añade los dos primeros a sus listas. Van dentro del formato de datos 5 (`DATA_FORMAT`): con datos
anteriores el motor avisa de que falta el paquete y sigue sin HUD partido; el mapa de Track_Select queda oculto.

## 2. Flujo de la carrera rápida

| Pantalla | Paquete | Clase de la decomp | Qué hace |
|---|---|---|---|
| Carrera rápida | `MainMenu_Sub` | `UIQRMainMenu` | Partida rápida · Carrera personalizada · Pantalla dividida |
| Tipo de prueba | `MainMenu_Sub` | `UIQRModeSelect` | Circuito, sprint, aceleración, eliminación (no en pantalla partida), radar; + peaje (extensión) |
| Selección de pista | `Track_Select` | `UIQRTrackSelect` | Prueba con su mapa, zona (L1/R1), longitud, mejor tiempo, candado |
| Opciones | `Track_Options` | `UIQRTrackOptions` | Dirección, vueltas, tráfico, oponentes, dificultad, alcanzar; + policía (extensión) |
| Pulsa START | `PressStart` | `uiQRPressStart` | Reparto de mandos (solo pantalla partida) |
| Selección de coche | `Car_Select` | `UIQRCarSelect` | Una por jugador: listas de serie / carrera / bonificación, barras, candado |
| Carrera | HUD del juego | — | `MultiplayerRace.start` → `RaceSystem` / `RaceSession` |
| Resultados | `PostRace_Results` | — | Vuelta al menú de la carrera rápida |

Partida rápida: una prueba desbloqueada al azar con el último coche elegido [I: el juego va a `Quick_Race_Brief`].

### 2.1 Selección de pista [D: UIQRTrackSelect]
- Lista: bins 21 y 15 → 1 (el bucle salta del 21 al 16), carreras del mundo y del rival, del tipo elegido, fuera las de la
  Serie de desafíos. Filtro de zona `RegionFilterBits`: universitaria, costera, ciudad o todas (0xA6850651 … 0x632DD19B).
- Mapa: textura `TRACK_MAP_<id con «_»>` en el objeto `TRACK_MAP`; el UV hace zoom y paneo en 1 s a la caja de la prueba con
  0,125 de margen y cuadrada (`CalcBoundsForRace` + `UpdateMap`) [D]. La caja se calcula con salida, puntos de control,
  meta y radares pasados al plano del radar (calibración `TrackInfo` 2000) [I: mismo plano que el radar; se ve bien].
- Nombre `TRACKNAME_<id>` (p. ej. «Ironwood Estates»), longitud en km o millas, «Vuelta rápida» en circuitos.
- Desbloqueo [I: `UnlockSystem` no está en los datos]: libres las pruebas con `AvailableQR` [V], las de los bins cuyo rival ya
  se venció en la carrera profesional (`save.json`) y las ganadas allí. Bloqueada: candado y «Desbloquea esta pista al
  derrotar a %s, miembro %d de la Blacklist» (0xBD563BE5).

### 2.2 Opciones [D: UIQRTrackOptions + UIWidgetMenu + FEToggleWidget]
Filas `OPTION_NAME_n` / `OPTION_DATA_n` / `LEFT_ARROW_n` / `RIGHT_ARROW_n` colocadas desde la esquina de `TITLEMASTER`
(0xA753C46C) una por altura de título, cursor 0x06745352 con los scripts `POS1…POS9`, `HIGHLIGHT` / `UNHIGHLIGHT` en la fila.

| Fila | Valores | En el juego |
|---|---|---|
| Dirección de circuito | Adelante / Hacia atrás | Si la prueba tiene versión `.r` |
| Vueltas | 1…8 | Solo circuito |
| Nivel de tráfico | Ninguno, mínimo, moderado, máximo | No en drag; no en pantalla partida (aquí sí) |
| Oponentes | 1…(4 − jugadores) | 0…(4 − jugadores) en pantalla partida (el juego: ninguno) |
| Dificultad | Fácil, medio, difícil | `Tweak_QuickRaceSkills` |
| Alcanzar | Sí / No | «Pegamento» (catch-up) de la IA |
| Policía | Sí / No | Extensión: el juego la quita siempre (`SetCopsEnabled(false)`) |

Los ajustes se guardan en `settings.json`, clave `quickRace`.

### 2.3 Coches [D: UIQRCarSelect, FECarRecord]
| Lista | Coches | Desbloqueo |
|---|---|---|
| De serie (0xD9D6B954) | `pvehicle` con `PlayerUsable` y modelo convertido (34) | `frontend.UnlockedAt` [V]: libre si el bin actual de la carrera ≤ UnlockedAt; si no, «derrota a … nº UnlockedAt + 1» (0x4EF2A115) |
| M. carrera (0xEE053562) | El BMW M3 GTR de la historia (`M3GTRCAREERSTART`) | Siempre |
| Bonificación (0xD8A058F7) | Lista Negra BL15…BL2 y `RAZORMUSTANG` (presets del disco); premios SL65, 911 GT2, M3 GTR (demo E3), Corvette C6.R | Rival vencido; premios con sus textos 0xBD8BAC91…94 [D] y regla [I] |

Nombre: `CARNAME_<marca>_<colección frontend>` con la marca de `frontend.manufacturer` (1 = BMW … 25 = CORVETTE) [D][V];
logotipo `SECONDARY_LOGO_<colección>`; barras de aceleración, punta y manejo (`TwoStageSlider`, ancho 160, `LED_main` con
U = ancho / 32) con indicadores propios a partir de par, masa, arrastre y agarre [I: `EstimatePerformance` no está
decompilado]. El logotipo de la marca (`CARSELECT_MANUFACTURER_*`) no está en los paquetes convertidos: se oculta.
El coche se ve en la calle del refugio con la cámara girando [diseño propio: el juego lo pone en el garaje].

## 3. Pantalla partida del juego (2 jugadores)

- **Horizontal: jugador 1 arriba, jugador 2 abajo** [V: `HUD_Player1` ocupa y = −240…0 del lienzo 640×480 con una raya de
  1200×4 en y = 0; `HUD_Player2` ocupa 0…240]. Los dos HUD se dibujan a pantalla completa.
- HUD (`ePlayerHudType` PHT_SPLIT1/2 y PHT_DRAG_SPLIT1/2 [D: FEPkg_Hud.cpp]): velocímetro, nitro (arco de 180° [D]),
  cuentarrevoluciones como **barra que crece** (no aguja) y se pone roja en la zona roja [D: Tachometer::Update y
  DragTachometer::Update con USER_SPLIT_SCREEN], posición, vuelta, tiempo, mensajes, cuenta atrás, sentido contrario.
  Sin calor, persecución ni radar de velocidad. El radar solo existe en `HUD_Player1`, sobre la raya: no gira con el coche
  y lleva el coche del otro jugador (`PLAYERCARINDICATOR2`) [D: Minimap::Update / UpdatePlayer2Element].
- Panorámica: los grupos con el script 0x1EDC08 (0x5D0101F1, 0x2FE4FF9C y el del radar 0x1603009E) se desplazan como en el
  HUD normal [V].
- Cámara: cada valor de `camerainfo` es un par; el segundo es el de pantalla partida (`CameraInfo::SplitScreenPOVArray`)
  [D][V: p. ej. «far» LAG −5,44 → −8,2, HEIGHT 1,70 → 1,85].
- En el juego: sin rivales de la IA (`SetNumOpponents(1)` = el otro jugador), sin policía, sin opción de tráfico; sin
  eliminación; sprint, aceleración y radar van directos a «Pulsa START» sin opciones [D].
- Pausa (en el juego: Reanudar, Reiniciar, Salir, Opciones [D: uiPause]): cualquiera de los dos jugadores puede pausar
  (`cFEngJoyInput::HandleJoy` lee los dos puertos [D]). Aquí sale la pausa de la interfaz; «Salir» abandona la prueba y
  vuelve a un jugador.
- Fin: la prueba sigue hasta que acaban los dos [D: FEManager mira al otro jugador]; aquí, 30 s tras el primero [I].

## 4. Extensión: 3 y 4 jugadores

- Cuartos de pantalla (2×2). Los de arriba llevan `HUD_Player1` con la ventana del lienzo y = −240…0 y los de abajo
  `HUD_Player2` con 0…240, encajados en su cuarto y recortados (sin radar: no cabe).
- Con 3 jugadores el cuarto libre enseña una vista aérea sobre el centro de los coches.
- Parrilla: la IA delante; los humanos detrás, en orden.

## 5. Mandos: un mando, un jugador

| Mando | Cómo se lee | Se une con | Barra de luz | LED de jugador | Vibración |
|---|---|---|---|---|---|
| Xbox One / Series | GameController | START (≡) o A | — | Sí (`GCController.playerIndex`) | Sí (CoreHaptics) |
| DualSense (PS5) | GameController | Options o ✕ | Color del jugador | Sí (LED de jugador 1…4) | Sí + gatillos |
| DualShock 4 (PS4) | GameController | Options o ✕ | Color del jugador | — | Sí |
| MFi | GameController | Menú o A | — | Según el mando | Según el mando |
| DualShock 3 (USB) | IOKit HID | START o ✕ | — | — | Sí |
| Adaptador de PS2 / HID genérico | IOKit HID | START (botón 10) o ✕ | — | — | — |
| Teclado | Teclas del Mac | Intro (se va con Retroceso) | — | — | — |

Colores de jugador: azul, rojo, verde y rosa (el orden de PlayStation) [I].

Cómo funciona el reparto (`UI/JoinScreen.swift`, paquete `PressStart` del juego):
1. «Jugador N presiona START» (0xCF538E1C). El primer dispositivo que pulsa es el jugador 1 (el mando maestro):
   «El primero en elegir será designado como Jugador 1» (0x61E75E95) [D].
2. Cada mando unido se pinta con el color de su jugador y enciende su LED de jugador.
3. Un jugador unido que pulsa ○ / B se va; el jugador 1 solo, vuelve atrás.
4. Con 2 o más, el jugador 1 pulsa START para seguir. Luego cada jugador elige su coche con su mando.

Sin mezclas (`Multiplayer/PlayerDevices.swift`): en pantalla partida cada coche lee **solo** su dispositivo
(`Controllers.readPad`, `HIDPads.readPad`, teclado aparte); la vibración, los gatillos y la luz van a cada mando con los datos
de su coche. En un jugador todo sigue como antes (cualquier mando conduce).

Menús: los de la carrera rápida los lleva el jugador 1 (`MenuOwners`); cada selección de coche, su jugador; en la carrera,
cualquiera puede pausar (como el juego). El teclado del Mac siempre puede mover los menús.

Desconexión (`SplitScreen`): la partida se para con el aviso del propio juego (`ControllerUnplugged.fng`: «Se ha extraído el
mando… puerto de mando %d… pulsa START») hasta que ese jugador, u otro mando libre, pulse START [D: CheckUnplugged]. Prueba:
`--split-test 2 --unplug-test`.

## 6. Varias pantallas (extensión)

- Ajuste en `settings.json`: `"multiplayer": {"displays": "1" | "2" | "all", "maxPlayers": 4}`; opción de arranque
  `--displays all|1|2` (no se guarda). Con `--race ID --players N` la app va directa a «Pulsa START» con esa prueba.
- Una ventana sin bordes a pantalla completa por pantalla extra (`NSScreen.screens`), cada una con su `CAMetalLayer`, vsync
  y resolución dinámica propias (`Multiplayer/MultiDisplay.swift`).
- Reparto lo más parejo posible: 4 en 2 = 2 + 2; 3 en 2 = 2 + 1. Cada pantalla se parte con la regla de §3–4; una pantalla con
  un solo jugador lleva el HUD normal.
- Límites: la simulación va al ritmo de la pantalla principal; una pantalla más rápida repite estados (sin interpolar). Cada
  pantalla es otra pasada de escena: el presupuesto de GPU (13,5 ms) es por pantalla. Teclado y ratón van a la ventana
  principal. Los menús de la interfaz (pausa, resultados) solo salen en la principal.

## 7. Render

- `Renderer.encode(views:)`: varias vistas en la misma textura HDR con su viewport, su cámara y su recorte por frustum; una
  sola pasada final de tono PS2. Con una vista es el camino de siempre (mismas llamadas).
- Streaming: cada casilla mide la distancia a la cámara más cercana; el tope de casillas cercanas crece con las vistas.
- Coches de la IA instanciados: anillo de 16 búferes (una entrada por vista y fotograma en vuelo).
- Sonido: `SFXWorld` recibe un coche local y un oyente (su cámara) por jugador.
- Tráfico: frena por todos los humanos y se aparta (o se accidenta) al tocarlos; la policía sigue al jugador 1 [I].

## 8. Rendimiento medido [V]

MacBook Air M4, 2940×1912, prueba 6.1.1 (ciudad), sin rivales de la IA, tráfico mínimo, 30 s con piloto automático.
GPU por fotograma completo; «CPU» incluye la espera a la GPU (la prueba sin ventana espera cada fotograma).

| Jugadores | GPU mediana | GPU p95 | CPU+espera mediana | Llamadas | > 16,7 ms |
|---|---|---|---|---|---|
| 1 | 2,59 ms | 3,06 ms | 3,72 ms | 1 174 | 0 % |
| 2 (horizontal) | 3,47 ms | 4,92 ms | 5,21 ms | 2 792 | 0 % |
| 3 (+ vista aérea) | 3,59 ms | 4,26 ms | 5,74 ms | 5 826 | 0 % |
| 4 (cuartos) | 5,20 ms | 5,82 ms | 7,87 ms | 5 529 | 0 % |
| 4 en 2 pantallas falsas de 1920×1080 | 4,28 ms (las dos) | 5,55 ms | 6,33 ms | — | 0 % |

No hace falta bajar la resolución de cada vista: la resolución dinámica (por pantalla) baja sola si se pasa de 13,5 ms.

## 9. Pruebas sin ventana

```bash
Rockport --split-test 2 --size 2940x1912 --screenshot .build/shots/mp/split2.png        # 2 jugadores (horizontal)
Rockport --split-test 4 --race 6.1.1 --seconds 30 --screenshot .build/shots/mp/city4.png  # 4 jugadores, ciudad
Rockport --split-test 4 --displays 2 --size 1920x1080 --screenshot .build/shots/mp/md4.png  # dos pantallas falsas
Rockport --split-test 2 --unplug-test --screenshot .build/shots/mp/unplug.png             # mando desenchufado
Rockport --quickrace-test --screenshot .build/shots/qr/qr.png                             # pantallas de la carrera rápida
Rockport --quickrace-test --split 2 --screenshot .build/shots/qr/qr2p.png                 # … con «Pulsa START»
```
Capturas `-start`, `-mid`, `-end` (y `-pantallaN` con varias pantallas) y un JSON con los tiempos.

## 10. Archivos

| Archivo | Qué hace |
|---|---|
| `UI/QuickRaceFlow.swift` | Flujo, menús de iconos, arranque de la carrera, prueba `--quickrace-test` |
| `UI/QuickRaceScreens.swift` | Track_Select, Track_Options, Car_Select, vitrina del coche |
| `UI/QuickRaceData.swift` | Pruebas, coches, desbloqueos, ajustes (`settings.json`) |
| `UI/JoinScreen.swift` | «Pulsa START» para unirse |
| `Multiplayer/PlayerDevices.swift` | Dispositivo por jugador: conducción, menús, luz, LED, vibración |
| `Multiplayer/SplitScreen.swift` | Jugadores, coches, cámaras, HUD, vistas, desconexión, sonido |
| `Multiplayer/SplitLayout.swift` | Huecos por número de jugadores y reparto entre pantallas |
| `Multiplayer/SplitHUD.swift` | HUD de un jugador (RaceHUD) |
| `Multiplayer/MultiplayerRace.swift` | Monta la carrera con N humanos |
| `Multiplayer/MultiDisplay.swift` | Ventanas en las demás pantallas |
| `Multiplayer/MultiplayerSettings.swift` | `--displays`, `--players`, `settings.json` |
| `Multiplayer/MultiplayerTests.swift` | `--split-test` |
| Cambios fuera | `Renderer` (vistas), `Engine` (enganches), `TileStreamer` (varias cámaras), `ChaseCamera` (valores de pantalla partida), `FEHud` (tipos partidos), `FERenderer` (marcos y recorte), `RaceSession` (varios humanos y opciones), `Controllers`/`HIDPads`/`MenuInput` (lectura por mando), `AIWorld` (otros humanos) |

## 11. Pendiente

- Probar con mandos reales (sin hardware en estas pruebas): LED de jugador del DualSense, barra de luz por mando, desconexión.
- Logotipos de marca de Car_Select (`CARSELECT_MANUFACTURER_*`): buscar el pack que los trae.
- `Quick_Race_Brief` (partida rápida del juego) y el diálogo de transmisión manual/automática.
- Choques del tráfico con los humanos 2…4 sin frenarlos; la policía solo persigue al jugador 1.
- Menús de la interfaz en las pantallas extra.
- Récords de la carrera rápida (`bestTimes` de la partida) al terminar una prueba.
