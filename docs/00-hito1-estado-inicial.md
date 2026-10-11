# Hito 1 · Estado inicial (2026-10-11)

Leyenda: **[V]** verificado en la copia PS2 del usuario · **[I]** inferido de otra versión · **[H]** hipótesis · **[D]** decisión de diseño.

## 1. Disco del usuario
| Dato | Valor | Nivel |
|---|---|---|
| Archivo | `Need for Speed Most Wanted.iso` (4 094 197 760 B) | V |
| SHA-256 | `5949a98565d6ccde0f0fe3176e66bd9595e3710349417719cf761382c9b2582e` | V |
| MD5 | `06811fd45d653d00d301ad1e5ebbf3ad` | V |
| ID (SYSTEM.CNF) | `BOOT2 = cdrom0:\SLES_535.59;1`, `VER = 1.00`, `VMODE = PAL` | V |
| Tipo | Edición comercial PAL (no prototipo), fecha de volumen 2005-10-15 | V (fecha) / I (comercial) |
| Ejecutable | `SLES_535.59`, ELF32 LE, MIPS, 4 919 508 B | V |
| Idiomas | El ELF referencia 10 archivos `LANGUAGES\*.BIN` | V |

Contenido del disco: `SYSTEM.CNF`, `SLES_535.59`, `NFS/IOPRP280.IMG`, `NFS/IRX281A.BUN`, `NFS/IRX281B.BUN`, `NFS/ZDIR.BIN`, `NFS/ZZDATA0..3.BIN` (~4 GB).

## 2. Contenedor ZDIR/ZZDATA [V]
- `ZDIR.BIN` = 1497 entradas de 24 B, little-endian, ordenadas por hash.
- Entrada: `{nameHash, archivo(0-3), offsetLocal(sectores 2048), offsetGlobal(sectores), tamaño(B), checksum}`.
- `offsetGlobal == base(archivo) + offsetLocal` en las 1497 entradas.
- `nameHash` = bStringHash (`h = h*33 + c`, inicio `0xFFFFFFFF`) de la ruta en mayúsculas con `\`.
  Comprobado con 10 rutas reales (p. ej. `TRACKS\STREAML2RA.BUN` → 191 032 148 B, `CARS\BMWM3GTRE46\GEOMETRY.BIN`).
- El significado exacto de `checksum` está sin confirmar [H].
- Script de verificación: lectura pura, no modifica nada.

## 3. Decompilación dbalatoni13/nfsmw (HEAD 80993f3, 2026-10-10)
- Proyecto *matching*: recompila y compara con el binario original. **No genera un port nativo** [V].
- Versiones PS2 admitidas: `SLUS-21351` (EE. UU., Black Edition) y `SLES-53558-A124` (prototipo). **SLES-53559 no está admitida** [V].
- Progreso PS2: SLUS-21351 22,7 %; A124 18,6 % (GC: 61 %) [V, decomp.dev].
- Licencia CC0. Muy activo. Política: nada de ports hasta tener base casi perfecta.
- Valor para nosotros: tipos PS2 en `symbols/PS2/` y `SpeedChunks.hpp` (IDs de chunks PS2) [V].

## 4. MWEncyclopedia
- Solo PC 1.3. Sin licencia explícita. Útil para contenedores comunes [V].
- PS2 usa chunks propios: texturas `0x3030xxxx` (GS, PSMT8/4 + CLUT, swizzle) y geometría `0x00134A0x` (strips en quadwords) [I, de la decomp].
- Discrepancia: la enciclopedia describe otro hash; el disco PS2 usa el de la decomp [V].

## 5. Herramientas de terceros
- Ekey/NFS.BIN.Tool: desempaqueta ZDIR/ZZDATA PS2 (sin licencia) [I].
- No existe extractor público de texturas o geometría PS2 de MW [I].
