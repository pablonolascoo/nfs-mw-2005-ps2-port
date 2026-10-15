# Películas, subtítulos, colisión del juego y otros formatos de la auditoría

Etiquetas: [V] verificado en bytes con SLES-53559 · [D] decomp · [I] inferido · [H] hipótesis.
Todo esto salió de la auditoría de cobertura (doc 21). Nada de lo exportado se sube a git.

## 1. Películas: qué hay en el disco

- 32 películas × 3 idiomas de audio en la PAL: `MOVIES\<NOMBRE>_<ENGLISH|SPANISH|ITALIAN>_PAL.MPC` [V].
- Las 64 de castellano e italiano eran entradas `_UNKNOWN` del inventario. Sus nombres salen por hash y están en
  `tools/data/filenames-extra.list` [V].
- **La historia y los tutoriales están doblados** al castellano y al italiano [V]. En `STORYFMV_BLA134` la música y los efectos
  son idénticos (correlación 1,000) y la voz cambia (0,1–0,5) justo donde hay diálogo.
- Las 15 de la Lista Negra y la demo son idénticas byte a byte en los tres idiomas. El logo de EA y el aviso PSA cambian.
- Regla del juego [D: `FEObjectCallbacks.cpp CalculateMovieFilename`]: `MOVIES\<nombre>_<IDIOMA>_<PAL|NTSC>`; si no existe en el
  idioma actual, el inglés. En este disco, quien juegue en francés o alemán ve la versión inglesa sin subtítulos (su texto está vacío) [I].

| Tipo | Películas | Duración | Notas |
|---|---|---|---|
| Historia `STORYFMV_*` | 9 | 32 s – 3 min 9 s | Dobladas; subtítulos en 6 idiomas |
| Lista Negra `BLACKLIST_01…15` | 15 | ~30 s | Retratos de rivales; rótulos («Procedencia: …») traducidos |
| Tutoriales `*_TUTORIAL` | 5 | 24–52 s | Doblados; dos líneas de texto por frase en 10 idiomas |
| `EALOGO`, `PSA`, `ATTRACT_MOVIE` | 3 | 3 s, 11 s, 61 s | — |

## 2. Formato MPC [V: comparado con ffmpeg]

Bloques seguidos `{char tag[4], u32 tamaño LE (incluye los 8 B)}` hasta el final del archivo:

| Bloque | Qué lleva |
|---|---|
| `MPCh` | **Una imagen MPEG-2** por bloque. El primero lleva también la cabecera de secuencia (`00 00 01 B3`), su extensión y el comentario «Encoded with MPEG Gimex module» |
| `SCHl` | Cabecera de audio: `GSTR`, 12 B y etiquetas EA desde `0xFD` hasta `0xFF`. `0x80` = 3 (revisión → ADPCM R3, 48 kHz por defecto), `0x85` = nº de muestras, `0x82` = canales |
| `SCCl` | u32 nº de bloques de audio |
| `SCDl` | Audio: u32 BE nº de muestras, u32 BE desplazamiento de cada canal (relativo a esa cabecera) y tramas de 28 muestras |
| `SCEl` | Fin |

- Vídeo: 512×416, 25 fps, código de aspecto 1, GOP de 13 imágenes con imágenes B (`I P B B P B B …`) [V].
- Audio: EA ADPCM «R3», 48 kHz estéreo. Trama: 1 B {coeficiente | desplazamiento} + 14 B de nibbles, o `0xEE` + 2 historias +
  28 muestras PCM big endian. La historia sigue de un bloque al siguiente [D: ffmpeg `adpcm.c`].
- **Nuestro decodificador** (`tools/src/lib/mpc.ts decodeMpcAudio`) da las **1 615 852 muestras × 2 canales idénticas a ffmpeg**
  en `STORYFMV_BLA134_SPANISH` (0 diferencias), en 45 ms [V].

## 3. Subtítulos [V][D]

`SUBTITLES\<película>` = `SubtitleInfo[]` de 8 B [D: `Frontend/SubtitleInfo.hpp`, `SubTitle.cpp`]:

| Desplazamiento | Campo |
|---|---|
| +0 | u16 `startTime` en décimas de segundo; `0xFFFF` = fin |
| +2 | u16 relleno (`0x0087` siempre: basura de la herramienta) |
| +4 | u32 `stringHash` = `bStringHash` de la etiqueta; `0x001A20BA` = `bStringHash("")` = borrar el texto |

- El texto está en la tabla de cada idioma (`LANGUAGES\<IDIOMA>.BIN`, chunk `0x00039000`, doc 17). `LABELS.BIN` da el nombre
  de cada etiqueta: `SUBTITLE_STORY_<n>_<m>` [V].
- **Inglés, holandés, sueco, danés, finés y polaco** traen el texto de la historia. En **castellano, italiano, francés y alemán**
  esas entradas existen pero están **vacías**, porque esas películas van dobladas [V]. Esto explica la duda abierta del doc 16.
- Cuándo los enseña el juego [D: `SubTitler`]: los de la historia solo si el idioma no es el inglés y el texto no está vacío.
  Los de los tutoriales siempre.
- Tutoriales: cada entrada son dos líneas, `bStringHash("_A", hash)` y `bStringHash("_B", hash)` (la cadena se encadena al hash) [V].
- `^` dentro del texto es un salto de línea [V]. `LARGEST.BIN` es, para cada texto, la traducción más larga (para medir cajas) [V].
- Resultado: 30 archivos de subtítulos, 169 frases, 12 idiomas con texto.

## 4. Reproducción en el motor nativo: decisión

**Decisión: reproducir las MPC directamente, sin ffmpeg y sin convertirlas al instalar.**

| Pieza | Cómo | Estado |
|---|---|---|
| Vídeo MPEG-2 | **VideoToolbox de macOS** (`kCMVideoCodecType_MPEG2Video`): decodificador por software que viene con el sistema. Cada bloque `MPCh` se pasa tal cual como una muestra | [V] 807/807 imágenes de `STORYFMV_BLA134` sin errores, ~900 imágenes/s en un M4 (36× tiempo real) |
| Orden de las imágenes | VideoToolbox las devuelve en **orden de decodificación** aunque se pida `EnableTemporalProcessing` [V]. Hay que reordenar con `temporal_reference` de la cabecera de imagen (PTS = inicio del GOP + referencia; `parseMpc().pictures`): guardar la última I/P hasta la siguiente | [V] PTS de salida 0, 3, 1, 2, 6, 4, 5, 9… |
| Audio | Decodificador R3 propio (portar `decodeMpcAudio` a Swift, ~40 líneas) → AVAudioEngine a 48 kHz | TS [V] igual a ffmpeg |
| Datos | `movies.json` guarda `isoOffset` y tamaño de cada archivo: la app lee la película **de la ISO del jugador** sin copiarla (0 s de instalación, 0 MB) | Hecho en el conversor |
| Idioma | Regla del juego: idioma de la app → archivo; si falta, inglés. Subtítulos con la regla de `SubTitler` | Datos en `movies.json` |
| Pantalla | 512×416 a 4:3 con bandas [I] (la PS2 estiraba la imagen a 4:3) | — |

- Por qué no convertir al instalar: un decodificador MPEG-2 en TypeScript sería mucho código y tardaría minutos en 2,3 GB;
  ffmpeg no puede ir dentro de la app (licencia y tamaño). VideoToolbox ya lo hace en el sistema.
- Si el jugador mueve la ISO: la app avisa y sigue sin películas (o, como opción, copia solo las del idioma elegido, ~0,76 GB).
- Otras plataformas [I]: Windows trae decodificador MPEG-2 en Media Foundation (Windows 8+); iOS tiene el mismo VideoToolbox.
- **Hecho en el motor nativo** (`native-engine/Sources/Rockport/Movies/`): ver §13.

## 5. Colisión del juego: `CollisionGeometry::Bounds` [V][D]

`0x8003B900` (contenedor) → un `0x0003B901` por objeto [D: `Physics/Bounds.h`]:

- Relleno `0x11` hasta 16 · `BoundsHeader` 16 B {UCrc32 nombre, i32 nº, i32 resuelto (0), relleno} · `Bounds[n]` de 0x30 B ·
  `PCloudHeader` + nubes de puntos (Vector4) opcionales.
- `Bounds`: +0x00 cuaternión s16 / 32767 · +0x08 posición s16 / 1000 m · +0x0E flags (`Box` 0x40, `Sphere` 0x80,
  `PrimVsWorld` 0x2, `PrimVsObjects` 0x4, `MeshVsGround` 0x10…) · +0x10 semidimensiones s16 / 1000 · +0x16 nº de hijos ·
  +0x17 nube de puntos · +0x18 pivote · +0x1E primer hijo · +0x20 radio f32 · +0x24 UCrc32 superficie · +0x28 UCrc32 nombre.
- `GLOBAL\GLOBALB.BUN`: **83 coches**, 10–14 volúmenes cada uno. Ejemplo del primero: caja raíz 0,99 × 0,58 × 2,24 m (medias),
  dos cajas de carrocería, una caja de suelo `MeshVsGround` y esferas en las esquinas. Los 83 nombres son `attribHash(<COCHE>)` [V].
- `TRACKS\L2RA.BUN`: **405 objetos del mundo** (2 141 volúmenes, 332 nubes de puntos): farolas, señales, vallas que se rompen.
  Su nombre es `attribHash` del modelo de escenario (179 de 405 resueltos, p. ej. `XS_Speed35_1b_00`, `XO_LightPostB_1b_00`) y
  es el UCrc32 al que apuntan los rompibles de `effects.json` (`smokeables[].collision`, doc 24) [V].
- Superficies resueltas por hash: `carbody`, `metal`, `glass`, `wood`, `stone` [V].
- Los usa el motor nativo para los choques coche-coche y coche-objeto (Crash/, doc 13 §12): volúmenes `PrimVsObjects` de cada coche y de cada rompible. El paso `bounds` deja también `crash/WINDOW_DAMAGE0.png`, `DAMAGE0.png` y `COPS_DAMAGED_ICON.png` de GLOBALB (formato 11). Lector `lib/bounds.ts`,
  exportador `cli/bounds.ts` → `bounds.json`.

## 6. Contornos de la zona jugable («troughs») [V][D]

`TRACKS\L2RA\TROUGHBOUNDARY.BIN`: 563 chunks `0x00034190`, uno por contorno [D: `TroughBoundary` en los tipos de PS2]:
+0x08 nombre[80] (`TRN_CP_<zona>_Road_A_nn`, `…_Terrain_…`, `…_Segment`, `…_Hole`) · +0x58 tipo (normal / agujero / anti) ·
+0x5C número · +0x5E padre · +0x60 caja 2D · +0x70 nº de puntos · +0x74 puntos (x, y). El tamaño cuadra en los 563.
484 contornos normales y 79 agujeros, dentro de los límites de Rockport. Uso probable: saber si el coche se salió de la zona
jugable y reiniciarlo [I]. Los exporta `effects.ts` (`effects/troughs.json`, lector `lib/world-extra.ts`, doc 24 §9).

## 7. Suavizado de normales de los coches [V][D]

Dentro de cada sólido de `CARS\<COCHE>\GEOMETRY.BIN` (30 MB en total, lo más grande que faltaba de los coches):

- `0x00134017` `eNormalSmoother`: cabecera de 12 B, **a cero en el disco** (se rellena al cargar).
- `0x00134018` `eSmoothVertex[]` (8 B): u32 hash de la posición · u8 grupo · normal s8×3 / 127. 99,7 % con |n| ≈ 127.
- `0x00134019` `eSmoothVertexPlat[]` (12 B): u32 hash · u32 máscara de grupo [I] · u16 tira | u16 vértice << 16.
  165 846 de 165 846 índices válidos en 5 coches; todos los vértices con el mismo hash están en el mismo sitio (±1 cm).
- Uso [D: `CarRender.cpp eSmoothNormals`]: al montar el coche con piezas de tuneo, promedia las normales de las costuras.
  Lector `lib/smooth-normals.ts`. El port aún no lo aplica.

## 8. Paquetes «MEMO» (`GLOBAL\*MEMORYFILE.BIN`) [V]

Copias de otros archivos para leerlos de una vez: cabecera {0, 0, `0x53219999`, nº} + entradas de 20 B {hash de la ruta,
posición, tamaño, bytes guardados, [H]}. `GLOBALMEMORYFILE` lleva 25 (atributos, `GLOBALB.LZC`, inglés, `.CSI`, la parte
residente de los TPK de coches…); `INGAMEMEMORYFILE` 29 (tablas de la radio, `.FX`, mapas de mezcla). Las 54 son idénticas
byte a byte al original (o a su principio). Lector `lib/memfile.ts`.

## 9. Textos de la tarjeta de memoria (`MEMCARD\LOCALE_*.LOC`) [V]

`LOCH` + `LOCI` (id → índice) + `LOCL` (40 cadenas UTF-16LE). 19 idiomas, más `LOCALE_ENGLISH_ASIAN.LOC` (nombre nuevo).
Lector `lib/loc.ts`. El port guarda en `save.json` y no los necesita.
Los iconos `MEMCARD\*.ICO` son el formato estándar de PS2 (1 074 vértices, textura RLE 128×128: una matrícula de
Rockport «NFSMW»). Lector `lib/ps2icon.ts` [V].

## 10. Ocultación del escenario por sección [V][D]

Dentro de cada sección de `STREAML2RA.BUN` (0x80034100), 9,4 MB que faltaban [D: `World/Scenery.cpp`]:

| Chunk | Qué es | Formato |
|---|---|---|
| `0x00034105` | Árbol de cajas (`SceneryTreeNode`) | 0x24 B: caja f32 mín/máx · s16 nº de hijos · s16 hijos[5]. Hijo ≥ 0 = instancia; < 0 = nodo −hijo. Raíz = nodo 0 |
| `0x00034107` | Oclusión precalculada (`tPrecullerInfo`) | 128 B = 1 024 bits. Bit a 1 = la instancia no se ve con la cámara en la celda `((int)x >> 5 & 31) + ((int)y & 0x3E0)` (32 × 32 celdas de 32 m, se repite cada 1 024 m) |
| `0x00034106` | Instancia → reemplazo (`SceneryOverrideInfoHookup`) | u16 nº de reemplazo · u16 nº de instancia |

- Cada instancia apunta a su tabla de oclusión con s16 en +0x1C (+0x1E = contexto de luz, −1).
- Comprobado: los 137 503 hijos son válidos; las 110 954 instancias se alcanzan una sola vez desde la raíz y caben en la caja
  de su nodo; el índice de oclusión más alto es el último de su tabla en las 1 476 secciones; los 18 902 enganches apuntan a
  instancias y reemplazos que existen.
- Los tipos de PS2 de la decomp dan al nodo una caja de s16 (0x18 B); en el disco es de floats (0x24 B) [V].
- El juego solo usa la oclusión por encima de 40 mph y fuera de las celdas que marca `PRECULLERBOOBOOSCRIPT.HOO` [D].
- Lector `lib/scenery-cull.ts`. El motor nativo dibuja por casillas HLOD y aún no lo necesita; serviría para dibujar menos en
  ciudad.

## 11. Cómo se genera

```bash
cd tools
bun src/cli/movies.ts ../original/SLES-53559.iso SLES-53559 [--srt] [--wav]   # movies.json (+ SRT, + WAV de comprobación)
bun src/cli/bounds.ts ../original/SLES-53559.iso SLES-53559                   # bounds.json
bun src/cli/coverage.ts ../original/SLES-53559.iso SLES-53559 --docs          # doc 21
```

`movies.json`: `movies[]` con `name`, `kind` (historia, lista-negra, tutorial, otro), `video` (imágenes, fps, GOP),
`audioByLanguage.<IDIOMA>` (`path`, `isoOffset`, `size`, `identicalToEnglish`, audio), `differentFromEnglish` y `subtitles`
(`cues[]` con `start`, `end`, `label`, `text.<IDIOMA>` y, en tutoriales, `textB`).

## 12. Pendiente

- Prólogo «D-Day» (pruebas 16.x): sus películas están mapeadas (§13.3) pero las pruebas aún no existen en el port.
- Momento exacto de los tutoriales de persecución y recompensa (el código que los lanza no está en la decomp).
- Usar `bounds.json` en los choques y los contornos «trough» para los reinicios.
- Aplicar el suavizado de normales al montar coches con piezas de tuneo.
- Nombres de 226 de los 405 objetos del mundo de `bounds.json` (el nombre completo no está en el disco: doc 24).

## 13. Reproductor de películas en el motor nativo (`Movies/`)

| Pieza | Archivo | Qué hace |
|---|---|---|
| Catálogo e ISO | `MovieLibrary.swift` | `movies.json`; la ISO se mapea en memoria (4 GB virtuales, solo se lee lo que suena) y cada MPC es un trozo de ella. Busca la ISO en `install.ok` («iso»), `--iso`, `ROCKPORT_ISO` y `original/<ID>.iso` del repo. Sin ISO: aviso una vez y el juego sigue sin películas |
| Contenedor y audio | `MPCFile.swift` | Bloques MPCh/SCHl/SCDl; PTS de cada imagen = base del GOP (cabecera `00 00 01 B8`) + `temporal_reference`; audio EA ADPCM R3 portado de `lib/mpc.ts` |
| Vídeo | `MPEG2Decoder.swift` | VideoToolbox (`kCMVideoCodecType_MPEG2Video`, BGRA compatible con Metal). Cada muestra lleva su PTS; la salida (en orden de decodificación) se reordena con una ventana pequeña |
| Reproducción | `MoviePlayer.swift` | Carga en segundo plano, hilo de vídeo con 12 imágenes por delante, audio por AVAudioEngine a 48 kHz. **El reloj es el audio**: cada fotograma se enseña la última imagen con PTS ≤ reloj (se saltan imágenes si va tarde; nunca se espera al vídeo) |
| Dibujo | `MovieRenderer.swift` | Negro, imagen a 4:3 con bandas, subtítulo abajo (texto blanco sobre caja oscura, como el `SubTitler`) |
| Director | `Movies.swift` | Cola, salto, momentos del juego (§13.3), ajustes `settings.json → "movies": {"enabled", "intro"}` |
| Pruebas | `MovieTests.swift` | `--movie-test` (§13.4) |

### 13.1 Decisiones

- **Sin el tono PS2** [I]: el juego dibuja las películas con su reproductor (FEng `FEMovie`), fuera de la escena y de su
  tratamiento visual; no hay ninguna prueba de que las pasara por el tono del mundo. Se ven tal cual vienen en el MPEG-2.
- **4:3 con bandas** [I]: 512×416 se estira a 4:3 como en la tele; en pantallas anchas, bandas a los lados. Las películas ya
  traen bandas negras dentro de la imagen (formato panorámico dentro del 4:3) [V: capturas].
- Mientras hay película, `Engine.frame` cede el fotograma entero: la simulación, la interfaz y los ganchos del motor esperan;
  el sonido del juego calla y la música se pausa donde estaba («Is Movie Playing» / «NIS Play Mute» del mapa de mezcla,
  `ESndGameState` FMV [D]).
- **Idioma**: el de la interfaz (`frontend/index.json`, en la PAL `spanish`) o `--lang`. Audio: el doblaje de ese idioma si existe;
  si no, el inglés [D]. Subtítulos con la regla del `SubTitler` (§3): con la PAL en castellano la historia va doblada y sin texto;
  los tutoriales y los rótulos de la Lista Negra («Procedencia: Beacon Point») sí salen [V].
- **Volumen** por película: `MovieVolumeArray` del juego [D] (historia 0x50, demo 0x41, logo 0x3C, tutoriales 0x37, aviso 0x32,
  Lista Negra 0x2D, de 0x7F).
- **Salto** con Start / ✕ (A) en el mando o Intro / Espacio / Esc. El logo de EA no se salta [D: `MovieData.Bypassable`];
  las películas del D-Day solo tras 5 s [D: `MoviePlayer_Bypass`].
- El audio doblado dura algo más que el vídeo en algunas películas (`STORYFMV_BLA134`: 33,66 s de audio y 32,28 s de vídeo,
  `PSA` 12,47 / 11,24 s) [V]: la película acaba cuando acaban los dos; la última imagen se queda quieta.

### 13.2 Arranque

`sBootFlowPAL` [D: `FEBootFlowManager.cpp`]: `LS_EAlogo` → `LS_PSA` → `MW_LS_AttractFMV` → `MW_LS_Splash` («Pulsa START»).
La app hace lo mismo antes de «Pulsa START» (`--skip-intro` o `settings.json → movies.intro = false` lo quitan). En «Pulsa START»,
30 s sin tocar nada vuelven a la demo [D: `SplashScreenMovieTimeout` = 30, `DoAttract`]. `INTRO_MOVIE` y `EAHD_BUMPER` no están
en la PAL [V].

### 13.3 Cuándo sale cada película en la carrera

| Momento | Película | Fuente |
|---|---|---|
| Carrera nueva (tras el prólogo) | `STORYFMV_SAF25` → `BLACKLIST_15` | [D] `FEAnyMovieScreen::PlaySafehouseIntroMovie` → `SafeHouseRivalBio` → `uiRepSheetRivalFlow` etapa 5 |
| Rival vencido | `BLACKLIST_<nuevo bin>` (presentación del siguiente rival) | [D] `uiRepSheetRivalFlow::Next` etapa 5: `blacklist_%02d` con el bin actual |
| Al llegar al bin 13 (una vez) | `STORYFMV_RAP30` (la ficha policial) | [D] etapa 6: `!HasRapSheet() && GetCurrentBin() == 13` |
| Prueba 1.5.2 (jefe del bin 1) | `STORYFMV_BLA134` antes | [V] `gameplay.json` IntroMovie |
| 1.8.1 (persecución épica) | `STORYFMV_HER136` antes | [V] IntroMovie |
| 16.1.0 / 16.2.1 / 16.2.2 / 16.2.3 (D-Day) | `RAC01` / `PIN11` (y `BUS12` al ganar) / `CRO06_COH06A` / `RAZ08` | [V] IntroMovie / OutroMovie |
| Desafío 19.8.32 (peaje) | `TOLLBOOTH_TUTORIAL` antes | [V] IntroMovie |
| Primera prueba de aceleración / radar / peaje | `DRAG_` / `SPEEDTRAP_` / `TOLLBOOTH_TUTORIAL` | [D] `InGameAnyTutorialScreen` + `HasDone*Tutorial`; el disparo exacto [I] |
| Primera persecución / primera recompensa | `PURSUIT_` / `BOUNTY_TUTORIAL` | [H] (el juego también los ofrece con △ en los menús, `FEAnyTutorialScreen`) |

- En el menú de la Lista Negra el juego también deja ver la película de cada rival con △ (`uiRepSheetRivalBio`, `__PAD_BUTTON4__`) [D];
  en el port aún no hay esa pantalla.
- Lo visto se guarda en la partida (`save.json → moviesSeen`), para no repetir la ficha policial ni los tutoriales.
- `STORYFMV_DDA01`, `EPI138`, `POL17_MOT21` y `ROC02` están en la tabla de volúmenes del juego pero **no en el disco** [V].

### 13.4 Pruebas y resultados [V: M4, SLES-53559]

```bash
cd native-engine && swift build -c release
.build/release/Rockport --movie-test all                       # 32 películas: vídeo + audio, orden de salida de VideoToolbox, tabla de IntroMovie
.build/release/Rockport --movie-test BLACKLIST_01               # reloj simulado: capturas cada 2 s, audio.wav y stats.json en .build/movie-test/
.build/release/Rockport --movie-test BOUNTY_TUTORIAL --lang dutch --seconds 16
.build/release/Rockport --movie-test STORYFMV_SAF25 --realtime --mute --seconds 8   # AVAudioEngine de verdad, reloj del audio
.build/release/Rockport --movie-test EALOGO --engine            # dentro del motor: «Pulsa START», película, vuelta a la interfaz
```

- `all`: **32/32 películas, 37 877 imágenes (1 515 s) sin un error**, en orden de presentación, a 1 640–2 050 imágenes/s (leyendo de la ISO).
  Salida de VideoToolbox `0,3,1,2,6,4,5,9…` en todas (orden de decodificación) [V].
- Reloj simulado (`BLACKLIST_01`): 777/777 imágenes, ninguna saltada, desfase medio 12,6 ms (el de enseñar 25 imágenes/s en una
  pantalla de 60 Hz), máximo +20 ms. En tiempo real (`STORYFMV_SAF25`): 202 imágenes en 8 s, 0 saltadas, desfase medio 10,2 ms,
  adelanto máximo 19,9 ms y retraso máximo 9,4 ms.
- `--engine`: 167 fotogramas de película sin ningún gancho del juego; al acabar vuelve «Pulsa START» [V: captura].
- Sin ISO: aviso y salida limpia («la app seguiría sin películas»).
