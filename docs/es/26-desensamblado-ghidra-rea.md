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
