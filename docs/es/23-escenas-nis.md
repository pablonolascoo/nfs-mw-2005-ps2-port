# Escenas NIS (cinemáticas con el motor)

Etiquetas: [V] verificado en bytes de SLES-53559 (y SLUS-21351, mismo resultado) · [D] decomp `dbalatoni13/nfsmw` (fuente o ensamblador) · [I] inferido · [H] hipótesis.

Las NIS son las escenas que el juego reproduce **con su propio motor**: la llegada a la salida de cada carrera, las presentaciones de los rivales de la Lista Negra, los arrestos, el final, el vuelo de la intro, los «momentos» de la zona libre (WM*) y las partes con coches de las películas (FMV*). No son vídeo: son cámaras + animaciones de coches y personajes + eventos (nitro, luces, efectos, pantallas) + audio.

Lector: `tools/src/lib/nis.ts`. Exportador: `tools/src/cli/nis.ts`.

## 1. Cómo se ejecuta

```bash
cd tools && bun src/cli/nis.ts ../original/SLES-53559.iso SLES-53559
```

Unos 4 s de CPU. Sale en `map-data/<ID>/nis/` (no se sube a git, `.gitignore`: `map-data/**/nis/`):

| Archivo | Qué es |
|---|---|
| `index.json` | Las 87 escenas (de la tabla del juego), bancos de audio NIS, candidatos, grupos de cámara sin escena, tamaños por chunk |
| `<Escena>.json` | Cabecera, duración, actores, cámaras (claves + muestreo a 30 fps), eventos, revoluciones del motor, audio |
| `<Escena>.glb` | Nodos animados (coches, esqueletos de personajes con su malla en reposo) y cámaras glTF animadas |

Resultado [V]: 87 escenas · 83 pistas de cámara (824 claves) · 271 coches animados · 64 personajes · 805/805 animaciones decodificadas · 1365 eventos con tiempo · 58 escenas con audio · 86 GLB válidos (glTF Validator: 0 errores, 0 avisos).

## 2. Mapa de datos

| Chunk | Nombre | Dónde | Estado | Notas |
|---|---|---|---|---|
| `0x80037020` | NisScene (contenedor) | `NIS\SCENE_*_BUNDLEB.BUN` | descifrado y exportado | Contiene 0x37030 y 0x37040 [D: `LoaderAnimSceneData`] |
| `0x00037030` | Cabecera NisScene | NIS | descifrado y exportado | §3 [V] |
| `0x00037040` | Entidades (personajes/props) | NIS (arrestos) | descifrado y exportado | §4 [D][V] |
| `0x00E34010` | EAGLAnimations | NIS, INGAMEB, L2RA | descifrado y exportado (NIS) | ELF con `AnimBank`; tipos 10, 11, 20, 21 decodificados; 17 (DeltaQ) sin decodificar (solo en INGAMEB) §5 |
| `0x00E34009` | EAGLSkeletons | NIS (arrestos), INGAMEB (`ROOT`) | descifrado y exportado | ELF con `SkeletonData` §6 |
| `0x0003B811` | EventSequence «CARP» | NIS, L2RA | descifrado y exportado (NIS) | Máquina de estados + acciones con eventos §8 |
| `0x8003B200`–`0x8003B203` + `0x0003B210` | Cámaras ICE por contexto | `GLOBAL\INGAMEB.BUN` | descifrado y exportado | NIS, FMV, REPLAY, GENERIC §7 |
| `0x0003B211` | ICEShakeTracks | INGAMEB | descifrado, sin usar | 4 pistas, los 11 556 B cuadran [V] |
| `0x00037060` | AnimDirectory | INGAMEB | descifrado y exportado | Escena → BUN §9 |
| `0x00037070` | CAnimCandidateData | INGAMEB | parcial | Contadores, momentos y listas de coches; candidatos de salida en crudo §9 |
| `0x80134000` / `0xB3300000` | Sólidos y texturas | NIS (arrestos) | exportado (malla en reposo) | Policías, detenidos y esposas; sin pesos de piel |
| `SOUND\NISREVDATA\*.BIN` | Revoluciones del motor | 29 archivos | descifrado y exportado | §10 |
| `SOUND\STREAMS\NISAUDIO.IDX/.EVT/.BIG` | Audio NIS | — | descifrado y enlazado | Escena → pista `audio/escenas/NNN.flac` §11 |

## 3. Cabecera de escena `0x00037030` [D: `NisScene`, `AnimScene.hpp`] [V]

| Desp. | Tipo | Campo |
|---|---|---|
| 0x00 | u32 | `mSceneNameHash` = bStringHash(nombre) — es también el `handle` del grupo de cámaras |
| 0x04 | char[16] | nombre (`IntroNis01`, `ArrestM01`…) |
| 0x14 | ptr | descripción (en el archivo: 0; el texto va justo detrás, en 0x40) |
| 0x18 | s32 | `SceneType` |
| 0x1C | s32 | `HaveLayout` |
| 0x20 | s32 | `HaveCarAnimation` |
| 0x24 | s32 | `NumberOfCars` |
| 0x28 | s32 | `StartFrame` (fotogramas a 30 fps) |
| 0x2C | s32 | `VanishFrame` → **duración = VanishFrame / 30 s** [D: `BindToGame`] |
| 0x30 | char[16] | overlay del «Seeulator» (vacío en todas) |
| 0x40 | char[] | descripción («Cars rolling up to start», «Career Racestart Number 05»…) |

`SceneType` [D: `CAnimScene::Init`, `SetCarAnimationPositions`] [V: 25/26/4/32 escenas]:

| Valor | Escenas | Origen de coordenadas |
|---|---|---|
| 0 | IntroNis01–09, GenericStart, IntroNisToll01, WM* | línea de salida |
| 2 | Arrest* | posición de la actividad (el arresto) |
| 3 | Replay* | línea de salida, jugador forzado al coche 1 |
| 4 | IntroNis10, IntroNisBL*, IntroNisDD*, Ending*, Flythrough, FMV* | **mundo** (0,0,0): las coordenadas son absolutas |

Con 0, 2 y 3 la matriz de escena es `traslación(origen, z = suelo) · rotZ(ángulo − 90°)` [D: `CAnimLocator::GetInitialAnimMatricies`]; el origen y el ángulo los pone la actividad (`NISActivity::StartLocation`): para las salidas es la parrilla de la carrera (`races.json` → `start.pos`/`yaw`).

Comprobación [V]: los coches de IntroNisBL05 terminan en (4794, 973, 13,8) y la parrilla de `race_bin_05/5_2_2_sprint` está en (4792,6, 994,2, 11,7): la escena es de mundo y cae en su carrera. En IntroNis01 los coches llegan de y = −28 a y = −3 (escena local, la salida en el origen).

Coordenadas: espacio de render del juego, Z arriba, metros (como `world.json` y `races.json`). En simulación (Y arriba) = (−y, z, x) [D: `NISActivity::GetNISStartLocation`].

## 4. Entidades `0x00037040` [D: `AnimEntity_BasicCharacter.hpp`, `AnimEntity_Prop.hpp`] [V]

Precedidas de relleno `0x11`. Personaje (`mTypeID` = 1, 0x90 B; prop = 2, 0x60 B):

| Desp. | Campo |
|---|---|
| 0x00 | `mTypeID` |
| 0x04 / 0x08 | hash de instancia / de padre |
| 0x0C | `mPlayFlags` |
| 0x10 | `mLocalMatrix` (4×4, colocación en la escena) |
| 0x50 | `mLODNameHash[4]` = hash del sólido (`MCOP01`, `PERP01`, `CUFFS01`…) [V] |
| 0x60–0x6C | hashes de las animaciones de traslación, rotación, escala y esqueleto |
| 0x70 | hash del esqueleto (`Bip20`, `Bip23`, `Bip24`…) |
| 0x74 / 0x78 | velocidad y retardo de reproducción |
| 0x7C–0x8C | tipo de objeto del mundo, bucle, relleno |

Solo hay personajes (64, en los arrestos). Velocidad con esqueleto: `playSpeed × 0,5` → 15 fps [D: `AnimEntity_BasicCharacter.cpp`].

## 5. Animaciones `0x00E34010` [D: `EAGL4Anim/*`] [V]

El chunk es una **imagen ELF32 MIPS reubicable** (tras relleno `0x11`): `.data`, `.symtab`, `.rel.data` (solo `R_MIPS_32` contra la sección, así que los punteros son desplazamientos dentro de `.data`). El símbolo `__AnimationBank:::bank` apunta a:

```
AnimBank { s32 size, s32 numAnims, ptr attributeDict, ptr csisDict, ptr anims[], ptr names[], ptr stat }
```

Cada animación empieza por `u16 tipo, u16 checksum`. En las NIS todas son **15 = Compound** `{tipo, cs, ptr atributos, u16 nCanales, u16 nFotogramas, ptr canales[]}` con subcanales [V: 805 animaciones]:

| Tipo | Nombre | Formato | Uso |
|---|---|---|---|
| 10 | DeltaLerp | `{tipo, cs, ptr datos, u16 nFotogramas, u16 dofIdx[]}` + DeltaCompressedData | traslación y escala de coches |
| 11 | DeltaQuat | igual, 4 valores por índice | rotación de coches y huesos |
| 20 | DeltaF3 | cubos de 2^p fotogramas: u16 físico ×3 + deltas u8 ×3 | traslación de huesos |
| 21 | DeltaF1 | igual con 1 componente | huesos sueltos |
| 17 | DeltaQ | — | solo `Rotate_360_q` de INGAMEB: **sin decodificar** |

DeltaCompressedData [D: `DeltaCompressedData.cpp`]: `u16 nDofs, u8 bits (4/8/16), pad`, `DofInfo {f32 min, f32 range, f32 start}[nDofs]` y deltas por fotograma: `valor(f) = start + Σ_{i<f} (q_i · range + min)`.

DeltaF1/F3 [D: `FnDeltaF3.cpp`, `InitBuffersAsRequired` en ensamblador]: cabecera `{tipo, cs, ptr dofIdx, ptr tiempos, u16 nClaves, u16 nHuesos, u8 p, u8 nConst, pad}`, `DofInfo {f32 physMin[c], f32 physRange[c], u16 qMin[c], u16 qRange[c]}`; físico = `q·range/65535 + min`; delta = `q · range·2·qRange/65535/255 + range·(2·qMin/65535 − 1)`. Si `tiempos ≠ 0` son claves en esos fotogramas. Huesos constantes detrás del último cubo.

Los índices de DOF apuntan al búfer SQT de 12 floats por hueso: **0–2 escala, 4–7 cuaternión (x, y, z, w), 8–10 traslación** [D: `/0xC` en `DeltaChan.cpp`] [V: 2811 curvas en 4, 2438 en 8, en NIS, L2RA e INGAMEB].

Comprobación [V]: todos los cuaterniones de las 2811 curvas de rotación (NIS, L2RA e INGAMEB), fotograma a fotograma, tienen norma 1 ± 0,004.

**Coches**: `<Escena>ZPM_Car1…8` / `ZPM_Cop1…8` con sufijos `_t`, `_q` (y `_s`), sobre el esqueleto `ROOT` de INGAMEB (2 huesos; el coche es el hueso 1) [D: `CreateCarAnimationControllers`]. Se reproducen a escala de tiempo 0,5 → **fotograma = t · 15** [D]. Eje delantero del coche = +X [V: el ángulo del cuaternión sigue la dirección del movimiento]. El juego después baja el coche al suelo y lo pasa a la física (`SetNISPosition`).

## 6. Esqueletos `0x00E34009` [D: `SkeletonData.h`] [V]

Misma imagen ELF. `__Skeleton:::<nombre>` → `{u32 AnimationTarget, u16 checksum, u16 flags, s32 nHuesos, ptr invEscalas}` + `BoneData[n]` de 0x70 B: `S(3), s32 padre, Q(4), T(3), s32 izq/der, matriz inversa de base (16)`. Cada `__Bone:::<esqueleto>.<hueso>` apunta a un u32 con el índice del hueso (`Bip20 L Thigh`…).

Hay: `ROOT` (2 huesos, coches), bípedos `Bip20`–`Bip23` (48 huesos), esposas `Bip24` (3 huesos).

## 7. Cámaras ICE [D: `ICEData.hpp`, ensamblador de `ICEMover`/`ICEManager`] [V]

Están todas en `GLOBAL\INGAMEB.BUN`: un contenedor por contexto (`0x8003B200` NIS, `…01` FMV, `…02` REPLAY, `…03` GENERIC) con 85 grupos `0x0003B210`:

```
grupo:  u32 handle (NIS/FMV: hash de la escena) · u32 nPistas · pistas
pista:  ptr sig, ptr ant, ptr grupo, f32 Start, f32 Length, s16 nClaves, s8, char[14] nombre, nClaves × ICEData
```

ICEData (0x84 B):

| Desp. | Campo | Desp. | Campo |
|---|---|---|---|
| 0x00 | u8 tipo (12/13/14) | 0x10 | f32 `fParameter` (inicio del tramo, 0–1) |
| 0x01 | u8 suave | 0x14 | f32 tangente[2] |
| 0x02 / 0x03 | u8 cúbico ojo / mirada | 0x1C | f32 ojo[2][3] (inicio, fin) |
| 0x04 / 0x05 | u8 espacio ojo / mirada: 0 coche, 1 mundo, 2 híbrido, 3 escena | 0x34 | f32 mirada[2][3] |
| 0x06 / 0x07 | u8 limitar a coches / mundo | 0x4C | f32 giro «dutch»[2] (radianes [I]) |
| 0x08 / 0x09 | u8 ignorar orientación / retardo en espacio de coche | 0x54 | f32 lente mm[2] |
| 0x0A | u8 overlay | 0x5C | f32 plano cercano[2] |
| 0x0C | u32 tipo de sacudida | 0x64 / 0x6C | f32 ruido amplitud / frecuencia[2] |
| | | 0x74 | f32 distancia focal[2] |
| | | 0x7C / 0x7E / 0x80 | u8 apertura[2], franjas[2], velocidad de simulación %[2] |

Cada clave es un **tramo** del parámetro `[fParameter, fParameter de la siguiente]` (la última hasta 1) con valores de inicio y fin; la clave siguiente empieza donde acaba la anterior [V].

Evaluación [D]:
- NIS: `p = (t − inicio) / (duración − inicio)` con la duración de la escena (`ICETrack::GetParameter`). FMV/GENERIC: `(reloj − Start) / Length`.
- `t` local lineal dentro del tramo (`ICEMover::Update`).
- Ojo y mirada: Hermite (`ICE::Cubic1D`: `a = s0+s1−2Δ, b = 3Δ−s1−2s0`) si `bCubicEye`/`bCubicLook`, si no lineal. Giro y FOV: Hermite con el indicador del ojo.
- Pendientes (`ICEManager::GetSlope`): si el vecino comparte el extremo, `w = tc/(tc+tv)`, pendiente = `Δvecino · w · tc/tv · tangente + Δpropia · (1−w) · tangente`; si no, `Δpropia · tangente`.
- FOV = `2 · atan(15,96 / lente)` [D: constante `0x417F5C2A`]; se interpola en ángulo. Horizontal [I]; en el GLB se pasa a vertical con aspecto 4:3 [I].

Comprobación [V]: en las salidas la mirada cae a 1–5 m de un coche animado en cada segundo; en los arrestos a ~1 m de los personajes.

Sin aplicar todavía: ruido, sacudidas (`0x3B211`), retardo en espacio de coche y las claves en espacio **coche** (29 claves NIS y 41 FMV: el JSON trae el espacio de cada clave para que el motor las resuelva con la matriz del coche).

Grupos sin escena: REPLAY (6 grupos, cámaras de repetición en espacio de coche), GENERIC (36 pistas) y un grupo NIS `0x020DE420` (8 pistas) cuyo nombre no sale de ninguna lista [?].

## 8. Eventos «CARP» `0x0003B811` [D: tipos `EventSeq*`, `bChunkCarpHeader`] [V]

```
bChunkCarpHeader {s32 tamaño, s32 sección, s32 flags, ptr}            16 B
"PRAC" {u32 ?, u32 nEntradas+1, u32 1}                                 16 B
"srtS" {u16 ?, u16 bytes de texto, u32 nCadenas, u32 desp. desde srtS} 16 B
entrada × n: {u16 índice, char[2] tipo, u8 3, u24 tamaño, u32 hash, u32 desp. relativo a la entrada}
```

Los nombres se cifran con `attribHash` (Jenkins, semilla 0xABCDEF00) y la tabla de cadenas los trae todos. Las referencias internas son `{u16 índice, char[2] tipo}`.

| Tipo | Estructura |
|---|---|
| `Ee` | EventSeqEngine `{ref nombre, u32 nSistemas, u32 ids[], ref sistemas[]}` |
| `Se` | EventSeqSystem `{u32 estado inicial, u32 por defecto, u32 nEstados, ids[], refs[]}` — un sistema por actor: `car1`, `cop1`, `GLOBAL`… |
| `Te` | EventSeqState `{u32 nEstímulos, ptr filtro, u32 estímulos[], {u32 estado final, ref acción}[]}` |
| `Ae` | EventSeqAction `{u32 nombre, u32 nTags, u32 nTiempos, f32 duración, tags[], f32 tiempos[], ref listas[]}` |
| `le` | EventList `{u32 n, pad[3]}` + `{u32 id, u32 tamaño, u32 desp., pad}[n]` + datos |
| `Ni` / `Sc` | cadenas (nombre del motor / textos de eventos) |

Id del evento = `attribHash("E" + nombre)` [V: los 33 tipos se resuelven]. Los datos (`Event::StaticData`) se leen con los campos de `Generated/Events/*.hpp`. Más usados: `ENISDetach`/`ENISReattach` (soltar/enganchar el coche a la animación), `ENISCarShake`, `ENISNitro`, `ENISPixelate`, `ENISCarPitch`/`Roll`, `ENISLights`, `ENISBrakelock`, `ENISBurnout`, `ENISOverlayMessage` (`BUSTED_OVERLAY.fng`, `BLACK_FADE_OUT.fng`…), `ENISPlayEffect` (`env_leafblast1`, `dustbillow_md1`…), `ENISTimeOfDay`, `ENISRain`.

En todas las escenas cada sistema pasa de `Begin*` a `End*` con el estímulo `START` y lanza su acción; la línea de tiempo del JSON supone que `START` llega en t = 0 [I].

## 9. Directorio y candidatos (INGAMEB)

`0x00037060` AnimDirectory (0x4808 B) [D] [V]: `u32 nEscenas` · `AnimSceneLoadInfo[256] {u32 hash, u8 nCompartidos, u8 primero, u8 nPropios, u8 primero}` · `u32 nArchivos` · `char[256][64]` rutas (`NIS\Scene_IntroNis01_BundleB.bun`). 87 escenas = 87 BUN del disco.

`0x00037070` CAnimCandidateData (0x1054 B) [D]: 1 candidato de salida, 41 «momentos» (escena → tipo: arrestos 12, WM* 1–20, peaje 13) y 53 listas de coches especiales (arrestos `ONE_COP`, Lista Negra `TRAFFIC_MIX1–5`…). Las máscaras por circuito están vacías.

## 10. Revoluciones `SOUND\NISREVDATA\<ESCENA>.BIN` [D: `NIS_RevManager::OpenNISRevData`] [V]

16 conjuntos seguidos (coche 1–8, policía 1–8): `u32 n` y, si n > 0, `n × {f32 tiempo s, s32 RPM, s32 acelerador 0–100}`. Lo que queda detrás es basura del grabador (p. ej. 7 452 B en IntroNis02). 28 escenas + `OPMRivalIntro` (sin BUN): casi siempre solo el coche 1; RPM 1000–10 000. Así suena el motor de tu coche en la escena.

## 11. Audio `SOUND\STREAMS\NISAUDIO.*` [D: `SFXObj_NISStream.cpp`, `NISAudio.hpp`] [V]

`.IDX` es un CLUMP_IDX como el de la radio: 4 bancos. Cabecera de banco: `u16 frase, u16, u8 nParámetros, u8 nClips, u8, u8 unidad, u32`; por clip `u16 BE desplazamiento × (unidad+1)·256 B` + parámetros [V: los 140 clips caen en una cabecera SCHl].

| Frase | Evento Csis | Clips | Parámetros |
|---|---|---|---|
| 0x4023 | `NIS_Select_Start` | 30 | bit de escena, bit de pista de cámara (13 = Track00, 14/15 = entrar/salir del garaje), sección (0 completa, 2 final) |
| 0x4025 | `NIS_Select_Blacklist` | 34 | bit de rival (0 = BL01… 15 = BL16, 16/17 = BL06End/BL07End), pista, sección |
| 0x4024 | `NIS_Select_End` | 18 | bit de arresto/final, pista, sección |
| 0x400E | `SoundFX_Select` | 58 | 2 parámetros (efectos sueltos) |

Escena → bit: tabla `uNIS_STRINGHASHMAP` (68 entradas) del juego. GenericStart tiene una pista por cámara (`audio.cameraTrack1`). «Completa» es la pista entera; «final» es lo que suena si saltas la escena. Las pistas duran más que la animación (IntroNis01: 6 s de escena, 11,2 s de audio, que siguen durante la cuenta atrás) [V: duraciones de las FLAC]. Sin audio: IntroNis09, IntroNisBL01 (no hay clip con su bit), WM*, Replay*, FMV* (estas usan el audio de la película). BL06End y BL07End usan el audio de BL06/BL07 (así está en la tabla del juego) aunque el banco trae clips propios.

## 12. Esquema del JSON de escena

```jsonc
{
  "scene": "IntroNis01", "nameHash": "0x0d0e57f6", "description": "...", "sceneType": 0,
  "origin": "...", "coordinates": "Z arriba, metros...", "startSeconds": 0, "duration": 6,
  "bundle": { "solids": 0, "texturePacks": 0, "models": [...], "textures": [...], "skeletons": [{ "name", "bones": [{ "name", "parent", "t", "q", "s" }] }] },
  "actors": {
    "cars": [{ "slot": "car1", "channel": "car1", "anims": [...], "frames": 91, "fps": 15, "seconds": 6, "start": [x,y,z], "end": [x,y,z],
               "startRotation": [x,y,z,w], "track": { "t": [x,y,z,...], "q": [x,y,z,w,...], "s": [...] } }],
    "characters": [{ "typeName": "character", "model": "MCOP01", "skeleton": "Bip20", "skelAnim": "ArrestM01_MCop_s", "frames", "fps", "localMatrix": [16], ... }]
  },
  "animations": [{ "name", "frames", "channels": [{ "type", "typeName", "decoded", "dofs" }] }],
  "cameras": [{ "context": "NIS", "track": 0, "name": "Track 0", "start", "length", "spaces": ["scene"],
                "keys": [ICEData como en §7 + "fovDeg"], "sampleFormat": ["time","eyeX","eyeY","eyeZ","lookX","lookY","lookZ","fovDeg","dutch"], "samples": [[...] a 30 fps] }],
  "events": { "engine", "systems": [{ "name", "initialState", "states": [{ "name", "responses": [{ "stimulus", "endState", "action" }] }] }],
              "actions": [{ "name", "duration", "tags": [...], "timed": [{ "time", "events": [{ "id", "name", "data", "raw" }] }] }],
              "timeline": [{ "time", "actor", "action", "event", "data" }] },
  "engineRevs": { "sets": [{ "slot": 0, "points": [[t, rpm, acelerador], ...] }] },
  "audio": { "csisEvent", "sceneBit", "complete": { "clip", "file": "audio/escenas/060.flac", "seconds" }, "buttonThroughEnd": {...} }
}
```

GLB: raíz `NIS_<escena>` girada −90° en X (Z-arriba → Y-arriba), hijo `scene_origin` (colocar en la parrilla si la escena no es de mundo), nodos `car1…`/`cop1…`, personajes (`MCOP01`… con la jerarquía de huesos y la malla en reposo como hijo) y `camera_<contexto>_<pista>` con cámara glTF. Animaciones: `actors` y una por pista de cámara (son alternativas: el juego elige una con `ChooseGoodSceneCameraTrackIndex`).

## 13. Escenas

| Grupo | Escenas | Qué muestran |
|---|---|---|
| Salidas | GenericStart, IntroNis01–10, IntroNisToll01 | Coches llegando a la parrilla, trompos, nitro; 6–15 s |
| Lista Negra | IntroNisBL01–16, BL06End, BL07End | Presentación del rival antes de su carrera, con policías; 15–32 s, de mundo |
| Día D | IntroNisDD, IntroNisDDEnd | Salida de la carrera del Día D (43 s) |
| Arrestos | ArrestF02…M19 (+ variantes «b») | Policía (M = hombre, F = mujer) y detenido con esposas junto al coche patrulla |
| Final | EndingNis03, EndingNis04 | Salida del último rival y final del juego |
| Mundo | WM* (14) | Cámaras de los «momentos» de la zona libre (gasolinera que explota, torre de agua…) |
| Película | FMV17to21, FMVroc02, FMV20T1, FMVBLIntro, FMVPIN11X06, FMVPSA, FMVTest, FMVNoCars | Parte de las películas hecha con el motor (coches y cámaras de contexto FMV) |
| Repetición | ReplaySpeed/Corner/Burnout/Slide | Animaciones cortas de coche para las repeticiones |
| Vuelo | Flythrough | Vuelo por Rockport (45 s, 42 claves) |

## 14. Lo que falta

- DeltaQ (tipo 17), solo en una animación de INGAMEB [H: cuaternión comprimido con W recuperado, `DeltaQRecoverW`].
- Piel de los personajes: las mallas salen en postura de reposo; falta qué hueso mueve cada tira.
- Cámaras en espacio de coche/híbrido, ruido, sacudidas (`0x3B211` leído pero no aplicado) y retardos de `ICEMover`.
- El momento exacto de cada estímulo CARP fuera de `START` (los eventos con tag) [I].
- `0x00037070`: significado de los campos de los candidatos de salida.
- Grupo de cámaras NIS `0x020DE420` sin nombre.
- Unidades del giro «dutch» (radianes [I]) y si el FOV es horizontal [I].
