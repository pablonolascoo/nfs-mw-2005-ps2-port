# Rockport · motor nativo para macOS

> [English version](README.en.md)

Primera versión nativa del port de **Need for Speed: Most Wanted (2005, PS2)** para Mac.
Es una app de verdad: **Swift + AppKit + Metal**. No es una web ni usa un navegador.
Pantalla completa, sin menús alrededor del juego, a la resolución real de tu pantalla.

Lee los datos que genera `tools/` desde **tu propia ISO**. Aquí no hay ningún dato del juego.

Etiquetas: [V] verificado en bytes o medido · [D] sacado de la decomp · [I] inferido · [H] hipótesis.

## Qué hace hoy

- Abre Rockport entero a pantalla completa, a 60 fps con vsync [V].
- Carga las casillas de 400 m alrededor de la cámara en hilos de fondo, sin tirones [V].
- Texturas, recorte alfa con el umbral del juego (`0x28`), pintadas y cristales con mezcla, sombras horneadas, aditivos y agua [V][D].
- Repetición o recorte al borde por textura y por eje (TilableUV del juego) [V].
- Cielo con degradado y plano de mar, como el visor web [H: el juego pinta un plano de mar].
- **Tono PS2**: pasada final cálida, amarillenta, con negros levantados. Se ajusta con un solo número.
- Cámara libre (WASD + ratón) y **conducción** del BMW M3 GTR con la **física del juego**, mando y cámaras de persecución del juego.
- El coche se monta como el juego: una pieza por ranura, ruedas y frenos con las medidas de `cars.json` [D].
- El coche pisa la **colisión real** del juego (`collision/*.bin`) y choca con sus muros [V].
- Modo sin ventana para sacar capturas y medir rendimiento (`--screenshot`, `--bench`).

## Capturas

Se generan en `native-engine/.build/shots/` (no se suben a git):

| Archivo | Qué muestra |
|---|---|
| `city.png` | Vista de partida (refugio 1), casillas cercanas y lejanas |
| `street.png` | A pie de calle: vallas con recorte alfa, árboles |
| `drive.png` | Conduciendo el BMW M3 GTR, cámara de persecución |
| `drive-grade0.png` | Lo mismo sin tono PS2 (`--grade 0`), para comparar |
| `drive-moving.png` | Tras 6 s de conducción automática (`--autodrive 6`) |
| `carside.png`, `car34.png` | El coche de lado y de tres cuartos (`--carcam`) |
| `carwheel.png` | Rueda delantera de cerca: llanta, disco y pinza |
| `aerial.png` | Toda la ciudad desde 900 m (nivel lejano) |

## Cómo se compila y se arranca

Necesitas macOS 14 o superior y las herramientas de Xcode (Swift 5.9+). No hace falta abrir Xcode.

```bash
cd native-engine
swift build -c release                         # compila (≈1 min la primera vez)
./.build/release/Rockport --data ../map-data/SLES-53559
./scripts/make-app.sh                          # monta .build/Rockport.app (firma local)
open .build/Rockport.app --args --data "$PWD/../map-data/SLES-53559"
```

Si no pasas `--data`, busca los datos en este orden:
1. `--data <carpeta>` (la carpeta `<ID>` o su carpeta padre).
2. La variable `ROCKPORT_DATA`.
3. `~/Library/Application Support/Rockport/<ID>/` (lo que usará el instalador).
4. En desarrollo: `map-data/<ID>/` subiendo desde la carpeta actual o desde el ejecutable.

Los datos se generan antes con `cd tools && bun run build-all <tu ISO>` (ver `CONTEXT.md`).

### Controles

| Tecla | Acción |
|---|---|
| Ratón | Mirar |
| W A S D / flechas | Moverse (o acelerar, frenar y girar en el coche) |
| E / Espacio, Q / Ctrl | Subir y bajar (cámara libre). En el coche: E/Q cambio de marcha, Espacio freno de mano |
| Mayús | Rápido (×5). En el coche: nitro (también N) |
| X · V | Coche: mirar atrás · cambiar de cámara (parachoques, capó, cerca, lejos) |
| C | Cambiar entre cámara libre y coche |
| R | Recolocar el coche (parado, sobre el suelo) |
| Mando | Xbox, PS3/PS4/PS5, adaptadores de PS2 y HID genéricos: ver [doc 15](../docs/es/15-mandos.md) |
| DualShock 4 / DualSense | Barra de luz como opción de tuneo y colores de persecución; radio de la policía por su altavoz: [doc 15 §7–8](../docs/es/15-mandos.md) |
| Tab | Soltar o capturar el ratón |
| Esc o ⌘Q | Salir |

### Opciones de arranque

| Opción | Para qué |
|---|---|
| `--data <carpeta>` / `--disc <ID>` | Elegir datos y disco |
| `--grade <n>` | Solo desarrollo: fuerza del tono PS2. En el juego va **siempre** a 1 y no se puede quitar. También `ROCKPORT_GRADE` |
| `--cam x,y,z,rumbo,inclinación` | Cámara inicial (metros y grados) |
| `--drive` / `--car` | Empezar conduciendo / con el coche aparcado |
| `--scale <f>` | Fija la escala de resolución (sin resolución dinámica) |
| `--quit-after <s>` | Salir solo (pruebas) |
| `--screenshot <png> [--size AxB] [--frames N]` | Sin ventana: carga, dibuja y guarda una captura |
| `--bench [--seconds N] [--size AxB]` | Sin ventana: vuelo a 250 km/h y tiempos por fotograma |
| `--autodrive <s>` | Con `--drive` y `--screenshot`: acelera s segundos sobre la colisión real y lo resume |
| `--near <m>` | Depuración: radio del nivel cercano (`--near -1`: solo nivel lejano) |
| `--carcam ox,oy,oz,tx,ty,tz` | Cámara fija respecto al coche (X adelante, Y izquierda, Z arriba) |
| `--car-preset <NOMBRE>` | Coche del juego de `presets.json`: `M3GTRCAREERSTART` (por defecto), `RAZORMUSTANG`, `BL2…BL15`, `ninguno` |
| `--audit` | Carga todas las casillas y comprueba geometría y texturas |
| `--race <ID>` · `--career` | Empezar directamente una carrera rápida (EventID «15.1.1») · entrar en la carrera profesional |
| `--race <ID> --players N` · `--displays all\|1\|2` | Pantalla partida de N jugadores (2…4): primero «Pulsa START» para repartir los mandos · pantallas a usar (no se guarda; `settings.json` → `multiplayer.displays`) |
| `--split-test N [--race ID] [--seconds S] [--displays D] [--unplug-test] [--screenshot base.png]` | Sin ventana: N jugadores con piloto automático; capturas `-start/-mid/-end` por pantalla, tiempos de GPU/CPU y JSON |
| `--quickrace-test [--split N] [--screenshot base.png]` | Sin ventana: recorre las pantallas de la carrera rápida (y «Pulsa START») hasta la salida, con una captura de cada una |
| `--race-test <ID> [--autodrive] [--seconds N] [--opponents N] [--screenshot base.png]` | Sin ventana: corre la prueba con piloto automático; posiciones, tiempos, capturas `-start/-mid/-results/-finish` y JSON |
| `--garage-test <zona> [--garage-mode drive\|inside\|list] [--garage-screen S] [--screenshot base.png]` | Sin ventana: entra en un garaje (doc 07 §3.4) |
| `--career-test [--save ruta]` · `--race-audit` | Sin ventana: Lista Negra simulada 15 → 1 · rutas de todas las pruebas frente a `RaceLength` |
| `--physics-test [COCHE] [--physics-trace]` | Sin ventana: física del juego en un plano: 0–100, punta, frenada, curva, freno de mano, NOS |
| `--lightbar paint\|police\|heat\|off\|custom:RRGGBB` | Modo de la barra de luz del mando en esta sesión (no se guarda). También `ROCKPORT_LIGHTBAR` |
| `--radio-out auto\|pad\|mac\|off` · `--radio-log` | Por dónde suena la radio de la policía · escribir cada frase en la consola |
| `--audio-devices` · `--radio-test` · `--pad-audio-test` · `--lightbar-test` | Sin ventana: salidas de audio y mandos · radio del disco (contra vgmstream) · Opus/SBC/informes HID del mando · colores de la barra |
| `--sound-off` · `--volume 0…1` | Sonido del juego apagado · volumen general (también en `settings.json` → `"sound"`) |
| `--sound-dump` · `--sound-test [COCHE]` · `--sound-trace` · `--sound-live [s]` | Sin ventana: bancos y motores decodificados (contra vgmstream) · recorrido con guion renderizado a `.build/sound-test/<COCHE>.wav` · traza de RPM y mezcla · salida real del Mac unos segundos (con `--volume 0` no se oye) |

## Estructura de carpetas

```
native-engine/
├─ Package.swift            paquete Swift (un ejecutable, sin dependencias externas)
├─ VERSION                  versión de la app
├─ scripts/make-app.sh      monta Rockport.app con su Info.plist
├─ Sources/Rockport/
│  ├─ main.swift            argumentos, modo sin ventana (--screenshot, --bench), PNG
│  ├─ App.swift             ventana sin bordes a pantalla completa, MTKView, entrada, resolución dinámica
│  ├─ Engine.swift          estado del juego: cámara libre, coche, streaming, fotograma
│  ├─ Config.swift          TODOS los ajustes (tono PS2, radios, presupuesto de GPU, cielo, niebla)
│  ├─ GameData.swift        dónde están los datos y lectura de world.json, zones.json, cars.json
│  ├─ GLB.swift             lector GLB mínimo (solo lo que escribe tools/src/lib/glb.ts)
│  ├─ TextureCache.swift    PNG → textura Metal con mipmaps, caché compartida
│  ├─ Mesh.swift            búferes de GPU por GLB y tramos de dibujo por material
│  ├─ TileStreamer.swift    casillas de 400 m: lejanas siempre, cercanas por distancia
│  ├─ Renderer.swift        pasadas Metal y orden de dibujo
│  ├─ Shaders.swift         shaders Metal (se compilan al arrancar)
│  ├─ Collision.swift       colisión NFSC v1: suelo y muros
│  ├─ Car.swift             coche: ruedas, pintura, pose de la física interpolada
│  ├─ Physics/              física del juego (doc 13): RigidBody, Tire, SuspensionRacer, EngineRacer, PVehicle, prueba
│  ├─ Input/                teclado y mandos (doc 15): GameController, IOKit HID, luz, gatillos, vibración
│  ├─ Camera/               cámara de persecución con las vistas camerainfo del juego (y las de pantalla partida)
│  ├─ Garage/               fondo de los menús y garajes sin carga: escenario, cámara del frontend, menús, tuneo (doc 07)
│  ├─ Multiplayer/          pantalla partida: mando por jugador, vistas, HUD partido, varias pantallas (doc 19)
│  └─ MathUtil.swift        matrices, cajas, frustum
└─ .build/                  salida de compilación y capturas (ignorado por git)
```

### Datos del usuario y futuro instalador

La app nunca escribe dentro de sí misma. Los datos convertidos viven fuera:

```
~/Library/Application Support/Rockport/
└─ SLES-53559/              misma estructura que map-data/<ID>/
   ├─ world.json  zones.json  cars.json  garages.json  roads.json
   ├─ tiles/  textures/  cars/  interiors/  groups/  collision/
```

### Instalador de primer arranque (`Installer.swift` + `tools/src/cli/install.ts`)

```
Rockport.app/Contents/
├─ MacOS/Rockport                 este motor
├─ Resources/rockport-convert     tools/src/cli/install.ts compilado con `bun build --compile` (~60 MB, firmado)
└─ Info.plist
```

1. La app no encuentra datos y lleva `rockport-convert` dentro → muestra la pantalla del instalador (negro y ámbar, sin menús).
2. «Elegir mi ISO de PS2» → `NSOpenPanel`.
3. **Detección del disco** (`DiscProbe`): lee el ISO9660, busca `SYSTEM.CNF` y saca el ID de `BOOT2` [V con las dos ISOs]:
   PAL `SLES-53559` o NTSC-U `SLUS-21351`. Otro disco → aviso «no probado». Algo que no es ISO de PS2 → error.
4. Lanza `rockport-convert install <iso> <ID> <destino>`. Cada paso corre en un proceso nuevo del mismo binario.
   La barra avanza con las líneas `PASO i/n · nombre`.
5. Todo se escribe en `~/Library/Application Support/Rockport/<ID>/` (también el inventario). La ISO no se copia ni se toca.
6. Al terminar escribe `install.ok`. Una instalación a medias (hay `install.log` sin `install.ok`) se repite en el siguiente arranque.
7. Arranca el juego directamente.

Para probar la detección sin abrir la app: `.build/release/Rockport --probe ruta/a/tu.iso`.
Para montar el `.dmg`: `scripts/make-dmg.sh` → `.build/Rockport-<versión>.dmg`.
Sin datos y sin conversor dentro (desarrollo), la app muestra un aviso con las rutas buscadas.

## Cómo funciona

### 1. Lector GLB (`GLB.swift`)
- Solo entiende lo que genera `tools/src/lib/glb.ts`. Por eso es corto y rápido.
- Lee posiciones, normales, UV, `COLOR_0` (puede pasar de 1: luz horneada del PS2 [V]) e índices.
- Materiales: `baseColorFactor`, textura, `alphaMode`, `alphaCutoff`, `extras.blend`, `extras.role`.
- Nodos de coche: `extras.pieza` (ranura, kit, estilo, de serie) y `extras.marcadores` (matrices del juego).
- Muestreador por textura: repetir o recortar al borde, por eje (TilableUV del juego).
- Imágenes por URI (casillas) o embebidas (coches).
- Ignora la rotación −90° en X del nodo raíz: todo queda en coordenadas del juego, Z arriba.
- Vértice de 32 bytes: posición, UV, color en half, normal en 8 bits.

### 2. Texturas (`TextureCache.swift`)
- PNG con ImageIO **sin premultiplicar** el alfa. Muchas texturas son "moduladas": alfa ≈ 0 pero opacas.
- Mipmaps con filtro de caja en el hilo de carga. Subida a memoria privada de GPU con un blit.
- Texturas con alfa útil: el color de los texeles vacíos se rellena con el de sus vecinos y los mipmaps se ponderan por el alfa. Así no salen bordes negros en hojas, vallas y pintadas.
- Formato sRGB: la GPU pasa a lineal al leer.
- Cola de subida propia: el hilo principal nunca espera a una subida [V: sin ella había parones de 38 ms].
- Caché por ruta: cada textura se carga una vez.

### 3. Streaming (`TileStreamer.swift`)
- Igual que el visor web (`viewer/src/main.ts`).
- Al arrancar se cargan las 212 casillas **lejanas** (color de vértice, ~0,9 M triángulos).
- Las casillas **cercanas** (con textura) entran a menos de 650 m de la cámara, máximo 28.
- Se liberan a más de 1100 m tras 5 s sin usarse.
- Todo se lee y se prepara en hilos de fondo. El hilo principal solo recoge casillas listas.
- Cada casilla es un búfer de vértices y uno de índices, con un tramo por material.

### 4. Pasadas de dibujo (`Renderer.swift`)
1. Cielo: degradado según la altura de la mirada (colores del visor).
2. Opacos y recorte alfa (vallas, árboles): escriben profundidad.
3. Coche opaco: la misma luz que el visor (hemisférica + sol, difusa Lambert y especular GGX).
4. Mar: plano a z = −0,2 con olas suaves.
5. Sombras horneadas (`sombra`, texturas `SHD_*`) con sesgo de profundidad; sombra de contacto del coche.
6. Mezcla normal (`mezcla`, `recorte_mezcla`: carteles, pintadas, ramas).
7. Aditivos (`aditiva`). 8. Agua del mapa (`agua`, UV que se mueve). 9. Cristales del coche.

- Profundidad invertida con plano lejano infinito: precisión para 6 km de ciudad.
- Niebla lineal hacia el color del horizonte (1200–9000 m).
- El nivel lejano ya no se oscurece: su color sale del conversor igual que el cercano [V: medido en la misma vista].

### 5. Tono PS2 (pasada final, `fs_post` en `Shaders.swift`)
La escena se dibuja en una textura HDR. La pasada final la escala a la pantalla y aplica el tono.
Trabaja en espacio de pantalla (gamma), en tres pasos:
1. **Negros levantados** con un toque cálido (la salida analógica del PS2 casi nunca daba negro puro [I]).
2. **Tinte amarillo/ámbar** en medios tonos y luces, no en sombras.
3. **Saturación** algo más baja, conservando los tonos cálidos.

Un solo número lo controla todo: `Config.ps2GradeStrength` (por defecto 1).
0 = imagen neutra. 1 = tono por defecto. Más de 1 = exagerado.
Va siempre activo en el juego. Solo para desarrollo se cambia con `--grade <n>` o `ROCKPORT_GRADE`.

### 6. Resolución dinámica y vsync (`App.swift`)
- La salida siempre es la resolución real de la pantalla (píxeles Retina).
- La escena se dibuja a una fracción (0,5–1,0) según el tiempo de GPU del último fotograma.
- Objetivo: 13,5 ms de GPU, por debajo de los 16,7 ms de 60 Hz. Vsync activado.

### 7. Coche (`Car.swift`, `Collision.swift`)
- Modelo `cars/BMWM3GTRE46.glb`, de serie, con la pintura del jugador (`Config.playerPaint`).
- **Una pieza por ranura** (`Car.visibleParts`, copia de `applyCarConfig` del visor) [D: CarInfo.cpp, CarRender.cpp]:
  - el kit pedido sustituye al KIT00 solo en las ranuras que trae;
  - fuera daños (`dano`), zonas de vinilo (`calcomania`) y el soporte de alerón de tuneo;
  - un panel `DAMAGE0` es la carrocería intacta (policía): solo se ve si la ranura no tiene pieza normal.
- **Ruedas** como `mountWheels` del visor [D: CarRender.cpp 1855-1999]:
  - un solo modelo (`FRONT_TIRE`, o `REAR_TIRE` detrás) colocado cuatro veces;
  - radio `TireOffsets.w`, ancho `skidWidth × kitWidthScale`;
  - la cara de la llanta en |TireOffsets.y| (+ `kitOffsetFront/Rear` en mm hacia fuera);
  - lado izquierdo girado 180° (o en espejo si `spokes & 0x80`);
  - caída `camber × 7°`; altura del eje `z + feCompression − camber × 0,03`.
- **Frenos** (`FRONT_BRAKE`/`REAR_BRAKE`) en el marcador de la rueda, sin escala de radio, en espejo a la izquierda.
- Piezas en GPU: 0 carrocería, 1–4 ruedas (giran y viran), 5–8 frenos (solo viran).
- Las tarjetas de llanta ya se dibujan: el conversor arregló su orientación.
- `BMWM3` toma los atributos de `bmwm3gtr` (no tiene colección propia) [V: cars.json].
- Luz: la del visor (`HemisphereLight` + `DirectionalLight`, `MeshStandardMaterial`). Pintura: metal 0,45, rugosidad 0,32.
- Conducción: **la física del juego** portada de la decomp (ver «Física del juego» abajo y el doc 13). Sin `physics.json`, el prototipo arcade de antes.
- Suelo: triángulos de colisión en celdas de 8 m. Muros: segmentos verticales.

## Coches del juego: presets, vinilos y piel compuesta (2026-10-15)
- `CarSkin.swift` lee `presets.json` (82 presets de `GLOBAL\GLOBALB.BUN`: Lista Negra `RAZORMUSTANG`, `BL2…BL15`, el BMW de la historia `M3GTRCAREERSTART`…) y compone la carrocería como `CarSkin.cpp`: color base (alfa = brillo) + vinilo con su máscara (`m ≥ 128` → vinilo, `0 < m < 128` → mezcla `m/128`). Se compone en CPU a 1024×1024 (el doble del PS2) con muestreo bilineal y se sube con mipmaps. La misma piel va al alerón y a la toma de techo.
- `Car.swift` con preset: monta exactamente los sólidos del preset (kit, capó), la llanta de `WHEELS.glb`, el alerón (`SPOILER*.glb`) y la toma de techo (`ROOF.glb`) en los marcadores `SPOILER`/`ROOF_SCOOP` de la pieza BASE; tiñe la llanta con `PAINT_RIM` (máscara `_WHEEL_INNER_MASK`), oscurece los cristales según el tintado [I] y elige metalicidad/rugosidad por acabado (GLOSS/METAL/PEARL) [I].
- El jugador lleva por defecto el BMW M3 GTR de la historia (plata + franjas azules). `--car-preset RAZORMUSTANG` (o `BL2…BL15`, `ninguno` = de serie) y `--carcam` para capturas. Tráfico y policía no cambian (su `SKIN1` es una textura real del disco).
- Detalle de formatos y la tabla de la Lista Negra: [docs/es/10-coches.md §8](../docs/es/10-coches.md).

## HUD original al 100 %, radar y pantallas de carrera (2026-10-15)

- El HUD es **solo** el del juego (`HUD_SingleRace` / `HUD_Drag`) con la lógica de `FEngHud`: todo invisible al crearlo y cada
  elemento enciende solo lo que registra según `DetermineHudFeatures`. El HUD propio (`HUDPursuit.swift`) queda para `--debug-hud`.
- **Radar** con los mapas del disco (`TRACKS\L2RA\MINI_MAP*.BIN`, 267, uno por prueba con la ruta), calibrado con `TrackInfo` 2000;
  gira con el coche, iconos de policía (parpadeo azul/rojo en persecución), rivales y punto de control. Sin zoom por velocidad (la decomp lo deja fijo).
- **Persecución**: tiempo, recompensa, policías, barra ARRESTADO/EVADIDO, ZONA SEGURA, C.P.E.; la barra naranja rayada era el
  fondo de «REFUERZOS» que no se recortaba al irse (repetición de textura: ahora `TilableUV`). Arresto: «ARRESTADO» + cámara de la
  policía (`BUSTED_OVERLAY`); evasión: «BOLSA CONSEGUIDA» (`PostRace_MilestoneRewards`).
- **Carreras**: API `RaceHUD` (`UI/RaceHUD.swift`, `engine.raceHUD`): cuenta atrás, posición, vueltas, tiempo, tabla, radares, peajes,
  aceleración, mensajes, resultados (`PostRace_Results`), Lista Negra (`InGameReputationOverview` con retratos de `RIVALS.BIN`) y coche ganado.
- Modo panorámico del juego (radar a la izquierda, cuentarrevoluciones a la derecha), ajustado a 16:10.
- `--traffic-test` dibuja el HUD original. Capturas: `--ui-test HUD-chase|HUD-cooldown|HUD-busted|HUD-evaded|Race-<tipo>|Results|Blacklist|CarWon`
  → `.build/shots/hud/`. Necesita datos con formato 4 (paso «Interfaz del juego»). Detalle: [doc 17 §8](../docs/es/17-interfaz.md).

## Interfaz original del juego: menús y HUD (2026-10-15)

- La app arranca con las **pantallas del propio juego** (paquetes FEng `.fng` del disco): «Pulsa START» → menú principal →
  Modo carrera (Continuar / Empezar nuevo) → zona libre con el **HUD original** (cuentarrevoluciones, velocímetro, nitro, calor,
  panel de persecución). Start o Esc: menú de pausa del juego (volver, reiniciar, opciones, salir). ⌘Q sale.
- Textos y fuentes del disco: castellano en PAL, inglés en NTSC-U. Las demás opciones abren el cuadro del juego con «Próximamente.».
- A resolución nativa: lienzo 640×480 escalado con su aspecto; imágenes con bicúbica Catmull-Rom; letras con campo de distancias
  (SDF ×4 del conversor). Se dibuja después del tono PS2, como en el PS2.
- Código en `Sources/Rockport/UI/`; datos del paso `frontend` de `tools/`. `--no-ui` la quita; `--ui-test <pantalla>` saca capturas
  (`.build/shots/ui/`). Formato, decisiones y lo que falta: [doc 17](../docs/es/17-interfaz.md).

## Carreras y Lista Negra (2026-10-15)

- **Datos**: paso `races` de `tools/` → `races.json` (254 pruebas, 20 bins, 94 desafíos, vallas de TrackPath de `L2RA.BUN`);
  formato de datos 4. La colisión de los grupos ocultos (vallas, candados) va aparte en `collision/groups/`: antes eran muros
  invisibles en la zona libre.
- **Motor** (`Race/`, `Career/`): ruta por la red de carreteras cerrada por las vallas de cada prueba (mediana 0,997 de la
  longitud del juego), vallas dibujadas y con colisión, rivales con la física del juego y el conductor de la IA del juego
  (velocidad por curvatura, PID de gas y dirección, habilidad, rubber-banding «glue», NOS), los 7 tipos de prueba, cuenta atrás,
  posiciones, vueltas, eliminaciones, radares, peajes, drag con cambio manual y carriles, sentido contrario, reinicio, policía y
  tráfico por prueba, resultados y recompensas.
- **Carrera profesional**: Lista Negra 15 → 1 con `RequiredRacesWon` / `RequiredChallenges` (hitos + radares de la zona libre)
  / `RequiredBounty`, carreras del rival, coche ganado, candados de distrito por bin y partida en
  `~/Library/Application Support/Rockport/save.json`. Marcadores de prueba en el mundo (Intro / ✕ para empezar).
- **API para los menús**: `Career.shared.start()` / `newGame()` / `showBlacklist()`, `QuickRace.shared.start(eventID:)`,
  `RaceSystem.shared?.abandon()`. El HUD lo pone la interfaz (`UI/RaceHUD.swift`).
- **Pruebas**: `--race-test <ID> --autodrive --screenshot base.png`, `--career-test`, `--race-audit`. Detalle y resultados:
  [doc 18](../docs/es/18-carreras-y-lista-negra.md).

## Garajes sin carga y fondo de los menús (2026-10-15)

- **Fondo de los menús como el juego**: «Pulsa START», el menú principal y el de la carrera muestran el garaje del frontend
  (`PLATFORMCRIB`: azotea industrial con grúas y cúpula del cielo) con el coche del jugador (el de la partida con su tuneo; por
  defecto el BMW M3 GTR de la historia), colocado como `GarageMainScreen` y con la cámara de `GLOBAL\FE_ATTRIB.BIN`
  (`SelectCarCameraMover`: entrada → final → ángulo de cada pantalla, con su giro de cámara) [D][V].
- **Garajes sin pantallas de carga** (`Garage/`): los 15 garajes del juego. Al llegar despacio a la puerta real, el edificio se
  recorta en los shaders del mundo, la persiana sube y el interior del menú ya está dentro; se entra, se aparca y salen los menús
  originales del sitio con la cámara del frontend alrededor del coche: **refugio** (Lista Negra, Mis coches, Guardar),
  **concesionario** (comprar coches con precio y desbloqueo de `FE_ATTRIB.BIN`) y **taller** (pintura, vinilos, llantas,
  alerones, kit y **barra de luz del mando**, montados en el coche al momento). Se sale marcha atrás y la persiana se cierra.
  Los refugios 2, 4 y 5 ya tienen su edificio real (`XB_SafeHouse`, `XB_FishSafehouse`, `XB_TC_SafeHouse`). Mod de ejemplo:
  `mods/garajes-unicos`.
- **Arreglo del conversor**: las tiras con posiciones en float (V4-32) se quedaban en un punto; ahora salen la cúpula del cielo de
  los garajes y **5 071 tiras del mundo** (rascacielos del centro, cielo, montañas del fondo).
- **Carrusel de iconos**: el centro es `OPTION_MASTER` (ensamblador), que además se oculta: ya no se solapan iconos; iconos en
  naranja dentro del juego; flechas que se apagan en los extremos. Lista Negra con su panel de requisitos y recompensa/dinero.
- Pruebas: `--garage-test <zona> [--garage-mode drive|inside|list] [--garage-screen …]`. Detalle:
  [doc 07](../docs/es/07-conduccion-y-garajes.md) y [doc 17](../docs/es/17-interfaz.md).

## Carrera rápida y pantalla partida (2026-10-15)

- **Carrera rápida con las pantallas del juego** (`UI/QuickRace*.swift`, doc 19): menú (Partida rápida / Carrera personalizada /
  Pantalla dividida), tipo de prueba, **Track_Select con el mapa de cada prueba** (`TRACK_MAP_<id>` de `TrackMaps.bin`, zoom a la
  ruta como `UITrackMapStreamer`), zona, longitud y mejor tiempo; **Track_Options** (dirección, vueltas, tráfico, oponentes,
  dificultad, alcanzar y policía); **Car_Select** por jugador con coches de serie (desbloqueo `frontend.UnlockedAt`), el de la
  historia y los de la Lista Negra según la partida; resultados y vuelta al menú.
- **Pantalla partida original** (2 jugadores, horizontal, jugador 1 arriba): HUD `HUD_Player1/2` del disco
  (`INGAMESPLITSCREEN.BUN`), cuentarrevoluciones de barra, radar compartido con el otro coche, cámaras de pantalla partida de
  `camerainfo`. **Extensión**: 3 y 4 jugadores en cuartos (con 3, vista aérea en el cuarto libre), rivales de la IA, tráfico y
  policía opcionales, **varias pantallas** (una ventana por pantalla, 4 en 2 = 2 + 2).
- **Un mando, un jugador** (`Multiplayer/PlayerDevices.swift`): «Pulsa START» (`PressStart.fng`) reparte los mandos; el primero es
  el jugador 1; cada coche lee solo su mando (o el teclado); luz y LED de jugador con su color; vibración por mando; mando
  desenchufado = pausa con `ControllerUnplugged.fng` hasta pulsar START.
- **Render**: varias vistas en la misma textura con una sola pasada de tono PS2; streaming con todas las cámaras. Medido a
  2940×1912 en la ciudad: 2 jugadores GPU 3,5 ms, 4 jugadores 5,2 ms (mediana) [V].
- Pruebas: `--split-test 2|3|4`, `--split-test 4 --displays 2`, `--split-test 2 --unplug-test`, `--quickrace-test [--split 2]`.
  Detalle: [doc 19](../docs/es/19-carrera-rapida-y-multijugador.md).

## Física del juego, mandos y cámara (2026-10-12)

- **Física**: `SuspensionRacer`, `EngineRacer`, `Chassis` y `RigidBody` del juego, en Swift (`Physics/`), a **60 Hz fijos** como el juego
  (`Scheduler::Init(1/60)` [V]) e interpolada al dibujar. Valores de `physics.json` (paso `physics-attribs` de `tools/`).
  Agarre con círculo de fricción, transferencia de pesos por suspensión, derrape con freno de mano, NOS, caja automática. Detalle: [doc 13](../docs/es/13-fisica-conduccion.md).
- **Medidas** (`--physics-test`, BMW M3 GTR, plano) [V]: 0–60 mph 3,03 s · 0–100 km/h 3,12 s · punta 390 km/h (corte en 6.ª) · frenada 100→0 en 14,5 m.
  Referencia del juego: 0–60 mph ≈ 3,9 s [H].
- **Mandos**: Xbox One/Series, DualShock 4, DualSense y MFi por GameController; DualShock 3 (USB), adaptadores de PS2 y HID genéricos por IOKit; aviso para el Xbox 360 (necesita 360Controller).
  Barra de luz, panel táctil, gatillos adaptativos y vibración. Detalle: [doc 15](../docs/es/15-mandos.md).
- **Cámara**: vistas `camerainfo` del coche (parachoques, capó, cerca, lejos); movimiento propio [H] (el del juego no está decompilado).
- **Tono PS2 siempre activo**: se quitó la tecla G.
- Capturas: `.build/shots/drive-physics.png` (curva con balanceo y ruedas giradas) y `.build/shots/drive-cameras.png` (las 4 vistas).

## Sonido del juego: motores, efectos y sirenas (2026-10-15)

- **Bancos del disco** (`tools/src/cli/sound.ts` → `sound/`, `DATA_FORMAT` 5): 301 bancos AEMS `ABKC` y 160 motores granulares `.GIN`
  copiados tal cual; la app decodifica PS-ADPCM, EA-XA v2 y EA-XAS (`Audio/SFXBank.swift`, `EngineGinsu.swift`), idénticos a vgmstream.
- **Motor** (`Audio/EngineSound.swift`): la cadena del juego —RPM de audio por la curva del coche, cambios con sus curvas de RPM,
  mezcla acelerando/desacelerando de dos .GIN (`SFXCTL_HybridMotor`), sintetizador granular Ginsu portado línea a línea—, turbo con
  carga y descargas, nitro, petardeos. Cada coche con su sonido del juego (el BMW M3 GTR suena como el TVR Cerbera, igual que en PS2).
- **Mundo** (`Audio/SFXWorld.swift`, `SFXMixer.swift`): derrapes, viento, rodadura, golpes con los «stitches» del juego, rivales de carrera
  con motor completo, policía con sirena y motor en 3D (Doppler, paneo, filtro por distancia), tráfico con rumor y cláxones.
  Un solo nodo de audio; 0,2 % de un núcleo. Pantalla partida: `localCarsProvider` / `listenersProvider`.
- Detalle y etiquetas: [doc 16 §7–10](../docs/es/16-audio-y-voces.md). Falta la capa AEMS (módulos MIPS) y los mapas de mezcla del juego.

## Barra de luz y radio de la policía (2026-10-15)

- **Barra de luz** (`Input/LightBarConfig.swift`): opción de tuneo por coche —pintura, color propio, policía, calor, apagada— guardada en
  `settings.json`; encima, colores de la persecución con el patrón de las luces de los patrulla del juego (rojo/azul), ámbar/azul en enfriamiento,
  rojo al arrestarte, verde al escapar. API `LightBar.shared` para el menú de tuneo. Detalle: [doc 15 §7](../docs/es/15-mandos.md).
- **Radio de la policía** (`Audio/`): las frases del disco (castellano en PAL, inglés en NTSC), decodificadas por la propia app (MicroTalk),
  elegidas por evento con las tablas `.EVT/.IDX` del juego y disparadas por la persecución (`PursuitFX.swift`). Suena por el altavoz del mando
  si está por USB, por informes HID (Opus / SBC) si está por Bluetooth —sin probar con mando real— y si no por el Mac con filtro de escáner.
  Detalle: [doc 15 §8](../docs/es/15-mandos.md) y [doc 16 §5–6](../docs/es/16-audio-y-voces.md). Necesita datos convertidos con formato 3 (paso «Radio de la policía»).

## Tráfico y policía (2026-10-12)

- **Tráfico** como `AITrafficManager` del juego: patrón de coches por barrio (zonas `TRAFFIC_PATTERN` de `L2RA.BUN`), ritmo, máximos y porcentajes de
  `trafficpattern`, aparición a 200 ± 50 m por delante, carriles de tipo 1 a la derecha del sentido de marcha, sentido único, sin tráfico, cruces al azar,
  35/55 mph en calle/autopista, frenada tras el de delante, accidente al golpearlo. 20 coches a la vez (el PS2: 10 vehículos en total) [D][V].
- **Policía** como `AICopManager` + `AIPursuit`: patrullas, detección con línea de visión, calor 1–5 (`pursuitlevels` heat_01…05), refuerzos,
  formaciones (BOX_IN, PIT, ROLLING_BLOCK, HERD, FOLLOW, STAGGER), embestidas, arresto (5 s bajo `BustSpeed` con un policía a 15 m),
  enfriamiento y evasión, controles de carretera con la tabla de montajes de la decomp y pinchos. Barra de luces roja y azul con la fórmula de `CarRender`.
- **HUD**: el original del juego (ver «HUD original al 100 %»); el HUD mínimo propio solo con `--debug-hud`. El mando se pone rojo y azul en la persecución.
- Datos: `ai.json` (nuevo paso `ai-attribs` de `tools/`) + `roads.json` + `collision/`. Coches con su librea real del disco, dibujados con instancias.
- Prueba sin ventana: `--traffic-test N [--heat H] [--test-plan busted|run|flee] [--screenshot x.png]` → capturas y estadísticas (`x.json`).
  Opciones: `--traffic-max N`, `--no-traffic`, `--no-police`.
- Medido [V]: 19 de tráfico + 12 policías a 2940×1912: GPU 4,3 ms, CPU 1,0 ms; 100 % de los coches sobre el suelo, 0 saltos de carril.
- Detalle, tablas VLT y fuentes: [doc 14](../docs/es/14-trafico-y-policia.md). Capturas: `.build/shots/traffic-*.png`, `heat5-control.png`.

## Cambios con los datos nuevos (2026-10-12)

Qué cambió en el conversor y cómo lo sigue el motor:

| Cambio en los datos | Qué hace ahora el motor | Por qué |
|---|---|---|
| Color de vértice guardado como `(c/128)^2,2` | Fuera la corrección ×0,45 del nivel lejano (`Config.farColorScale`, `--far-scale`) | Medido [V]: lejano/cercano = 0,95–1,2 sin corrección (antes 1,8). Con grado 0 el motor da el mismo color medio que el visor (±2 de 255) |
| Recorte con umbral `0x28` del juego | El recorte usa el `alphaCutoff` del material y pasa si alfa > umbral | `_alphaRef` [D]. Con 0,5 se perdían rejas y ramas |
| Pintadas y cristales con mezcla | Ya iban a la pasada de mezcla; ahora sin bordes negros (relleno y mipmaps por alfa) | Igual que `tile-worker.ts` |
| Repetición por textura (TilableUV) | Ya se leía el `sampler`; verificado con el GLB nuevo | 4 muestreadores (repetir/recortar por eje) |
| Casillas con más de 256 texturas | Sin cambios: el motor no usa arrays de texturas | `--audit` [V]: 212 casillas × 2 niveles, todas con geometría y texturas; la mayor (10_1) tiene 269 |
| Coches con `extras.pieza` y `extras.marcadores` | Una pieza por ranura, ruedas y frenos de la decomp | Antes salían todos los kits, daños y calcomanías a la vez |
| `cars.json` con `skidWidth`, `camber`… | Leídos en `GameData.CarAttribs` | Medidas reales de rueda [D] |

Comparación con el visor (misma cámara, `--carcam`, `--grade 0`) [V]:
- Pintura del lado en sombra: motor (57, 62, 74), visor (59, 63, 74) en sRGB.
- Calle de la captura `street.png`: color medio del motor (76, 76, 72), visor (75, 74, 71).

## Rendimiento medido

MacBook Air M4 (16 GB), pantalla a 2940×1912 píxeles. Compilación release. [V]

| Prueba | Resultado |
|---|---|
| App a pantalla completa, vista de partida | **60 fps** estables, GPU 5,6–5,9 ms, CPU 1,1–1,5 ms, escala 1,0 |
| Captura fija 1920×1080 | GPU mediana 4,0 ms, ~1400 llamadas, 0,67 M triángulos |
| Vuelo a 250 km/h, 20 s, 1920×1080 | GPU mediana 3,2 ms (p95 6,6), 0,2 % de fotogramas > 16,7 ms |
| Vuelo a 250 km/h, 20 s, 2940×1912 | GPU mediana 3,9–5,0 ms (p95 8,4–9,5), 0,4–3 % > 16,7 ms |
| Con los datos nuevos (2026-10-12), vuelo 20 s, 1920×1080 | GPU mediana 3,2 ms (p95 4,4), 0,3 % > 16,7 ms, 722 llamadas |
| Con los datos nuevos, vuelo 20 s, 2940×1912 | GPU mediana 5,3 ms (p95 7,8), 0,9 % > 16,7 ms |
| Coche de cerca, 1600×900 | GPU mediana 2,1–2,7 ms, ~1000 llamadas |
| `--audit`: las 212 casillas, cercanas y lejanas | 2,2 s, 6,6 M triángulos, 2562 texturas |
| Prueba de estrés: ciudad entera con detalle (`--near 6000`) | 60 fps con escala 0,5, GPU ~12 ms, 9300 llamadas, 3,1 M triángulos |
| Carga inicial (lejanas + cercanas de la vista) | 0,5–1 s |

Notas:
- En el vuelo sin ventana cada fotograma espera a la GPU, así que es más exigente que la app real.
- El visor web hacía 60 fps con trucos (arrays de texturas, 2 llamadas por casilla). Aquí no hacen falta.
- La memoria de casillas cercanas ronda 25–40 MB; texturas 35–45 MB en una vista normal.

## Limitaciones conocidas

- Lo que se ve desde el aire entre carreteras es el plano de mar: el mapa del juego solo tiene geometría junto a las calles [V].
- El nivel lejano usa color medio de textura: se nota el salto al entrar una casilla cercana.
- La luz del coche es la del visor, no la del juego: el juego usa mapas de entorno [D].
- Tomas de techo de tuneo (pack `ROOF`) aún no se ofrecen en el taller; llantas y alerones sí (doc 07 §3.3).
- El conductor del BMW (`4e8cf857`) no tiene textura en el disco: sale gris oscuro, como en el visor [V].
- Sonido: sin la capa AEMS de los motores ni los mapas de mezcla del juego (doc 16 §9). Tráfico y policía sin helicóptero ni choques físicos entre coches (doc 14).
- Choques con muros: impulsos propios, no `RigidBody::DoBarrierCollision` del juego (doc 13).
- Mandos sin probar aún con hardware real (doc 15).

## Camino al DMG jugable (siguientes pasos)

1. ✅ **Instalador de primer arranque** y `scripts/make-dmg.sh` (ver arriba).
2. **Firma Developer ID y notarización**: necesita una cuenta de Apple Developer (de pago). Sin ella, el `.dmg` funciona pero macOS avisa la primera vez (clic derecho → Abrir).
3. ✅ **Mando** (GameController + IOKit HID) — falta volante y ajustes de vídeo (escala, FOV).
4. ✅ **Física del juego** desde la decomp y atributos VLT de cada coche (doc 13) — faltan choques del juego, daño y reglajes.
5. **Audio** (EA SCHl/MPC) y música.
6. ~~Garajes sin carga y selección de coche~~ (hecho: doc 07). Falta el mapa de la carrera y la hoja de antecedentes.
7. **Carreras y Lista Negra** con `gameplay.json` + `roads.json`.
8. Rendimiento extra: texturas comprimidas (ASTC/BC7), oclusión por secciones del juego, búferes de argumentos.
9. Sombra y luces del coche más fieles; reflejos del entorno.

## Propósito

Demostrar que los datos abiertos de `map-data/` bastan para un motor nativo.
Dar una base limpia en Swift + Metal para llegar a un `.dmg` jugable, sin emulador y sin el binario de PS2.
