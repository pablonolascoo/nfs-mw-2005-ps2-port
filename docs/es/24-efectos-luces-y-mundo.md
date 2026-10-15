# 24 · Efectos, luces y datos del mundo

> Paso `effects` del conversor: `bun src/cli/effects.ts <iso> <ID>` → `map-data/<ID>/effects.json` + `effects/`.
> Lectores: `tools/src/lib/effects.ts` y `tools/src/lib/world-extra.ts`. Tarda menos de 1 s.
> Etiquetas: **[V]** verificado en bytes de SLES-53559 · **[D]** decomp · **[I]** inferido · **[H]** hipótesis.
> Lo que ya exporta el paso `fx` (doc 20) no se repite aquí: sol (`0x00034202`), `visuallook*`, `light_flares_cg`
> (destellos de los coches), `eLightMaterial` (`0x00135200`) y texturas del cielo.

## 1. Resumen: qué hay y dónde

| Chunk | Nombre | Dónde | Estado | Qué sale |
|---|---|---|---|---|
| `0x0003BC00` | EmitterLibrary | `STREAML2RA.BUN` (290 secciones), `FRONTEND\PLATFORMS\*.BIN` | descifrado y exportado | 1 535 emisores del mundo + 41 de los garajes |
| — | `emittergroup` / `emitterdata` / `effects` / `simsurface` / `smackable` / `fuelcell_*` | `GLOBAL\ATTRIBUTES.BIN` (VLT) | descifrado y exportado | 128 grupos, 205 emisores, 198 efectos, 47 superficies |
| — | TPK «PARTICLE» | `GLOBAL\INGAMEB.BUN` | exportado | 46 texturas de partícula (PNG) |
| `0x00034027` | SmokeableSpawnerPack | `STREAML2RA.BUN` (350 secciones) | descifrado y exportado | 5 952 objetos rompibles |
| `0x00034026` | SmokeableInfo | — | no está en el disco PAL | — |
| `0x0013401A` | marcadores de sólido → destellos | `STREAML2RA.BUN` | descifrado y exportado | 2 242 destellos del mundo |
| `0x00034019/1A/1B`, `0x80135100/01/02` | packs de destellos | — | no están en el disco | ver §4 |
| `0x80036000/01/02/03` | EventTriggerPack | `STREAML2RA.BUN` (415 secciones) | descifrado y exportado | 12 161 disparadores (todos de sonido) |
| `0x00034159` | HeliSheet | `STREAML2RA.BUN` (435 secciones) | descifrado y exportado | 51 504 triángulos |
| `0x00034250` | Weatherman (GenericRegion) | `L2RA.BUN` | descifrado y exportado | 61 regiones (todas de bloom) |
| `0x8003B600…B608` | ParameterMaps | `L2RA.BUN` | descifrado y exportado | 14 capas (ambiente, reverb, voz, niebla, lluvia, nubes, viento, tinte) |
| `0x00034201` | TrackInfo | `GLOBALB.BUN` | descifrado y exportado | 18 pistas |
| `0x00034146` | TrackPositionMarker | `L2RA.BUN` | descifrado y exportado | 328 marcadores |
| `0x00034191` | TrackOBB | `L2RA.BUN` | descifrado y exportado | 1 caja |
| `0x00037080/90/110/150` | WorldAnim | `L2RA.BUN` | descifrado y exportado | 11 árboles e instancias |
| `0xB0300100` (`0x30300101/2/3`) | TextureAnimPack | `STREAML2RA`, `GLOBALB`, `INGAMEA`, garajes | descifrado y exportado | 11 texturas animadas |
| `0x0003410C` | ModelHierarchy | `L2RA.BUN` | descifrado y exportado | 125 jerarquías |
| `0x00034190` | «Trough» | `TRACKS\L2RA\TROUGHBOUNDARY.BIN` | parcial | 563 polígonos con nombre |
| `0x80034150` (`0x34151/52/53/55/58`) | VisibleSectionManager | `L2RA.BUN` | descifrado y exportado | 515 contornos, 435 listas de visibilidad, 39 zonas de carga, 2 overlays |
| `0x00034113` / `0x00034111` / `0x00034112` | streaming: DiscBundle / Info / Barriers | `L2RA.BUN` | descifrado y exportado / vacío | 75 lotes; info = {0, 0}; barreras de 0 B |
| `0x00034105/06/07` | árbol, ganchos y preculler del escenario | `STREAML2RA.BUN` | sin descifrar | ver §8 |

`L2RA_SUNSET.BUN` y `STREAML2RA_SUNSET.BUN` tienen los mismos chunks y las mismas cuentas [V: censo]. Se lee solo la versión de día.

## 2. Emisores de partículas

### 2.1 Colocación en el mundo: `0x0003BC00` [D: `Ecstasy/EmitterSystem.h`][V]
Datos alineados a 16 (relleno `0x11111111` delante).

```
EmitterLibraryHeader (0x10): i32 EndianSwapped, i32 Version (=5), i32 NumEmitterLibraries, i32 SectionNumber
por biblioteca:
  EmitterLibrary (0x50): u32 GroupKey @0x00 · u32 pad · u16 SectionNumber @0x08 · u16 NumTriggers @0x0A · ptr mGroup
                         · bMatrix4 LocalWorld @0x10 (filas; fila 3 = posición en metros, Z arriba)
  WorldFXTrigger × NumTriggers (0x30): bTNode · ptr · f32 radio @0x0C · bVector3 pos @0x10 · f32 reinicio @0x20
                         · u16 probabilidad @0x24 (0xFFFF) · u8 estado · u8 flags · f32 fin · pad
```
- Comprobado: cabecera + suma de bibliotecas y disparadores = tamaño del chunk en los 679 chunks [V].
- `GroupKey` es la clave Attrib (`attribHash`) de una colección `emittergroup`: **1 535/1 535 resueltas** [V].
- Todas las posiciones caen dentro de Rockport [V]. Los mismos paquetes salen en la sección N y en N+40 (LOD): se quita el duplicado por `SectionNumber`.
- 1 512 son continuos (sin disparadores) y 23 se disparan por cercanía (42 disparadores, radio 5 m, reinicio 3 s) [V].
- Tipos más comunes: hojas que caen (`fxenv_leaves1`, 627), niebla (`fxenv_fog1/2/1thick`, 577), humo de chimeneas y fábricas (`fxenv_chimney1`, `fxenv_smokestack*`), fuentes, pájaros, vapor.
- Garajes (`FRONTEND\PLATFORMS`): PLATFORMCRIB 11, CAREER_SAFEHOUSE 7, CAR_LOT 4, CUSTOMIZATION_SHOP 10, _BACKROOM 9.
- `0x0003BB00` (EmitterGroup ya horneado) no aparece en el disco: el juego crea los grupos desde el VLT.

### 2.2 Definiciones: `GLOBAL\ATTRIBUTES.BIN` [V][D]
- `emittergroup` (128): `Emitters[]` (referencias a `emitterdata`), `FarClip`, `IntensityRanges`.
- `emitterdata` (205): vida, velocidad, cono, gravedad, arrastre, tamaño por clave (`Size`, `KeyPositions`), cuatro colores, encendido/apagado (`OnCycle`, `OffCycle`), `Texture` y `TextureAnimation`.
  - `Texture` es `ParticleTextureRecord {u32 enum, u32 index}`: el enum es `bStringHash` del nombre de la textura [V: 42 usadas, todas resueltas].
  - `TextureAnimation` es `ParticleAnimationInfo {u32 tipo (0, 2, 4, 8, 16 = rejilla N×N), u8 FPS, u8 inicio aleatorio}`.
- `effects` (198): nombre de efecto → `emittergroup` (`carexhaustnos → fxcar_nos`, `carhit → fxcar_impactl`, `carblowtire → fxcar_tireblow`…).
- `simsurface` (47): `TireSlideEffects`, `TireSlipEffects`, `TireDriveEffects` = `TireEffectRecord {RefSpec emisor, f32 velMín, f32 velMáx}` por superficie [D: `MWAttribUserTypes.h`]. Es el humo y la tierra de las ruedas.
- `smackable` (181): reacción de cada rompible (masa, `EventSequencer`, `OnScrapeGround` = `EffectLinkageRecord {superficie, efecto, velMín, velMáx}`).
- `fuelcell_effect/emitter`, `emitteruv`: sistema nuevo de chispas (solo 4/8/4 colecciones).

### 2.3 Efectos del coche [D]
- Neumáticos: `TireState::Effect::LazyInit` crea el `emittergroup` de la superficie (`simsurface`) [D: `CarRenderConn.cpp`].
- Nitro, escape, golpes, cristales, reventón, muerte del coche de policía: `VehicleRenderConn::Effect::Fire/Update` con la clave del `emittergroup` (`fxcar_nos` = `emcar_nos_fire` + `emcar_nos_glow`) [D].
- Luces de policía como partículas: `fxcar_coplightred/blue/white` [V].

### 2.4 Texturas
46 texturas `FX_*` en el TPK «PARTICLE» de `GLOBAL\INGAMEB.BUN` [V]. Los nombres del TPK vienen cortados a 23 letras; se resuelven por hash con el enum `eTEG_ParticleTextures` [D]. Salen a `effects/particles/<NOMBRE>.png`.

## 3. Objetos rompibles: `0x00034027` [D: `Physics/SmokeableInfo.hpp`][V]
```
SmokeableSpawnerPack: bTNode · s16 ScenerySectionNumber @0x08 · s16 FirstID · s16 NumSpawners @0x0C · u8 swapped · u8 pad
SmokeableSpawner (0x40): Quaternion @0x00 · Vector4 pos @0x10 · UCrc32 modelo @0x20 · UCrc32 colisión @0x24
                         · UCrc32 atributos @0x28 · u32 SceneryOverrideInfo @0x2C · u32 id @0x30 · u32 ExcludeFlags @0x34 · ptr · pad
```
- 0x10 + n × 0x40 = tamaño del chunk en los 824 chunks [V].
- `UCrc32` = `attribHash` (Jenkins). Los 88 valores de `mAttributes` son colecciones `smackable` [V].
- Posición y giro en **espacio de simulación** (Y arriba). Mundo: `X = z, Y = −x, Z = y` [V].
- Comprobación: el `SceneryOverrideInfo` apunta a la instancia de escenario del objeto. **5 952/5 952** coinciden en posición a menos de 5 cm [V].
- Modelo: 5 242 resueltos por el nombre completo del sólido o de la instancia; 710 quedan con hash (el nombre original lleva minúsculas y en el disco solo está cortado a 23 letras). `sceneryModel` da siempre el nombre de la instancia.
- La colisión (`mCollisionName`) apunta a los `CollisionBody` de `0x0003B901` (doc del lector `lib/bounds.ts`).
- `0x00034026 SmokeableInfo` no existe en el disco PAL: los datos de reacción están en el VLT `smackable`.
- **En el motor (formato 11)**: el paso `tiles` saca la instancia de escenario de cada rompible de la casilla cercana (se queda en la lejana) y la escribe en `smackables/<SÓLIDO>.glb` (233 modelos) + `smackables.json` (id, sección, instancia, matriz). El motor los dibuja instanciados (Crash/SmackableRender.swift) y los tira con física (Crash/Smackables.swift): pegados al mundo hasta que el impulso supera `DETACH_FORCE` (0 = suelto, −1 = solo derrumbe) [D: AttachedToWorld/Detach; umbral I], gravedad del rigidbodyspecs `smackable` (−13 m/s²), arrastre `DRAG` como `RigidBody::DoDrag` [D], suelo con `GROUND_FRICTION`, reposo con `SLEEP_VELOCITY`; desaparecen tras `KILL_OFF_SCREEN` s fuera de pantalla y vuelven tras `RESPAWN_TIME` s [I]. Sonidos `SMK_<X>vsCAR_*` por material [I].

## 4. Destellos del mundo (farolas, semáforos, catadióptricos)
- En PS2 **no hay packs de destellos** (`0x00034019…`, `0x80135100…`) en ningún archivo [V: censo de GLOBAL, TRACKS y FRONTEND].
- El juego los crea en cada fotograma desde los **marcadores de los sólidos** (`0x0013401A`, `ePositionMarker` de 0x50 B) al dibujar el escenario [D: `Scenery.cpp`]:
  `posición = (marcador.fila3 − PivotMatrix.fila3) × matriz de la instancia`, `tipo = iParam0 + ELF_CATSEYE_ORANGE (14)`.
- 20 modelos tienen marcadores. Salen 2 242 destellos: 955 ámbar intermitente, 340 rojo, 199 verde, 748 catadióptrico naranja [V].
- 2 216/2 242 caen dentro de la caja de su instancia (±1 m). Las 26 restantes son de un solo modelo, `XS_MEDIANPOLER_1B_00`, cuyo segundo marcador queda fuera de su caja [V].
- Texturas y colores por tipo: `light_flares_cg` y `HEADLIGHTGLOW`, en el paso `fx` (doc 20).

## 5. Disparadores, helicóptero y marcadores

### 5.1 EventTriggerPack `0x80036000` [D: `World/EventManager.*`][V]
- `0x00036001` cabecera (0x20): bTNode · Version (=2) · ScenerySectionNumber · NumEventTriggers · swapped · 2 punteros.
- `0x00036002` árbol `vAABBTree` (0x10) + `vAABB` × n (0x30).
- `0x00036003` `EventTrigger` (0x20): NameHash · EventID · Parameter · TrackDirectionMask · pos[3] · radio.
- Los 12 161 son `TRIGGER_EVENT_SOUND` (0x10007): sonidos de ambiente por zona [V]. `Parameter`: 6 valores; `Comment` (555) y `OVERPASS` (380) resueltos por `bStringHash` con cadenas del ELF; los otros 4 no.
- Las salidas de carrera, garajes y radares **no** están aquí: están en el VLT (`gameplay.json`, doc 18).

### 5.2 HeliSheet `0x00034159` [D: `World/HeliSheet.cpp`][V]
`HeliSection` (0x18: bTNode, SectionNumber, NumPolys, swapped, ptr) + `HeliPoly` × n (18 B: s16 X[3], Y[3], Z[3]; X, Y × 0,25 m; Z × 0,0625 m).
Altura de vuelo = plano del triángulo que contiene (x, y), buscando en la sección conducible. Caja: x −1 563…4 966, y −1 201…5 092, z −11…510 m.

### 5.2b Helicóptero en el motor
La HeliSheet limita la altura del helicóptero de la policía (Crash/Heli.swift, doc 14 §8.3).

### 5.3 TrackPositionMarker `0x00034146` [D][V]
0x30 B: bTNode · NameHash · Param · bVector3 · bAngle · TrackNumber (2000). 318/328 con nombre (`bStringHash` de cadenas del ELF): `BustedMomentMarker` 194, `IconMarker` 37, `TollboothMarker` 36, `GarageMarker` 14, y los derrumbes de persecución («Moments»: gasolinera, torre de agua, andamios…).
- Los 37 «Moments» con rompibles de estructura alrededor son los derrumbes de persecución del motor (Crash/PursuitBreakers.swift, doc 14 §8.2).

### 5.4 TrackOBB `0x00034191` [D: `World/Track.hpp`][V]
Una caja de 0x60 B (hash de tipo `0xA4E74294` sin nombre, en 2090, 1405, 153; 11,55 × 4,4 × 0,05 m).

## 6. Clima, niebla, tinte y sonido por zonas

### 6.1 Weatherman `0x00034250` [D: `World/WeatherMan.hpp`][V]
`WeatherRegionPack` (0x10: bTNode, Version 2, NumRegions 61) + `GenericRegion` × 61 (0xA4: nombre, grupo, tipo, color de niebla, posición, radio, intensidad, caídas, forma, mezcla…). Las 61 son de tipo `BLOOM` (`BLOOM_CP_*`): puntos de brillo, no lluvia ni niebla.

### 6.2 ParameterMaps `0x8003B600` [D: `World/ParameterMaps.cpp`][V]
Cada capa `0x8003B601`: cabecera `B602` (0x24) · tipos `B603` · offsets `B604` · conjuntos `B605` · árbol cuaternario `B607` (u8, 4 B) o `B608` (u16, 8 B). Sin relleno. Hoja: hijo0 = 0, dato = hijo1. Búsqueda por (x, y) del mundo [D]: lo hacen el sonido ambiente (`Ambience`) y el de túnel (`Reverb`).

| Capa | Campos | Conjuntos | Uso |
|---|---|---|---|
| Ambience | 1 int | 11 | ambiente sonoro por zona |
| Reverb | 3 | 19 | reverberación (túneles, calles) |
| Speech | 2 int | 26 | zona para la radio de la policía |
| Clouds, Rain | 2 float | 4 | densidad de nubes y lluvia |
| Wind | 2 float | 2 | viento |
| Normal Fog, Rain Fog | 8 float | 3–4 | niebla por zona |
| Screen Tint SunRise / Midday | 3 float | 1 | tinte de pantalla (RGB 219, 206, 87) |
| Fog Blend Distance | 1 float | 1 | 50 m |
| 3 sin nombre | 1–3 | 1 | dos tintes (219, 186, 87) más |

Los nombres salen por `bStringHash` de `ParameterAccessor("…")` de la decomp y de cadenas del ELF [V].

### 6.3 TrackInfo `0x00034201` (`GLOBALB.BUN`) [D][V]
18 × 0x120 B. La 2000 es «Most Wanted World» (`L2RA`, calibración del minimapa, `SunInfoNameHash 0xB05E7F4C` sin resolver). Las demás son pistas de prueba de EA (Speedway, «CG Visual Target», «(5400) Carbon»…).

## 7. Animaciones y texturas animadas

### 7.1 WorldAnim [D: `Animation/AnimEntity_WorldEntity.cpp`][V]
- `0x37080` `WorldAnimEntityInfo` (0x70): tipo, instancia, padre, modelo, LOD, árbol y animación, matriz local.
- `0x37110` `WorldAnimEntityTreeMarker` (0x50): cierra un árbol (las entidades leídas antes) con 4 rangos con nombre.
- `0x37090` `WorldAnimInstance` (0xA0): id, árbol, sección, velocidad, retardos, disparadores, matriz y caja.
- `0x37150` `WorldAnimInstanceEntryInfo` (0x10): id, árbol, sección, tiempo.
- 11 árboles e instancias en Rockport. Las curvas son EAGL (`0x00E34010`): las lee el paso de NIS.

### 7.2 TextureAnimPack `0xB0300100` [D][V]
`0x30300101` cabecera (0x10) · `0x30300102` `TextureAnim` (0x34: nombre[24], hash, fotogramas, FPS) · `0x30300103` fotogramas (0x10: hash).
11 animaciones: agua `ANM_WATERA_` (14 fotogramas, 17 FPS), semáforo de paso, carteles con luces, rótulo de Bob's Lobster, rotor, bombillas, televisión y ventilador del refugio. Los nombres de fotograma salen de los TPK del mismo archivo [V].

### 7.3 ModelHierarchy `0x0003410C` [D][V]
`ModelHeirarchy` (8 B) + `Node` × n (0x10: UCrc32 nombre, hash del sólido, ptr, flags, padre, hijos, primer hijo). 125 jerarquías de rompibles con piezas (raíz + `_FRAG*`).

## 8. Visibilidad y streaming (`effects/visibility.json`) [D][V]
- `0x34151`: `LODOffset = 40` (por eso cada sección N tiene su LOD en N+40) y 373 secciones conducibles de la región.
- `0x34152`: 515 contornos (0x24 + NumPoints × 8 en disco; caja, centro, puntos).
- `0x34153`: 435 secciones conducibles con su lista de secciones visibles (0x12 + MaxVisible × 2, alineado a 4). Es el PVS del juego.
- `0x34155`: 39 zonas de carga (`LoadingSection`, 0x4C).
- `0x34158`: overlays `FlyBy` (500 entradas) y `E3Demo` (0).
- `0x34113`: 75 lotes de disco (`DiscBundleSection`, 0x14 + n × 8).
- `0x34105` (árbol de escenario, 0x24 B por nodo en el disco), `0x34106` (ganchos de override) y `0x34107` (preculler, 128 B por grupo): descifrados en el doc 22 §10 (`lib/scenery-cull.ts`).

## 9. «Troughs»: `0x00034190` (`TROUGHBOUNDARY.BIN`) [V][I]
Struct `TroughBoundary` en los tipos de PS2 de la decomp [D] (+0x58 `TypeRegularTrough`, +0x59 `TypeTroughHole`, +0x5A `TypeAntiTrough`, +0x5C `TroughNumber`, +0x5E `ParentTroughNumber`): 484 normales y 79 agujeros [V]. Comprobado en los 563 chunks:
`u32 ×2 (0) · char Name[80] · u32 tipo · u16 a · u16 b · bVector2 mín · bVector2 máx · u32 n · bVector2 puntos[n]`.
Nombres `TRN_CP_*_Road/Terrain_*`, `TROUGH_*`, `TroughNJ_*`, con `_Hole` y `_Segment`. Son perímetros 2D por zonas [I]. Su uso (límite de fuera del mapa o de reinicio) es una hipótesis [H].

## 10. Qué puede usar ya el port
- Partículas del mundo (`worldEmitters`) y de los garajes con sus definiciones y texturas: humo, niebla, hojas, fuentes, pájaros.
- Humo y tierra de ruedas por superficie, nitro, golpes y reventones (`library.tireEffectsBySurface`, `library.effects`).
- Destellos de semáforos y catadióptricos (`flares`).
- Rompibles con su modelo, posición, giro y tipo de reacción (`smokeables`).
- Niebla, nubes, lluvia y tinte por zona; ambiente y reverb por zona para el audio (`parameterMaps`, consulta con `parameterSetAt`).
- Altura del helicóptero (`heli-sheet.json`), marcadores de persecución y garajes, PVS por sección.

## 11. Pendiente
- 4 de los 6 `Parameter` de los disparadores de sonido y el `NameHash` de los disparadores.
- 3 capas de parámetros sin nombre, el hash de sol de TrackInfo y el tipo de la TrackOBB.
- 710 modelos de rompibles con nombre completo desconocido (en el disco solo está cortado).
- El uso exacto de los troughs (`0x34105/06/07`: doc 22 §10).
- Reproducción de partículas, destellos y niebla/tinte por zona en el motor nativo: hechos (doc 20 §9, `native-engine/Sources/Rockport/Effects/`). Faltan los rompibles, los disparadores de sonido y el material del suelo para el polvo y el agua de las ruedas.
