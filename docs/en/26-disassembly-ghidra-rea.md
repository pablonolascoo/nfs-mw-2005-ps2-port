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

## 5. Types: field names in the pseudocode

- **Source:** the decomp's `symbols/PS2/PS2_types.nothpp`. It is a stdump of the **PS2 prototype's** debug info (NFS.ELF, Alpha 124): 4,328 structures with fields and offsets.
- **Problem:** the prototype is not the final game. `GRaceStatus::mRaceBin` sits at 0x1944 in the prototype, 0x1AB0 in the final GameCube build and **0x1C44 in the final PS2 build**. [V]
- **Rule:** a structure is applied only if it has the same size in the PS2 prototype and in the final GameCube build (the headers' `// total size:` comments). [I] That gives **939 reliable structures**: `GRaceBin`, `GRaceDatabase`, `GRaceParameters`, `GTimer`… The ones that changed (`GRaceStatus`, `GManager`, `GCharacter`) keep raw offsets, so no names are invented.
- **Tools:**
  - `tools/src/cli/ghidra-types.ts` → `proto-types.tsv`.
  - `tools/ghidra/ImportProtoTypes.java` builds the structures (3,406 fields) and types `this` in **1,571 methods**. Never in static ones: the dump marks them.
- **Result:** `GetNextDDayRace(GRaceDatabase *this)`, `this->mIndex->mChallengeGoal`… instead of `*(param_1 + 0x18)`.

```bash
bun tools/src/cli/ghidra-types.ts experiments/decomp/nfsmw experiments/ghidra/proto-types.tsv
~/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless ~/Tools/ghidra-projects nfsmw-slus -process SLUS_213.51 -noanalysis \
  -scriptPath ~/Tools/ghidra-scripts -postScript ImportProtoTypes.java "$PWD/experiments/ghidra/proto-types.tsv" \
  -postScript ExportDecompiled.java "$PWD/experiments/decomp/nfsmw/config/SLUS-21351/symbols.txt" "$PWD/experiments/ghidra/SLUS-21351"
```

## 6. The game scripts are Lua 5.0 (on the disc)

- The story, each event's conditions and the career are **not in the executable**: they are **258 message handlers** (`messagehandler`) in `GLOBAL\GAMEPLAY.BIN`. [V]
- Each one carries `bytecode`: an `Attrib::Blob` = {u32 size, pointer} resolved through `PtrN`. [V]
  - Inside is an EA **HUFF** block (the same decompressor as `lz.ts`) holding **Lua 5.0**: "\x1bLua" 0x50, little endian, 6/8/9/9 instruction fields and a 4-byte float `lua_Number`. [V]
  - All **258 of 258** load.
- **Organisation:**
  - Each handler has an **owner** (`handler_owner`): an activity ("16_2_1_d_day_intro", "race_bin_16/drive_to_safe_house") or a template ("basicrace", "drive_to_target").
  - It also has a **state** (`stateref` → `state.Name`: prerace, racing, postrace, done…) and a **message** (stateenter, triggerenter, notifytimer, notifyengineblown…).
- **The game's interpreter** lives in `zLua` (353 functions). It exposes `Game.*` and `E*` events: about 150 names, listed with `bun` over `scripts.json`.
- **Converter (`DATA_FORMAT` 12):**
  - `vlt-dump` decodes `Attrib::Blob` (`base64`).
  - It writes `scripts.json` with every handler already decompressed: owner, state, message and bytecode.
- **Reading them:**
  - `tools/src/lib/lua50.ts` disassembles (`disasmLua50`).
  - It also gives a rough Lua reading (`pseudoLua50`), e.g. `Game.SabotageEngine(Game.GetPlayerElement(0), 5)`.

## 7. The engine runs the original scripts

- `Script/Lua50.swift` is a Lua 5.0 interpreter that loads the disc's bytecode. It implements the `lvm.c` 5.0 instructions the scripts use; anything else fails loudly.
- `Script/GameScript.swift` runs the activities:
  - States and messages with `self` (the activity, with its child collections by short name), `msg` and `state`.
  - Timers (`Game.SetTimer` / `KillTimer`) and plane and box triggers. They fire by proximity; the real plane has an orientation. [I]
  - Deferred state changes (`ChangeState`).
  - Game functions with no equivalent yet warn once ("aún sin equivalente") and return `nil`.
- **In races** (`RaceSession`):
  - If the event has its own handlers, its activity is created: prerace on setup, racing at "GO!", postrace at the end and done when closing.
  - If the script asks for `ChangeState("postrace")` mid-race, the event ends as completed.
  - Game functions already wired:

| Script function | What it does in the engine |
|---|---|
| `ForceAIControl` / `ClearAIControl` | Player autopilot |
| `SabotageEngine` | Engine loses power and sends `notifyengineblown` |
| `SpawnCop` | Police car at the marker, and a pursuit |
| `EBailPursuit` / `NoNewPursuitsOrCops` | The pursuit ends and no new pursuits start |
| `Fade` / `EFadeScreen…` | Black layer |
| `ECellCall` / `EAddSMS` | The disc's `SMS_MESSAGE_<n>` text |
| `E911Call` | 911 notice |
| `ENISNukeSmack` | Clears breakables from the start |
| `JumpToCarLot` | Jump to the car lot |

- **The prologue** (`Career/Prologue.swift`, doc 18 §9) is the first full use.
