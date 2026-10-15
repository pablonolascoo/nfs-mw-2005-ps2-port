# Coches: modelos, texturas de sustitución, pintura y ruedas

Etiquetas: [V] verificado con bytes de SLES-53559 · [D] sacado de la decomp · [I] inferido · [H] hipótesis.

## 1. Dónde está cada cosa

| Qué | Origen en el disco | Código | Salida |
|---|---|---|---|
| Geometría | `CARS\<COCHE>\GEOMETRY.BIN` | `tools/src/cli/convert.ts` (modo `car`) | `map-data/<ID>/cars/<COCHE>.glb` |
| Texturas propias | `CARS\<COCHE>\TEXTURES.BIN` | `tools/src/lib/tex-ps2.ts` | dentro del GLB |
| Texturas comunes | `CARS\TEXTURES.BIN`, **`GLOBAL\GLOBALB.BUN`**, `GLOBAL\INGAMEA.BUN` | idem | dentro del GLB |
| Texturas que cambia el juego | ninguna (se generan en tiempo de ejecución) | `tools/src/lib/car-textures.ts` | materiales con `extras.role` |
| Datos de cada pieza | nombre del sólido + chunk de marcadores `0x0013401A` | `tools/src/lib/car-parts.ts` | `extras.pieza`, `extras.marcadores` del nodo |
| Ruedas (posición, tamaño, caída) | `GLOBAL\ATTRIBUTES.BIN`, clases `ecar` y `tires` | `tools/src/cli/car-attribs.ts` | `map-data/<ID>/cars.json` |
| Montaje en el visor | — | `viewer/src/drive.ts` (`applyCarConfig`, `mountWheels`, `paintCar`, `skinCar`, `presetSkin`, `carHolder`) | — |

Hay **91 modelos** en SLES-53559 [V]: 40 coches, 11 de policía, 27 de tráfico, 6 remolques y 7 de piezas de tuneo (`WHEELS`, `SPOILER`, `ROOF`, `BRAKES`…).
`cars.json` tiene **92 colecciones** de atributos (`ecar`, `car`…) [V].

Regenerar solo los coches:

```bash
cd tools && awk -F'\\' '/^CARS\\[A-Z0-9_]+\\GEOMETRY\.BIN,/{print $2}' ../inventory/SLES-53559.csv | xargs bun src/cli/convert.ts ../original/SLES-53559.iso SLES-53559 car
bun src/cli/car-attribs.ts ../original/SLES-53559.iso SLES-53559
```

## 2. Piezas, kits y ranuras [V][D]
Lista de ranuras: `CarPartID.h` (76 ranuras con modelo). Coche de serie = nivel de mejora 0 en cada ranura (`SetStockParts`, `CarInfo.cpp`) [D].

| Nombre del sólido | Qué es | De serie |
|---|---|---|
| `<COCHE>_BASE_<LOD>` | base (marco de cristales); lleva los marcadores SPOILER / ROOF_SCOOP / luces | sí |
| `<COCHE>_KIT00_<RANURA>` | pieza de serie (BODY, HOOD, FRONT_TIRE, FRONT/REAR_BRAKE, DRIVER, luces, cristales, retrovisores, SPOILER…) | sí |
| `<COCHE>_KITnn_BODY` (nn 01–05) | kit de carrocería: **un BODY entero** (en MW no hay paragolpes ni faldones sueltos) [D] | no |
| `<COCHE>_STYLEnn_HOOD` | capó de tuneo (17 estilos, 33 coches) | no |
| `<COCHE>_KITnn_UNIVERSAL_SPOILER_BASE` | soporte de alerón: solo con alerón de tuneo [D: CarRender.cpp 1894] | no |
| `<COCHE>_(KITnn_)DECAL_*` | zonas de vinilos, vacías de serie | no |
| `KITnn_DAMAGE0_<PANEL>` | panel **intacto**: policía y tráfico se montan así (BODY, HOOD, puertas, paragolpes, COP_LIGHTS) | sí |
| `KITnn_DAMAGE0_FRONT/REAR/…LEFT/RIGHT` | capa de golpes (textura `DAMAGE0` 0x236bd9ce) [I] | no |
| `KITnn_DAMAGE1_*` | paneles rotos (no se exportan) | — |

- El conversor guarda ahora **todas** las piezas (mejor LOD; en PS2 la `B`, la misma que usa el juego para el jugador [D]). Cada nodo glTF lleva `extras.pieza = {slot, kit, style, stock, kind}` (`carPartInfo`).
- Antes se dibujaban a la vez todos los kits y todos los capós: el A3 mostraba 6 carrocerías y 18 capós superpuestos. La policía salía sin carrocería (se descartaban sus paneles `DAMAGE0`).
- Regla del visor (`applyCarConfig`): una pieza por ranura; el kit pedido sustituye al KIT00 solo en las ranuras que trae; un `STYLEnn_HOOD` oculta el capó del kit; una pieza normal gana a un panel `DAMAGE0` de la misma ranura.
- Ejes del modelo: X adelante, Y izquierda, Z arriba; origen en el suelo bajo la carrocería [V].

## 3. Texturas
El modelo pide nombres "comodín" que el juego cambia al vuelo (`CarRenderInfo::MasterReplacementTextureTable`) [D]. Muchos genéricos son texturas reales de **`GLOBAL\GLOBALB.BUN`** [V]; el conversor ya lo carga.

| Hash | Nombre [V] | Dónde | Resultado |
|---|---|---|---|
| `03c906ef` / `1a268b3c` | `TREAD` / `TREAD_N` | neumático | GLOBALB (banda) / mapa de normales (no se dibuja en PS2) |
| `e38806e3` | `TIRE_BACK` | tapa plana en la cara **interior** de la rueda | GLOBALB |
| `7811c146…49` | `ROTOR1…4` | disco de freno | GLOBALB |
| `721aff7c` | `CARBONFIBRE` | alerones, piezas de carbono | GLOBALB |
| `1b049702` | `WINDOW_MASK` | BASE, cristales | GLOBALB |
| `bd1f0e0a` · `cc772afb` · `69c032b9/ba` · `68100815` · `427b4565` · `8c283c65` · `bf30889b` | `CARBOTTOM` · `DOORLINE` · `GRILL_01/02` · `RADIATOR` · `INTERCOOLER` · `RUBBERACCORDIAN` · `METAL_SWATCH` | carrocería, capós | GLOBALB |
| `30e7076e` / `bf19330c` | `DRIVER_CUTOUT` / `DRIVER_COP` | conductor | GLOBALB / INGAMEA |
| `896efc91` | `TRAFFIC_TIRE` | tráfico: `<COCHE>_TIRE` → `TRAFFIC_TIRE` [D: CarRender.cpp 1206] | alias en el conversor |
| `<COCHE>_BADGING_N`, `<COCHE>_MISC_N`, `<COCHE>_TIRE_N` | mapas de normales (Xbox) | en la tabla, sin uso en las tiras de PS2 | — |
| `<COCHE>_KIT00_HEADLIGHT_GLASS_OFF` | cristal de faro | cristales | sustituto `cristal` |
| `910e6654…`, `445a675d`, `d0161a90` | `DUMMY_DECAL1…`, `DUMMY_NUMBER_LEFT/RIGHT` | zonas de vinilo | ocultas |
| `<COCHE>_SKIN1`, `GLOBAL_SKIN1`, `SPOILER_SKIN1`, `ROOF_SKIN` | pintura | carrocería, alerón, toma de techo | sustituto `pintura` |

Nombres sacados con `bStringHash` sobre `Hash.hpp`, cadenas del ELF y los formatos `%s_…` de `CarInfo.cpp`, y confirmados recorriendo todos los packs de texturas del disco: **115 de 137** hashes de coche resueltos [V].
Siguen sin nombre: `13ccf4d8` (en las tablas de neumático y llantas, sin uso en tiras de PS2), `5ef7bdee` (neumáticos de 911GT2, BMWM3GTR, CORVETTEC6R), `c6ede248` (carrocería, alerón, retrovisores, capó), `4e8cf857` (conductor del BMWM3GTRE46), `c6578694…97` (pack `BRAKES`), `1366865e` (`TRAFDMPTR_BADGING`, no está en el disco).

### Pintura en el visor
- `paintCar(model, "#rrggbb")` cambia solo los materiales con `role = "pintura"`.
- Coche del jugador: por defecto el preset del juego `M3GTRCAREERSTART` (plata + franjas azules, sección 8); `?preset=BL5` elige otro; `?pintura=1f6fd1` vuelve a pintura lisa. Coches de exposición: campo `paint` del mod.

## 4. Ruedas y frenos [D][V]
El juego coloca **un solo modelo de rueda** cuatro veces (`CarRender.cpp` 1855-1999, 3330-3460) [D]:
- Modelo = pieza `FRONT_TIRE` (detrás también, salvo que exista `REAR_TIRE`). Cara de la llanta en **y = 0** del modelo; la tapa `TIRE_BACK` en y = ancho (lado interior) [V].
- Escala: radio `TireOffsets.w / (caja.x / 2)`; ancho `TireSkidWidth[i] × TireSkidWidthKitScale[kit] / caja.y`.
- Cadena: pivote (y −= ancho/2) · giro izquierdo (Z 180°, o espejo en y si `WheelSpokeCount & 0x80`) · caída sobre X (`Camber × 7°`, + delantera y trasera izquierdas, − derechas) · eje.
- Eje: x = `TireOffsets.x`; y deja la **cara de la llanta en |TireOffsets.y|** (+ `KitWheelOffset × 0,001` hacia fuera); z = `TireOffsets.z + FECompressions − Camber × 0,03`.
- Frenos (`FRONT_BRAKE`/`REAR_BRAKE`): y del marcador `FRONT_BRAKE`/`REAR_BRAKE` de la rueda (BMW: 0,061 m), sin escala de radio, en espejo en el lado izquierdo.
- El visor antiguo montaba la rueda del revés (la tapa interior hacia fuera, oculta como "un cuadrado"), sin frenos y unos 30 cm baja. Arreglado en `mountWheels`.
- `cars.json` trae ahora `skidWidth`, `kitWidthScale`, `kitOffsetFront/Rear`, `camber`, `feCompression`, `rimSize` (pulgadas, clase `tires`, `RIM_SIZE`).
- Las entradas raras con x trasera de 3 o 5 m (`default`, `traffic`, `racers`, `cops`, `street`, `van`, `truck`, `choppers`, `trailers`, `copheli`) son **colecciones plantilla (padres)**, no coches [V]. `BMWM3` no tiene colección `ecar`: el visor usa la de `bmwm3gtr`.

## 5. Tuneo: llantas, alerones, tomas de techo [D][V]
- **Las llantas de tuneo son ruedas enteras**, no una textura sobre el neumático: `WHEELS.glb` trae 164 modelos `<MARCA>_STYLEnn_<17-20>_25` (llanta + `TREAD` + `TIRE_BACK`) con su textura `<MARCA>_STYLEnn_WHEEL` [V].
  El juego las mide y escala igual que la rueda de serie [D]. `_WHEEL_INNER_MASK` solo sirve para teñir la llanta (`CompositeRim`, `CarSkin.cpp`) [D].
- Alerones (`SPOILER*.glb`, `SPOILER_STYLEnn[_CF]`) en el **marcador `SPOILER`** de la pieza BASE; tomas de techo (`ROOF.glb`, `ROOF_STYLEnn[_DUAL|_OFFSET][_CF]`) en **`ROOF_SCOOP`** [D: CarRender.cpp 3262-3316, V: marcadores del A3].
- Los marcadores salen del chunk `0x0013401A` (`ePositionMarker`, 0x50 B: hash, 2 parámetros, matriz 4×4) y van a `extras.marcadores` [V].
- Visor (coche del jugador y vista previa), por URL: `?kit=2&capo=5&llanta=BBS_STYLE01&aleron=SPOILER_STYLE03&techo=ROOF_STYLE01`. El tamaño de llanta sigue el `RIM_SIZE` del coche.

## 6. Resultado (91 modelos, 2026-10-12)
- Los 91 modelos revisados en la vista previa (hoja de contactos): coches, policía, tráfico, camiones y helicóptero salen completos, con banda de rodadura, discos y pinzas.
- Texturas que faltan tras convertir: solo `4e8cf857` (conductor del BMWM3GTRE46), `c6578694…97` (pack BRAKES) y `1366865e` (logo del TRAFDMPTR).

## 7. Pendiente
- Remolques: se ven todas las cargas `ATTACHMENTn`; algunas quedan lejos del remolque (seguramente van con marcador o una por variante) [H].
- Alerones con `USEMARKER2` (marcador `SPOILER2`), capa de golpes, `ExtraRearTireOffset`, calcomanías de tienda (sección 8). Reflejos y material de luz de la pintura: hechos (doc 20).
- Hashes sin nombre de la sección 3.

## 8. Coches predefinidos (Lista Negra), vinilos y piel compuesta (2026-10-15)

### Dónde están [V][D]
Todo en `GLOBAL\GLOBALB.BUN` (no en el VLT: la clase `presetride` de `ATTRIBUTES.BIN` solo guarda niveles de rendimiento [D: `presetride.h`]).

| Chunk | Contenido | Tamaño |
|---|---|---|
| `0x00030220` | `PresetCar[82]` [D: `CarInfo.hpp`]: `+0x08` tipo de coche (char[32]), `+0x28` nombre del preset (char[32]), `+0x48` FEKey u64, `+0x50` VehicleKey u64, `+0x58` FilterBits, `+0x5C` PhysicsLevel, `+0x60` `PartNameHashes[139]` (una por `CARSLOTID`) | 0x290 B (0x28C + relleno del u64) [V: 53 792 = 82 × 0x290] |
| `0x80034602` | `CarPartPack`: `0x34603` cabecera (60 B; 11 925 piezas, 1 751 atributos, 99 tipos, 487 tablas de modelo) · `0x34606` cadenas (desplazamiento ×4) · `0x3460c` tablas de atributos (int16) · `0x34605` atributos (8 B: hash + valor) · `0x3460a` modelos (0x18 B) · `0x3460b` tipos · `0x34604` piezas (0xE B) | [V] |
| `0x00034600` | `CarTypeInfo[84]` (0xD0 B, alineado a 16) | [V] |
| `0x00034607` | tipos por ranura `u32[139×2]` (0xFFFFFFFF = el propio coche) + 10 `CarSlotTypeOverride` | [V] |
| `0x00135200` | materiales de luz (156): `+0x0C` hash, `+0x14` nombre (`WINDSHIELD_TINT_L2_RED`, `METPAINTSILVER`…) | [V] |

- Por ranura: `0` = vacía, `1` = la de serie (nivel 0), otro valor = hash de la pieza, que se busca por `PartID` (`CarPartSlotMap`) y tipo (`GetTypesFromSlot`) [D: `FillWithPreset`, `NewGetCarPart`].
- Atributos de pieza (bStringHash) [V]: `RED GREEN BLUE GLOSS` (pintura), `TEXTURE` (cadena: nombre del vinilo), `NUMCOLOURS`, `REMAP`, `NUMREMAPCOLOURS`, `BRAND_NAME` (`GLOSS`/`METAL`/`PEARL`/`VINYL`/`RIM`), `TEXTURE_NAME` (llanta), `LIGHT_MATERIAL_NAME`, `KITNUMBER`, `CARBONFIBRE`, `USEMARKER2`, `NAME`, `SPOKE_COUNT`, `INNER/OUTER_RADIUS`… Sin resolver: `0x311151f8`, `0x4732da07`.
- Sólido de cada pieza: `CarPart::GetModelNameHash` [D] = `bStringHash("_B", bStringHash(nombre, bStringHash(medio, base)))` con base = tipo de coche, marca o 0xFFFFFFFF. Cuadra con los nodos de los GLB: `MUSTANGGT_KIT04_BODY_B`, `SPOILER_STYLE15_CF_B`, `WHEELS:OZ_STYLE01_20_25_B` [V].
- 82 presets: `RAZORMUSTANG` y `BL2…BL15` (Lista Negra), `M3GTRCAREERSTART` y `E3_DEMO_BMW` (BMW de la historia), `CS_CAR_*` (escenas), `CE_*`/`BONUS_*` (edición coleccionista), policía de escena.
- En `gameplay.json` el jefe de `race_bin_01` (Razor) lleva `E3_DEMO_BMW`, el mismo aspecto que `M3GTRCAREERSTART` [V].

### Vinilos y composición (CarSkin.cpp) [D][V]
- Cada coche tiene `CARS\<COCHE>\VINYLS.BIN` (~276 texturas PSMT8 de **512×512**) con `<BASE>_<TEXTURE>` y `<BASE>_<TEXTURE>_MASK`, en el mismo espacio UV que `<BASE>_SKIN1` [V]. `PREVINYL.BIN` solo trae 3 pruebas de 256×256 (`_PRECOM_`).
- Los vinilos de la Lista Negra son `NNNOMBRE` (`01RAZORCALLAHAN`…`15TONYHO`); el del BMW es `PSRTEST` (las franjas azules) [V].
- `CompositeSkin` (8 bits, PS2) [D]: lienzo = color base (RGB de la pintura, alfa = `GLOSS`); por píxel `m` = byte R de la paleta de la máscara: `m ≥ 0x80` → píxel del vinilo, `0 < m < 0x80` → mezcla `m/128`. El alfa del vinilo es el brillo (zonas mate). Con `REMAP` el vinilo se recolorea con `VINYL_COLOUR0_0…2` (pesos alfa/B/G [H]); **ningún preset del disco usa REMAP** [V].
- La misma piel va a `SPOILER_SKIN1`, `ROOF_SKIN` y `GLOBAL_SKIN1` [D: `ReplaceSpoilerHash`].
- Llanta: `CompositeRim` tiñe `<LLANTA>_WHEEL` con `PAINT_RIM` según `<LLANTA>_WHEEL_INNER_MASK` de `CARS\WHEELS\TEXTURES.BIN` [D][V].
- Cristales: el tintado cambia el material de luz (`WINDSHIELD_TINT_*`), no una textura; el color se deduce del nombre [I].
- Calcomanías (`DECAL_*_TEXn`): ningún preset de la Lista Negra las usa [V]; las zonas `DECAL_*` se quedan ocultas.

### Conversor y motores
- `tools/src/lib/car-presets.ts` (lectores) y `tools/src/cli/presets.ts` → `map-data/<ID>/presets.json` (por preset: `solids` con el nodo exacto de cada ranura, `kit`, `paint`, `vinyl` con sus colores, `rim`, `rimPaint`, `windowTint`, `decals`) y `vinyls/*.png` (42 vinilos + máscaras + 18 máscaras de llanta; solo local). Paso del instalador «Coches de la Lista Negra»; `DATA_FORMAT` = 3. ~6 s.
- Motor nativo: `CarSkin.swift` compone la piel en CPU **a 1024×1024** (el doble del PS2, muestreo bilineal de imagen y máscara: bordes suaves sin inventar detalle) y la sube con mipmaps; `Car.swift` monta solo los sólidos del preset, llantas de `WHEELS`, alerón y toma de techo de los packs en los marcadores `SPOILER`/`ROOF_SCOOP`. Por defecto el jugador lleva `M3GTRCAREERSTART`; `--car-preset RAZORMUSTANG` (o `BL2…BL15`, `ninguno`).
- Visor: `?preset=RAZORMUSTANG` (por defecto el BMW de la historia); `presetSkin`/`skinCar` en `viewer/src/drive.ts` hacen la misma composición en un lienzo.
- Sólido roto del disco: `CAYMANS_KIT00_REAR_LEFT/RIGHT_WINDOW` tiene vértices a 9 m del coche [V]; los dos motores descartan piezas que se salen del coche.

### La Lista Negra (presets del disco) [V]
| Nº | Preset | Coche | Carrocería | Capó | Alerón | Techo | Llanta | Pintura | Vinilo | Llanta pintada | Cristales |
|---|---|---|---|---|---|---|---|---|---|---|---|
| — | `M3GTRCAREERSTART` | BMWM3GTRE46 | KIT00_BODY | — | — | — | KIT00_FRONT_TIRE | METAL_L1_COLOR41 `#b7b7b7` | PSRTEST | — | STOCK WINDOW TINT |
| 1 | `RAZORMUSTANG` | MUSTANGGT | KIT04_BODY | STYLE04_HOOD | SPOILER_STYLE15_CF | ROOF_STYLE01 | OZ_STYLE01_20_25 | GLOSS_L1_COLOR62 `#000000` | 01RAZORCALLAHAN | `#c0cfd4` | DARK RED |
| 2 | `BL2` | SLR | KIT00_BODY | KIT00_HOOD | — | — | ADR_STYLE05_20_25 | GLOSS_L1_COLOR62 `#000000` | — | — | DARK RED |
| 3 | `BL3` | DB9 | KIT05_BODY | STYLE03_HOOD | SPOILER_STYLE43_CF | — | OZ_STYLE02_20_25 | METAL_L1_COLOR27 `#f8ca00` | 03RONNIEMCCREA | — | DARK BLUE |
| 4 | `BL4` | VIPER | KIT03_BODY | STYLE21_HOOD | SPOILER_STYLE43_CF | — | BBS_STYLE02_20_25 | PEARL9_PAINT `#3ca03c` | 04JOEVEGA | `#303030` | DARK BLACK |
| 5 | `BL5` | CORVETTE | KIT01_BODY | KIT00_HOOD | SPOILER_STYLE02_CF | — | BBS_STYLE05_20_25 | GLOSS_L1_COLOR45 `#5f2700` | 05WESALLEN | — | DARK ORANGE |
| 6 | `BL6` | GALLARDO | KIT00_BODY | KIT00_HOOD | SPOILER_STYLE42_CF | — | OZ_STYLE03_20_25 | METAL_L1_COLOR62 `#000000` | 06HECTORDOMINGO | — | DARK PEARL ORANGE |
| 7 | `BL7` | CLK500 | KIT03_BODY | STYLE07_HOOD | SPOILER_STYLE15_CF | ROOF_STYLE18_CF | OZ_STYLE02_20_25 | METAL_L1_COLOR61 `#7d7d7d` | 07KIRANAZAKATO | `#6e6e6e` | DARK BLACK |
| 8 | `BL8` | MUSTANGGT | KIT05_BODY | STYLE21_HOOD | SPOILER_STYLE16_CF | — | ADR_STYLE03_20_25 | GLOSS_L1_COLOR03 `#fffceb` | 08JADEBARRETT | — | DARK BLACK |
| 9 | `BL9` | LANCEREVO8 | KIT04_BODY | STYLE26_HOOD | SPOILER_STYLE11_CF | ROOF_STYLE18_OFFSET_CF | ENKEI_STYLE04_20_25 | GLOSS_L1_COLOR01 `#ffffff` | 09PIERREDUPONT | — | DARK YELLOW |
| 10 | `BL10` | CAYMANS | KIT04_BODY | STYLE07_HOOD | SPOILER_STYLE43_PORSCHES_CF | ROOF_STYLE01 | BBS_STYLE04_20_25 | GLOSS_L1_COLOR62 `#000000` | 10KARLSMIT | `#6e6e6e` | DARK RED |
| 11 | `BL11` | ECLIPSEGT | KIT05_BODY | STYLE13_HOOD | SPOILER_STYLE16 | ROOF_STYLE02 | ROJA_STYLE03_20_25 | METAL_L1_COLOR62 `#000000` | 11LOUPARK | `#000000` | DARK PEARL GOLD |
| 12 | `BL12` | RX8 | KIT03_BODY | STYLE17_HOOD | SPOILER_STYLE15_CF | — | ROJA_STYLE01_20_25 | METAL_L1_COLOR02 `#4f4f4f` | 12ISABELDIAZ | — | DARK PEARL AQUA |
| 13 | `BL13` | SUPRA | KIT03_BODY | STYLE20_HOOD | SPOILER_STYLE02 | — | OZ_STYLE03_20_25 | GLOSS_L1_COLOR76 `#0b0e2e` | 13VICTORVASQUEZ | `#856a35` | DARK ORANGE |
| 14 | `BL14` | IS300 | KIT03_BODY | STYLE26_HOOD | SPOILER_STYLE36_CF | ROOF_STYLE15_CF | VOLK_STYLE01_20_25 | GLOSS_L1_COLOR46 `#5f4200` | 14VINCEKILIC | `#d10707` | MEDIUM RED |
| 15 | `BL15` | GTI | KIT01_BODY | STYLE07_HOOD | KIT00_SPOILER | ROOF_STYLE03 | BBS_STYLE04_20_25 | GLOSS_L1_COLOR03 `#fffceb` | 15TONYHO | `#6e6e6e` | DARK PEARL RED |

Hoja de contactos del motor nativo con los 15: coinciden con las libreas del juego (Razor negro con llamas, Ronnie amarillo, JV verde perlado, Kaze gris, Jewels blanco, Earl azul y blanco, Baron negro con llamas, Sonny blanco y azul…).
