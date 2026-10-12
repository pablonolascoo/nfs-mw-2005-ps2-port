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
- Texturas, transparencias con recorte, sombras horneadas, carteles con mezcla, aditivos y agua [V].
- Cielo con degradado y plano de mar, como el visor web [H: el juego pinta un plano de mar].
- **Tono PS2**: pasada final cálida, amarillenta, con negros levantados. Se ajusta con un solo número.
- Cámara libre (WASD + ratón) y **conducción** del BMW M3 GTR con cámara de persecución.
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
| `carside.png`, `cartop.png` | El coche con sus 4 ruedas y la sombra de contacto |
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
| `--near <m>` / `--far-scale <f>` | Depuración: radio del nivel cercano / brillo del lejano |

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
- Muestreador por textura: repetir o recortar al borde, por eje (TilableUV del juego).
- Imágenes por URI (casillas) o embebidas (coches).
- Ignora la rotación −90° en X del nodo raíz: todo queda en coordenadas del juego, Z arriba.
- Vértice de 32 bytes: posición, UV, color en half, normal en 8 bits.

### 2. Texturas (`TextureCache.swift`)
- PNG con ImageIO **sin premultiplicar** el alfa. Muchas texturas son "moduladas": alfa ≈ 0 pero opacas.
- Mipmaps con filtro de caja en el hilo de carga. Subida a memoria privada de GPU con un blit.
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
3. Coche opaco: luz simple (hemisférica + sol + brillo en la pintura).
4. Mar: plano a z = −0,2 con olas suaves.
5. Sombras horneadas (`sombra`, texturas `SHD_*`) con sesgo de profundidad; sombra de contacto del coche.
6. Mezcla normal (`mezcla`, `recorte_mezcla`: carteles, pintadas, ramas).
7. Aditivos (`aditiva`). 8. Agua del mapa (`agua`, UV que se mueve). 9. Cristales del coche.

- Profundidad invertida con plano lejano infinito: precisión para 6 km de ciudad.
- Niebla lineal hacia el color del horizonte (1200–9000 m).
- El nivel lejano se oscurece ×0,45 para casar con el cercano [V: medido en la misma vista].

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
- Modelo `cars/BMWM3GTRE46.glb`. El modelo trae una sola rueda (`*_TIRE_*`).
- Cuatro ruedas con `cars.json` → `tires`: cara exterior en |y| = TireOffsets.y [D: CarRender.cpp].
- Las del otro lado se reflejan. Las delanteras giran al virar; todas ruedan.
- Pintura en los materiales `role = pintura`. Se ocultan las tarjetas de llanta de tuneo (`role = llanta`).
- Conducción arcade igual que `viewer/src/drive.ts`. **No es la física del juego.**
- Suelo: triángulos de colisión en celdas de 8 m. Muros: segmentos verticales.

## Rendimiento medido

MacBook Air M4 (16 GB), pantalla a 2940×1912 píxeles. Compilación release. [V]

| Prueba | Resultado |
|---|---|
| App a pantalla completa, vista de partida | **60 fps** estables, GPU 5,6–5,9 ms, CPU 1,1–1,5 ms, escala 1,0 |
| Captura fija 1920×1080 | GPU mediana 4,0 ms, ~1400 llamadas, 0,67 M triángulos |
| Vuelo a 250 km/h, 20 s, 1920×1080 | GPU mediana 3,2 ms (p95 6,6), 0,2 % de fotogramas > 16,7 ms |
| Vuelo a 250 km/h, 20 s, 2940×1912 | GPU mediana 3,9–5,0 ms (p95 8,4–9,5), 0,4–3 % > 16,7 ms |
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
- La luz del coche es una aproximación; el juego usa mapas de entorno.
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
