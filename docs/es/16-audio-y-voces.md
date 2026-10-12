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

- Radio en castellano: **9854 clips** en SLES-53559 [V]. Son trozos de frase que el juego encadena (unidad, dirección, nombre de calle…) [D].
- Qué clip suena en cada momento lo deciden `.IDX`, `.CSI` (`MOIR`) y `.EVT`. Aún no están decodificados [H].

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
├─ escenas-NISAUDIO.flac
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
- Tabla de eventos de la radio (`.IDX` / `.CSI` / `.EVT`) para reproducirla como el juego.
- Bancos de efectos `.ABK` (motores, sirenas) para el motor nativo.
