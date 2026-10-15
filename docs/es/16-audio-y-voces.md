# Audio y voces

Etiquetas: [V] verificado con SLES-53559 / SLUS-21351 · [D] decomp · [I] inferido · [H] hipótesis.

## 1. Dónde están las voces

| Qué | Archivo del disco | Formato | Idiomas |
|---|---|---|---|
| Películas de la historia y de la Lista Negra (actores reales) | `MOVIES\*.MPC` (32) | MPEG-2 512×416 25 fps (PAL) + audio EA-XA v2 / ADPCM EA R3, 48 kHz estéreo, en bloques `SCHl` [V] | **Solo inglés** en los dos discos [V] |
| Subtítulos de las películas | `SUBTITLES\STORYFMV_*` | bChunk `0x00870000`: pares (tiempo en décimas de segundo, hash de frase) [V] | El texto no está en `LANGUAGES\SPANISH.BIN` (esas entradas están a cero) [V]. Pendiente |
| Radio de la policía | `SOUND\SPEECH\COPSPEECH_<EN\|SP\|IT>.BIG` (+ `.IDX`, `.CSI`, `.EVT`) | Miles de clips `SCHl` seguidos [V] | PAL: castellano, inglés e italiano · NTSC-U: inglés |
| Audio de escenas con el motor | `SOUND\STREAMS\NISAUDIO.BIG` | ADPCM EA R2, 32 kHz estéreo, 27 min seguidos [V] | — |
| Sonidos de motor, turbo, derrapes… | `SOUND\ENGINE`, `TURBO`, `SKIDS`… (`.ABK`, `.BIN`) | Bancos EA | — |

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
- Bancos de efectos `.ABK` (motores, sirenas) para el motor nativo.

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
