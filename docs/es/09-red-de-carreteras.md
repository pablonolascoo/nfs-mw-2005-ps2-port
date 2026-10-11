# Red de carreteras y colisión

Etiquetas: [V] verificado con bytes reales de SLES-53559 · [D] sacado del decomp · [H] hipótesis.

Código: `tools/src/lib/roads-ps2.ts` (lector) y `tools/src/cli/roads.ts` (exportador).
Uso: `bun src/cli/roads.ts <iso> <ID>` → `map-data/<ID>/roads.json`.

## 1. Qué chunk es cada cosa

| Chunk | Archivo | Qué es |
|---|---|---|
| `0x0003B800` | `L2RA.BUN` | `BCHUNK_UPPLE_UWORLD` = `BCHUNK_CARP_WGRID`. Mundo "CARP": rejilla espacial y **red de carreteras** [D][V] |
| `0x0003B801` | `STREAML2RA.BUN`, por sección | `BCHUNK_CARP_WCOLLISIONPACK`. **Colisión** de una sección: suelo (tiras de triángulos) y muros (barreras) [D][V] |

El cargador de `0x0003B800` es `WWorld::Loader`. El de `0x0003B801` es `WCollisionAssets::LoadCollisionPack` [D].

## 2. Formato UGroup (común a los dos chunks)
- Los datos empiezan alineados a 16 B. El hueco previo se rellena con bytes `0x11` [V].
- Todo es un árbol de registros de 16 B: `u32 tag · u32 bits · u32 count · u32 offset` [D][V].
- La etiqueta se lee como texto: `'RN'<<16 | 'gp'` → `RNgp` [D][V].
- **Grupo:** `bits >> 5` = nº de subgrupos. `count` = nº de datos. `offset` en unidades de 16 B desde el registro. Ahí van primero los subgrupos y luego los datos [V].
- **Dato:** `bits >> 8` = tamaño total en bytes. `count` = nº de elementos. `offset` en bytes desde el registro [V].
- Etiquetas con índice: tipo de 2 letras + `u16` (p. ej. `ca#7`) [D][V].

Árbol de `0x0003B800` en SLES-53559 [V]:

```
CARP
├─ CDat: CGcn (2779 celdas), CGrd (1), co#0 (vacío)
├─ Map : vacío
└─ RNgp: RNhd (1), RNnd (4385), RNpf (710), RNrd (1308), RNsg (6538)
```

## 3. Coordenadas
- Los datos están en espacio "Bond": Y arriba [D].
- Paso a mundo (Z arriba): **X = z, Y = −x, Z = y** (`bConvertFromBond`) [D][V].
- Con ese paso, los nodos caen en X −1404…4857, Y −987…4569, Z −13…265 [V]. Coincide con Rockport.

## 4. Red de carreteras (`RNgp`)

### Cabecera `RNhd` (14 B) [D][V]
`u16` × 6: perfiles 710 · nodos 4385 · segmentos 6538 · intersecciones 0 · carreteras 1308 · cruces 0.
No hay datos de intersecciones en el disco [V].

### Nodo `RNnd` (32 B) [D][V]
| Offset | Tipo | Campo |
|---|---|---|
| 0x00 | f32×3 | posición (Bond) |
| 0x0C | s16 | índice propio (= posición en la tabla en los 4385) [V] |
| 0x0E | s16 | perfil de la calzada |
| 0x10 | u8 | nº de segmentos (1–7) |
| 0x12 | u16×7 | segmentos que tocan el nodo |

### Segmento `RNsg` (22 B) [D][V]
| Offset | Tipo | Campo |
|---|---|---|
| 0x00 | u16×2 | nodo inicial, nodo final |
| 0x04 | u16 | longitud × 1000/65535 m |
| 0x06 | s16 | carretera (`RNrd`); −1 en los tramos de cruce |
| 0x08 | s16 | índice propio [V] |
| 0x0A | u16 | flags (tabla abajo) |
| 0x0C | u16 | largo del tirador final |
| 0x0E | u16 | largo del tirador inicial |
| 0x10 | s8×3 | dirección del tirador final (/127) |
| 0x13 | s8×3 | dirección del tirador inicial (/127) |

- Tirador en metros = `dir × largo × 500/(127·65535)` [D].
- La curva es una **Bézier cúbica**: `[inicio, inicio+tiradorInicial, fin+tiradorFinal, fin]` [D].
- Prueba: la longitud guardada coincide con el arco de esa Bézier. Error mediano 0,01 m, p95 0,05 m [V].
- Los tiradores apuntan hacia dentro del tramo en 6133 de 6538 segmentos [V].

Flags (`fFlags`) [D]; recuento en SLES-53559 [V]:

| Bit | Nombre | Nº |
|---|---|---|
| 0 | decision | 3463 |
| 1 | noTraffic | 1356 |
| 2 | raceRouteForward | 0 (se rellena en carrera) |
| 3 | intersection | 3463 |
| 4 | entrance | 1809 |
| 5 | copsXorTraffic | 21 |
| 6 | oneWay | 104 |
| 7 | shortcut | 0 |
| 8 | curved | 5892 |
| 9 / 10 | endInverted / startInverted | 1220 / 1222 |
| 11 | chopperStayLow | 7 |
| 12 / 13 | crossesBarrier / crossesDriveThroughBarrier | 0 (se calculan al cargar) |
| 14 | laneMap | 239 |
| 15 | inRace | 0 (se rellena en carrera) |

### Perfil `RNpf` (64 B) [D][V]
- `u8 numZones`, `u8 middleZone`, 2 B de relleno, 15 carriles de `u32`.
- Carril: tipo = bits 0–3; ancho = bits 4–17 con signo × 100/8191 m; desplazamiento = bits 18–31 igual [D].
- Ejemplo, perfil 1: 6 zonas de 3,99 m, desplazamientos ±2, ±6, ±10 m. Tipos 3‑1‑1‑1‑1‑3 [V].
- `middleZone` separa los carriles de un sentido y del otro [D].
- Tipos vistos: 1, 2, 3, 4, 7, 10 [V]. El tipo 1 es tráfico [D]. Según las tablas `drivable_lanes`, 7 (y 13) no se conducen; 2 lo evitan los policías; 10 lo usan las carreras y el reaparecer [D]. Los nombres concretos son [H].

### Carretera `RNrd` (8 B) [D][V]
`u16 nScale` (siempre 256 = escala 1) · `u16 nLength` · `u8 nShortcut` (siempre 255 = ninguno) · `u8 nMinWidth` · `u16 nSpeechId` (83 valores).
- `nLength / 16,384` ≈ suma de las longitudes de sus segmentos (mediana 16,378) [V]. La escala exacta es [H].
- `nMinWidth` sin unidad confirmada [H]. `nSpeechId` sería el nombre de calle que dice la radio de la policía [H].

### Rejilla `CDat` [D][V]
- `CGrd` (36 B): mínimo Bond (−4800, 0, −1664), celda de 64 m, 103 filas × 92 columnas.
- Columna sale de Bond x; fila de Bond z [D].
- `CGcn`: 2779 celdas guardadas, seguidas sin hueco. Cabecera de 20 B: `u32 0 · u16 celda · u16 0 · u8 nº[4] · u16 offset[4]`; luego `u32` por elemento [D][V].
- Listas por celda: instancias de colisión (`sección<<16 | índice`), triggers, objetos y segmentos de carretera [D].
- Todas las celdas guardadas tienen al menos un segmento [V].

## 5. Colisión por sección (`0x0003B801`)
Sí: este chunk es **geometría de colisión**. No es la red de carreteras.

- Cabecera `bChunkCarpHeader` (16 B): `s32 tamaño · s32 nº de sección · s32 flags · u32 dirección` [D][V].
- Luego un árbol UGroup: `CARP` → `Arti` con `Name` (texto, p. ej. "101"), `ci#0` (instancias) y `ca#N` (artículos) [D][V].
- 454 chunks, 390 packs distintos. El pack N está en la sección de streaming N o N+40 (p. ej. pack 101 en A41); 64 packs salen dos veces [V]. El porqué es [H].

### Instancia `ci` (64 B) [D][V]
| Offset | Campo |
|---|---|
| 0x00 | fila 0 de la matriz (f32×3) + ancho |
| 0x10 | u16 sello · u16 flags (bit 0‑1: eje Y no vertical) |
| 0x14 | f32 altura |
| 0x18 | u16 grupo · u16 artículo |
| 0x1C | puntero (0 en disco) |
| 0x20 | fila 2 de la matriz + largo |
| 0x30 | traslación inversa P + radio |

- Mundo → local: `local = R·mundo + P`. Por tanto `mundo = Rᵀ·(local − P)` [D][V].

### Artículo `ca#N` [D][V]
- Cabecera 16 B: `u16 nº tiras · u16 bytes tiras · u16 nº barreras · u16 bytes barreras · u8 resuelto · u8 nº superficies · u16 · u16 · s16 flags`.
- Tiras: primero una esfera por tira (`f32 pos[3] · u16 radio · u16 offset`); luego los vértices.
- Vértice (8 B): `s16 x, y, z` / 128 + centro de la esfera, y `u16` de superficie.
- En el vértice 0 ese campo es el nº de vértices; en el 1 son flags (1 = mira arriba) [D].
- Barrera (32 B): dos `f32×4`. Puntos inferior y superior de un muro vertical. `w` del 1.º = superficie; `w` del 2.º = 1/longitud en planta [D].
- Al final, un hash `u32` por superficie (material físico) [D].
- Total en Rockport: 243 418 triángulos y 45 793 barreras [V].

## 6. Comprobaciones hechas [V]
- Índices: 0 referencias rotas nodo↔segmento; cada segmento listado en un nodo lo enlaza de vuelta.
- La red es un único grafo conexo. Grados: 5 nodos de grado 1, 1766 de grado 2, el resto 3–7.
- **Nodos sobre el suelo:** 4373 de 4385 caen a < 1 m de un triángulo de colisión. Error mediano 0,000 m. Los 10 restantes no tienen triángulo debajo.
- Punto medio de cada Bézier: 6277 de 6538 a < 1 m del suelo (mediana 0,08 m).
- Esto valida a la vez la red, la colisión y la matriz de las instancias.

## 7. Pendiente
- Nombres de los tipos de carril 2, 3, 4, 7, 10 [H].
- Unidad de `nMinWidth` y `nSpeechId` de `RNrd` [H].
- Unidad de `radio` en las esferas de tiras (¿/16?) [H].
- Para qué sirve la copia de un pack en la sección N+40 [H].
- Rutas de carrera: viven en `TrackPathManager` y en los eventos; `inRace`/`raceRouteForward` se calculan en tiempo de juego [D].
- Escribir: el formato es plano (tablas de tamaño fijo). Añadir nodos/segmentos exige recalcular `RNhd`, los tamaños UGroup y las listas `CGcn` [H].
