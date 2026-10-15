# Rockport Native · Need for Speed: Most Wanted (2005)

**Español** · [English](README.en.md)

<a href="https://rockport-native.vercel.app"><img src="site/img/banner.jpg" alt="Rockport Native: el BMW M3 GTR de Most Wanted en el motor nativo de macOS" width="100%"></a>

<p align="center"><b><a href="https://github.com/pablonolascoo/nfs-mw-2005-ps2-port/releases/latest">⬇️ Descargar para Mac (v0.7.1)</a></b> · <a href="https://rockport-native.vercel.app">🌐 Página del proyecto</a> · <a href="#guía-de-uso">Guía de uso</a> · <a href="#la-ampliación-rust-belt">La expansión</a> · <a href="ROADMAP.md">Hoja de ruta</a> · <a href="CONTRIBUTING.md">Colaborar</a> · <a href="CONTEXT.md">Contexto</a></p>

**Proyecto abierto de decompilación e ingeniería inversa** del *Need for Speed: Most Wanted* (2005) de **PlayStation 2**. Leemos tu propia ISO, entendemos cada formato y cada sistema del juego (con ayuda de la decomp [dbalatoni13/nfsmw](https://github.com/dbalatoni13/nfsmw)) y lo volvemos a montar como **juego nativo**, fiel al original: misma ciudad, mismos coches, misma interfaz, mismo tono cálido de PS2.

Y después, **lo ampliamos**: una expansión que continúa la historia como si la hubiera hecho el mismo estudio en 2006.

> **No incluye datos del juego.** Necesitas tu propio disco (PAL SLES-53559 o NTSC-U SLUS-21351). Todo se genera en tu equipo a partir de tu ISO. Proyecto de fans sin ánimo de lucro, sin relación con Electronic Arts.

## Tres partes, un objetivo

| | Qué | Estado |
|---|---|---|
| 🔬 **Decompilación** | Formatos del disco, base de datos, física, IA, interfaz, audio, películas, música, escenas… todo documentado en [`docs/`](docs/es) con cada dato etiquetado ([V] verificado, [D] decomp, [I] inferido, [H] hipótesis) | ✅ **99,94 % del disco entendido** ([doc 21](docs/es/21-cobertura.md)) |
| 🖥️ **Port nativo** | Motor propio que juega Rockport desde tu ISO, sin emulador | ✅ jugable en Mac (v0.7) |
| 🗺️ **Expansión «Rust Belt»** | 4 distritos nuevos, Lista Negra 2, coches clásicos, la historia continúa | 🧭 diseñada, [ver abajo](#la-ampliación-rust-belt) |

### Plataformas
| Plataforma | Estado | Cómo |
|---|---|---|
| **macOS** (Apple Silicon) | ✅ **jugable** · `.dmg` en [Releases](https://github.com/pablonolascoo/nfs-mw-2005-ps2-port/releases/latest) | Swift + Metal, a pantalla completa y a la resolución de tu pantalla |
| **Windows** | 🔜 posible | El conversor (`tools/`, TypeScript + Bun) ya funciona en Windows. Falta un motor con DirectX 12 o Vulkan que lea los mismos datos |
| **iPhone / iPad** | 🔜 posible | Mismo Metal y mismos mandos que en Mac; habría que adaptar los controles táctiles y la memoria |
| **Android / Linux** | 💡 idea | Vulkan + los mismos datos convertidos |

Los datos convertidos (glTF, PNG, JSON) son abiertos y no dependen de la plataforma: cualquiera puede escribir su motor encima. ¿Te animas con Windows o con móvil? Mira [CONTRIBUTING.md](CONTRIBUTING.md).

### La expansión, en una imagen

<img src="docs/expansion/valle.jpg" alt="Vista del valle industrial de la expansión Rust Belt" width="100%">

Al vencer a Razor se abre un condado industrial del Rust Belt alrededor de Rockport: **Millbrook**, **Ironwood**, **Calder Bay** y **Black Hollow**. Una nueva Lista Negra de 15, coches clásicos (Countach, Testarossa, 959…), persecuciones nuevas y la historia que sigue. [Plano, bocetos e historia →](#la-ampliación-rust-belt)

## En imágenes

<img src="site/img/blacklist-grid.jpg" alt="Los 15 coches de la Lista Negra con sus pinturas exclusivas" width="100%">

| Carrera con el HUD original | Persecución con la policía |
|---|---|
| <img src="site/img/carrera.jpg" alt="Carrera sprint con el HUD original y las vallas de la prueba"> | <img src="site/img/persecucion.jpg" alt="Persecución con el HUD original y el radar"> |
| **Menú principal: el patio de los depósitos de agua** | **Tu refugio, con la pizarra de la Lista Negra** |
| <img src="site/img/menu.jpg" alt="Menú principal original con el BMW M3 GTR en el patio nocturno"> | <img src="site/img/garaje-coches.jpg" alt="El BMW M3 GTR en el refugio"> |
| **Taller de tuneo sin pantallas de carga** | **Pantalla de la Lista Negra** |
| <img src="site/img/taller.jpg" alt="Taller de tuneo: pintura del BMW"> | <img src="site/img/listanegra-pantalla.jpg" alt="Pantalla de la Lista Negra con Sonny, el #15"> |

## Qué funciona hoy

### El juego (motor nativo de macOS, v0.7)
| | Estado |
|---|---|
| Rockport entero a pantalla completa, a la resolución de tu pantalla y a 60 fps, con el tono cálido de PS2 siempre puesto | ✅ |
| **Interfaz original**: «Pulsa START», menús, pausa y HUD 100 % del juego, con los textos en castellano de tu disco — [doc 17](docs/es/17-interfaz.md) | ✅ |
| **Conducción con la física del juego** (decompilada), 4 cámaras — [doc 13](docs/es/13-fisica-conduccion.md) | ✅ |
| **Coches de la historia con su pintura exacta**: BMW M3 GTR gris y azul, Mustang de Razor, los 15 de la Lista Negra — [doc 10](docs/es/10-coches.md) | ✅ |
| **Carreras y Lista Negra**: sprint, circuito, eliminación, drag, radar, peaje y desafíos; progresión 15 → 1, coches de rosa y partida guardada — [doc 18](docs/es/18-carreras-y-lista-negra.md) | ✅ |
| **Tráfico, policía y persecuciones** con las tablas del juego, radio de la policía en castellano — [doc 14](docs/es/14-trafico-y-policia.md) | ✅ |
| **Garajes sin pantallas de carga**: refugio, concesionario y taller de tuneo — [doc 07](docs/es/07-conduccion-y-garajes.md) | ✅ |
| **Sonido original**: motor de cada coche, turbo, cambios, nitro, derrapes, golpes, sirenas — [doc 16](docs/es/16-audio-y-voces.md) | ✅ |
| **Carrera rápida y pantalla partida** (2 jugadores como el original; 3-4 y varias pantallas como ampliación) — [doc 19](docs/es/19-carrera-rapida-y-multijugador.md) | ✅ |
| **Mandos** Xbox, PS3/PS4/PS5 y PS2 por USB, con barra de luz, táctil y gatillos del DualSense — [doc 15](docs/es/15-mandos.md) | ✅ (sin probar con hardware real) |
| **Iluminación del juego**: reflejos del coche con los mapas de entorno del disco, sombra, cielo, sol y resplandor; garajes fieles al original — [doc 20](docs/es/20-iluminacion-y-efectos.md) | ✅ |
| **Películas** desde tu ISO, con el doblaje al castellano del disco PAL: logos, intro, presentaciones de la Lista Negra e historia — [doc 22](docs/es/22-peliculas-subtitulos-y-colision.md) | ✅ |
| **Música EA Trax** y música de persecución con la lógica del juego — [doc 25](docs/es/25-musica-y-mezcla.md) | ✅ |
| **Partículas, destellos y niebla por zona**: humo de neumáticos, nitro, chispas, semáforos, faros, luces de policía — [doc 24](docs/es/24-efectos-luces-y-mundo.md) | ✅ |
| **Choques y daños**: coches que chocan con la colisión del juego, policía destrozada, 5952 objetos rompibles, trampas para la policía y **helicóptero** — [doc 14](docs/es/14-trafico-y-policia.md) | ✅ |
| Mapa de la carrera profesional, pinchos que revientan neumáticos, menú de opciones completo | 🔜 |

### La ingeniería inversa
| | Estado |
|---|---|
| Contenedor del disco, nombres de archivo (95 %), compresión HUFF/JDLZ/RAWW byte a byte | ✅ |
| Geometría y texturas de PS2 (VIF, swizzle del GS), 181.535 tiras sin un error | ✅ |
| Rockport: 718 secciones, 106.714 objetos, 5,8 M triángulos | ✅ |
| Base de datos del juego (VLT): 6.287 colecciones, 255 eventos | ✅ |
| Red de carreteras (4385 nodos, Bézier, carriles) y colisión (243 mil triángulos) | ✅ |
| Interfaz (FEng), sonido (ABK, GIN, MicroTalk), coches preparados y vinilos, rutas de carrera | ✅ |
| Decompilación [dbalatoni13/nfsmw](https://github.com/dbalatoni13/nfsmw) compilando en Apple Silicon | ✅ |
| Visor web de investigación (Three.js) y mods de datos (`mods/`) | ✅ |

## Carrera rápida y pantalla partida

<img src="site/img/pantalla-partida.jpg" alt="Pantalla partida a 4 jugadores en el motor nativo" width="100%">

La carrera rápida va con las pantallas del juego: tipo de prueba, selección de pista con el mapa de cada prueba, opciones y selección de coche. **Pantalla partida para 2 jugadores como el original** (horizontal, con el HUD de pantalla partida del disco) y, como ampliación del port, **3 y 4 jugadores** y **varias pantallas a la vez** (por ejemplo, 2 jugadores en cada monitor).

Cada jugador usa su propio mando (Xbox, DualSense, DualShock 4, DualShock 3, adaptador de PS2 o el teclado) **sin mezclas**: «Pulsa START» para unirte, el primero es el jugador 1 y lleva los menús, cada mando mueve solo su coche, la barra de luz y el LED toman el color de tu jugador, y si se desenchufa un mando la partida se para hasta que vuelva. `--race 15.1.1 --players 2` empieza directamente; `--displays all` usa todas las pantallas. Detalle: [doc 19](docs/es/19-carrera-rapida-y-multijugador.md).

## Jugar en tu Mac
1. Descarga `Rockport-<versión>.dmg` de [Releases](https://github.com/pablonolascoo/nfs-mw-2005-ps2-port/releases) y arrastra **Rockport** a Aplicaciones.
2. Ábrelo (la primera vez: clic derecho → Abrir; aún no está notarizado).
3. Elige tu ISO de PS2. Detecta **PAL SLES-53559** o **NTSC-U SLUS-21351** y convierte el juego en alrededor de 1 minuto.
4. El juego arranca a pantalla completa y a la resolución de tu pantalla. Los datos convertidos quedan en `~/Library/Application Support/Rockport/`.

Montar el `.dmg` tú mismo: `native-engine/scripts/make-dmg.sh` (necesita las herramientas de Xcode y Bun). Detalle: [native-engine/README.md](native-engine/README.md).

## La ampliación «Rust Belt»

Una expansión hecha por fans **como si fuera de 2006**. Se desbloquea al vencer a la Lista Negra original y continúa la historia con una **Lista Negra 2** de 15 rivales con coches únicos. Misma estética: Rust Belt, otoño y el tono cálido de PS2.

<img src="docs/expansion/valle.jpg" alt="Vista del valle industrial de la expansión" width="100%">

| Plano: Rockport real + 4 distritos nuevos | Distritos |
|---|---|
| <img src="docs/expansion/mapa-expansion.svg" alt="Plano de la expansión" width="420"> | **1 · Millbrook**: pueblo obrero, nuevo refugio (Lista Negra 2 #15–#11)<br>**2 · Ironwood**: altos hornos y vías de tren (#10–#6)<br>**3 · Calder Bay**: grúas y contenedores (#5–#2)<br>**4 · Black Hollow**: puerto de montaña y presa (#1)<br><br>Unidos por la interestatal **I-99**. Coches clásicos como el Countach, el Testarossa o el 959. |

| Ironwood | Calder Bay | Black Hollow | Puente e I-99 |
|---|---|---|---|
| <img src="docs/expansion/ironwood.jpg" alt="Ironwood"> | <img src="docs/expansion/calder-bay.jpg" alt="Calder Bay"> | <img src="docs/expansion/black-hollow.jpg" alt="Black Hollow"> | <img src="docs/expansion/puente-interestatal.jpg" alt="Puente"> |

Diseño completo, historia y reglas para modelar: [docs/es/12-expansion-rust-belt.md](docs/es/12-expansion-rust-belt.md). Bocetos de ambiente hechos con IA (no son recursos del juego).

## Guía de uso

### Primer arranque
1. Abre **Rockport** desde Aplicaciones. La primera vez: clic derecho → **Abrir** (la app aún no está firmada por Apple).
2. Pulsa **ELEGIR MI ISO DE PS2** y selecciona tu copia. Detecta sola PAL **SLES-53559** o NTSC-U **SLUS-21351**.
3. Espera a la barra (alrededor de 1 minuto).
4. «Pulsa START» → **Modo carrera** → **Empezar nuevo** (o **Continuar** si ya tienes partida). También tienes **Carrera rápida** para jugar solo o a pantalla partida.

### Controles

| Acción | Xbox | PlayStation | Teclado |
|---|---|---|---|
| Acelerar (analógico) | RT | R2 | W / ↑ |
| Frenar y marcha atrás (analógico) | LT | L2 | S / ↓ |
| Girar | stick izquierdo | stick izquierdo | A D / ← → |
| Freno de mano | A o RB | ✕ o R1 | Espacio |
| Nitro | B | ○ | N o Mayús |
| Mirar atrás (mantener) | LB o L3 | L1 o L3 | X |
| Cambiar de cámara (4 vistas del juego) | Y · cruceta → / ← | △ · cruceta → / ← | V |
| Recolocar el coche en la calle | X o Ver | □ o Share / Create | R |
| Subir / bajar marcha | cruceta ↑ / ↓ | cruceta ↑ / ↓ | E / Q |
| Pausa (continuar, reiniciar, salir al menú) | Menú | Options / Start | Esc |
| Cámara libre / modo foto | — | — | C |
| Soltar el ratón | — | — | Tab |

- El cambio es automático, como en el juego. La cruceta sirve para cambiar a mano cuando quieras.
- Con el stick derecho también puedes acelerar (↑) y frenar (↓).
- El tono cálido y amarillento de PS2 va **siempre** puesto: es parte del juego.

### Extras de PS4 (DualShock 4) y PS5 (DualSense)

| Extra | Qué hace |
|---|---|
| Barra de luz | Toma el color de tu coche. En una persecución parpadea en rojo y azul |
| Deslizar el dedo → / ← en el panel táctil | Cámara siguiente / anterior |
| Pulsar el panel táctil (mantener) | Mirar atrás mientras lo mantienes |
| Toque corto en el panel | Vistazo atrás de 1 segundo |
| Dos dedos en el panel | Modo foto (cámara libre) y vuelta al coche |
| Gatillos adaptativos (solo PS5) | L2 ofrece resistencia al frenar y vibra si las ruedas se bloquean. R2 casi libre, tiembla en el corte de inyección y se suelta con el nitro |
| Vibración | Según el agarre de las ruedas, el corte de inyección, el nitro y los golpes |

### Persecuciones
- **Arriba a la izquierda**: nivel de notoriedad (HEAT, de 1 a 5) y número de policías.
- **Abajo**: la barra **EVADE ← → BUSTED**.
  - Si vas lento con un policía encima, se llena hacia **BUSTED**: te arrestan.
  - Si les pierdes de vista, empieza el **COOLDOWN**. Aguanta sin que te vean y saldrá **EVADED**.
- **Para escapar**: corta la línea de visión (esquinas, túneles, callejones) y busca escondites del juego (bajo puentes, aparcamientos). Ahí la policía no te ve.
- **Desde la notoriedad 2** aparecen controles de carretera, algunos con pinchos. Busca el hueco o cambia de calle.
- **Te persiguen si** vas muy rápido delante de ellos, chocas con el tráfico o embistes a un coche patrulla.

### Mandos compatibles
- **Sin instalar nada**, por cable o Bluetooth: Xbox One y Series, PS4, PS5, Switch Pro y mandos MFi.
- **Solo por cable**: PS3 (DualShock 3) y mandos de PS2 con adaptador USB.
- **Xbox 360**: macOS necesita el driver gratuito [360Controller](https://github.com/360Controller/360Controller). El juego te avisa si falta.
- Se pueden conectar y desconectar en cualquier momento. Detalle completo: [docs/es/15-mandos.md](docs/es/15-mandos.md).

### Problemas frecuentes
| Problema | Solución |
|---|---|
| «No se puede abrir porque no se ha verificado el desarrollador» | Clic derecho en la app → **Abrir** → **Abrir** |
| Un mando PS3, PS2 o genérico no responde | Ajustes del Sistema › Privacidad y seguridad › **Monitorización de entrada** → activa Rockport |
| Quiero volver a convertir mi ISO | Borra `~/Library/Application Support/Rockport/<ID>/` y abre la app |
| Actualicé la app | Si los datos son de una versión anterior, se reconvierten solos con la misma ISO |
| Desinstalar | Borra **Rockport** de Aplicaciones y la carpeta `~/Library/Application Support/Rockport/` |

## Inicio rápido (herramientas de investigación)
**Con una sola ISO PAL (SLES-53559) basta para todo el proyecto** (también vale SLUS-21351).
```bash
# requisitos: Bun y tu propia ISO
cd tools && bun install
bun run build-all /ruta/a/tu.iso          # todo en ~6 min → map-data/<disco>/
cd ../viewer && bun install && bunx vite   # http://localhost:5181 → «Cargar ciudad completa» → «Conducir»
```
Paso a paso:
```bash
cd tools && bun install
bun src/cli/inventory.ts ../original/SLES-53559.iso SLES-53559
bun src/cli/convert.ts   ../original/SLES-53559.iso SLES-53559 tiles 400 3   # Rockport entero en casillas a 60 fps (~1 min)
bun src/cli/convert.ts   ../original/SLES-53559.iso SLES-53559 interior CAREER_SAFEHOUSE CAR_LOT CUSTOMIZATION_SHOP
bun src/cli/vlt-dump.ts  ../original/SLES-53559.iso SLES-53559                # gameplay.json + zones.json
bun src/cli/convert.ts   ../original/SLES-53559.iso SLES-53559 car BMWM3GTRE46
bun src/cli/topdown.ts   ../original/SLES-53559.iso SLES-53559 4096          # plano cenital PNG
cd ../viewer && bun install && bunx vite                                    # http://localhost:5181
```

## Documentación
Cada documento existe en español (`docs/es/`) y en inglés (`docs/en/`). Para retomar el proyecto: **[CONTEXT.md](CONTEXT.md)**.

| # | Tema | Español | English |
|---|---|---|---|
| 00 | Identificación del disco | [es](docs/es/00-identificacion-disco.md) | [en](docs/en/00-disc-identification.md) |
| 01 | Compatibilidad con la decomp | [es](docs/es/01-compatibilidad-sles53559.md) | [en](docs/en/01-sles53559-compatibility.md) |
| 02 | Formatos de PS2 | [es](docs/es/02-formatos-ps2.md) | [en](docs/en/02-ps2-formats.md) |
| 03 | El mundo de Rockport | [es](docs/es/03-mundo-rockport-ps2.md) | [en](docs/en/03-rockport-world-ps2.md) |
| 04 | Arquitectura del port | [es](docs/es/04-arquitectura-port.md) | [en](docs/en/04-port-architecture.md) |
| 05 | Base de datos del juego (VLT) | [es](docs/es/05-vlt-atributos.md) | [en](docs/en/05-vlt-attributes.md) |
| 06 | Rendimiento | [es](docs/es/06-rendimiento.md) | [en](docs/en/06-performance.md) |
| 07 | Conducción y garajes | [es](docs/es/07-conduccion-y-garajes.md) | [en](docs/en/07-driving-and-garages.md) |
| 08 | Mods | [es](docs/es/08-mods.md) | [en](docs/en/08-mods.md) |
| 09 | Red de carreteras y colisión | [es](docs/es/09-red-de-carreteras.md) | [en](docs/en/09-road-network.md) |
| 10 | Coches, pinturas y vinilos | [es](docs/es/10-coches.md) | [en](docs/en/10-cars.md) |
| 11 | Catálogo de datos generados | [es](docs/es/11-catalogo-de-datos.md) | [en](docs/en/11-data-catalog.md) |
| 12 | Expansión «Rust Belt» | [es](docs/es/12-expansion-rust-belt.md) | [en](docs/en/12-rust-belt-expansion.md) |
| 13 | Física de conducción | [es](docs/es/13-fisica-conduccion.md) | [en](docs/en/13-driving-physics.md) |
| 14 | Tráfico, policía y persecuciones | [es](docs/es/14-trafico-y-policia.md) | [en](docs/en/14-traffic-and-police.md) |
| 15 | Mandos | [es](docs/es/15-mandos.md) | [en](docs/en/15-controllers.md) |
| 16 | Audio y voces | [es](docs/es/16-audio-y-voces.md) | [en](docs/en/16-audio-and-voices.md) |
| 17 | Interfaz original | [es](docs/es/17-interfaz.md) | [en](docs/en/17-interface.md) |
| 18 | Carreras y Lista Negra | [es](docs/es/18-carreras-y-lista-negra.md) | [en](docs/en/18-races-and-blacklist.md) |
| 19 | Carrera rápida y multijugador | [es](docs/es/19-carrera-rapida-y-multijugador.md) | [en](docs/en/19-quick-race-and-multiplayer.md) |
| 20 | Iluminación y efectos | [es](docs/es/20-iluminacion-y-efectos.md) | [en](docs/en/20-lighting-and-effects.md) |
| 21 | Cobertura del disco (qué está descifrado) | [es](docs/es/21-cobertura.md) | [en](docs/en/21-coverage.md) |
| 22 | Películas, subtítulos y colisión | [es](docs/es/22-peliculas-subtitulos-y-colision.md) | [en](docs/en/22-movies-subtitles-and-collision.md) |
| 23 | Escenas con el motor (NIS) | [es](docs/es/23-escenas-nis.md) | [en](docs/en/23-nis-scenes.md) |
| 24 | Partículas, destellos y datos del mundo | [es](docs/es/24-efectos-luces-y-mundo.md) | [en](docs/en/24-effects-lights-and-world.md) |
| 25 | Música y mezcla | [es](docs/es/25-musica-y-mezcla.md) | [en](docs/en/25-music-and-mixing.md) |

Cada afirmación lleva **[V]** verificado en datos reales, **[D]** sacado de la decomp, **[I]** inferido o **[H]** hipótesis.

## Estructura
`tools/` lectores de formatos y conversores (TypeScript + Bun, multiplataforma) · `native-engine/` el juego nativo de macOS (Swift + Metal) · `viewer/` visor web de investigación · `docs/` investigación · `mods/` mods de datos · `site/` página del proyecto.

## Créditos
- [dbalatoni13/nfsmw](https://github.com/dbalatoni13/nfsmw) (CC0): la decompilación que hace posible entender los sistemas del juego.
- [TsyVM/MWEncyclopedia](https://github.com/TsyVM/MWEncyclopedia): referencia de formatos de PC.
- Las tablas de memoria del GS siguen la documentación pública (como PCSX2).

## Licencia
MIT (código y documentación). Ver [LICENSE](LICENSE).
