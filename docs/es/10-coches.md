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
| Montaje en el visor | — | `viewer/src/drive.ts` (`applyCarConfig`, `mountWheels`, `paintCar`, `carHolder`) | — |

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
- Coche del jugador: `?pintura=1f6fd1` (por defecto plata `aeb7c2`). Coches de exposición: campo `paint` del mod.

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
- Alerones con `USEMARKER2` (marcador `SPOILER2`), pintura de llanta, vinilos y pintura compuesta, capa de golpes, `ExtraRearTireOffset`.
- Hashes sin nombre de la sección 3.
