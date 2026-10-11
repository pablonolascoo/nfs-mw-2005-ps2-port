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
- **Cielo** `SKYDOME`/`SKY_SPECULAR`: sus texturas no existen en el disco (se generan al vuelo); el visor dibuja un degradado propio [V: búsqueda en todos los archivos].
