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
- Cámara libre (WASD + ratón) y **conducción** del BMW M3 GTR con cámara de persecución.
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
| E / Espacio, Q / Ctrl | Subir y bajar (cámara libre). Espacio = freno de mano en el coche |
| Mayús | Rápido (×5) |
| C | Cambiar entre cámara libre y coche |
| R | Recolocar el coche sobre el suelo |
| G | Tono PS2 sí / no |
| Tab | Soltar o capturar el ratón |
| Esc o ⌘Q | Salir |

### Opciones de arranque

| Opción | Para qué |
|---|---|
| `--data <carpeta>` / `--disc <ID>` | Elegir datos y disco |
| `--grade <n>` | Fuerza del tono PS2 (0 = neutro, 1 = por defecto). También `ROCKPORT_GRADE` |
| `--cam x,y,z,rumbo,inclinación` | Cámara inicial (metros y grados) |
| `--drive` / `--car` | Empezar conduciendo / con el coche aparcado |
| `--scale <f>` | Fija la escala de resolución (sin resolución dinámica) |
| `--quit-after <s>` | Salir solo (pruebas) |
| `--screenshot <png> [--size AxB] [--frames N]` | Sin ventana: carga, dibuja y guarda una captura |
| `--bench [--seconds N] [--size AxB]` | Sin ventana: vuelo a 250 km/h y tiempos por fotograma |
| `--autodrive <s>` | Con `--drive` y `--screenshot`: acelera s segundos sobre la colisión real y lo resume |
| `--near <m>` | Depuración: radio del nivel cercano (`--near -1`: solo nivel lejano) |
| `--carcam ox,oy,oz,tx,ty,tz` | Cámara fija respecto al coche (X adelante, Y izquierda, Z arriba) |
| `--audit` | Carga todas las casillas y comprueba geometría y texturas |

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
│  ├─ Car.swift             coche: ruedas, pintura, conducción arcade
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
Se cambia sin compilar con `--grade <n>` o `ROCKPORT_GRADE`, y con la tecla G en marcha.

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
- Conducción arcade igual que `viewer/src/drive.ts`. **No es la física del juego.**
- Suelo: triángulos de colisión en celdas de 8 m. Muros: segmentos verticales.

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
- Algunos objetos lejanos del fondo parecen flotar sobre el horizonte (decorados de fondo del nivel lejano) [I].
- El nivel lejano usa color medio de textura: se nota el salto al entrar una casilla cercana.
- La luz del coche es la del visor, no la del juego: el juego usa mapas de entorno [D].
- Llantas, alerones y tomas de techo de tuneo (packs `WHEELS`, `SPOILER`, `ROOF`) aún no se montan: el coche va de serie.
- El conductor del BMW (`4e8cf857`) no tiene textura en el disco: sale gris oscuro, como en el visor [V].
- No hay mando, sonido, tráfico, policía, carreras ni menús.
- La conducción es un prototipo arcade, no la física de la decomp.

## Camino al DMG jugable (siguientes pasos)

1. ✅ **Instalador de primer arranque** y `scripts/make-dmg.sh` (ver arriba).
2. **Firma Developer ID y notarización**: necesita una cuenta de Apple Developer (de pago). Sin ella, el `.dmg` funciona pero macOS avisa la primera vez (clic derecho → Abrir).
3. **Mando** (GameController) y volante; ajustes de vídeo (tono PS2, escala, FOV).
4. **Física real** desde la decomp (`zPhysics`, `zDynamics`) y atributos VLT de cada coche.
5. **Audio** (EA SCHl/MPC) y música.
6. **Garajes sin carga** (ya hechos en el visor) y selección de coche.
7. **Carreras y Lista Negra** con `gameplay.json` + `roads.json`.
8. Rendimiento extra: texturas comprimidas (ASTC/BC7), oclusión por secciones del juego, búferes de argumentos.
9. Sombra y luces del coche más fieles; reflejos del entorno.

## Propósito

Demostrar que los datos abiertos de `map-data/` bastan para un motor nativo.
Dar una base limpia en Swift + Metal para llegar a un `.dmg` jugable, sin emulador y sin el binario de PS2.
