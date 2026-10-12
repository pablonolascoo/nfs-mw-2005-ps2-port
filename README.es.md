# NFS Most Wanted (2005) · PS2 → nativo

Español · [English](README.md)

<a href="https://rockport-native.vercel.app"><img src="site/img/nativo.jpg" alt="Rockport en el motor nativo de macOS (Metal)" width="100%"></a>

**[⬇️ Descargar para Mac (v0.1)](https://github.com/pablonolascoo/nfs-mw-2005-ps2-port/releases/latest)** · **🌐 Página del proyecto: [rockport-native.vercel.app](https://rockport-native.vercel.app)** · [Guía de uso](#guía-de-uso) · [Hoja de ruta y expansión](ROADMAP.md) · [Colaborar](CONTRIBUTING.md) · [Contexto del proyecto](CONTEXT.md)

| Red de carreteras sobre la ciudad | Garaje sin pantallas de carga |
|---|---|
| <img src="site/img/carreteras.jpg" alt="Red de carreteras decodificada"> | <img src="site/img/garaje.jpg" alt="Interior del concesionario"> |

Investigación y herramientas abiertas para convertir tu propia copia de **PlayStation 2** de *Need for Speed: Most Wanted* (2005) en formatos abiertos (glTF/PNG/JSON). Es la base para **ports nativos a cualquier plataforma**, empezando por macOS.

> **No incluye datos del juego.** Necesitas tu propio disco. Todo lee tu ISO y escribe los derivados en tu equipo. Proyecto sin relación con Electronic Arts.

## Qué funciona hoy
| Área | Estado |
|---|---|
| Contenedor del disco (ZDIR/ZZDATA) y nombres | ✅ 95 % de archivos con nombre |
| Compresión HUFF / JDLZ / RAWW | ✅ exacta byte a byte |
| Geometría PS2 (paquetes VIF, cortes de tira) | ✅ 181.535 tiras, 0 errores |
| Texturas PS2 PSMT8 / PSMT4 (swizzle del GS) | ✅ |
| Rockport entero: 718 secciones, 106.714 objetos, 5,8 M triángulos | ✅ exportado a glTF |
| Coches con texturas, pintura, cristales, pilotos y 4 ruedas (TireOffsets) | ✅ |
| **Motor nativo de macOS (Swift + Metal)**: pantalla completa, resolución de la pantalla, 60 fps, tono PS2, coche conducible — [native-engine/](native-engine/README.md) | ✅ primera versión |
| Visor web de investigación (Three.js) | ✅ |
| Descompilación (dbalatoni13/nfsmw) en Apple Silicon | ✅ con Rosetta 2 |
| Base de datos del juego (VLT): 6.287 colecciones, 255 eventos, Blacklist, 15 zonas de garaje/tienda | ✅ |
| Interiores del menú (garajes, concesionario, taller) | ✅ exportados |
| Ciudad entera a 60 fps (casillas HLOD, arrays de texturas, workers, resolución dinámica) | ✅ |
| Coche conducible sobre la ciudad real (prototipo arcade, 60 fps) | ✅ |
| Garajes sin pantallas de carga: se abre la puerta real, interior ya cargado, aparcas, vista de exposición, sales conduciendo | ✅ |
| Mods: datos propios sobre tu ISO (`mods/`), ejemplo «Garajes únicos» | ✅ |
| Red de carreteras (4385 nodos, 6538 tramos Bézier, carriles) y colisión (243 mil triángulos) | ✅ decodificada y validada |
| **Física de conducción del juego original** (decomp), 4 cámaras, mandos (Xbox, PS3/PS4/PS5, PS2 por USB) con barra de luz y táctil — [doc 13](docs/es/13-fisica-conduccion.md), [doc 15](docs/es/15-mandos.md) | ✅ v0.2 |
| **Tráfico, policía y persecuciones** con las tablas del juego: notoriedad, refuerzos, formaciones, controles, HUD de MW — [doc 14](docs/es/14-trafico-y-policia.md) | ✅ v0.2 |
| Voces originales y audio de escenas extraídos de tu disco (uso local) — [doc 16](docs/es/16-audio-y-voces.md) | ✅ |
| Carreras y Lista Negra jugables, garajes en el motor nativo, audio dentro del juego | 🔜 |

## Jugar en tu Mac
1. Descarga `Rockport-<versión>.dmg` de [Releases](https://github.com/pablonolascoo/nfs-mw-2005-ps2-port/releases) y arrastra **Rockport** a Aplicaciones.
2. Ábrelo (la primera vez: clic derecho → Abrir; aún no está notarizado).
3. Elige tu ISO de PS2. Detecta **PAL SLES-53559** o **NTSC-U SLUS-21351** y convierte el juego en unos 5 minutos.
4. El juego arranca a pantalla completa y a la resolución de tu pantalla. Los datos convertidos quedan en `~/Library/Application Support/Rockport/`.

Montar el `.dmg` tú mismo: `native-engine/scripts/make-dmg.sh` (necesita las herramientas de Xcode y Bun). Detalle: [native-engine/README.md](native-engine/README.md).

## Guía de uso

### Primer arranque
1. Abre **Rockport** desde Aplicaciones. La primera vez: clic derecho → **Abrir** (la app aún no está firmada por Apple).
2. Pulsa **ELEGIR MI ISO DE PS2** y selecciona tu copia. Detecta sola PAL **SLES-53559** o NTSC-U **SLUS-21351**.
3. Espera a la barra (unos minutos). Al terminar, el juego arranca a pantalla completa y a la resolución de tu pantalla.
4. Pulsa **C** (o **Menú / Options** en el mando) para pasar de la cámara libre al coche.

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
| Cámara libre / modo foto | Menú | Options / Start | C |
| Soltar el ratón · Salir | — | — | Tab · Esc |

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
| Dos dedos en el panel | Cámara libre (modo foto) y vuelta al coche |
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
Ver la tabla del [README en inglés](README.md#documentation): cada documento existe en `docs/es/` y `docs/en/`.

Para retomar el proyecto en cualquier momento: **[CONTEXT.md](CONTEXT.md)** (estado, rutas, comandos, pendientes) y el índice [docs/es/README.md](docs/es/README.md).
Expansión: [12 «Rust Belt» (plano, bocetos, historia)](docs/es/12-expansion-rust-belt.md) · Nuevos: [09 Red de carreteras](docs/es/09-red-de-carreteras.md) · [10 Coches](docs/es/10-coches.md) · [11 Catálogo de datos](docs/es/11-catalogo-de-datos.md).
Cada afirmación lleva **[V]** verificado, **[D]** tipos de depuración de la decomp, **[I]** inferido o **[H]** hipótesis.

## Licencia
MIT (código y documentación). Ver [LICENSE](LICENSE).
