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
`*.sdf.png`, `strings/<idioma>.json`. Va en `build-all.ts` y en el instalador (paso «Interfaz del juego»; `DATA_FORMAT` = 3).
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
| HUD | `HUD_SingleRace` | Cuentarrevoluciones (aguja, zona roja, marcha, luz de cambio), velocímetro de 3 dígitos (km/h en castellano), nitro, medidor de calor, panel de persecución (ARRESTADO/EVADIDO, policías, tiempo, bolsa), enfriamiento |

Sustituye al HUD propio (`HUDPursuit.swift` queda como respaldo si faltan los datos). Start/Esc abre la pausa; ⌘Q sale.
`--no-ui` arranca como antes; `--drive` entra directo a conducir con el HUD.

### Pruebas sin ventana
```bash
.build/release/Rockport --screenshot .build/shots/ui/mainmenu-2940.png --size 2940x1912 --ui-test MainMenu
#  --ui-test Splash | MainMenu | Career | Pause | HUD | Dialog | <paquete>   --ui-time <ms>   --ui-hud-demo
```
Capturas en `native-engine/.build/shots/ui/` (1920×1080 y 2940×1912).

## 7. Pendiente
- Películas (logos EA, presentación) y fondo del garaje con el coche en los menús.
- Minimapa (`TRACKMAPS.BIN`, 36 MB de texturas), hitos, infracciones, cuenta atrás y mensajes del HUD.
- Navegación genérica por botones (`FEButtonMap`) y el resto de pantallas (opciones, carrera rápida, tiendas).
- Sonidos de la interfaz (los mensajes de sonido se ignoran).
- 63 texturas que nombran los paquetes no están en el disco PS2 (teclas de PC, Xbox, demo).
