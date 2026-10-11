# Hito 1 · Compatibilidad de SLES-53559 con la descompilación (2026-10-11)

Leyenda: **[V]** verificado · **[I]** inferido · **[H]** hipótesis · **[D]** decisión.

## Discos disponibles
| Disco | Ejecutable | SHA-1 ELF | Notas |
|---|---|---|---|
| SLES-53559 (PAL España, VER 1.00) | `SLES_535.59` 4 919 508 B | `923d2141…94bb8` | Principal (idioma español) [V] |
| SLUS-21351 (NTSC-U Black Edition, VER 1.01) | `SLUS_213.51` 4 918 740 B | `60289f3f…5034b` | **Coincide exactamente** con `config/SLUS-21351` de la decomp [V]. Trae demo de 007 FRWL. |

## Comparación de ejecutables (tools/elfcompare.py) [V]
- Mismo layout de secciones, mismas flags MIPS (`0x20924001`), sin tabla de símbolos.
- `.text`: PAL 3 926 464 B vs US 3 926 144 B (+320 B, ≈80 instrucciones).
- `.data` idéntica en tamaño (480 348 B); `.rodata` +272 B; `.bss` igual.
- Entrada: `0x436270` (PAL) vs `0x436128` (US).
- **Conclusión [I]:** misma base de código con pequeños cambios regionales. Portar el mapa de símbolos de SLUS a SLES es viable con un emparejado de funciones (Ghidra / firma por función); **no** basta con cambiar el ID de versión.

## Compilar la decomp en el Mac M4 [V]
- `configure.py -v SLUS-21351` + `ninja`: 316 de 377 pasos OK; falla al invocar `ee-gcc.exe` (Windows x86) mediante `wibo` (binario Mach-O x86_64).
- Causa: **Rosetta 2 no está instalado** (`arch -x86_64 /usr/bin/true` → "Bad CPU type").
- Solución (la ejecuta el usuario; acepta licencia de Apple): `softwareupdate --install-rosetta --agree-to-license`.
- Estado de la decomp: matching (recompila el ELF original), sin target nativo. PS2: SLUS 22,7 %, A124 18,6 %.

### Actualización tras instalar Rosetta 2 [V]
- `ninja` completa la compilación en 1 min 34 s (M4, 10 hilos).
- Progreso medido en local (SLUS-21351): 22,72 % de código idéntico al original, 47,17 % aproximado.
- Funciones: 6 995 de 21 549. Código del juego: 26,30 % idéntico.
- Enlazado: 0 de 306 archivos. Todavía no se puede generar un ELF completo, como era de esperar en esta fase del proyecto.

## Implicaciones para el port [D]
- **Datos:** se extraen de SLES-53559 (español). Los formatos son iguales en SLUS (mismo pipeline).
- **Lógica:** la decomp (SLUS) es la referencia de comportamiento; código nuevo nativo (C++/Metal) reutiliza sus estructuras.
- Ghidra 12.1.4 instalado (`brew install ghidra`) para el emparejado SLES↔SLUS.
