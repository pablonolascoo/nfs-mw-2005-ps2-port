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
718 secciones con escenario · 106 714 instancias · 18 156 sólidos únicos · 5,75 M triángulos visibles · 2 627 texturas · 4 instancias sin modelo · 5 texturas no encontradas (de 7: `HEADLIGHTGLOW` y `GRAY_MID_A` están en `GLOBAL\GLOBALB.BUN` / `INGAMEA.BUN`).
Plano cenital: `map-data/SLES-53559/rockport-plano.png` (1,49 m/px; calibración en `rockport-plano.json`).

## Grupos de escenario y bloqueos [V]
- `ExcludeFlags` (u32 @0x18 de la instancia PS2): bit `0x10` = oculto por defecto, `0x400` = arte volteado [D: `SceneryGroup::EnableRendering`].
- `L2RA.BUN` → `0x00034108` SceneryOverrideInfo[] (6 B: sección, instancia, flags) y `0x00034109` SceneryGroup (`NameHash`, `GroupNumber`, `NumObjects`, `BarrierFlag`, `DriveThroughBarrierFlag`, índices u16; tamaño `(n·2+0x17)&~3`).
- 754 grupos: 675 `BARRIER_SPLINE_n` (bloqueos con flecha de cada carrera), 6 `BARRIER_LOCKED_10..15` (candados de la historia), `SCENERY_GROUP_DOOR` (escombros y excavadoras que cierran calles; el juego lo activa al cargar), 71 bloqueos más resueltos por fuerza bruta y un grupo grande sin nombre (#1, 7 353 objetos, visible).
- El juego activa los grupos por nombre con `EnableBarrierSceneryGroup` (carreras y progreso).

## Zonas de garaje y tiendas [V]
15 zonas en `GAMEPLAY.BIN` (ver doc 05): 4 refugios, 3 concesionarios, 8 talleres. Cada una tiene su edificio cerca: `XS_SafeGarage` / `XB_CT_SafehouseA` (refugio 1), `XB_CarParkDealership` (concesionarios), `XB_ChopShopA` (los 8 talleres, mismo modelo).
En el juego original, pulsar el botón en la zona llama a `EQuitToFE(GARAGETYPE_*)`: sale del mundo y carga el menú con el fondo del interior (`FRONTEND\PLATFORMS\*.BIN`).

## Sombras, agua y cielo [V]/[H]
- **Sombras horneadas** `SHD_*` (1 026 texturas): RGB negro y alfa = densidad. Se mezclan encima del suelo; no van al nivel lejano [V].
- **Agua animada** `ANM_WATERA_000…013` (14 fotogramas) en `TRN_Ocean_*` y piezas de costa, con alfa de vértice 0,5 [V]. Esos modelos solo cubren la costa; el cuerpo de agua se dibuja como plano a z = 0 en el visor [H: no localizado aún en el código del juego].
- **Cielo** `SKYDOME`/`SKY_SPECULAR`: la cúpula cambia sus texturas por capa (`SkyRender.cpp`) y esas texturas **sí están** en `GLOBAL\DYNTEX.BIN` (`SKY_MIDDAY_A_GRADIENT_A`, `…_CLOUDS_A`, `…_CAP_A`…, nombres truncados a 23 letras) [V, corrige lo dicho antes]. El motor nativo las usa (doc 20 §5); el visor sigue con su degradado.

## Visibilidad y niveles de detalle del escenario [D][V]
Código del juego: `SetupSceneryCullInfo` (`Ecstasy.cpp`) y el recorte de `Scenery.cpp`. Código propio: modo `tiles` de `tools/src/cli/convert.ts`.
- Byte bajo de `ExcludeFlags`: el juego salta la instancia si `((flags & 0xFF) ^ 0x60) & vista`. La vista del jugador vale `0x10 | 0x02`.
  - `0x10` oculto (grupos desactivados) · `0x02` **fuera de la vista del jugador** · `0x20` / `0x40` solo entran en retrovisor y reflejos/sombras.
  - 2 232 instancias tienen `0x02` [V]. Son copias unos 20 m más bajas de pórticos y carteles de autopista, puentes y pasos elevados. Antes se dibujaban: se veían carteles y estructuras duplicados bajo la calzada.
- `0x200`: modelo ya en coordenadas de mundo (sin matriz). Las 10 438 instancias con ese bit tienen matriz identidad [V].
- `0x400000` marca las 9 147 instancias con matriz espejo (determinante < 0) [V]. El conversor invierte su orden de vértices.
- Las sustituciones de `0x00034108` copian el mismo valor que ya trae la instancia [V]: no cambian nada al cargar.
- LOD: en PS2 no existe `pModel[0]`; el juego lo copia de `pModel[1]` [D: `Scenery.cpp` 416-420]. Cerca = `NameHash[1]`; lejos = `NameHash[2]` (o el 1). `NameHash[3]` es para reflejos y sombras: no se usa en la vista normal.

## Auditoría de texturas (2026-10-12)
Herramientas: `tools/src/lib/tex-ps2.ts` (lee también `TilableUV`, `ApplyAlphaSorting`, `RenderingOrder`). Capturas antes/después en 8 puntos de calle (puertas de `garages.json`).

| Problema visto | Causa | Arreglo |
|---|---|---|
| Casillas enteras sin paredes ni edificios (solo el nivel lejano gris) | Arrays de texturas de más de 256 capas: WebGPU los rechaza y la casilla no se dibuja | `viewer/src/tile-worker.ts`: arrays por tamaño exacto, máximo 256 capas |
| Texturas borrosas | Todas se reescalaban a 128×128 en cuanto la casilla tenía más de 32 | Tamaño original, sin reescalar |
| Bordes negros en hojas, vallas y pintadas | Mipmaps y filtro mezclaban el negro de los texeles vacíos | Relleno del color hacia los texeles transparentes y mipmaps ponderados por alfa |
| Rejas, ramas y barandillas finas comidas | Umbral de recorte 0,5 | Umbral del juego `0x28` (`materials.ts`) |
| Pintadas y cristales con recorte duro | `MODULATED + BLEND` se trataba como recorte | Mezcla normal, sin escritura de profundidad |
| Líneas en el borde de carteles | Todo se repetía | `TilableUV` → recortar al borde (sampler glTF y atributo `wrapc` en el visor) |
| Luz horneada plana, colores lavados | Color de vértice usado como lineal | `COLOR_0 = (c/128)^2,2` (`mesh-build.ts`) |
| Carteles y puentes duplicados ~20 m más abajo | Se dibujaban instancias `0x02` | Fuera en `convert.ts` |
| Placas sólidas flotando en el cielo (árboles lejanos) | El nivel lejano pintaba las tiras con recorte sin su alfa | El nivel lejano solo lleva tiras opacas y usa `NameHash[2]` |
| Asfalto gris en el nivel lejano | El color medio ignoraba los texeles con alfa ≈ 0 | En texturas opacas cuenta todo el texel |
| Farolas y señales sin textura | `HEADLIGHTGLOW`, `GRAY_MID_A` viven en `GLOBALB`/`INGAMEA` | Se cargan esos packs |

Lo que no es un fallo [V]: UV con valores fuera de 0…1 (43 % de los vértices, texturas que se repiten), ningún `0x400` de volteo activo, y los paneles de fondo `TRN_CT_PROPS_HIGHWAY1_*_CHOP_*` a 200-340 m de altura (decorado de horizonte del juego: de cerca parecen placas sueltas).

Pendiente: 5 texturas del mundo siguen sin aparecer (`7e2734a8`, `7e2734a9`, `8b335c76`, `6dc61680`, `61a56b42`); el agua sigue siendo un plano propio; no se ha comparado píxel a píxel con capturas de PCSX2.
