# Formatos PS2 de NFS MW descifrados (SLES-53559)

Leyenda: **[V]** verificado con datos reales · **[D]** tipos de depuración de la decomp (`symbols/PS2`) · **[H]** hipótesis.
Código de referencia en `tools/src/lib/`.

## Contenedor del disco — `zdir.ts` [V]
- `NFS/ZDIR.BIN`: entradas de 24 B LE `{hash, archivo, sectorLocal, sectorGlobal, tamaño, checksum}`.
- Hash = `bStringHash` (`h = h*33 + c`, inicio `0xFFFFFFFF`) de la ruta en mayúsculas con `\`.
- 1497 archivos (PAL) / 1447 (US). 95 % con nombre resuelto con `tools/data/filenames-mw-ps2.list` (lista propia verificada por hash) y cadenas del ELF.

## bChunk — `bchunk.ts` [V][D]
`{u32 id, u32 tamaño}`; bit `0x80000000` = contenedor. Relleno `0x11111111` dentro de los chunks. Alineaciones relativas al inicio de archivo/sección (16 para eSolid, 128 para píxeles).

## Compresión — `lz.ts` [V]
`JDLZ`, `HUFF` (Huffman EA con runs y deltas `0x32fb/0x34fb`), `RAWW`. Portado de `LZCompress.cpp`; tamaños de salida exactos en todas las pruebas.

## Geometría (sólidos) — `solid-ps2.ts`
- Árbol `0x80134000 → 0x80134010 → {0x00134011 eSolid, 0x00134012 texturas, 0x80134100 → 0x00134A00/01/02}` [D][V].
- `eStripEntry` 16 B: `{flags, numVerts, numPolys, densidad, qwOffset, Nz, Nt, qwSize, grupo, textura, luz}` [D][V].
- Cada tira es un paquete **VIF** listo para VU1 [V]:

| Dir. VU | Formato | Contenido |
|---|---|---|
| 0 | V4-8 | `[numVerts, grupos de 4, 23, ?]` |
| 1 | V4-32 | `[ADC0, escala=0.0002, ADC2, ADC3]` |
| 2 | V3-32 ×2 | AABB de la tira (inflada 0,01) |
| 4 | V4-32 | cono de normales |
| 5 | V4-16 | XYZ en SoA: por grupo, filas `x[4] y[4] z[4]`; sueltos en `V{m}-16 ×3` |
| 29 | V4-16 | UV: por fila `(s0, t0, t1, s1)`, ÷4096 |
| 45 | V4-8u | RGBA por vértice (solo escenario), 128 = 1.0 |
| 77 | V4-8 | normales SoA (int8) |

- **Posición** = `entero × 0,0002 + desplazamiento entero por eje`. El desplazamiento se deduce de la AABB (`round(min − vmin·escala)`); validado con 9 027 vértices compartidos entre tiras [V]. Dónde lo calcula el VU: [H].
- **Cortes de tira (ADC)** [V, 100 % en 181 535 tiras]: vértices 0–14 en la palabra F bits 14→0 (F = ADC0; ADC3 si hay 3 grupos; ADC2 si hay 7); vértices ≥15 en ADC3 bit `4·grupos+5−k` (7 grupos: `33−k`, y el vértice 15 se completa con su pareja de reinicio).

## Texturas — `tex-ps2.ts`, `gsmem.ts`
- Pack `0xB3300000` (mismos IDs que PC). Tablas `0x33310004` TextureInfo (0x7C) + `0x33310005` PlatInfo (0x54) [D][V]; o entradas en streaming comprimidas `0x33310003` (coches) con TextureInfo+PlatInfo al final [V].
- Formatos: PSMT8 (`0x13`) y PSMT4 (`0x14`) con CLUT PSMCT32; alfa PS2 (0x80 = opaco). Mundo: 2 472 de 2 622 texturas son PSMT4 [V].
- **Swizzle** [V a ojo]: PSMT8 subido como PSMCT32 de (W/2)×(H/2); PSMT4 subido como **PSMCT16** de (W/2)×(H/2). CLUT de 8 bits en CSM1 (bits 3↔4 del índice).

## Transparencia, repetición y color de vértice [V][D]
Regla del juego: `eSetBlendMode` [D: `GameCube/Src/Ecstasy/EcstasyEx.cpp`]. Código: `alphaFor` en `tools/src/lib/materials.ts`.

| `AlphaUsageType` | `AlphaBlendType` | Modo | Texturas [V] |
|---|---|---|---|
| 0 ninguno | 0 copia | opaco | 1 012 |
| 2 modulado | 0 copia | **opaco** (el alfa no es transparencia: asfalto) | 367 |
| 1 recorte | 0 copia | prueba de alfa `> 0x28` (0,157) | 175 |
| 2 modulado | 1 mezcla | mezcla normal: `SHD_*` (1 026) y calcomanías, pintadas, cristales, alambradas (33) | 1 059 |
| cualquiera | 2 aditiva | aditiva (neones, luces) | 12 |

- El umbral de recorte es `0x28`, no 0,5 [D: `_alphaRef`]. Con 0,5 se perdían hojas, rejas y barandillas finas.
- `TilableUV` (`TextureInfo +0x4F`): bit 0 repite U, bit 1 repite V; 0 = recortar al borde [V: solo el 0,8 % de los UV de esas texturas sale de 0…1]. Carteles y señales usan 0. En el GLB va como `sampler` (`CLAMP_TO_EDGE` / `REPEAT`).
- Otros campos útiles de `TextureInfo`: `ApplyAlphaSorting +0x54` (23 texturas), `RenderingOrder +0x51` (4 = sombras), `ScrollType +0x52`.
- **Color de vértice**: 128 = 1,0 y el GS modula en espacio de pantalla [D/V]. El conversor lo guarda en `COLOR_0` como `(c/128)^2,2` (lineal, puede pasar de 1). Así cualquier visor glTF da textura × color igual que la PS2. Antes se guardaba sin linealizar y la luz horneada salía plana y apagada.
- Las banderas de tira (`eStripEntry.Flags`) siguen a la textura: `0x4040` ↔ mezcla, `0x4008` ↔ recorte [V]. No hay banderas de cara única: todo se dibuja a dos caras.
