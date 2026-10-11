# SLES-53559 vs. the decompilation (2026-10-11)

Legend: **[V]** verified · **[I]** inferred · **[H]** hypothesis · **[D]** decision.

## Discs used
| Disc | Executable | ELF SHA-1 | Notes |
|---|---|---|---|
| SLES-53559 (PAL Spain, VER 1.00) | `SLES_535.59` 4,919,508 B | `923d2141…94bb8` | Main data source (Spanish) [V] |
| SLUS-21351 (NTSC-U Black Edition, VER 1.01) | `SLUS_213.51` 4,918,740 B | `60289f3f…5034b` | **Exact match** for the decomp's `config/SLUS-21351` [V]. Includes a 007 FRWL demo. |

## Executable comparison (`tools/elfcompare.py`) [V]
- Same section layout and MIPS flags (`0x20924001`); no symbol table.
- `.text`: PAL 3,926,464 B vs US 3,926,144 B (+320 B, ≈80 instructions).
- `.data` identical size (480,348 B); `.rodata` +272 B; `.bss` identical.
- Entry point: `0x436270` (PAL) vs `0x436128` (US).
- **Conclusion [I]:** same code base with small regional changes. Porting the SLUS symbol map to SLES is feasible with function matching (Ghidra / per-function signatures); just changing the version ID is **not** enough.

## Building the decomp on an Apple M4 [V]
- Requires **Rosetta 2** (`softwareupdate --install-rosetta --agree-to-license`): the PS2 compiler `ee-gcc.exe` runs through `wibo` (x86_64).
- `python configure.py -v SLUS-21351 && ninja` → 1 min 34 s.
- Local progress: 22.72 % matched, 47.17 % fuzzy, 6,995 / 21,549 functions, 0 / 306 files linked (no full ELF yet).

## Implications for the port [D]
- **Data** is read from the user's own disc (any region; formats are the same).
- **Logic** reference = the decomp (SLUS); new native code reuses its structures.
