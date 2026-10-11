# NFS Most Wanted (2005) · PS2 → nativo

Español · [English](README.md)

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
| Coches con texturas | ✅ (la pintura la genera el juego al vuelo; color provisional) |
| Visor web (Three.js, WebGPU → Metal) | ✅ |
| Descompilación (dbalatoni13/nfsmw) en Apple Silicon | ✅ con Rosetta 2 |
| Base de datos del juego (VLT): 6.287 colecciones, 255 eventos, Blacklist, 15 zonas de garaje/tienda | ✅ |
| Interiores del menú (garajes, concesionario, taller) | ✅ exportados |
| Ciudad entera a 60 fps (casillas HLOD, arrays de texturas, workers, resolución dinámica) | ✅ |
| Carreteras, colisiones, física | 🔜 |

## Inicio rápido
```bash
# requisitos: Bun y tu propia ISO (probadas SLES-53559 / SLUS-21351)
mkdir -p original && ln -s /ruta/a/tu.iso original/SLES-53559.iso
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
Cada afirmación lleva **[V]** verificado, **[D]** tipos de depuración de la decomp, **[I]** inferido o **[H]** hipótesis.

## Licencia
MIT (código y documentación). Ver [LICENSE](LICENSE).
