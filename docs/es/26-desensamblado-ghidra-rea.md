# 26 · Desensamblado completo del ejecutable (Ghidra + REA)

> Qué es: el entorno para leer **todo** el código del juego, no solo la parte que ya tiene en C la decomp.
> Por qué: la decomp de referencia (`dbalatoni13/nfsmw`) solo tiene en C el ~14 % del código (~30 % aproximado, decomp.dev, 2026-10-31).
> El resto —historia, condiciones de carrera, IA de carrera, scripts Lua, menús— solo existía como ensamblador MIPS.

## 1. Piezas instaladas (fuera del repo, en `~/Tools`)

| Pieza | Versión | Para qué |
|---|---|---|
| JDK Temurin | 21.0.13 | Ghidra corre en Java |
| Ghidra | 12.1.4 | Desensamblador y descompilador (de la NSA, gratuito) |
| ghidra-emotionengine-reloaded | 2.1.39 | Procesador del PS2 (MIPS R5900, «Emotion Engine») |
| Decompilador nativo | compilado en el Mac (arm64) | Ghidra no lo trae para Apple Silicon |
| REA (`rea-agents`) | 6.8.0 | Servidor MCP: Claude maneja Ghidra directamente |

Notas:
- **Decompilador para Apple Silicon:** Ghidra solo trae binarios nativos para Linux y Windows. Se compila desde `Ghidra/Features/Decompiler/src/decompile/cpp` con `make ARCH_TYPE="-arch arm64" ghidra_opt sleigh_opt` y se copia a `os/mac_arm_64/decompile` y `os/mac_arm_64/sleigh`.
  - Sin `-arch arm64`, el Makefile compila para Intel.
  - Para evitar que intente compilar módulos que piden `bfd.h`, antes se crean vacíos los archivos `*/depend`.
- **REA** usa Node 24.22.2 (nvm, sin cambiar la versión por defecto). Está registrado solo en este proyecto: `claude mcp add --scope local rea` con `GHIDRA_INSTALL_DIR` y `JAVA_HOME`. `rea doctor` da todo correcto.
- No se instalaron Hopper ni IDA (son de pago).

## 2. Análisis del ejecutable

Se usa **SLUS_213.51** (EE. UU.), porque coincide byte a byte con la decomp y así se le pueden poner sus nombres. La lógica es la misma que en el PAL (doc 01).

```bash
export JAVA_HOME=~/Tools/jdk-21.0.13+9/Contents/Home
S=experiments/decomp/nfsmw/config/SLUS-21351/symbols.txt
~/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless ~/Tools/ghidra-projects nfsmw-slus \
  -import experiments/elf/SLUS_213.51 -overwrite -processor "r5900:LE:32:default" \
  -scriptPath ~/Tools/ghidra-scripts \
  -preScript ApplyDecompSymbols.java "$PWD/$S" \
  -postScript ExportDecompiled.java "$PWD/$S" "$PWD/experiments/ghidra/SLUS-21351"
```

- `ApplyDecompSymbols.java` pone los **14 810 nombres de función** de la decomp. [V]
- El análisis automático tarda **54 s**. [V]
- `ExportDecompiled.java` escribe el pseudocódigo de cada función, agrupado por el archivo original (`Speed/Indep/SourceLists/zGameplay.cpp.c`…).
- Los scripts están en `tools/ghidra/`.
- **La salida es código de EA y no se sube:** `experiments/ghidra/` está en `.gitignore`. Cada uno la genera con su propio disco.

## 3. Qué hay en cada archivo original (funciones con nombre)

| Archivo | Funciones | Contenido |
|---|---|---|
| zAI | 1161 | IA: tráfico, policía, rivales, persecuciones |
| zPhysicsBehaviors | 1092 | Comportamientos físicos de los coches |
| zFe2 / zFe / zFEng / zFeOverlay | 985 / 606 / 347 / 348 | Menús e interfaz |
| zEAXSound / zEAXSound2 | 675 / 804 | Sonido |
| **zGameplay** | **741** | **Carreras, carrera profesional, hitos, historia** |
| zWorld / zWorld2 | 597 / 395 | Mundo |
| zSpeech | 559 | Radio de la policía y voces |
| zMain | 473 | Arranque y bucle principal |
| zCamera | 447 | Cámaras |
| **zLua** | **353** | **Intérprete Lua interno (scripts del juego)** |

## 4. Cómo se usa para el port

1. Elegir un sistema (por ejemplo, el prólogo de la historia).
2. Leer su pseudocódigo en `experiments/ghidra/SLUS-21351/…` o pedírselo a REA (MCP `rea`).
3. Portarlo a Swift en `native-engine/` y etiquetar cada dato: **[D]** si sale de la decomp en C y **[G]** si sale del pseudocódigo de Ghidra (ensamblador leído, menos fiable que [D]).
4. Probarlo contra el comportamiento del juego original.

## 5. Tipos: nombres de campo en el pseudocódigo

- **Fuente:** `symbols/PS2/PS2_types.nothpp` de la decomp. Es el volcado (stdump) de la información de depuración del **prototipo** PS2 (NFS.ELF, Alpha 124): 4328 estructuras con campos y posiciones.
- **Problema:** el prototipo no es el juego final. `GRaceStatus::mRaceBin` está en 0x1944 en el prototipo, 0x1AB0 en GameCube final y **0x1C44 en PS2 final**. [V]
- **Criterio:** una estructura solo se aplica si mide lo mismo en el prototipo PS2 y en GameCube final (comentarios `// total size:` de los headers). [I] Así salen **939 estructuras fiables**: `GRaceBin`, `GRaceDatabase`, `GRaceParameters`, `GTimer`… Las que cambiaron (`GRaceStatus`, `GManager`, `GCharacter`) se dejan con desplazamientos para no inventar nombres.
- **Herramientas:**
  - `tools/src/cli/ghidra-types.ts` → `proto-types.tsv`.
  - `tools/ghidra/ImportProtoTypes.java` crea las estructuras (3406 campos) y tipa `this` en **1571 métodos**. Nunca en los estáticos: los marca el volcado.
- **Resultado:** `GetNextDDayRace(GRaceDatabase *this)`, `this->mIndex->mChallengeGoal`… en vez de `*(param_1 + 0x18)`.

```bash
bun tools/src/cli/ghidra-types.ts experiments/decomp/nfsmw experiments/ghidra/proto-types.tsv
~/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless ~/Tools/ghidra-projects nfsmw-slus -process SLUS_213.51 -noanalysis \
  -scriptPath ~/Tools/ghidra-scripts -postScript ImportProtoTypes.java "$PWD/experiments/ghidra/proto-types.tsv" \
  -postScript ExportDecompiled.java "$PWD/experiments/decomp/nfsmw/config/SLUS-21351/symbols.txt" "$PWD/experiments/ghidra/SLUS-21351"
```

## 6. Los guiones del juego son Lua 5.0 (en el disco)

- La historia, las condiciones de cada prueba y la carrera profesional **no están en el ejecutable**: son **258 manejadores de mensajes** (`messagehandler`) de `GLOBAL\GAMEPLAY.BIN`. [V]
- Cada uno lleva `bytecode`: un `Attrib::Blob` = {u32 tamaño, puntero} resuelto con `PtrN`. [V]
  - Dentro va un bloque **HUFF** de EA (el mismo descompresor de `lz.ts`) con **Lua 5.0**: «\x1bLua» 0x50, little endian, campos de instrucción 6/8/9/9 y `lua_Number` float de 4 B. [V]
  - Se leen **258 de 258**.
- **Organización:**
  - Cada manejador tiene un **dueño** (`handler_owner`): una actividad («16_2_1_d_day_intro», «race_bin_16/drive_to_safe_house») o una plantilla («basicrace», «drive_to_target»).
  - Tiene también un **estado** (`stateref` → `state.Name`: prerace, racing, postrace, done…) y un **mensaje** (stateenter, triggerenter, notifytimer, notifyengineblown…).
- **El intérprete del juego** está en `zLua` (353 funciones). Expone `Game.*` y eventos `E*`: unos 150 nombres, listados por `bun` sobre `scripts.json`.
- **Conversor (`DATA_FORMAT` 12):**
  - `vlt-dump` decodifica los `Attrib::Blob` (`base64`).
  - Escribe `scripts.json` con cada manejador ya descomprimido: dueño, estado, mensaje y bytecode.
- **Leerlos:**
  - `tools/src/lib/lua50.ts` desensambla (`disasmLua50`).
  - También da una lectura aproximada en Lua (`pseudoLua50`), por ejemplo `Game.SabotageEngine(Game.GetPlayerElement(0), 5)`.

## 7. El motor ejecuta los guiones originales

- `Script/Lua50.swift` es un intérprete de Lua 5.0 que lee el bytecode del disco. Implementa las instrucciones de `lvm.c` 5.0 que usan los guiones; las que no usan dan error claro.
- `Script/GameScript.swift` lleva las actividades:
  - Estados y mensajes con `self` (la actividad, con sus colecciones hijas por nombre corto), `msg` y `state`.
  - Temporizadores (`Game.SetTimer` / `KillTimer`) y disparadores de plano y caja. El disparo es por cercanía; el plano real tiene orientación. [I]
  - Cambio de estado diferido (`ChangeState`).
  - Las funciones del juego que aún no tienen equivalente avisan una vez («aún sin equivalente») y devuelven `nil`.
- **En las pruebas** (`RaceSession`):
  - Si la prueba tiene manejadores propios, se crea su actividad: prerace al montar, racing al «¡YA!», postrace al acabar y done al cerrar.
  - Si el guion pide `ChangeState("postrace")` en plena carrera, la prueba termina como completada.
  - Funciones del juego ya conectadas:

| Función del guion | Qué hace en el motor |
|---|---|
| `ForceAIControl` / `ClearAIControl` | Piloto automático del jugador |
| `SabotageEngine` | Motor sin potencia y mensaje `notifyengineblown` |
| `SpawnCop` | Policía en el marcador y persecución |
| `EBailPursuit` / `NoNewPursuitsOrCops` | Fin de la persecución y sin persecuciones nuevas |
| `Fade` / `EFadeScreen…` | Capa negra |
| `ECellCall` / `EAddSMS` | Texto `SMS_MESSAGE_<n>` del disco |
| `E911Call` | Aviso del 911 |
| `ENISNukeSmack` | Quita los rompibles de la salida |
| `JumpToCarLot` | Salto al concesionario |

- **El prólogo** (`Career/Prologue.swift`, doc 18 §9) es el primer uso completo.
