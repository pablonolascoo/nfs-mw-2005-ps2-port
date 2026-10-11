# Disc identification (2026-10-11)

Legend: **[V]** verified on the PS2 disc · **[I]** inferred from another version · **[H]** hypothesis · **[D]** design decision.

## 1. Reference disc (SLES-53559)
| Item | Value | Level |
|---|---|---|
| Image | 4,094,197,760-byte ISO dumped from the author's original disc | V |
| SHA-256 | `5949a98565d6ccde0f0fe3176e66bd9595e3710349417719cf761382c9b2582e` | V |
| MD5 | `06811fd45d653d00d301ad1e5ebbf3ad` | V |
| ID (SYSTEM.CNF) | `BOOT2 = cdrom0:\SLES_535.59;1`, `VER = 1.00`, `VMODE = PAL` | V |
| Type | Retail PAL release (not a prototype), volume date 2005-10-15 | V (date) / I (retail) |
| Executable | `SLES_535.59`, ELF32 LE, MIPS, 4,919,508 B | V |
| Languages | The ELF references 10 `LANGUAGES\*.BIN` files | V |

Disc contents: `SYSTEM.CNF`, `SLES_535.59`, `NFS/IOPRP280.IMG`, `NFS/IRX281A.BUN`, `NFS/IRX281B.BUN`, `NFS/ZDIR.BIN`, `NFS/ZZDATA0..3.BIN` (~4 GB).

## 2. ZDIR/ZZDATA container [V]
- `ZDIR.BIN` = 1497 entries of 24 bytes, little-endian, sorted by hash.
- Entry: `{nameHash, archive(0-3), localOffset(2048-byte sectors), globalOffset(sectors), size(bytes), checksum}`.
- `globalOffset == base(archive) + localOffset` for all 1497 entries.
- `nameHash` = bStringHash (`h = h*33 + c`, seed `0xFFFFFFFF`) of the upper-case path with `\` separators.
- The exact meaning of `checksum` is unconfirmed [H].

## 3. dbalatoni13/nfsmw decompilation (HEAD 80993f3, 2026-10-10)
- Matching decompilation: it rebuilds and diffs against the original binary. **It does not produce a native port** [V].
- Supported PS2 versions: `SLUS-21351` (US Black Edition) and `SLES-53558-A124` (prototype). **SLES-53559 is not supported** [V].
- PS2 progress: SLUS-21351 22.7 %; A124 18.6 % (GameCube: 61 %) [V, decomp.dev].
- License CC0. Very active. Value for us: PS2 debug types in `symbols/PS2/` and chunk IDs in `SpeedChunks.hpp`.

## 4. MWEncyclopedia
- PC 1.3 only, no explicit license. Useful for shared containers.
- PS2 uses its own geometry chunks (`0x00134A0x`) and GS texture formats; see [02-ps2-formats.md](02-ps2-formats.md).
- Its hashing description does not match the PS2 disc; the decomp's `bStringHash` does [V].
