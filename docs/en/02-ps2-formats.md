# PS2 formats decoded (SLES-53559)

Legend: **[V]** verified on real data · **[D]** from the decomp's PS2 debug types (`symbols/PS2`) · **[H]** hypothesis.
Reference code: `tools/src/lib/`.

## Disc container — `zdir.ts` [V]
- `NFS/ZDIR.BIN`: 24-byte LE entries `{hash, archive, localSector, globalSector, size, checksum}`.
- Hash = `bStringHash` (`h = h*33 + c`, seed `0xFFFFFFFF`) of the upper-case path with `\`.
- 1497 files (PAL) / 1447 (US); 95 % resolved via `tools/data/filenames-mw-ps2.list` (our own list, hash-verified) + ELF strings.

## bChunk — `bchunk.ts` [V][D]
`{u32 id, u32 size}`; bit `0x80000000` = container. Padding `0x11111111` inside chunks. Alignment is relative to the file/section start (16 for eSolid, 128 for pixel data).

## Compression — `lz.ts` [V]
`JDLZ`, `HUFF` (EA Huffman with runs and `0x32fb/0x34fb` deltas), `RAWW`. Ported from `LZCompress.cpp`; output sizes exact in every test.

## Geometry (solids) — `solid-ps2.ts`
- Tree `0x80134000 → 0x80134010 → {0x00134011 eSolid, 0x00134012 textures, 0x80134100 → 0x00134A00/01/02}` [D][V].
- `eStripEntry` 16 B: `{flags, numVerts, numPolys, density, qwOffset, Nz, Nt, qwSize, group, texture, lightMaterial}` [D][V].
- Each strip is a ready-to-DMA **VIF** packet for VU1 [V]:

| VU addr | Format | Content |
|---|---|---|
| 0 | V4-8 | `[numVerts, packs of 4, 23, ?]` |
| 1 | V4-32 | `[ADC0, scale=0.0002, ADC2, ADC3]` |
| 2 | V3-32 ×2 | strip AABB (inflated by 0.01) |
| 4 | V4-32 | normal cone |
| 5 | V4-16 | XYZ as SoA: per pack rows `x[4] y[4] z[4]`; leftovers in `V{m}-16 ×3` |
| 29 | V4-16 | UV: per row `(s0, t0, t1, s1)`, ÷4096 |
| 45 | V4-8u | per-vertex RGBA (scenery only), 128 = 1.0 |
| 77 | V4-8 | normals as SoA (int8) |

- **Position** = `integer × 0.0002 + integer offset per axis`. The offset is derived from the AABB (`round(min − vmin·scale)`); validated with 9,027 vertices shared between strips [V]. Where the VU microcode computes it: [H].
- **Strip restarts (ADC)** [V, 100 % on 181,535 strips]: vertices 0–14 live in word F, bits 14→0 (F = ADC0; ADC3 when there are 3 packs; ADC2 when there are 7); vertices ≥15 live in ADC3 bit `4·packs+5−k` (7 packs: `33−k`, and vertex 15 is completed from its restart pair).

## Textures — `tex-ps2.ts`, `gsmem.ts`
- Pack `0xB3300000` (same IDs as PC). Tables `0x33310004` TextureInfo (0x7C) + `0x33310005` PlatInfo (0x54) [D][V]; or compressed streaming entries `0x33310003` (cars) with TextureInfo+PlatInfo at the end [V].
- Formats: PSMT8 (`0x13`) and PSMT4 (`0x14`) with a PSMCT32 CLUT; PS2 alpha (0x80 = opaque). World: 2,472 of 2,622 textures are PSMT4 [V].
- **Swizzle** [V, visually]: PSMT8 was uploaded as PSMCT32 of (W/2)×(H/2); PSMT4 as **PSMCT16** of (W/2)×(H/2). 8-bit CLUT in CSM1 order (index bits 3↔4 swapped).
