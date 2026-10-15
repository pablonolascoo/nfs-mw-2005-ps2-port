# Audio y voces

Etiquetas: [V] verificado con SLES-53559 / SLUS-21351 · [D] decomp · [I] inferido · [H] hipótesis.

## 1. Dónde están las voces

| Qué | Archivo del disco | Formato | Idiomas |
|---|---|---|---|
| Películas de la historia y de la Lista Negra (actores reales) | `MOVIES\*.MPC` (32) | MPEG-2 512×416 25 fps (PAL) + audio EA-XA v2 / ADPCM EA R3, 48 kHz estéreo, en bloques `SCHl` [V] | **Solo inglés** en los dos discos [V] |
| Subtítulos de las películas | `SUBTITLES\STORYFMV_*` | bChunk `0x00870000`: pares (tiempo en décimas de segundo, hash de frase) [V] | El texto no está en `LANGUAGES\SPANISH.BIN` (esas entradas están a cero) [V]. Pendiente |
| Radio de la policía | `SOUND\SPEECH\COPSPEECH_<EN\|SP\|IT>.BIG` (+ `.IDX`, `.CSI`, `.EVT`) | Miles de clips `SCHl` seguidos [V] | PAL: castellano, inglés e italiano · NTSC-U: inglés |
| Audio de escenas con el motor | `SOUND\STREAMS\NISAUDIO.BIG` | ADPCM EA R2, 32 kHz estéreo, 27 min seguidos [V] | — |
| Sonidos de motor, turbo, derrapes… | `SOUND\ENGINE`, `TURBO`, `SKIDS`… (`.ABK`, `.GIN`) | Bancos AEMS `ABKC` + motores granulares `Gnsu` (§7) [V] | — |

- Clips de radio en SLES-53559 [V]: **castellano 9854**, inglés 13 562, italiano 9986. Duran de 0,1 s a ~22 s.
- Codec de la radio: EA MicroTalk. vgmstream solo lo abre si el clip se guarda como `.asf` [V]. El port lo decodifica solo (§5).
- `NISAUDIO.BIG`: 140 pistas SCHl seguidas (EA-XA v2) [V].
- Tamaño extraído en FLAC: películas 161 MB, escenas 108 MB, radio 706 MB (es) + 1 GB (en) + 762 MB (it). Unos 22 min en un M4.
- Los clips de radio son trozos de frase que el juego encadena (unidad, dirección, nombre de calle…) [D].
- Qué clip suena en cada momento lo deciden `.IDX` (bancos) y `.EVT` (eventos): ya se leen, ver §6. `.CSI` (`MOIR`) es la interfaz Csis y no hace falta.

## 2. Extraer todo (uso local)

```bash
brew install ffmpeg vgmstream
cd tools && bun src/cli/audio.ts ../original/SLES-53559.iso SLES-53559
```

Sale en `map-data/<ID>/audio/` (no se sube a git):

```
audio/
├─ peliculas/<PELÍCULA>.flac        32 pistas, voces originales en inglés
├─ radio-policia-castellano/NNNNN.flac
├─ radio-policia-ingles/NNNNN.flac
├─ radio-policia-italiano/NNNNN.flac
├─ escenas/NNN.flac                140 pistas de escenas NIS
└─ indice.json                      qué es cada archivo y qué personajes salen [I]
```

FLAC sin pérdida: son las mismas muestras del disco.

## 3. Voces y clonación
- Las voces son de **actores reales**. Su voz no forma parte de la licencia del juego.
- **No se clonan voces sin el permiso por escrito de cada actor.** ElevenLabs también lo exige.
- Para la expansión: voces **diseñadas** nuevas (no copias), actores contratados, o clones solo con permiso.
- El audio del disco del jugador sí se puede reproducir dentro del port, igual que las texturas.

## 4. Pendiente
- Texto de los subtítulos (buscar dónde están las cadenas de las películas).
- Radio: qué banco de cada frase es cada voz [H] y cuándo exactamente dispara cada evento el juego (`SoundAI`, `PursuitFlow`).
- ~~Bancos de efectos `.ABK` (motores, sirenas) para el motor nativo~~ → hecho (§7–10). Queda: capa AEMS de los motores (módulos MIPS), `SOUND\MIXMAPS` (mapas de mezcla), qué muestra exacta es cada papel en algunos bancos ([H] en §8), música (`PFDATA`).

## 5. Decodificador MicroTalk propio (radio dentro del juego)

La app no lleva vgmstream ni FFmpeg: decodifica la radio ella misma.

| Pieza | Archivo |
|---|---|
| Decodificador en TypeScript (conversor y pruebas) | `tools/src/lib/microtalk.ts` |
| El mismo en Swift (la app, al vuelo) | `native-engine/Sources/Rockport/Audio/MicroTalk.swift` |
| Paso del conversor | `tools/src/cli/radio.ts` → `map-data/<ID>/radio/` (`install.ts` paso «Radio de la policía», `build-all.ts`) |
| Prueba contra vgmstream | `bun src/cli/microtalk-check.ts ../map-data/<ID>/radio [n]` y `Rockport --radio-test` |

Formato [V con SLES-53559 y SLUS-21351]:
- Contenedor EA SCHl: cabecera `SCHl` con etiquetas `PT` (0x80 versión = 3, 0x85 muestras, 0xA0 códec = 4 «MT10», 0x82 canales;
  sin 0x84 → 22 050 Hz en PS2), `SCCl` (nº de bloques), `SCDl` (u32 muestras del bloque, u32 desplazamiento por canal, 1 byte, datos), `SCEl`.
- Versión 3: cada trama empieza por un byte; `0xEE` = la trama trae muestras PCM sin comprimir que sustituyen a las decodificadas.
- Trama de 432 muestras = 4 subtramas de 108: 12 coeficientes de reflexión cuantizados (6 bits los 4 primeros, 5 el resto),
  predictor de tono (retardo 8 bits, ganancia 4 bits) y excitación fija (RELP o multipulso con dos libros Huffman); banda reducida
  con interpolación de las muestras impares. Lector de bits LSB primero; al cambiar de bloque se reinicia el lector, no el estado.
- Algunos clips son estéreo (97 en castellano, 177 en inglés NTSC: las llamadas al móvil de `CellCall`): un decodificador por canal; la app los mezcla a mono.

Resultado [V]:
- 300 clips al azar de SLES-53559 (16,3 M muestras) y 150 de SLUS-21351: **iguales a vgmstream r2117 salvo ±1** en el 0,7–0,8 % de las muestras, ninguna longitud distinta.
- El ±1 viene de que vgmstream, compilado para arm64, junta multiplicación y suma (FMA); el decodificador hace lo mismo
  (`addingProduct` en Swift, producto en doble precisión en TypeScript). Sin FMA la diferencia llega a ±35.
- Velocidad: ~5 ms por clip en TypeScript; en la app se decodifica al vuelo y se guardan los 64 últimos.

Salida del paso `radio` (no se sube a git: `map-data/**/radio/` está en `.gitignore`):
```
radio/COPSPEECH.BIG   los clips tal cual del disco (castellano 128 MB; inglés NTSC 172 MB)
radio/radio.json      índice: clips [desplazamiento, bytes, muestras], bancos y eventos
```
Idioma: PAL (SLES) → castellano (`SP`), NTSC (SLUS) → inglés; se puede forzar con `bun src/cli/radio.ts <iso> <ID> IT` o `ROCKPORT_RADIO_LANG`.
`--wav 0,100` escribe además esos clips en `radio/wav/` para escucharlos.

Créditos: el formato se estudió en vgmstream (`src/coding/libs/utkdec.c`, `src/layout/blocked_ea_schl.c`, licencia ISC), que a su vez
parte del trabajo de Andrew D'Addesio (Niotso) sobre `sx.exe` de EA. El código es propio; las tablas (coeficientes, libros de códigos) son datos del formato.

## 6. Tablas de eventos de la radio (`.IDX` / `.EVT`)

| | castellano (SLES) | inglés (SLUS) |
|---|---|---|
| Clips | 9854 (391 min) | 13 562 (528 min) |
| Bancos | 559 | 579 |
| Frases distintas | 144 | 152 |
| Eventos | 139 | 139 |

`COPSPEECH_<L>.IDX` = `CLUMP_IDX_FILE` [D: `EAXSound/Clump.h`; V]: `numtypes`, `numbanks[20]`, `count` en 0x54 y `count` entradas de 16 B
`{key = tipo << 24 | nº, size, header, sample}`. `header` es la cabecera del banco dentro del propio `.IDX`; `sample`, dónde empieza en el `.BIG`.
Cabecera de banco [V, deducida]: u16 nº de frase · u16 · u8 `dims` (0, 1 o 2) · u8 nº de clips · u16 · u32 tamaño/256 · y por clip:
u16 big-endian desplazamiento/256 + `dims` bytes con el valor de cada parámetro del clip. Los clips de cada banco son consecutivos en el `.BIG` [V: los 559 bancos cubren los 9854 clips].

`COPSPEECH_<L>.EVT` [V, deducida; ids de `SND_GEN/P2temp.h`, D]: u32 nº de eventos en 0x10 y tabla de u16 × 4 desde 0x18.
Cada evento: u16 id (`SPCHType_1_EventID`), u16 prioridad (200), u16 500, u16 nº de alternativas, u8 nº de parámetros (en el byte 11).
Cada alternativa: piezas `{u16 frase, u16 0x0101 = la dice el policía que habla / 0 = voz fija, u32 nº de condiciones, condiciones}`,
condición = `{u32 máscara de valores permitidos, u8 nº de parámetro}`. Los parámetros son los campos del `Csis::*Struct` del evento
en orden (1 = `speaker_id`, 2… el resto) [D: `SND_GEN/COPSPEECH.hpp`]; los valores son bits (`Type_intensity_High = 2` → índice 1).
Ejemplos [V]: `InitPursuit` = frase 299; `Arrest` = frase 154; `Disp911Report` = 6 piezas (pitido de la central 269 + tipo + sospechoso + dirección + calle…).

Cómo arma el port una línea [I]: evento → alternativa cuyas condiciones encajan → para cada pieza, el banco de la voz que habla
(nº de banco dentro de la frase = voz [H]) → el clip cuyo valor de parámetro coincide (intensidad, sí/no, nº de sospechosos…) o uno al azar.
Qué evento suena en cada momento: `native-engine/Sources/Rockport/Audio/PursuitFX.swift` (inicio, refuerzos, calor, controles,
pérdida de vista, escape, arresto, avisos de fondo) y doc 15 §8 (por dónde suena). Lo que hace el juego exactamente
(`SoundAI`, `PursuitFlow`, `SPCH_Choose`) no está decompilado: la librería SPCH solo está en ensamblador.

## 7. Sonido del juego: formatos del disco [V con SLES-53559 y SLUS-21351]

| Carpeta | Qué hay | Formato |
|---|---|---|
| `SOUND\ENGINE` | 160 motores granulares `GIN_*.GIN` (acelerando y `_DCL` desacelerando), 76 bancos `CAR_NN_ENG_MB_EE/SPU.ABK` (capa AEMS), 76 `SWTN_CAR_NN_MB.ABK` (petardeos), `CAR_TRANNY`, `CAR_WHINE_00` | Gnsu · ABKC |
| `SOUND\TURBO` (32) · `SHIFTING` (16) · `SKIDS` (4) · `NOS` (2) | turbos y compresores, cambios de marcha, derrapes, nitro | ABKC |
| `SOUND\IG_GLOBAL` (13) | sirena, tráfico, viento, rodadura, golpes (`STICH_COLLISION`), pasadas, ambiente, helicóptero, lluvia | ABKC |
| `SOUND\FE`, `GLOBAL` | sonidos de los menús | ABKC |
| `SOUND\MIXMAPS`, `FXEDIT`, `EVT_SYS`, `NISREVDATA` | mapas de mezcla, reverbs, interfaces Csis, revoluciones de las escenas | sin descifrar (no hacen falta para sonar) |

**ABKC** (banco AEMS): cabecera de 0x5C B (`ABKC`, 0x14 tamaño, 0x18 posición del `BNKl`, 0x24 tamaño de la zona de muestras).
Entre la cabecera y el `BNKl` van los **módulos AEMS: código MIPS del EE** (`addiu sp,…`) que decide qué muestra suena con cada
parámetro. No se ejecutan: el port usa la lógica de la decomp (§9) y la tabla de papeles (§8).

**BNKl** v5: `u16` nº de entradas en 0x06 y tabla de desplazamientos relativos desde 0x18; cada entrada es una cabecera `PT`
de etiquetas {tag, n, n bytes big endian}: 0x84 frecuencia, 0x85 muestras, 0x86/0x87 bucle, 0x88/0x89 datos de cada canal
(relativo al `BNKl`), 0x82 canales, 0xA0 códec (0x0A = EA-XA v2; sin ella, PS-ADPCM). La última entrada es un terminador.
Los bancos `_EE` (memoria principal) van en **EA-XA v2** (tramas de 15 B o tramas PCM `0xEE` de 61 B); el resto, **PS-ADPCM**.

**Gnsu** (`.GIN`, estructura `GinsuDataLayout` de la decomp [D]): `Gnsu` `20`, f32 RPM mínima y máxima, nº de segmentos,
de ciclos y de muestras, frecuencia (32 000 Hz), tabla RPM → muestra (`segCount+1`), tabla de inicio de cada ciclo
(`cycleCount+1`) y datos **EA-XAS** (bloques de 19 B = 32 muestras, dos muestras de 12 bits con filtro y desplazamiento).
Un «ciclo» son dos vueltas del motor: RPM = 120 × frecuencia / periodo del ciclo [D: `GetCurrentPitch() × 120`; V: la tabla de
ciclos va de la RPM mínima a la máxima del archivo].

Conversor: `tools/src/lib/abk.ts` (lectores y decodificadores) y `tools/src/cli/sound.ts` → `map-data/<ID>/sound/` (paso
«Sonido» de `install.ts` y `build-all.ts`, `DATA_FORMAT` 5). Copia los 461 archivos tal cual (33 MB) y escribe `sound.json`.

Comprobación (`bun src/cli/sound.ts <iso> <ID> --check`, con vgmstream r2117 solo en local):
- **2350 / 2350 sonidos de 301 bancos ABK idénticos muestra a muestra** a vgmstream. En 94 hace falta guardar la historia del
  PS-ADPCM sin saturar, como vgmstream; la app la guarda saturada, como la SPU [I: psx-spx] (solo cambian las muestras que saturan).
- **160 / 160 `.GIN` idénticos** con el decodificador entero (historia truncada). El juego usa el de coma flotante de la decomp
  (`GinsuSynthData::DecodeBlock`), que es el que usan la app y `--wav`: difiere por redondeo dentro de cada bloque (RMS ≈ 47 / 32 768).
- Las mismas cifras con SLUS-21351.

## 8. Qué suena con qué (base de datos VLT y decomp)

`GLOBAL\ATTRIBUTES.BIN` [V]:
- **`engineaudio`** (69): `Filename_GinsuAccel` / `Filename_GinsuDecel`, `BankName_mainRAM`/`auxRAM` (AEMS), `SweetBank`,
  `MinRPM`/`MaxRPM` (rango del .GIN), mezclas `GINSUMix_*`, `DECEL_GINSUMix_*`, `AEMSMix_*`, volúmenes, umbrales de ΔRPM,
  `GINSU_Decel_Min/MaxRPM` + fundidos, `PhysicsRPM_Map` (curva de RPM), `Master_Vol`.
- **`pvehicle`** → `engineaudio[]` por nivel de motor (`UpgradeIntervals`), `TurboSND[]` y `ShiftSND[]` = `UpgradeSpecs {RefSpec, Level}`
  por nivel de inducción / transmisión, `HornType`, `TrafficEngType`, `WooshType` [D: `EAXCar::Attach`]. Ej.: el BMW M3 GTR
  (`bmwm3gtre46`) suena con **`tvr_cerb`** = `GIN_TVR_CERBERA.GIN` + `GIN_TVR_CERBERA_DCL.GIN` [V].
- **`turbosfx`** (18): banco, `ChargeTime`, `Leak_Rate`, volúmenes de soplado y descargas. **`shiftpattern`** (25): banco,
  `stShiftPair {i16 RPM, i16 Time}` y curvas de Bézier de la caída/enganche de RPM, retardos y volúmenes.
- **`audiosystem.mostwanted`**: bancos globales (derrapes, nitro, rodadura, viento, sirena/tráfico/varios, golpes, ambiente, menús).
- **`simsurface`**: `Aud_Roadnoise_LOOP` (bucle de rodadura: asfalto 5, tierra 0, hormigón 1, adoquín 2, agua 3, rueda reventada 6)
  y `Aud_Skid_Type` (0 asfalto, 1 tierra).
- **Golpes**: `GLOBAL\INGAMEB.BUN`, bChunk `0x8003B500` (`BCHUNK_SND_STICHBUNDLE`): 608 «stitches», uno por `STICH_COLLISION_TYPE`
  (`CRSH_CAR_2_WALL_FRNT_MED2`…), cada uno una lista de muestras de `STICH_COLLISION_MB` con volumen Q15, tono Q12 (4096 = 1),
  retardo en ms y variación al azar [D: `STICH_Struct.h`; V: 608 stitches, muestras 0–170].

Papel de cada muestra en los bancos (los módulos AEMS no se ejecutan; `sound.json → roles`):

| Banco | Muestras | Etiqueta |
|---|---|---|
| Turbo | 0 soplado (bucle, PSI), 1 descarga pequeña, 2–3 descargas grandes al azar (PSI > 75 %), 4 segundo bucle | [D] ids de `FX_TURBO_01` en `CARSFX_Turbo.cpp`; 4 [H] |
| Cambios | 0 reducir, 1 subir, 2 frenada | [D] `AEMS_SHIFTING_SAMPLES` |
| Derrapes | 0–2 chirridos tonales de asfalto, 3 derrape largo, 4 ruido de tierra | [I] por espectro; reparto lateral/longitudinal [H] |
| Nitro | 0 bucle, 1 entrada, 2 cierre | [I] |
| Sirena | 0 «yelp» (0,36 s), 2 «wail» (3,78 s), 1 y 3 las mismas a 14 kHz (lejos), 4 bucle corto | [I] |
| Tráfico | 0–1 rumor de motor, 2 claxon, 3 claxon de camión | [I] |
| Viento | 0 izquierda, 1 derecha, 2 rápido, 3 retumbo (1 kHz) | [I] |
| Rodadura | 0–6 bucles por superficie (`Aud_Roadnoise_LOOP`), 7–14 transiciones | [D] índice de bucle; transiciones [I] |

## 9. El sonido en el motor nativo

| Pieza | Archivo |
|---|---|
| Índice y decodificadores (PS-ADPCM, EA-XA v2) | `native-engine/Sources/Rockport/Audio/SFXBank.swift` |
| Motor granular Ginsu (datos + síntesis, línea a línea de la decomp) | `Audio/EngineGinsu.swift` |
| Lógica del motor: RPM de audio, cambios, mezcla acelerando/desacelerando, turbo | `Audio/EngineSound.swift` |
| Mezclador (un solo `AVAudioSourceNode`, rampas, paso bajo, limitador suave) | `Audio/SFXMixer.swift` |
| Mundo: coches, 3D, policía, tráfico, golpes, ajustes | `Audio/SFXWorld.swift` |
| Pruebas sin ventana | `Audio/SFXTests.swift` |

Motor de un coche [D salvo donde se indica]:
1. % de RPM de la física (ralentí…corte) → `PhysicsRPM_Map` (Bézier, solo jugador) → **RPM de audio** 1000–10 000.
2. `SFXCTL_Shifting`: al subir, la RPM cae por la curva `Up_DisengageFall` y vuelve por `Up_Engage` con un golpe de volumen
   (`Up_Engaging_Attack_Vol`); al bajar, cae, sube (`Down_Engaging_Rise`), baja y se reengancha. Suena la muestra de cambio tras `*_Shift_Sound_Delay`.
3. `SFXCTL_HybridMotor` (dos .GIN): par = acelerador × 100 (media de 3); ΔRPM medio de 4 pasos → % sobre `AccelDeltaRPMThreshold`;
   mezcla acelerando `GINSUMix_S…L`, desacelerando `DECEL_GINSUMix_S…L` × cruce `DecelCrossfadeMix`, paso bajo `GINSU_LowPassCutoff`
   al soltar; volúmenes con paso máximo 7000 por actualización.
4. RPM del .GIN = (audio − 1000) / 9000 × (MaxRPM − MinRPM) + MinRPM; por debajo de la mínima del archivo, se baja el tono.
5. `GinsuSynthesis`: paquetes de 11 ms; antes de cada uno salta ciclos enteros hacia la posición de esas RPM con un fundido de 0,5 ms
   y latencia de 60 ms. Así el tono es el de la grabación real a cualquier régimen.
6. Turbo (`CARSFX_Turbo`): carga con el par, fuga `Leak_Rate`, techo según RPM, descarga al soltar (pequeña o grande al azar).
   Nitro: entrada + bucle + cierre. Petardeos (`SWTN_CAR_NN`, `Vol_Sputters`) al soltar en alto [H: disparo propio].

Lo que **no** es del juego (decisiones del port, [H]):
- Todo a **30 Hz** (una actualización por fotograma de PS2). Con eso los umbrales de ΔRPM y la carga del turbo dan tiempos razonables
  (turbo lleno en ~0,7 s).
- Capa **AEMS** (bucles `CAR_NN_ENG_MB_*`): sus módulos son código MIPS. Su volumen (calculado como el juego con `AEMSMix_*`)
  se reparte entre los dos .GIN para no perder cuerpo al ralentí. Sin la muestra de corte de encendido: el limitador se oye
  como un recorte de volumen a 11 Hz.
- Mezcla por categorías (`SFXMix`) en lugar de `SOUND\MIXMAPS`. Derrapes por patinaje de las ruedas, viento y rodadura por velocidad.
- 3D propio: ganancia 1/distancia, paneo de igual potencia, Doppler a la mitad, y el paso bajo por distancia del motor
  (`UpdateFilterFX`: de 24 kHz a 725 Hz entre 6,5 y 50 m). El coche del jugador suena sin posición (cámara detrás).
- Policía: sirena «wail»/«yelp» alternando cada 4–8 s, 4 sirenas y 3 motores a la vez como máximo. Tráfico: 6 rumores; claxon si
  el jugador pasa rozando a más de 65 km/h. Rivales de carrera: los 4 más cercanos con su motor completo.
- Golpes: no hay aviso de choque de la física; se detectan por saltos de velocidad y se elige `CRSH_CAR_2_{CAR|WALL}_{FRNT|SIDE}_{VLIT…HRD}`.

Pantalla partida: `SFXWorld.shared.localCarsProvider = { [coche1, coche2] }` y `listenersProvider = { [oyente1, oyente2] }`.
Cada coche de jugador suena sin posición, un poco a su lado (−0,35 / +0,35); los demás sonidos se colocan respecto al oyente más cercano.

Ajustes: `settings.json → "sound": {"enabled": true, "master": 0.8}`, `SFXWorld.shared.setMasterVolume(_:)`, `setEnabled(_:)`;
al arrancar `--sound-off` y `--volume 0…1`. En pausa todo calla.

Coste medido (M4, versión `release`): **0,15–0,2 % de un núcleo** con 8–10 voces (lógica 0,2 ms + mezcla 1,4 ms por segundo de audio).

## 10. Pruebas

```bash
cd tools && bun src/cli/sound.ts ../original/SLES-53559.iso SLES-53559 --check   # bancos y .GIN contra vgmstream (local)
bun src/cli/sound.ts ../original/SLES-53559.iso SLES-53559 --wav IG_GLOBAL/SIREN_MB.ABK,ENGINE/GIN_TVR_CERBERA.GIN
cd native-engine && swift build -c release
.build/release/Rockport --sound-dump                 # todo decodificado por la app (52 M muestras) + comparación con vgmstream
.build/release/Rockport --sound-test BMWM3GTRE46     # → .build/sound-test/BMWM3GTRE46.wav (35 s) · --sound-trace: RPM/mezcla cada 0,5 s
.build/release/Rockport --sound-live 3 --volume 0    # el mismo nodo por la salida real (AVAudioEngine en tiempo real)
```

`--sound-test` [V]: ralentí, aceleración a fondo con cinco cambios, retención, nitro, frenada, freno de mano y una pasada de policía
con sirena y golpes. El sintetizador sigue a la RPM pedida con un error de ~1 % (BMW M3 GTR: 0,7 % en la tabla y 0,1 % medido en la salida por autocorrelación; Supra: 0,8 % y 1,3 %).
