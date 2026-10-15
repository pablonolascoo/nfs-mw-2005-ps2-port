# Cobertura del disco: qué está descifrado

> Generado por `tools/src/cli/coverage.ts` el 2026-10-15 con SLES-53559. **No lo edites a mano**: cambia las tablas
> `FILE_RULES` / `CHUNK_RULES` del script y vuelve a ejecutar `bun src/cli/coverage.ts <iso> <ID> --docs`.
> Etiquetas: [V] verificado en bytes · [D] decomp · [I] inferido · [H] hipótesis.

Cómo se cuenta:
- Cada archivo de `NFS/ZDIR.BIN` se clasifica por su ruta. Los que llevan bChunks (`.BUN`, `.BIN`, `.LZC`) se recorren
  chunk a chunk (los `.LZC` se descomprimen) y sus bytes del disco se reparten entre los ids de chunk en proporción.
- Estados: **descifrado y usado** (hay lector en `tools/src/lib` y el port lo usa) · **descifrado, sin usar** (sabemos leerlo,
  el juego nativo aún no lo usa) · **parcial** · **desconocido** (sabemos el nombre por la decomp, no el formato).
- «Antes» = estado al empezar la auditoría (2026-10-15); «ahora» = tras descifrar lo de esta tanda.
- Los bytes repetidos (ZDIR apunta varias veces al mismo sitio) se cuentan una vez. También cuentan el ELF, los módulos del IOP
  y el relleno de `ZZDATA*.BIN`.


## 1. Resumen

| Estado | Antes de la auditoría | Ahora |
|---|---:|---:|
| descifrado y usado | 893.7 MB · 23.14 % | 893.7 MB · 23.14 % |
| descifrado, sin usar | 1012.1 MB · 26.21 % | 2965.7 MB · 76.80 % |
| parcial | 1521.9 MB · 39.41 % | 2.2 MB · 0.06 % |
| desconocido | 433.9 MB · 11.24 % | 0.000 MB · 0.00 % |
| **Entendido (usado + descifrado)** | **49.35 %** | **99.94 %** |
| Entendido sin contar las películas | 72.45 % | **99.86 %** |
| Total del disco (bytes únicos) | | 3861.6 MB |

Entradas de ZDIR repetidas (misma posición): 32, 22.4 MB, no se cuentan dos veces.

## 2. Por categoría

| Categoría | MB | descifrado y usado | descifrado, sin usar | parcial | desconocido | Entendido antes → ahora |
|---|---:|---:|---:|---:|---:|---:|
| Mundo (Rockport) | 214.9 | 97.55 % | 2.45 % | 0.00 % | 0.00 % | 97.55 % → **100.00 %** |
| Coches | 194.8 | 84.45 % | 15.55 % | 0.00 % | 0.00 % | 84.59 % → **100.00 %** |
| Interfaz y textos | 53.0 | 98.16 % | 1.84 % | 0.00 % | 0.00 % | 100.00 % → **100.00 %** |
| Audio | 843.4 | 54.83 % | 44.93 % | 0.24 % | 0.00 % | 54.83 % → **99.76 %** |
| Películas | 2279.9 | 0.00 % | 100.00 % | 0.00 % | 0.00 % | 33.33 % → **100.00 %** |
| Escenas NIS y cámaras | 72.5 | 0.00 % | 99.99 % | 0.01 % | 0.00 % | 94.03 % → **99.99 %** |
| Partículas y efectos | 0.642 | 0.00 % | 100.00 % | 0.00 % | 0.00 % | 0.00 % → **100.00 %** |
| Iluminación, cielo y clima | 0.078 | 56.41 % | 43.59 % | 0.00 % | 0.00 % | 53.73 % → **100.00 %** |
| Datos de juego | 8.7 | 56.67 % | 43.33 % | 0.00 % | 0.00 % | 65.17 % → **100.00 %** |
| Sistema (código, tarjeta de memoria, paquetes) | 9.2 | 0.37 % | 97.98 % | 1.65 % | 0.00 % | 66.89 % → **98.35 %** |
| Sin uso / depuración / demo | 184.4 | 0.00 % | 100.00 % | 0.00 % | 0.00 % | 95.38 % → **100.00 %** |

## 3. Mundo (Rockport)

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| 0x33320002 TexturePackDataArray | 97.3 | 2 | descifrado y usado | lib/tex-ps2.ts | [V] Píxeles y paletas (GS swizzle). |
| 0x00134a02 PS2 strip data (VIF) | 76.4 | 1 | descifrado y usado | lib/solid-ps2.ts + lib/vif.ts | [V] Paquetes VIF de geometría. |
| 0x0003b801 WCollisionAssets | 7.2 | 1 | descifrado y usado | lib/roads-ps2.ts | [V] Colisión por sección. |
| 0x00134011 eSolid | 7.0 | 1 | descifrado y usado | lib/solid-ps2.ts | [V] Cabecera del sólido (AABB, matriz, nombre). |
| 0x00034103 SceneryInstances | 6.8 | 1 | descifrado y usado | lib/world-ps2.ts | [V] Instancias (matriz, flags). |
| 0x00034107 PrecullerInfos | 3.7 | 1 | descifrado, sin usar (antes: desconocido) | lib/scenery-cull.ts | [V][D] Oclusión precalculada: 1 024 bits por grupo de instancias (rejilla de 32 m). |
| 0x00134a01 PS2 strip entry table | 3.3 | 1 | descifrado y usado | lib/solid-ps2.ts | [V] Tabla de tiras. |
| 0x00034102 SceneryInfos | 2.3 | 1 | descifrado y usado | lib/world-ps2.ts | [V] Modelos (LOD) del escenario. |
| 0x33310004 TexturePackInfoTextures | 1.5 | 1 | descifrado y usado | lib/tex-ps2.ts | [V] TextureInfo de cada textura. |
| 0x00000000 relleno de alineación | 1.4 | 3 | descifrado y usado | — | [V] Relleno entre chunks. |
| 0x00134012 SolidTextures | 1.3 | 1 | descifrado y usado | lib/solid-ps2.ts | [V] Hashes de texturas del sólido. |
| 0x00134a00 eSolidPS2PlatInfo | 1.2 | 1 | descifrado y usado | lib/solid-ps2.ts | [V] Información de plataforma del sólido. |
| 0x33310005 TexturePackInfoComps (PS2 plat info) | 1.0 | 1 | descifrado y usado | lib/tex-ps2.ts | [V] Datos GS por textura (PSM, CLUT). |
| 0x00034105 SceneryTreeNodes | 0.973 | 1 | descifrado, sin usar (antes: desconocido) | lib/scenery-cull.ts | [V][D] Árbol de cajas de cada sección (0x24 B por nodo; hojas = instancias). |
| cabeceras bChunk / bChunk headers | 0.710 | 3 | descifrado y usado | lib/bchunk.ts | [V] Cabeceras de contenedores y compresión. |
| 0x00134002 SolidListInfo | 0.695 | 1 | descifrado y usado | lib/solid-ps2.ts | [V] Cabecera de la lista de sólidos. |
| 0x0003b800 UppleUWorld (CARP) | 0.525 | 1 | descifrado y usado | lib/roads-ps2.ts | [V] Red de carreteras (RNgp). |
| 0x00034190 TroughBoundary | 0.431 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts readTrough · cli/effects.ts | [V][D] 563 contornos 2D de la zona jugable (carretera/terreno/agujeros). |
| 0x00134003 SolidList keys | 0.317 | 1 | descifrado y usado | lib/solid-ps2.ts | [V] Hashes de los sólidos. |
| 0x33310001 TexturePackInfoHeader | 0.128 | 2 | descifrado y usado | lib/tex-ps2.ts | [V] Cabecera del TPK. |
| 0x33310002 TexturePackInfoKeys | 0.109 | 2 | descifrado y usado | lib/tex-ps2.ts | [V] Hashes de las texturas. |
| 0x00034101 ScenerySectionHeader | 0.096 | 1 | descifrado y usado | lib/world-ps2.ts | [V] Cabecera de sección. |
| 0x00034110 TrackStreamingSections | 0.090 | 1 | descifrado y usado | lib/world-ps2.ts | [V] Tabla de secciones de streaming. |
| 0x00034108 SceneryOverrideInfos | 0.082 | 1 | descifrado y usado | lib/world-ps2.ts | [V] Reemplazos de escenario. |
| 0x00034106 SceneryOverrideHooks | 0.076 | 1 | descifrado, sin usar (antes: desconocido) | lib/scenery-cull.ts | [V][D] Instancia → reemplazo de escenario (u16, u16). |
| 0x00034152 VisibleSectionBoundaries | 0.050 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Polígonos de cada sección. |
| 0x00034153 DrivableScenerySections | 0.045 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Secciones conducibles. |
| 0x00034109 SceneryBarrierGroups | 0.042 | 1 | descifrado y usado | lib/world-ps2.ts | [V] Grupos (vallas de carrera, candados). |
| 0x33320001 TexturePackDataHeader | 0.031 | 2 | descifrado y usado | lib/tex-ps2.ts | [V] Cabecera de los datos de VRAM. |
| 0x0003410c ModelHierarchy | 0.012 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] 125 modelos de varias piezas. |
| 0x00134013 SolidLightMaterials | 0.008 | 1 | descifrado y usado | lib/solid-ps2.ts | [V] Hashes de materiales de luz. |
| 0x0013401a SolidMarkers | 0.008 | 1 | descifrado y usado | lib/solid-ps2.ts | [V][D] Marcadores de posición (alerón, frenos, luces…). |
| 0x33310003 TexturePackInfoEntries | 0.007 | 1 | descifrado y usado | lib/tex-ps2.ts | [V] Tabla de flujo (texturas comprimidas). |
| 0x00034113 TrackStreamingDiscBundle | 0.004 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Agrupación de secciones en el disco. |
| 0x00034158 VisibleSectionOverlays | 0.003 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Superposiciones de visibilidad. |
| 0x00034155 LoadingSections | 0.003 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Secciones de carga. |
| 0x00037080 WorldAnimEntities | 0.003 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Objetos animados del mundo. |
| 0x00037090 WorldAnimInstances | 0.002 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Instancias animadas. |
| 0x30300103 TextureAnimFrames | 0.001 | 6 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Texturas animadas: fotogramas. |
| 0x00037110 WorldAnimTreeMarkers | 0.001 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Marcadores de animación. |
| 0x30300102 TextureAnimEntry | 0.001 | 6 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Texturas animadas: entradas. |
| 0x00034151 VisibleSectionManageInfo | 0.001 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Gestor de secciones visibles. |
| 0x30300101 TextureAnimPackHeader | 0.000 | 6 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Texturas animadas: cabecera. |
| 0x00037150 WorldAnimCtrl | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Control de animaciones del mundo. |
| 0x00034191 TrackObjectBounds | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Cajas orientadas de objetos. |
| 0x00034111 TrackStreamingInfos | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Parámetros del streaming. |
| 0x00034112 TrackStreamingBarriers | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Barreras de carga. |

## 4. Coches

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| 0x33320002 TexturePackDataArray | 107.0 | 124 | descifrado y usado | lib/tex-ps2.ts | [V] Píxeles y paletas (GS swizzle). |
| 0x00134a02 PS2 strip data (VIF) | 49.4 | 67 | descifrado y usado | lib/solid-ps2.ts + lib/vif.ts | [V] Paquetes VIF de geometría. |
| 0x00134019 eSmoothVertexPlat[] | 20.2 | 65 | descifrado, sin usar (antes: desconocido) | lib/smooth-normals.ts | [V][D] Qué vértice (tira, índice) recibe cada normal promediada. |
| 0x00134018 eSmoothVertex[] | 9.8 | 65 | descifrado, sin usar (antes: desconocido) | lib/smooth-normals.ts | [V][D] Normales promediadas por posición (hash) y grupo para las costuras entre piezas del coche. |
| 0x00134a01 PS2 strip entry table | 2.5 | 67 | descifrado y usado | lib/solid-ps2.ts | [V] Tabla de tiras. |
| 0x00000000 relleno de alineación | 1.6 | 191 | descifrado y usado | — | [V] Relleno entre chunks. |
| 0x00134011 eSolid | 1.6 | 67 | descifrado y usado | lib/solid-ps2.ts | [V] Cabecera del sólido (AABB, matriz, nombre). |
| 0x0013401a SolidMarkers | 0.428 | 61 | descifrado y usado | lib/solid-ps2.ts | [V][D] Marcadores de posición (alerón, frenos, luces…). |
| 0x33310003 TexturePackInfoEntries | 0.273 | 124 | descifrado y usado | lib/tex-ps2.ts | [V] Tabla de flujo (texturas comprimidas). |
| 0x00134a00 eSolidPS2PlatInfo | 0.271 | 67 | descifrado y usado | lib/solid-ps2.ts | [V] Información de plataforma del sólido. |
| 0x33320002 TexturePackDataArray | 0.256 | 38 | descifrado, sin usar | lib/tex-ps2.ts | [V] Píxeles y paletas (GS swizzle). |
| 0x00134012 SolidTextures | 0.256 | 67 | descifrado y usado | lib/solid-ps2.ts | [V] Hashes de texturas del sólido. |
| 0x00034604 DBCarParts_Array | 0.254 | 2 | descifrado y usado | lib/car-presets.ts | [V] Piezas. |
| 0x00134013 SolidLightMaterials | 0.225 | 67 | descifrado y usado | lib/solid-ps2.ts | [V] Hashes de materiales de luz. |
| 0x00134004 SolidList stream table | 0.196 | 67 | descifrado y usado | lib/solid-ps2.ts | [V] Tabla de flujo de sólidos. |
| cabeceras bChunk / bChunk headers | 0.134 | 191 | descifrado y usado | lib/bchunk.ts | [V] Cabeceras de contenedores y compresión. |
| 0x33310002 TexturePackInfoKeys | 0.092 | 124 | descifrado y usado | lib/tex-ps2.ts | [V] Hashes de las texturas. |
| 0x00030220 PresetRides | 0.082 | 2 | descifrado y usado | lib/car-presets.ts | [V] Coches predefinidos. |
| 0x00134017 eNormalSmoother | 0.071 | 65 | descifrado, sin usar (antes: desconocido) | lib/smooth-normals.ts | [V][D] Cabecera del suavizado de normales (a cero en el disco). |
| 0x00134003 SolidList keys | 0.066 | 67 | descifrado y usado | lib/solid-ps2.ts | [V] Hashes de los sólidos. |
| 0x00034606 DBCarParts_Strings | 0.038 | 2 | descifrado y usado | lib/car-presets.ts | [V] Cadenas. |
| 0x00034600 CarTypeInfos | 0.027 | 2 | descifrado y usado | lib/car-presets.ts | [V] Tipos de coche. |
| 0x0003460c DBCarParts_Offsets | 0.023 | 2 | descifrado y usado | lib/car-presets.ts | [V] Tablas de atributos. |
| 0x00034605 DBCarParts_Attribs | 0.021 | 2 | descifrado y usado | lib/car-presets.ts | [V] Atributos de piezas. |
| 0x0003460a DBCarParts_Structs | 0.018 | 2 | descifrado y usado | lib/car-presets.ts | [V] Estructuras de piezas. |
| 0x33310001 TexturePackInfoHeader | 0.016 | 124 | descifrado y usado | lib/tex-ps2.ts | [V] Cabecera del TPK. |
| 0x00134002 SolidListInfo | 0.010 | 67 | descifrado y usado | lib/solid-ps2.ts | [V] Cabecera de la lista de sólidos. |
| 0x00000000 relleno de alineación | 0.008 | 38 | descifrado, sin usar | — | [V] Relleno entre chunks. |
| 0x33310001 TexturePackInfoHeader | 0.005 | 38 | descifrado, sin usar | lib/tex-ps2.ts | [V] Cabecera del TPK. |
| 0x33320001 TexturePackDataHeader | 0.004 | 124 | descifrado y usado | lib/tex-ps2.ts | [V] Cabecera de los datos de VRAM. |
| 0x33310003 TexturePackInfoEntries | 0.003 | 38 | descifrado, sin usar | lib/tex-ps2.ts | [V] Tabla de flujo (texturas comprimidas). |
| 0x00034607 SlotTypes | 0.002 | 2 | descifrado y usado | lib/car-presets.ts | [V] Tipos por ranura. |
| 0x33320001 TexturePackDataHeader | 0.001 | 38 | descifrado, sin usar | lib/tex-ps2.ts | [V] Cabecera de los datos de VRAM. |
| 0x33310002 TexturePackInfoKeys | 0.001 | 38 | descifrado, sin usar | lib/tex-ps2.ts | [V] Hashes de las texturas. |
| cabeceras bChunk / bChunk headers | 0.001 | 38 | descifrado, sin usar | lib/bchunk.ts | [V] Cabeceras de contenedores y compresión. |
| 0x0003460b DBCarParts_Models | 0.001 | 2 | descifrado y usado | lib/car-presets.ts | [V] Modelos de piezas. |
| 0x00034609 CarSlotAnimHide{Open,Closed}Table | 0.000 | 2 | descifrado, sin usar (antes: desconocido) | lectura directa (doc 21) | [V][D] 2 × 32 máscaras u32 (abierto/cerrado); en este disco todas a 0xFFFFFFFF. |
| 0x00034608 CarSlotAnimHookupTable | 0.000 | 2 | descifrado, sin usar (antes: desconocido) | lectura directa (doc 21) | [V][D] s8 por ranura de pieza (139 + relleno): −1 = sin animación; solo 4 ranuras (44, 63, 64, 66) llevan animación 0/1 [D: CarInfo.cpp]. |
| 0x00034603 DBCarParts_Header | 0.000 | 2 | descifrado y usado | lib/car-presets.ts | [V] Piezas: cabecera. |

## 5. Interfaz y textos

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| 0x33320002 TexturePackDataArray | 23.8 | 30 | descifrado y usado | lib/tex-ps2.ts | [V] Píxeles y paletas (GS swizzle). |
| 0x0003a100 MiniMap | 22.1 | 267 | descifrado y usado | cli/frontend.ts | [V] Mapas del radar (TPK comprimido). |
| 0x00039000 Language strings | 2.5 | 14 | descifrado y usado | lib/feng.ts | [V] Textos del idioma. |
| 0x00134a02 PS2 strip data (VIF) | 2.2 | 8 | descifrado y usado | lib/solid-ps2.ts + lib/vif.ts | [V] Paquetes VIF de geometría. |
| CREDITS\*.TXT | 0.528 | 14 | descifrado, sin usar | texto UTF-16LE | [V] Créditos por idioma (UTF-16LE con BOM). |
| LANGUAGES\AGREE.* | 0.446 | 9 | descifrado, sin usar | texto plano | [V] Texto del acuerdo de la tarjeta de memoria/en línea por idioma (texto plano). |
| 0x00030210 FEngCompressedPackage | 0.426 | 6 | descifrado y usado | lib/feng.ts | [V] Paquetes FEng comprimidos. |
| 0x00030203 FEngPackage | 0.374 | 7 | descifrado y usado | lib/feng.ts | [V] Paquetes FEng. |
| 0x00030201 FEngFont | 0.316 | 17 | descifrado y usado | lib/feng.ts | [V] Fuentes. |
| 0x33310004 TexturePackInfoTextures | 0.097 | 15 | descifrado y usado | lib/tex-ps2.ts | [V] TextureInfo de cada textura. |
| 0x00134a01 PS2 strip entry table | 0.070 | 8 | descifrado y usado | lib/solid-ps2.ts | [V] Tabla de tiras. |
| 0x33310005 TexturePackInfoComps (PS2 plat info) | 0.066 | 15 | descifrado y usado | lib/tex-ps2.ts | [V] Datos GS por textura (PSM, CLUT). |
| 0x00000000 relleno de alineación | 0.047 | 47 | descifrado y usado | — | [V] Relleno entre chunks. |
| 0x33310003 TexturePackInfoEntries | 0.015 | 15 | descifrado y usado | lib/tex-ps2.ts | [V] Tabla de flujo (texturas comprimidas). |
| 0x00134011 eSolid | 0.015 | 8 | descifrado y usado | lib/solid-ps2.ts | [V] Cabecera del sólido (AABB, matriz, nombre). |
| 0x33310002 TexturePackInfoKeys | 0.012 | 30 | descifrado y usado | lib/tex-ps2.ts | [V] Hashes de las texturas. |
| 0x00134012 SolidTextures | 0.006 | 8 | descifrado y usado | lib/solid-ps2.ts | [V] Hashes de texturas del sólido. |
| 0x33310001 TexturePackInfoHeader | 0.005 | 30 | descifrado y usado | lib/tex-ps2.ts | [V] Cabecera del TPK. |
| 0x00134a00 eSolidPS2PlatInfo | 0.003 | 8 | descifrado y usado | lib/solid-ps2.ts | [V] Información de plataforma del sólido. |
| cabeceras bChunk / bChunk headers | 0.002 | 30 | descifrado y usado | lib/bchunk.ts | [V] Cabeceras de contenedores y compresión. |
| 0x00134002 SolidListInfo | 0.001 | 8 | descifrado y usado | lib/solid-ps2.ts | [V] Cabecera de la lista de sólidos. |
| 0x33320001 TexturePackDataHeader | 0.001 | 30 | descifrado y usado | lib/tex-ps2.ts | [V] Cabecera de los datos de VRAM. |
| 0x00134003 SolidList keys | 0.001 | 8 | descifrado y usado | lib/solid-ps2.ts | [V] Hashes de los sólidos. |

## 6. Audio

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| SOUND\SPEECH\COPSPEECH_*.{BIG,IDX,EVT} | 432.8 | 9 | descifrado y usado | lib/microtalk.ts · cli/radio.ts | [V] Radio de la policía (MicroTalk) y sus tablas de bancos y eventos. |
| SOUND\PFDATA\*.MUS | 378.7 | 5 | descifrado, sin usar (antes: desconocido) | lib/pathfinder.ts · cli/music.ts | [V] Música: 1 363 muestras SCHl en EA-XA v2 (26 canciones EA Trax, ambientes, golpes musicales y 1 310 piezas de persecución), iguales a vgmstream muestra a muestra (doc 25). |
| SOUND\**\*.ABK | 18.9 | 301 | descifrado y usado | lib/abk.ts | [V] Bancos AEMS: muestras (PS-ADPCM / EA-XA v2) usadas; los módulos AEMS (código MIPS) van aparte como parciales. |
| SOUND\ENGINE\*.GIN | 10.7 | 160 | descifrado y usado | lib/abk.ts (Gnsu) | [V] Motores granulares Ginsu (EA-XAS). |
| SOUND\**\*.ABK · módulos AEMS / AEMS modules | 2.0 | 301 | parcial | lib/abk.ts (solo tamaño) | [V][D] Código MIPS del EE que elige la muestra según los parámetros. No se ejecuta: el port usa la lógica de la decomp. |
| SOUND\MIXMAPS\*.{DYN,MXB} | 0.205 | 8 | descifrado, sin usar (antes: desconocido) | lib/mixmap.ts | [V][D] Mapas de mezcla: 4 mapas × 13 estados (controles, 3D, submezclas, maestros, eventos); el .DYN da los nombres. |
| 0x0003b503 SoundStich entries | 0.105 | 2 | descifrado y usado | cli/sound.ts | [V] «Stitches» de golpes. |
| SOUND\PFDATA\*.MPF | 0.070 | 5 | parcial (antes: desconocido) | lib/pathfinder.ts | [V][D] Grafo PathFinder 5 (nodos, ramas, eventos, enrutadores): estructura leída; falta el significado de 7 acciones y de los enrutadores. |
| 0x0003b502 SoundStich header | 0.031 | 2 | descifrado y usado | cli/sound.ts | [V] «Stitches» de golpes. |
| SOUND\**\*.CSI (MOIR) | 0.016 | 11 | descifrado, sin usar (antes: desconocido) | lib/mixmap.ts | [V][D] Interfaces Csis «MOIR» {nombre, id}: 452 de 454 coinciden con los InterfaceId de la decomp (doc 25). |
| SOUND\FXEDIT\*.FX | 0.003 | 15 | parcial (antes: desconocido) | lib/mixmap.ts | [V][H] Reverbs por zona (big endian): cabecera y cadenas de módulos leídas; parámetros [H] (los ejecuta el IOP). |

## 7. Películas

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| MOVIES\STORYFMV_*_{SPANISH,ITALIAN}_PAL.MPC | 835.3 | 18 | descifrado, sin usar (antes: parcial) | lib/mpc.ts (audio R3) + VideoToolbox · doc 22 | [V] Historia **doblada** al castellano y al italiano (antes sin nombre en ZDIR). Mismo vídeo, otra pista de voz. |
| MOVIES\*_{SPANISH,ITALIAN}_PAL.MPC (resto / rest) | 684.6 | 46 | descifrado, sin usar (antes: parcial) | lib/mpc.ts (audio R3) + VideoToolbox · doc 22 | [V] Lista Negra, tutoriales, logo, PSA, demo: entradas por idioma; casi todas idénticas byte a byte a la inglesa. |
| MOVIES\STORYFMV_*_ENGLISH_PAL.MPC | 417.7 | 9 | descifrado, sin usar | lib/mpc.ts (audio R3) + VideoToolbox · doc 22 | [V] Historia en inglés: MPEG-2 512×416 25 fps + audio EA en bloques SCHl. El port aún no las reproduce. |
| MOVIES\*_ENGLISH_PAL.MPC (resto / rest) | 342.2 | 23 | descifrado, sin usar | lib/mpc.ts (audio R3) + VideoToolbox · doc 22 | [V] Lista Negra (retratos), tutoriales, logo de EA, aviso PSA y demo. |
| SUBTITLES\* | 0.002 | 30 | descifrado, sin usar (antes: parcial) | lib/subtitles.ts | [V][D] SubtitleInfo {u16 décimas, u32 hash}. El texto está en LANGUAGES\<IDIOMA>.BIN (vacío en los idiomas con doblaje). |

## 8. Escenas NIS y cámaras

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| SOUND\STREAMS\NISAUDIO.{BIG,IDX,EVT} | 49.7 | 3 | descifrado, sin usar | cli/audio.ts (vgmstream) · lib/nis.ts (IDX/EVT → escena) | [V] Audio de las escenas NIS (140 pistas SCHl). |
| 0x33320002 TexturePackDataArray | 10.7 | 26 | descifrado, sin usar | lib/tex-ps2.ts | [V] Píxeles y paletas (GS swizzle). |
| 0x00134a02 PS2 strip data (VIF) | 7.2 | 26 | descifrado, sin usar | lib/solid-ps2.ts + lib/vif.ts | [V] Paquetes VIF de geometría. |
| 0x00e34010 EAGL animations (AnimBank) | 3.1 | 88 | descifrado, sin usar (antes: desconocido) | lib/nis.ts · cli/nis.ts (falta DeltaQ, tipo 17) | [V][D] AnimBank en ELF reubicable: tipos 10/11 (delta) y 20/21 (por tramos), 805/805 animaciones NIS; falta el tipo 17 (DeltaQ, una sola en INGAMEB). |
| 0x00e34009 EAGL skeletons | 0.453 | 28 | descifrado, sin usar (antes: desconocido) | lib/nis.ts · cli/nis.ts | [V][D] Esqueletos (ELF reubicable, huesos de 0x70 B con nombre). |
| 0x0003b811 EventSequence (CARP) | 0.277 | 60 | descifrado, sin usar (antes: desconocido) | lib/nis.ts · cli/nis.ts | [V][D] Máquina de estados con acciones temporizadas; 33 tipos de evento (id = attribHash de «E» + nombre). |
| 0x00134a01 PS2 strip entry table | 0.251 | 26 | descifrado, sin usar | lib/solid-ps2.ts | [V] Tabla de tiras. |
| 0x0003b210 ICE camera tracks | 0.225 | 2 | descifrado, sin usar (antes: desconocido) | lib/nis.ts · cli/nis.ts | [V][D] 85 grupos de cámaras (claves de 0x84 B): NIS, FMV, repeticiones. |
| SOUND\NISREVDATA\*.BIN | 0.214 | 29 | descifrado, sin usar (antes: desconocido) | lib/nis.ts | [V][D] Revoluciones grabadas por escena: 16 ranuras (coche 1–8, policía 1–8) de {tiempo, RPM, acelerador %}. |
| 0x00000000 relleno de alineación | 0.156 | 26 | descifrado, sin usar | — | [V] Relleno entre chunks. |
| 0x00037060 AnimDirectory | 0.028 | 2 | descifrado, sin usar (antes: desconocido) | lib/nis.ts · cli/nis.ts | [V][D] Escena → ruta del BUN (87). |
| 0x0003b211 ICEShakeTracks | 0.018 | 2 | descifrado, sin usar (antes: desconocido) | lib/nis.ts | [V][D] 4 pistas de temblor de cámara. |
| 0x33310004 TexturePackInfoTextures | 0.017 | 26 | descifrado, sin usar | lib/tex-ps2.ts | [V] TextureInfo de cada textura. |
| 0x33310005 TexturePackInfoComps (PS2 plat info) | 0.012 | 26 | descifrado, sin usar | lib/tex-ps2.ts | [V] Datos GS por textura (PSM, CLUT). |
| 0x33310001 TexturePackInfoHeader | 0.011 | 26 | descifrado, sin usar | lib/tex-ps2.ts | [V] Cabecera del TPK. |
| 0x00134011 eSolid | 0.011 | 26 | descifrado, sin usar | lib/solid-ps2.ts | [V] Cabecera del sólido (AABB, matriz, nombre). |
| 0x00037040 NisScene entity data | 0.010 | 26 | descifrado, sin usar (antes: desconocido) | lib/nis.ts · cli/nis.ts | [V][D] Personajes (0x90 B): modelo, esqueleto, animación, matriz. |
| 0x00037030 NisScene header | 0.010 | 87 | descifrado, sin usar (antes: desconocido) | lib/nis.ts · cli/nis.ts | [V][D] Cabecera de escena: hash = grupo de cámaras, duración, tipo y origen. |
| 0x00134002 SolidListInfo | 0.009 | 26 | descifrado, sin usar | lib/solid-ps2.ts | [V] Cabecera de la lista de sólidos. |
| 0x00037070 CAnimCandidateData | 0.006 | 2 | parcial (antes: desconocido) | lib/nis.ts | [V][D] 41 «momentos» y 53 listas de coches; campos de candidatos de salida sin descifrar. |
| cabeceras bChunk / bChunk headers | 0.005 | 87 | descifrado, sin usar | lib/bchunk.ts | [V] Cabeceras de contenedores y compresión. |
| 0x33320001 TexturePackDataHeader | 0.003 | 26 | descifrado, sin usar | lib/tex-ps2.ts | [V] Cabecera de los datos de VRAM. |
| 0x00134013 SolidLightMaterials | 0.002 | 26 | descifrado, sin usar | lib/solid-ps2.ts | [V] Hashes de materiales de luz. |
| 0x00134a00 eSolidPS2PlatInfo | 0.002 | 26 | descifrado, sin usar | lib/solid-ps2.ts | [V] Información de plataforma del sólido. |
| 0x33310002 TexturePackInfoKeys | 0.002 | 26 | descifrado, sin usar | lib/tex-ps2.ts | [V] Hashes de las texturas. |
| 0x00134012 SolidTextures | 0.001 | 26 | descifrado, sin usar | lib/solid-ps2.ts | [V] Hashes de texturas del sólido. |
| 0x00134003 SolidList keys | 0.001 | 26 | descifrado, sin usar | lib/solid-ps2.ts | [V] Hashes de los sólidos. |

## 9. Partículas y efectos

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| 0x00034027 SmokeableSpawners | 0.473 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] 5 952 objetos rompibles colocados (modelo, colisión, tipo smackable). |
| 0x0003bc00 EmitterSystem | 0.169 | 6 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] 1 535 emisores del mundo (EmitterLibrary) + 41 en garajes; definiciones en ATTRIBUTES.BIN, 46 texturas FX_* (doc 24). |

## 10. Iluminación, cielo y clima

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| 0x00135200 eLightMaterial | 0.042 | 2 | descifrado y usado | cli/presets.ts | [V] Materiales de luz de los coches. |
| 0x0003b608 ParameterMapQuad16s | 0.021 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros (quadtree 16 bits). |
| 0x00034250 Weatherman pack | 0.010 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] 61 regiones de clima (bloom). |
| 0x00034202 SunInfos | 0.002 | 2 | descifrado y usado (antes: desconocido) | cli/fx.ts (doc 20) | [V][D] SunChunkInfo: sol, color y halo (exportado por fx.ts). |
| 0x0003b607 ParameterMapQuad8s | 0.002 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros (quadtree 8 bits). |
| 0x0003b605 ParameterMap (2) | 0.001 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros. |
| 0x0003b602 ParameterMapLayerHeader | 0.001 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros: cabecera de capa. |
| 0x0003b603 ParameterMapLayerFields | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros: campos. |
| 0x0003b604 ParameterMap (1) | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros. |

## 11. Datos de juego

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| GLOBAL\{ATTRIBUTES,GAMEPLAY,FE_ATTRIB}.BIN | 4.8 | 3 | descifrado y usado | lib/vlt.ts | [V] Base de datos VLT (VPAK): esquema y valores de coches, física, IA, carreras, cámaras de los menús. |
| 0x00034159 HeliSheet | 1.1 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Altura de vuelo del helicóptero: 435 secciones, 51 504 triángulos. |
| 0x00036002 EventTriggerNodes | 1.0 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Disparadores: árbol. |
| GLOBAL\GAMEPLAY.LZC | 0.744 | 1 | descifrado, sin usar | lib/lz.ts + lib/vlt.ts | [V] GAMEPLAY.BIN comprimido (JDLZ); el port lee la versión sin comprimir. |
| 0x00036003 EventTriggerEntries | 0.547 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] 12 161 disparadores (sonido ambiente). |
| 0x0003b901 CollisionGeometry Bounds | 0.285 | 3 | descifrado, sin usar (antes: desconocido) | lib/bounds.ts · cli/bounds.ts | [V][D] Cajas y esferas de colisión de los 83 coches (GLOBALB) y 405 objetos del mundo (L2RA), con superficie. |
| 0x0003414a TrackPathZones | 0.071 | 1 | descifrado y usado | cli/ai-attribs.ts | [V] Zonas de TrackPath (IA). |
| 0x0003414d TrackPathBarriers | 0.032 | 1 | descifrado y usado | cli/races.ts | [V] Vallas de carrera. |
| 0x00036001 EventTriggerPackHeader | 0.022 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Disparadores del mundo: cabecera. |
| 0x00034146 TrackPositionMarkers | 0.015 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] 328 marcadores (318 con nombre). |
| 0x00034201 TrackInfos | 0.008 | 2 | descifrado y usado (antes: parcial) | lib/world-extra.ts · cli/frontend.ts | [V] TrackInfo de las 18 pistas (el radar usa la calibración). |

## 12. Sistema (código, tarjeta de memoria, paquetes)

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| SLES_535.59 | 4.7 | 1 | descifrado, sin usar | experiments/decomp | [D] Ejecutable del juego (la decomp coincide con el de la NTSC-U; doc 01). |
| GLOBAL\*MEMORYFILE.BIN | 1.8 | 3 | descifrado, sin usar (antes: desconocido) | lib/memfile.ts | [V] Paquetes «MEMO» (0x53219999): copias de otros archivos para cargarlos de una vez (atributos, GLOBALB, idioma, .CSI, .FX, mezclas). |
| ZZDATA: relleno entre archivos | 1.4 | 1 | descifrado, sin usar | — | [V] Alineación a sector y huecos sin archivo. |
| NFS/IOPRP*.IMG, NFS/IRX*.BUN | 0.603 | 3 | descifrado, sin usar (antes: desconocido) | identificados por sus cadenas | [V] Módulos ELF del IOP: IOPRP280.IMG = imagen ROMDIR de Sony (16 módulos, cdvdfsv…); IRX281A = SIO2MAN, PADMAN, MCMAN, MCSERV; IRX281B = LIBSD, SDRDRV, SNDDRV (sonido de EA), USBD, LGDEV (volante Logitech). Un port no los necesita. |
| MEMCARD\*.ICO | 0.253 | 4 | descifrado, sin usar (antes: desconocido) | lib/ps2icon.ts | [V] Icono 3D de la partida (formato estándar de PS2): 1 074 vértices y textura RLE 128×128 (una matrícula de Rockport «NFSMW»). |
| _UNKNOWN\89c2d30f.BIN | 0.151 | 1 | parcial (antes: desconocido) | — | [V][I] Otra superposición de código para la misma dirección que «.over» (comparte el final con la del ELF; trae FEImage/FEMovie: ¿la del frontend?). |
| _UNKNOWN\9141e080.BIN | 0.149 | 1 | descifrado, sin usar (antes: desconocido) | experiments/decomp (ELF) | [V] Copia exacta de la sección «.over» (superposición de código, 156 552 B) del ELF SLES_535.59. |
| MEMCARD\LOCALE_*.LOC | 0.125 | 19 | descifrado, sin usar (antes: desconocido) | lib/loc.ts | [V] Textos de la tarjeta de memoria por idioma («LOCH»/«LOCI»). |
| NFS/ZDIR.BIN | 0.034 | 1 | descifrado y usado | lib/zdir.ts | [V] Índice de archivos. |
| SYSTEM.CNF | 0.000 | 1 | descifrado y usado | cli/build-all.ts | [V] Arranque (identifica el disco). |

## 13. Sin uso / depuración / demo

| Qué | MB | Archivos | Estado | Lector | Nota |
|---|---:|---:|---|---|---|
| 0x00134a02 PS2 strip data (VIF) | 76.4 | 2 | descifrado, sin usar | lib/solid-ps2.ts + lib/vif.ts | [V] Paquetes VIF de geometría. |
| 0x33320002 TexturePackDataArray | 63.4 | 3 | descifrado, sin usar | lib/tex-ps2.ts | [V] Píxeles y paletas (GS swizzle). |
| 0x0003b801 WCollisionAssets | 7.2 | 1 | descifrado, sin usar | lib/roads-ps2.ts | [V] Colisión por sección. |
| 0x00134011 eSolid | 7.0 | 2 | descifrado, sin usar | lib/solid-ps2.ts | [V] Cabecera del sólido (AABB, matriz, nombre). |
| 0x00034103 SceneryInstances | 6.8 | 1 | descifrado, sin usar | lib/world-ps2.ts | [V] Instancias (matriz, flags). |
| 0x00034107 PrecullerInfos | 3.7 | 1 | descifrado, sin usar (antes: desconocido) | lib/scenery-cull.ts | [V][D] Oclusión precalculada: 1 024 bits por grupo de instancias (rejilla de 32 m). |
| 0x00134a01 PS2 strip entry table | 3.3 | 2 | descifrado, sin usar | lib/solid-ps2.ts | [V] Tabla de tiras. |
| 0x00034102 SceneryInfos | 2.3 | 1 | descifrado, sin usar | lib/world-ps2.ts | [V] Modelos (LOD) del escenario. |
| 0x33310004 TexturePackInfoTextures | 1.5 | 2 | descifrado, sin usar | lib/tex-ps2.ts | [V] TextureInfo de cada textura. |
| 0x00000000 relleno de alineación | 1.4 | 7 | descifrado, sin usar | — | [V] Relleno entre chunks. |
| 0x00134012 SolidTextures | 1.3 | 2 | descifrado, sin usar | lib/solid-ps2.ts | [V] Hashes de texturas del sólido. |
| 0x00134a00 eSolidPS2PlatInfo | 1.2 | 2 | descifrado, sin usar | lib/solid-ps2.ts | [V] Información de plataforma del sólido. |
| 0x00034159 HeliSheet | 1.1 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Altura de vuelo del helicóptero: 435 secciones, 51 504 triángulos. |
| 0x33310005 TexturePackInfoComps (PS2 plat info) | 1.0 | 2 | descifrado, sin usar | lib/tex-ps2.ts | [V] Datos GS por textura (PSM, CLUT). |
| 0x00036002 EventTriggerNodes | 1.0 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Disparadores: árbol. |
| 0x00034105 SceneryTreeNodes | 0.973 | 1 | descifrado, sin usar (antes: desconocido) | lib/scenery-cull.ts | [V][D] Árbol de cajas de cada sección (0x24 B por nodo; hojas = instancias). |
| cabeceras bChunk / bChunk headers | 0.711 | 5 | descifrado, sin usar | lib/bchunk.ts | [V] Cabeceras de contenedores y compresión. |
| 0x00134002 SolidListInfo | 0.695 | 2 | descifrado, sin usar | lib/solid-ps2.ts | [V] Cabecera de la lista de sólidos. |
| 0x00036003 EventTriggerEntries | 0.547 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] 12 161 disparadores (sonido ambiente). |
| 0x0003b800 UppleUWorld (CARP) | 0.525 | 1 | descifrado, sin usar | lib/roads-ps2.ts | [V] Red de carreteras (RNgp). |
| 0x00034027 SmokeableSpawners | 0.473 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] 5 952 objetos rompibles colocados (modelo, colisión, tipo smackable). |
| 0x00134003 SolidList keys | 0.317 | 2 | descifrado, sin usar | lib/solid-ps2.ts | [V] Hashes de los sólidos. |
| 0x0003b901 CollisionGeometry Bounds | 0.166 | 1 | descifrado, sin usar (antes: desconocido) | lib/bounds.ts · cli/bounds.ts | [V][D] Cajas y esferas de colisión de los 83 coches (GLOBALB) y 405 objetos del mundo (L2RA), con superficie. |
| 0x0003bc00 EmitterSystem | 0.166 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] 1 535 emisores del mundo (EmitterLibrary) + 41 en garajes; definiciones en ATTRIBUTES.BIN, 46 texturas FX_* (doc 24). |
| 0x33310001 TexturePackInfoHeader | 0.128 | 3 | descifrado, sin usar | lib/tex-ps2.ts | [V] Cabecera del TPK. |
| 0x0003b811 EventSequence (CARP) | 0.120 | 1 | descifrado, sin usar (antes: desconocido) | lib/nis.ts · cli/nis.ts | [V][D] Máquina de estados con acciones temporizadas; 33 tipos de evento (id = attribHash de «E» + nombre). |
| 0x33310002 TexturePackInfoKeys | 0.107 | 3 | descifrado, sin usar | lib/tex-ps2.ts | [V] Hashes de las texturas. |
| 0x00034101 ScenerySectionHeader | 0.096 | 1 | descifrado, sin usar | lib/world-ps2.ts | [V] Cabecera de sección. |
| 0x00034110 TrackStreamingSections | 0.090 | 1 | descifrado, sin usar | lib/world-ps2.ts | [V] Tabla de secciones de streaming. |
| 0x00034108 SceneryOverrideInfos | 0.082 | 1 | descifrado, sin usar | lib/world-ps2.ts | [V] Reemplazos de escenario. |
| 0x00034106 SceneryOverrideHooks | 0.076 | 1 | descifrado, sin usar (antes: desconocido) | lib/scenery-cull.ts | [V][D] Instancia → reemplazo de escenario (u16, u16). |
| 0x0003414a TrackPathZones | 0.071 | 1 | descifrado, sin usar | cli/ai-attribs.ts | [V] Zonas de TrackPath (IA). |
| 0x00030210 FEngCompressedPackage | 0.064 | 3 | descifrado, sin usar | lib/feng.ts | [V] Paquetes FEng comprimidos. |
| 0x00034152 VisibleSectionBoundaries | 0.050 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Polígonos de cada sección. |
| 0x00034153 DrivableScenerySections | 0.045 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Secciones conducibles. |
| 0x00034109 SceneryBarrierGroups | 0.042 | 1 | descifrado, sin usar | lib/world-ps2.ts | [V] Grupos (vallas de carrera, candados). |
| 0x0003414d TrackPathBarriers | 0.032 | 1 | descifrado, sin usar | cli/races.ts | [V] Vallas de carrera. |
| 0x33320001 TexturePackDataHeader | 0.031 | 3 | descifrado, sin usar | lib/tex-ps2.ts | [V] Cabecera de los datos de VRAM. |
| 0x00036001 EventTriggerPackHeader | 0.022 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Disparadores del mundo: cabecera. |
| 0x0003b608 ParameterMapQuad16s | 0.021 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros (quadtree 16 bits). |
| 0x00e34010 EAGL animations (AnimBank) | 0.016 | 1 | descifrado, sin usar (antes: desconocido) | lib/nis.ts · cli/nis.ts (falta DeltaQ, tipo 17) | [V][D] AnimBank en ELF reubicable: tipos 10/11 (delta) y 20/21 (por tramos), 805/805 animaciones NIS; falta el tipo 17 (DeltaQ, una sola en INGAMEB). |
| 0x00034146 TrackPositionMarkers | 0.015 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] 328 marcadores (318 con nombre). |
| TRACKS\PRECULLERBOOBOOSCRIPT.HOO | 0.013 | 1 | descifrado, sin usar | texto | [V] Guion de texto de herramientas (preculler) olvidado en el disco. |
| 0x0003410c ModelHierarchy | 0.012 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] 125 modelos de varias piezas. |
| 0x00034250 Weatherman pack | 0.010 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] 61 regiones de clima (bloom). |
| 0x00134013 SolidLightMaterials | 0.008 | 1 | descifrado, sin usar | lib/solid-ps2.ts | [V] Hashes de materiales de luz. |
| 0x0013401a SolidMarkers | 0.008 | 1 | descifrado, sin usar | lib/solid-ps2.ts | [V][D] Marcadores de posición (alerón, frenos, luces…). |
| 0x00034113 TrackStreamingDiscBundle | 0.004 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Agrupación de secciones en el disco. |
| 0x00034158 VisibleSectionOverlays | 0.003 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Superposiciones de visibilidad. |
| 0x00034155 LoadingSections | 0.003 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Secciones de carga. |
| 0x00037080 WorldAnimEntities | 0.003 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Objetos animados del mundo. |
| 0x00037090 WorldAnimInstances | 0.002 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Instancias animadas. |
| 0x0003b607 ParameterMapQuad8s | 0.002 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros (quadtree 8 bits). |
| 0x00037110 WorldAnimTreeMarkers | 0.001 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Marcadores de animación. |
| 0x30300103 TextureAnimFrames | 0.001 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Texturas animadas: fotogramas. |
| 0x0003b605 ParameterMap (2) | 0.001 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros. |
| 0x00034151 VisibleSectionManageInfo | 0.001 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Gestor de secciones visibles. |
| 0x30300102 TextureAnimEntry | 0.001 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Texturas animadas: entradas. |
| 0x0003b602 ParameterMapLayerHeader | 0.001 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros: cabecera de capa. |
| 0x0003b603 ParameterMapLayerFields | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros: campos. |
| 0x0003b604 ParameterMap (1) | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Mapas de parámetros. |
| 0x30300101 TextureAnimPackHeader | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/effects.ts · cli/effects.ts | [V][D] Texturas animadas: cabecera. |
| 0x00037150 WorldAnimCtrl | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Control de animaciones del mundo. |
| _UNKNOWN\48671a56.BIN | 0.000 | 1 | desconocido | — | [H] 130 B de texto hexadecimal (¿clave o firma de herramienta?). |
| 0x33310003 TexturePackInfoEntries | 0.000 | 1 | descifrado, sin usar | lib/tex-ps2.ts | [V] Tabla de flujo (texturas comprimidas). |
| 0x00034191 TrackObjectBounds | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Cajas orientadas de objetos. |
| 0x00034111 TrackStreamingInfos | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Parámetros del streaming. |
| 0x00034112 TrackStreamingBarriers | 0.000 | 1 | descifrado, sin usar (antes: desconocido) | lib/world-extra.ts · cli/effects.ts | [V][D] Barreras de carga. |

## 14. Lo que falta, por tamaño

| Qué | MB | Estado | Qué creemos que es |
|---|---:|---|---|
| SOUND\**\*.ABK · módulos AEMS / AEMS modules · Audio | 2.0 | parcial | [V][D] Código MIPS del EE que elige la muestra según los parámetros. No se ejecuta: el port usa la lógica de la decomp. |
| _UNKNOWN\89c2d30f.BIN · Sistema (código, tarjeta de memoria, paquetes) | 0.151 | parcial | [V][I] Otra superposición de código para la misma dirección que «.over» (comparte el final con la del ELF; trae FEImage/FEMovie: ¿la del frontend?). |
| SOUND\PFDATA\*.MPF · Audio | 0.070 | parcial | [V][D] Grafo PathFinder 5 (nodos, ramas, eventos, enrutadores): estructura leída; falta el significado de 7 acciones y de los enrutadores. |
| 0x00037070 CAnimCandidateData · Escenas NIS y cámaras | 0.006 | parcial | [V][D] 41 «momentos» y 53 listas de coches; campos de candidatos de salida sin descifrar. |
| SOUND\FXEDIT\*.FX · Audio | 0.003 | parcial | [V][H] Reverbs por zona (big endian): cabecera y cadenas de módulos leídas; parámetros [H] (los ejecuta el IOP). |
| _UNKNOWN\48671a56.BIN · Sin uso / depuración / demo | 0.000 | desconocido | [H] 130 B de texto hexadecimal (¿clave o firma de herramienta?). |

## Notas

- Las películas son el 59 % del disco: por eso el porcentaje «entendido» es alto aunque queden formatos pequeños por descifrar.
  Lo que de verdad falta está en la última tabla, ordenado por tamaño.
- Hallazgos de esta auditoría: las 64 entradas `_UNKNOWN` de vídeo son `MOVIES\*_SPANISH_PAL.MPC` y `*_ITALIAN_PAL.MPC`
  (la historia está **doblada** al castellano y al italiano); los `*MEMORYFILE.BIN` son paquetes con copias de otros archivos;
  los subtítulos están en `LANGUAGES\<IDIOMA>.BIN` (doc 22).
- Lista de nombres añadidos: `tools/data/filenames-extra.list`.
- «Descifrado» mide el **formato**: sabemos leer cada byte y qué es. No quiere decir que el juego nativo ya lo use: lo usado sigue
  siendo el 23 %. Lo que falta por usar (películas, música, escenas NIS, partículas, colisión del juego…) está en los docs 22–25.
- Detalles abiertos dentro de lo «descifrado»: animación EAGL tipo 17 (DeltaQ, una sola animación), pesos de piel de los
  personajes NIS, significado de 7 acciones de la música, nombres de 226 objetos del mundo (docs 22–25).

