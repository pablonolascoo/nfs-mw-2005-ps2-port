# 26 · Full disassembly of the executable (Ghidra + REA)

> What it is: the setup for reading **all** of the game's code, not only the part the decomp already has in C.
> Why: the reference decomp (`dbalatoni13/nfsmw`) has only ~14 % of the code in C (~30 % fuzzy, decomp.dev, 2026-10-31).
> The rest — story, race conditions, race AI, Lua scripts, menus — only existed as MIPS assembly.

## 1. Installed pieces (outside the repo, in `~/Tools`)

| Piece | Version | Purpose |
|---|---|---|
| Temurin JDK | 21.0.13 | Ghidra runs on Java |
| Ghidra | 12.1.4 | Disassembler and decompiler (NSA, free) |
| ghidra-emotionengine-reloaded | 2.1.39 | PS2 processor (MIPS R5900, "Emotion Engine") |
| Native decompiler | built on the Mac (arm64) | Ghidra does not ship it for Apple Silicon |
| REA (`rea-agents`) | 6.8.0 | MCP server: Claude drives Ghidra directly |

Notes:
- **Decompiler for Apple Silicon:** Ghidra only ships native binaries for Linux and Windows. Build them from `Ghidra/Features/Decompiler/src/decompile/cpp` with `make ARCH_TYPE="-arch arm64" ghidra_opt sleigh_opt`, then copy them to `os/mac_arm_64/decompile` and `os/mac_arm_64/sleigh`.
  - Without `-arch arm64` the Makefile builds for Intel.
  - Create empty `*/depend` files first, so it does not try to build modules that need `bfd.h`.
- **REA** uses Node 24.22.2 (nvm, default version unchanged). It is registered for this project only: `claude mcp add --scope local rea` with `GHIDRA_INSTALL_DIR` and `JAVA_HOME`. `rea doctor` passes every check.
- Hopper and IDA were not installed (they are paid).

## 2. Analysing the executable

We use **SLUS_213.51** (USA): it matches the decomp byte for byte, so the decomp's names can be applied. The logic is the same as the PAL build (doc 01).

```bash
export JAVA_HOME=~/Tools/jdk-21.0.13+9/Contents/Home
S=experiments/decomp/nfsmw/config/SLUS-21351/symbols.txt
~/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless ~/Tools/ghidra-projects nfsmw-slus \
  -import experiments/elf/SLUS_213.51 -overwrite -processor "r5900:LE:32:default" \
  -scriptPath ~/Tools/ghidra-scripts \
  -preScript ApplyDecompSymbols.java "$PWD/$S" \
  -postScript ExportDecompiled.java "$PWD/$S" "$PWD/experiments/ghidra/SLUS-21351"
```

- `ApplyDecompSymbols.java` applies the decomp's **14,810 function names**. [V]
- Auto-analysis takes **54 s**. [V]
- `ExportDecompiled.java` writes each function's pseudocode, grouped by original source file (`Speed/Indep/SourceLists/zGameplay.cpp.c`…).
- The scripts live in `tools/ghidra/`.
- **The output is EA code and is never committed:** `experiments/ghidra/` is in `.gitignore`. Everyone generates it from their own disc.

## 3. What each original source file holds (named functions)

| File | Functions | Content |
|---|---|---|
| zAI | 1161 | AI: traffic, police, rivals, pursuits |
| zPhysicsBehaviors | 1092 | Car physics behaviours |
| zFe2 / zFe / zFEng / zFeOverlay | 985 / 606 / 347 / 348 | Menus and interface |
| zEAXSound / zEAXSound2 | 675 / 804 | Sound |
| **zGameplay** | **741** | **Races, career, milestones, story** |
| zWorld / zWorld2 | 597 / 395 | World |
| zSpeech | 559 | Police radio and voices |
| zMain | 473 | Boot and main loop |
| zCamera | 447 | Cameras |
| **zLua** | **353** | **Embedded Lua interpreter (game scripts)** |

## 4. How it is used for the port

1. Pick a system (for example, the story prologue).
2. Read its pseudocode in `experiments/ghidra/SLUS-21351/…`, or ask REA for it (MCP `rea`).
3. Port it to Swift in `native-engine/` and tag each fact: **[D]** when it comes from the decomp's C, **[G]** when it comes from Ghidra pseudocode (read from assembly, less reliable than [D]).
4. Test it against the original game's behaviour.
