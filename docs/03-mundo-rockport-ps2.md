# Mundo de Rockport en PS2 (SLES-53559)

- `TRACKS\L2RA.BUN` (1,38 MB): datos permanentes. Contiene la tabla de secciones `0x00034110`, la red de carreteras `0x0003B800`, triggers, eventos `0x8003B810`… [V]
- `TRACKS\STREAML2RA.BUN` (191 MB): 1 023 secciones de streaming [V].
- Entrada de sección (92 B) [V]: `+0 nombre[8]` · `+8 número` · `+16 tipo` · `+20 offset` · `+24 tamaño` (×3) · `+36 prioridad` · `+40 centro X,Y (f32)` · `+48 radio` · `+52 checksum`.
- Sección típica: pack de texturas + listas de sólidos + escenario `0x80034100` + luces `0x80036000` + datos de carretera `0x0003B801`.
- **SceneryInfo** (0x48): nombre[24] + 4 hashes de modelo (LOD) + radio [D][V].
- **SceneryInstance PS2** (0x40) [V]: `f32 bbMin[3]`, `f32 bbMax[3]`, …, `f32 pos[3] @0x20`, `s16 rot[9]/8192 @0x2C`, `s16 info @0x3E`. (En PC/GC la caja es s16; en PS2 es float.)
- Edificios grandes: geometría ya en coordenadas de mundo (instancia identidad). Props: posición + rotación.
- Coordenadas: Z arriba [D]. Unidades: metros [H] (el coche mide ≈4,5 m).

## Cifras de la conversión completa
718 secciones con escenario · 106 714 instancias · 18 156 sólidos únicos · 5,84 M triángulos · 2 627 texturas · 4 instancias sin modelo · 7 texturas no encontradas.
Plano cenital: `map-data/SLES-53559/rockport-plano.png` (1,49 m/px; calibración en `rockport-plano.json`).
