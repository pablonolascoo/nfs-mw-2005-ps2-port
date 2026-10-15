# Música y mezcla

Etiquetas: [V] verificado en bytes con SLES-53559 (y SLUS-21351 donde se indica) · [D] decomp · [I] inferido · [H] hipótesis.

La música del juego es **interactiva**: EA PathFinder 5. Un archivo `.MPF` describe un grafo de trozos de audio
(nodos), cómo se encadenan (ramas) y qué hace cada orden del juego (eventos). El audio va en un `.MUS` aparte.

## 1. Archivos

| Archivo (`SOUND\…`) | Bytes | Qué es |
|---|---|---|
| `PFDATA\MW_MUSIC.MPF` + `.MUS` | 8 936 + 257 105 024 | Canciones de EA Trax, ambientes y golpes musicales (proyecto 0) |
| `PFDATA\MW_MUS_1…4.MPF` + `.MUS` | 14–18 KB + 30–42 MB | Música de persecución: 4 proyectos, uno activo cada vez |
| `MIXMAPS\MAPOUTPUT{,DRG,2CR,2DR}.MXB` | 10 008 | Mapas de mezcla que carga el juego |
| `MIXMAPS\MAPOUTPUT{,DRG,2CR,2DR}.DYN` | 43 656–43 784 | El mismo mapa con nombres (archivo del editor) |
| `FXEDIT\*.FX` (15) | 160–336 | Presets de reverberación |
| `EVT_SYS\*.CSI` (7), `SPEECH\COPSPEECH_*.CSI` (3) | 64–5 136 | Interfaces Csis («MOIR») |

Totales [V]: **1363 muestras**, 3,2 h de audio. Los 10 archivos de `PFDATA`, los mapas de mezcla y las reverbs son
**idénticos byte a byte en SLES-53559 y SLUS-21351** [V]; el NTSC solo trae el `.CSI` de la radio en inglés. Canciones 26 (91 min), ambientes 14, golpes 8, persecución 1310 trozos.

## 2. Extraer (uso local)

```bash
cd tools && bun src/cli/music.ts ../original/SLES-53559.iso SLES-53559            # rápido: copia + JSON
bun src/cli/music.ts ../original/SLES-53559.iso SLES-53559 --audio                # + cada muestra en FLAC (ffmpeg)
bun src/cli/music.ts ../original/SLES-53559.iso SLES-53559 --check                # compara con vgmstream-cli
bun src/cli/music.ts ../original/SLES-53559.iso SLES-53559 --dump                 # grafo por consola
```

Sale en `map-data/<ID>/music/` (no se sube a git):

```
music/
├─ MW_MUSIC.MPF/.MUS, MW_MUS_1…4.MPF/.MUS   tal cual del disco (~400 MB). La app decodifica sola.
├─ music.json        proyectos (nodos, ramas, eventos, muestras), canciones, ambientes, golpes y lógica del juego
├─ mixmaps.json      4 mapas × 13 estados con nombres
├─ reverbs.json      15 presets + zona que usa cada uno
├─ csi.json          interfaces Csis
└─ audio/<PROYECTO>/NNN[ Artista - Título].flac   solo con --audio (1363 FLAC)
```

Código: `tools/src/lib/pathfinder.ts` (MPF + MUS + decodificador), `tools/src/lib/mixmap.ts` (MXB/DYN, CSI, FX),
`tools/src/cli/music.ts`.

## 3. Formato MPF (PathFinder 5) [V]

Little endian. Los 4 primeros bytes son `xDFP` («PFDx» al revés).

| Desp. | Tipo | Qué |
|---|---|---|
| 0x04 | u8, u8 | versión 5, subversión 1 |
| 0x06 | u16 | 0x01B0 [?] |
| 0x0C | u8 | 0 en MW_MUSIC, 1 en MW_MUS_n [?] |
| 0x0D–0x11 | u8 × 5 | nº de pistas (1), secciones, eventos, routers, variables |
| 0x12 | u16 | nº de nodos |
| 0x14 | u32 | índice de nodos (u16 por nodo, × 4 = posición) |
| 0x18 | u32 | datos de nodos |
| 0x1C / 0x20 | u32 | índice de eventos (u16 × 4) / datos de eventos |
| 0x24 | u32 | variables (20 B cada una) |
| 0x28 | u32 | índice de routers (u32 × 4, uno más que routers) |
| 0x2C / 0x30 | u32 | índice de pistas / datos de pistas |
| 0x34 | u32 | tabla de muestras (8 B cada una) |
| 0x38 | u32 | fin del archivo (= tamaño) |

**Nodo**: 16 B + 4 B por rama. El tamaño de cada nodo cuadra con el índice en los 1664 nodos [V].

| Desp. | Qué |
|---|---|
| 0x00 i16 | onda: `N > 0` = muestra N−1 · `0` = nodo mudo (cabecera de una parte) · `−1` = fin · `−3` = lanza el evento de 0x0C |
| 0x02 u8 | sección × 0x20 (MW_MUSIC: 1 canciones, 2 ambientes, 3 golpes) [I] |
| 0x03 u8 | 0x00, o 0xF8 en nodos de fin con dos ramas [?] |
| 0x04 u8 | 13–34 en las ondas de persecución, 0 en MW_MUSIC [?] |
| 0x05 u8 | nibble alto = nº de ramas |
| 0x06 u8 | 0x40 = tiene onda · 0x10 = sin onda |
| 0x08 u16 | en ondas: nodo de la **parte** a la que pertenece. Es el `nodeparm` que recibe `SongProgressCallback` [D]. En el resto, un contador |
| 0x0B u8 | 4 en ondas (avisar al juego) [I] |
| 0x0C u32 | en nodos −3: id del evento (24 bits) |
| 0x10 | ramas `{u8 mín, u8 máx, u16 destino}`: al acabar se va al destino si `mín < control ≤ máx` (mín 0xFF = −1) |

El **control** es la intensidad 0–127 que manda `MusicFlow::Update` con `PATH_control` [D].
Tramos típicos de las ramas: ≤20, ≤65, ≤85/100/110, ≤127 [V].

**Evento**: 20 B + 12 B por acción. 0x0C = id (24 bits bajos) | nº de acciones << 24 [V]. El id del código del juego lleva otro
byte alto (p. ej. 0x01C53FC7 en la decomp y 0x02C53FC7 en el disco): se comparan los 24 bits bajos [V].

| Acción (tipo/código) | Parámetros | Qué |
|---|---|---|
| 4/3 | nodo, 0xFF | ir al nodo [V: lleva a cada canción y parte] |
| 4/0x0F | 0xFFFF, 0x1FF | vaciar la cola / parar lo que suena [I] |
| 0x0D/0x0F | parámetro, id | llamada al juego `EventActionCallback(id, parámetro)` [D]: 1 = fin de canción, 2 = InteractiveDone, 3/0 y 3/1 = cambiar de proyecto (EVT_SWAP1/2) |
| 5/0x0C | 0x100 \| volumen, ms | fundido [H] (0x100 → 0 en 1750–3500 ms; 0x17F → 127) |
| 2/0x0C | ms, 0 | espera [H] |
| 8/0x0D | 127, 23 | volumen [H] |
| 8/6, 0x0E/0x0A, 0x0E/0x0E, 4/2 | — | variables y routers [H] |
| 1/0x9D, 0x9E, 0xAD, 0xAE, 0x11D, 0x12D | variable, valor | condición «si variable == valor» y variantes [H]; 1/0x40 cierra el bloque |
| 9/0 | id bajo, id alto | lanzar otro evento [H] |

En las condiciones, la variable 0 de MW_MUSIC es `rapsheet` (1–3, la pone el juego con `PATH_setnamedvalue`) [D+V];
en los proyectos de persecución la 3 contiene el nodo de la parte actual (se compara con 0, 0x6A, 0xD5, 0x132…) [I].

**Variable**: nombre[16] + i32 inicial. MW_MUSIC: `rapsheet`, `partnode`, `newnode`, `ambstate`; persecución: `partnode`, `newnode`.
**Router**: lista de pares u16 (nodo, nodo); 26–34 por proyecto de persecución, ninguno en MW_MUSIC [?].
**Pista**: u32 primera muestra, u16 sub-bancos (0 = flujo), u32 big endian = 4 primeros bytes del `.MUS` [V].
**Muestra**: u32 desplazamiento/0x80 en el `.MUS` · u32 duración en ms [V: coincide con la cabecera de cada flujo].

## 4. Formato MUS [V]

Flujos `SCHl` seguidos, alineados a 0x80, uno por muestra:

- `SCHl` {u32 LE tamaño} `GSTR` (plataforma genérica) + u32 y etiquetas `{tag, n, n bytes BE}` hasta 0xFF:
  0x06 prioridad (101), 0x80 versión (3), 0x82 canales (2), 0x84 frecuencia (32 000), 0x85 nº de muestras.
- `SCCl` (nº de bloques, BE), `SCDl` × n, `SCEl`.
- `SCDl` {u32 LE tamaño} u32 **BE** muestras del bloque (6412 = 229 tramas) · u32 BE desplazamiento de cada canal · datos.
- Códec **EA-XA v2** por canal: tramas de 15 B (28 muestras) o 0xEE + historias + 28 muestras PCM (61 B).
  La historia del ADPCM **sigue** de un bloque al siguiente.
- 36 216 B/s (el `PATH_TRACK_BYTESPERSEC` de la decomp) [D].

Decodificador propio: `decodeMusStream()` en `pathfinder.ts`. **Las 1363 muestras son idénticas a vgmstream r2117 muestra a
muestra** (239 M muestras estéreo de MW_MUSIC + 130 M de MW_MUS_1…4) [V]. Velocidad: ~3,5 s para las 2 h de canciones en un M4.

## 5. Canciones (EA Trax)

Los títulos están en la base de atributos (`GLOBAL\ATTRIBUTES.BIN`, clase `music`: `Artist`, `SongName`, `Album`, `PathEvent`,
`DefPlay`) y el orden en `audiosystem.mwlicensedmusic.PFMapping` [V]. `PathEvent` es el id del evento de MW_MUSIC que la pone.
`DefPlay`: FE = menús, IG = juego, AL = las dos.

| # | Artista – Título | DefPlay | Muestra | Duración |
|---|---|---|---|---|
| 0 | Styles Of Beyond – Nine Thou (Superstars Remix) | AL | 16 | 3:48 |
| 1 | T.I. Presents The P$$C – Do Ya Thang | FE | 14 | 4:06 |
| 2 | Rock – I Am Rock | FE | 8 | 3:24 |
| 3 | Suni Clay – In A Hood Near You | FE | 13 | 3:43 |
| 4 | The Perceptionists – Let's Move | FE | 2 | 2:55 |
| 5 | Juvenile – Sets Go Up | FE | 17 | 3:52 |
| 6 | Hush – Fired Up | FE | 1 | 3:19 |
| 7 | DJ Spooky and Dave Lombardo – B-Side Wins Again feat. Chuck D | FE | 3 | 4:27 |
| 8 | Celldweller feat. Styles Of Beyond – Shapeshifter | AL | 15 | 3:17 |
| 9 | Lupe Fiasco – Tilted | FE | 5 | 3:24 |
| 10 | Ils – Feed The Addiction | IG | 21 | 3:54 |
| 11 | Celldweller – One Good Reason | IG | 7 | 3:12 |
| 12 | Hyper – We Control | IG | 11 | 2:54 |
| 13 | Static-X – Skinnyman | IG | 12 | 3:21 |
| 14 | Diesel Boy + Kaos – Barrier Break | IG | 22 | 2:18 |
| 15 | Disturbed – Decadence | IG | 10 | 3:18 |
| 16 | The Prodigy – You'll Be Under My Wheels | IG | 6 | 3:53 |
| 17 | The Roots and BT – Tao Of The Machine (Scott Humphrey's Remix) | IG | 20 | 3:06 |
| 18 | Stratus – You Must Follow (Evol Intent VIP) | IG | 24 | 3:55 |
| 19 | Mastodon – Blood And Thunder | IG | 18 | 3:41 |
| 20 | Evol Intent, Mayhem & Thinktank – Broken Sword | IG | 23 | 2:33 |
| 21 | Bullet For My Valentine – Hand Of Blood | IG | 4 | 3:18 |
| 22 | Paul Linford and Chris Vrenna – The Mann | IG | 26 | 3:28 |
| 23 | Avenged Sevenfold – Blinded In Chains | IG | 9 | 5:27 |
| 24 | Jamiroquai – Feels Just Like It Should (Timo Maas Remix) | IG | 19 | 3:00 |
| 25 | Paul Linford and Chris Vrenna – Most Wanted Mash Up | IG | 25 | 3:34 |

Resto de MW_MUSIC [V salvo donde se indica]:
- Muestra 0 (30 s): pantalla de inicio (evento 0x01C53FC7, `SPLASH`) [D].
- Muestras 27–29: ficha policial (rap sheet), una por valor de `rapsheet` (1–3) [D+V]. 30: silencio de 0,3 s en bucle.
- Muestras 31–39: ambiente de las zonas 0–8 del mapa; 40 refugio, 41 taller, 42 resto de menús, 43 concesionario
  (`AmbientCrossMap` [D]; zona 9–13 en `UpdateAmbience` [D]). 44: ambiente del evento 0x9DF7DA [?].
- Muestras 45–52: golpes de 3–6 s al cambiar de proyecto de persecución (EVT_SWAP1/2 de cada uno de los 4 proyectos) [D+V].
- Cada canción: nodo mudo → onda → nodo −3 (evento 0x641F27, llamada 1 = «ha acabado») → fin. El juego elige la siguiente.
- Los ambientes de zona hacen un fundido según la variable `ambstate` y se repiten (rama 1–127 al mismo nodo); con control 0
  pasan al siguiente [H].

## 6. Música de persecución (MW_MUS_1…4)

Cada proyecto tiene 9 **partes**, cada una un nodo mudo seguido de ondas cortas (1,5–16 s) [V]. Los nodos de cada parte
salen de `PFXMAP` en la decomp (`SFXCTL_Pathfinder5.cpp`) [D] y coinciden con las cabeceras del archivo [V]:

| Parte | MW_MUS_1 | MW_MUS_2 | MW_MUS_3 | MW_MUS_4 |
|---|---|---|---|---|
| NEUTRAL | 0 (104 ondas) | 0 (106) | 0 (71) | 0 (64) |
| LOSE (te pillan) | 106 (105) | 108 (76) | 73 (59) | 66 (98) |
| WIN (escapas) | 213 (91) | 186 (48) | 134 (100) | 166 (104) |
| ELUDE (te escondes) | 306 (75) | 236 (40) | 236 (85) | 272 (38) |
| LOSE_END / WIN_END / ELUDE_END | 383 / 393 / 399 | 278 / 290 / 300 | 323 / 335 / 345 | 312 / 322 / 332 |
| ENDPAUSE_1 / END_PAUSE_2 | 409 / 412 | 310 / 313 | 355 / 358 | 342 / 345 |

Cómo suena (decomp, `Speech/MusicFlow.cpp` y `SFXObj_Pathfinder.cpp`) [D]:
1. Si `SoundAI` está en persecución activa o buscando, `StartInteractiveMusic(0x026E7282)` cambia de MW_MUSIC al proyecto
   interactivo; MusicFlow espera 0,5 s y manda `EVT_START` → nodo 0 (NEUTRAL).
2. Cada fotograma, MusicFlow calcula una intensidad 0–1 (media 0,99/0,01) y la manda × 127. Al acabar cada onda, la rama
   cuyo tramo contiene la intensidad elige la siguiente: más intensidad = capa más intensa.
3. MusicFlow cambia de estado y manda el evento: NEUTRAL 10, LOSE 11, WIN 12, ELUDE 13, fin 14 (`EVT_ENDWIN`) o 15
   (`EVT_ENDBUSTED`). Los eventos comprueban la parte actual (condiciones) y saltan a la parte nueva.
   - LOSE: el jugador va a menos del 12,5 % de su punta con un bloqueo, o la policía a < 32 m.
   - WIN: velocidad media > 50 % de la punta (o en enfriamiento y ≥ 35 %).
   - ELUDE: buscando, parado y sin ser visto > 4 s.
   - Cada estado dura al menos 30–90 s antes de cambiar («busy»).
4. Cada onda avisa al juego de su parte (`SongProgressCallback`), y así MusicFlow sabe dónde está.
5. Al acabar, la parte final lanza la llamada 2 (`InteractiveDone`) y vuelven las canciones tras 40 s de ambiente
   (`PURSUIT_TO_LIC_DELAY`).
6. Proyecto: uno de los 4 al azar al empezar; `EVT_SWAP1/2` pasa al siguiente y suena el golpe de MW_MUSIC.
   En pantalla partida no se carga ninguno (solo canciones).
7. «Pursuit breaker»: paso bajo de 65 535 → 630 Hz en 1 s y luego 1800 Hz; al salir vuelve a 65 535 Hz.

## 7. Mapas de mezcla (MIXMAPS) [D estructura; V lectura]

`szMixMapFiles[eMapType]`: 0 `MAPOUTPUT` (normal), 1 `MAPOUTPUTDRG` (drag), 2 `MAPOUTPUT2CR`, 3 `MAPOUTPUT2DR`
(pantalla partida [I por el nombre]). El juego carga el `.MXB`; el `.DYN` es el mismo mapa con nombres.

- Cabecera `stMixMapHeader` {MixMapID 0, NumStates 13, tabla en 0x10, −1} y 13 estados (`eMAINMAPSTATES`: MAIN, MUSIC,
  PLAYERCAR, AIRACECAR, COPCAR, TRAFFIC, ENVIRONMENT, COLLISION, DRIVEBY, PLANE, TRAIN, HELICOPTER, TRUCK).
- Estado `stMixMapStateHdr` (0x20 B): desplazamientos a MixCtl, 3DMixCtl, SubMix, MasterMix, Preset y EventCtl.
- Registros (ver `mixmap.ts`): MixCtl `{nINPUTID, nUScaleCntSwing}` + escalas; 3DMixCtl `{nINPUTID}` + 24 B por estado de cámara;
  SubMix `{MIXCHID, UpperLowerSwing}` + entradas; Master `{MIXCHID, MixData, SFXOBJID}` + entradas; Event
  `{nEVTCTLID, nUScaleCntSwing, nTriggerID, 3 parámetros}` + escalas (envolvente AR/ASR/ATR/LFO); Preset por canal maestro.
- Cada sección acaba justo donde empieza la siguiente en los 4 mapas [V].
- `MAPOUTPUT`: estado MAIN con 23 controles («FE Music Slider», «IG Music Slider», «SFX Slider»…), 38 controles de evento
  («NIS Play Ducker», «Pursuit Breaker», «Speech Ducker», «Jump Cam Duck»…), 24 canales maestros («@Cop Speech», «@RADIO volume»…).
- Nombres: 1352 registros con nombre del `.DYN`; 22 registros del `.DYN` de MAPOUTPUT/DRG tienen valores algo distintos
  (versión anterior del editor: volúmenes y una entrada) [V]. Los de 2CR/2DR coinciden todos.

## 8. Reverbs (FXEDIT) y CSI

- `SFXObj_Reverb` carga 12 presets (`csfxedit[]`) y elige por la zona del ParameterMap «Reverb»
  (`ReverbZoneCrossMap`: CARSHOW_SML, CARSHOW_BASS, CARSHOW_BASS_2, GARAGE, GARAGE_SML, SIMPLE_TUNNEL, SIMPLE_TUNNEL_SML,
  HILLS_CLOSE, HILLS, CITYOPEN, CITYDENSE, ALLEY) [D]. En el disco hay 15 `.FX`.
- `.FX` big endian: «FX» 0x0B00, u32 tamaño (= archivo) [V], u32 4, u32 n [?], … u32 3, u32 m [?]. Luego módulos
  (`{u8 tipo, u8 nº, u16, u16}`: tipo 7 con dos valores, tipo 1 con 5000–7500 [¿ms de retardo?]) y conexiones de 12 B
  `{u32 desde, u32 hasta, u8, u8}` en dos cadenas, con relleno 0xCCCC [H]. Lo ejecuta el IOP (`Snd::Hal::SetCustomFx`), que no está en la decomp.
- `.CSI` «MOIR»: lista de interfaces Csis `{nombre, id}` + id del archivo. **452 de 454** coinciden con los `InterfaceId` de
  `EAXSound/SND_GEN/*.cpp` [V+D]. Las dos que no: `FX_ROADNOISE_TRANS` no está en la decomp y lleva el id que la decomp
  da a `FX_ROADNOISE` (0x1B49), y `FX_ROADNOISE` lleva 0x2C48 (otra revisión de la interfaz). Los de
  `COPSPEECH_*.CSI` (139, uno por evento de la radio) usan la versión 1 de la cabecera, con el nº en el u16 de 0x0A.

## 9. Pendiente

- Confirmar con las funciones `PATH_*` (solo en ensamblador en la decomp) la lectura de §10.2: condiciones, fundidos, variables
  del sistema, routers (byte 0x04 = router + 1) y los nodos de fin con 0xF8. La lectura propia ya suena bien con los 5 proyectos.
- Acciones 0x0E y 4/2 (variables internas y routers) sin efecto en el port.
- Muestra 44 y eventos 0x9B7A50, 0xD2E818, 0x4F246E, 0xB29728, 0x6DD6BB: sin nombre en la decomp.
- Formato completo de los `.FX` y aplicar la reverb por zona; usar los mapas de mezcla también para los efectos (la música ya los usa).
- `EVT_INITSWAP` (cambio de proyecto a mitad de persecución con su golpe): no se sabe qué lo dispara; el port cambia de proyecto
  al volver a las canciones, como `StartLicensedMusic` [D].
- Rótulo de la canción («chyron», `NotifyChyron` [D]) en el HUD: de momento solo en la consola.

## 10. Reproductor en el motor nativo

| Pieza | Archivo | Qué hace |
|---|---|---|
| Datos | `Audio/MusicData.swift` | `music.json`, `.MUS` mapeados en memoria, decodificador EA-XA v2 (el de `pathfinder.ts`), niveles de `mixmaps.json`, capa «Ambience» de `effects.json` |
| Grafo | `Audio/MusicPathFinder.swift` | Una pista por proyecto: ramas por intensidad, eventos con condiciones y esperas, routers, parte actual |
| Salida | `Audio/MusicOutput.swift` | AVAudioEngine propio a 32 kHz; cada pista es una cadena de ondas **sin huecos** (la siguiente se encola 0,6 s antes) con su volumen y fundidos |
| Juego | `Audio/MusicSystem.swift` | `SFXObj_PFEATrax` y `MusicFlow` [D]: canciones, persecución, ambientes, mezcla, ajustes |
| Pruebas | `Audio/MusicTests.swift` | `--music-test`, `--music-live` |

### 10.1 Qué suena y cuándo [D: `SFXObj_Pathfinder.cpp`, `MusicFlow.cpp`]

- **«Pulsa START»**: evento `0x01C53FC7` (SPLASH, la muestra 0 de 30 s; a los 30 s el juego vuelve a la demo, doc 22 §13.2).
- **Menús, garajes y concesionario** (FE): canciones de la lista FE (DefPlay FE o AL). Sin canciones (EA Trax apagado o lista
  vacía): ambiente del sitio (9 refugio, 10 taller, 11 menú, 12 concesionario).
- **Zona libre y carreras** (IG): canciones de la lista IG (IG o AL), al azar o en orden, sin repetir hasta agotar la lista
  (`GenNextMusicTrackID`). Al pasar de menús a juego, si la canción no es de la lista nueva, se cambia. Carreras de aceleración:
  sin canciones (ambiente) [D: `TestToLicensed`].
- **Persecución** (`TestToPursuit`): policía persiguiendo o buscando → se corta la canción, `MusicFlow` espera 0,5 s y manda
  `EVT_START`. Cada actualización (30 Hz) manda la intensidad × 127 como control; los estados cambian de parte con los eventos
  10–15. Arresto: `EVT_ENDBUSTED`; fin sin arresto: `EVT_ENDWIN` [I: quién manda el 15 no está en la decomp].
- **Tras la persecución**: el remate de la parte final llama a `InteractiveDone` → 40 s del ambiente de la zona
  (`PURSUIT_TO_LIC_DELAY`) → siguiente canción. El siguiente proyecto de persecución es el siguiente de los 4 (`SwapInteractiveProjects`).
- **Ambiente de la zona**: capa «Ambience» de los ParameterMaps en la posición del coche (zonas 0–8, doc 24 §6.2); al cambiar de
  zona, fundido de 3,5 s y entrada en 3 s (los eventos del disco).
- **Películas**: la música se pausa donde estaba y sigue al acabar.
- **Pantalla partida**: sin música interactiva (no se carga el proyecto, `m_Flags & 2` [D]); solo canciones y ambientes.

### 10.2 Cómo se lee el grafo (lo que no está en la decomp)

| Cosa | Lectura | Etiqueta |
|---|---|---|
| Ramas | al acabar una onda, la rama con mín < control ≤ máx; si ninguna, la del tramo más cercano | [V] tramos · [H] el «más cercano» |
| Control de MW_MUSIC | 0: el juego no lo manda nunca. Con más de 63/70 las cabeceras de *Feels Just Like It Should* y *Feed The Addiction* saltarían la canción (rama directa al nodo de fin) | [I] |
| Nodos de fin con byte 3 = 0xF8 | ramas `{0,0}` siguiente y `{1,127}` repetir: se repite (los ambientes suenan en bucle hasta que el juego cambia de zona) | [H] |
| Nodo −3 | lanza su evento cuando la música **llega** ahí (no al encolar); −1 termina o sigue su rama | [I] |
| 4/15 | vaciar la cola **y cortar** lo que suena (fundido de 25 ms): `STOP` es solo esta acción | [I] |
| 4/3 | ir al nodo: ya si no suena nada; si suena, al acabar la onda actual | [I] |
| Condiciones 1/x | código = operación × 16 + tipo: 0x9 «si ==», 0x11 «si ≠», 0xA «si no, si ==», 0x12 «si no, si ≠»; tipo 0xE = variable del proyecto, 0xD = del sistema (3 = parte actual, 4 = suena algo); 1/0x40 cierra | [H: cuadra con todos los eventos de los 5 proyectos] |
| 5/12, 2/12, 8/13, 8/6, 9/0 | fundido a `p0 & 0xFF` en `p1` ms · esperar `p0` ms · volumen `p0` · variable `p0` = `p1` · lanzar el evento `p1 << 16 \| p0` | [H] |
| **Routers** | el byte 0x04 de cada onda de persecución es router + 1 (el máximo coincide con el nº de routers en los 4 proyectos). Si se pide ir a un destino y el router de la onda actual tiene un par (paso, destino), antes suena la onda de paso | [I] |

Los routers explican los finales: en la parte LOSE de MW_MUS_1 los pares mandan `409` a una onda `LOSE_END` y `412` a una
`WIN_END`; en NEUTRAL, WIN y ELUDE, al revés. Con `EVT_ENDWIN` (parte ≠ LOSE → 409) y `EVT_ENDBUSTED` (parte ≠ LOSE → 412) cada
final suena con el remate que encaja con la capa que sonaba [V: datos de los 4 proyectos].

### 10.3 Mezcla [V lectura · H unidades]

`MixData` de los canales maestros del estado MUSIC = {i16 mínimo −10000, i16 nivel} en milibelios: canciones +2 dB en el juego y
−11 dB en menús, música compuesta 0 / −1 dB, ambiente −7 dB en el juego y −4 dB en menús. «Speech Ducker» (estado MAIN):
−5,55 dB mientras habla la radio de la policía. Encima, el volumen del jugador y una referencia de 0,5 frente a los efectos [H]:
en las pruebas, la música queda unos 7 dB por debajo del motor a fondo (RMS 0,077 frente a 0,176).

### 10.4 Ajustes

`settings.json → "music"`: `volume` (0–1), `interactive` (música de persecución), `eaTrax` (canciones), `shuffle` (al azar o en
orden) y `playlist` (`{"<nº de canción>": "FE" | "IG" | "AL" | "OFF"}`; lo que falte usa el DefPlay del juego). API:
`MusicSystem.shared.setVolume / setInteractive / setEATrax / setShuffle / setPlaylist(song:_:)`. Al arrancar: `--music-off`,
`--music-volume V`. El menú de opciones del juego aún no está en el port.

### 10.5 Pruebas [V: M4, SLES-53559]

```bash
cd native-engine && swift build -c release
.build/release/Rockport --music-test [--project 1…4] [--seconds N]   # zona libre → persecución → evasión → ambiente → canción
.build/release/Rockport --music-test --busted --seconds 140          # la misma, pero acaba en arresto
.build/release/Rockport --music-live 3 --music-volume 0.01           # salida real (AVAudioEngine) unos segundos
```

Salida en `.build/music-test/`: `music.wav` (32 kHz) y `log.txt` (tipos, estados de MusicFlow, eventos, partes, ondas, routers).
Resultado con MW_MUS_2: canción → `EVT_START` (15,5 s) → NEUTRAL (intensidad limitada a 0,5 los primeros 30 s) → `EVT_LOSE`
(policía pegada) → `EVT_NEUTRAL` → `EVT_WIN` (enfriamiento rápido) → `EVT_ELUDE` (escondido) → `EVT_ENDWIN` → router 19
(onda 241 → paso 304) → `InteractiveDone` → ambiente de la zona 4 durante 40 s → canción. Con arresto (MW_MUS_1): `EVT_ENDBUSTED`
→ router 22 (onda 204 → paso 385, `LOSE_END`). **Sin huecos** entre ondas (solo los silencios del corte inicial y del final, 0,26 y
0,39 s); 175 s simulados en 0,2 s.
