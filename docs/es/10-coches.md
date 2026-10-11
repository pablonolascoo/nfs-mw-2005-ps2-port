# Coches: modelos, texturas de sustitución, pintura y ruedas

Etiquetas: [V] verificado con bytes de SLES-53559 · [D] sacado de la decomp · [I] inferido · [H] hipótesis.

## 1. Dónde está cada cosa

| Qué | Origen en el disco | Código | Salida |
|---|---|---|---|
| Geometría | `CARS\<COCHE>\GEOMETRY.BIN` | `tools/src/cli/convert.ts` (modo `car`) | `map-data/<ID>/cars/<COCHE>.glb` |
| Texturas propias | `CARS\<COCHE>\TEXTURES.BIN` | `tools/src/lib/tex-ps2.ts` | dentro del GLB |
| Texturas comunes | `CARS\TEXTURES.BIN` | idem | dentro del GLB |
| Texturas que cambia el juego | ninguna (se generan en tiempo de ejecución) | `tools/src/lib/car-textures.ts` | materiales con `extras.role` |
| Ruedas (posición y radio) | `GLOBAL\ATTRIBUTES.BIN`, campo `TireOffsets` | `tools/src/cli/car-attribs.ts` | `map-data/<ID>/cars.json` |
| Montaje en el visor | — | `viewer/src/drive.ts` (`mountWheels`, `paintCar`, `carHolder`) | — |

Hay **91 modelos** en SLES-53559 [V]: 40 coches, 11 de policía, 27 de tráfico, 6 remolques y 7 de piezas de tuneo (`WHEELS`, `SPOILER`, `ROOF`, `BRAKES`…).
`cars.json` tiene **92 colecciones** de atributos (`ecar`, `car`…) [V].

Regenerar solo los coches:

```bash
cd tools && awk -F'\\' '/^CARS\\[A-Z0-9_]+\\GEOMETRY\.BIN,/{print $2}' ../inventory/SLES-53559.csv | xargs bun src/cli/convert.ts ../original/SLES-53559.iso SLES-53559 car
bun src/cli/car-attribs.ts ../original/SLES-53559.iso SLES-53559
```

## 2. Piezas y niveles de detalle
- Cada pieza es un sólido `<COCHE>_KIT00_<PIEZA>_<LOD>`; LOD `A` es el mejor [V].
- El conversor guarda solo el mejor LOD de cada pieza y descarta `_DAMAGE*` (`bestLod` en `convert.ts`).
- En PS2 la mejor rueda disponible suele ser `_B` (p. ej. `BMWM3GTRE46_KIT00_FRONT_TIRE_B`) [V].
- Ejes del modelo: X adelante, Y izquierda, Z arriba; origen en el suelo del coche [V con la carrocería del BMW: Z 0…1,23 m].

## 3. Texturas de sustitución
El modelo pide texturas con nombres "comodín". El juego las cambia al vuelo con
`CarRenderInfo::MasterReplacementTextureTable` (`CarRender.cpp`) y `UsedCarTextureInfo` (`CarInfo.cpp`) [D].
No están en ningún `TEXTURES.BIN` del disco [V]. Por eso el conversor les pone un material sustituto.

| Nombre (hash bStringHash) | Papel (`extras.role`) | Sustituto |
|---|---|---|
| `<COCHE>_SKIN1`, `<COCHE>_SKIN1B`, `GLOBAL_SKIN1`, `SPOILER_SKIN1`, `ROOF_SKIN` | `pintura` | gris claro; el visor la pinta |
| `0xA7366AE6` CARBONSKIN, `0x3C84D757` GLOBAL_CARBONSKIN | `carbono` | casi negro |
| `WINDOW_*`, `REAR_DEFROSTER` | `cristal` | oscuro translúcido |
| `0xA7E6EA53` / `0xA532FC46` faros, `HEADLIGHT_GLASS_*` | `faro` / `cristal` | blanco / cristal claro |
| `BRAKELIGHT_*`, `BRAKELIGHT_GLASS_*` | `piloto` / `cristal` | rojo |
| `LICENSEPLATE` | `matricula` | blanco |
| `0x5799E60B` DRIVER | `piloto_conductor` | gris oscuro |
| `BRAKE_GLOBAL*`, `0x7811C149` | `freno` | gris metal |
| `0x03C906EF`, `0xE38806E3` (caras de la llanta en la pieza TIRE) | `llanta` | gris metal [I: por la geometría] |

Hashes aún sin nombre en el BMW: `1b049702 cc772afb bd1f0e0a 721aff7c 4e8cf857` → gris oscuro neutro.
Para resolver más nombres: `experiments/decomp/.../Generated/Hash.hpp` y prueba de `bStringHash` (ver `tools/src/lib/hash.ts`).

### Pintura en el visor
- `paintCar(model, "#rrggbb")` cambia solo los materiales con `role = "pintura"`.
- Coche del jugador: parámetro de URL `?pintura=1f6fd1` (por defecto plata `aeb7c2`).
- Coches de exposición: campo `paint` en cada `display` del mod (`mods/garajes-unicos/mod.json`).

## 4. Ruedas
El modelo trae **una sola rueda** (la delantera). El juego la copia cuatro veces [D].

`TireOffsets[i] = (x, y, z, radio)` para i = 0 DI, 1 DD, 2 TD, 3 TI [D].
Ejemplo BMW M3 GTR: delante x = 1,6, detrás x = −1,13, y = ±0,91, radio 0,33 m [V].

Regla de montaje (`CarRender.cpp`, `WheelPivotTranslationAmount = 0.5`) [D]:
- La pieza TIRE va de y = 0 (dentro) a y = ancho (fuera, cara de la llanta) [V].
- La **cara exterior** queda en |y| = `TireOffsets.y`. La goma entra hacia el coche.
- Las ruedas del lado contrario se dibujan en espejo (escala y = −1).
- `z = 0` en `TireOffsets` = eje a la altura del centro de la pieza.
- El juego además escala ancho y radio (`TireSkidWidth`, `KitWheelOffsetFront/Rear`) y aplica caída (`CamberFront/Rear`). **Aún no se aplica en el visor.**

Rarezas: algunas colecciones de `cars.json` (clase `ecar`) traen x traseras de 3 o 5 m [V]; parecen valores de plantilla, no de un coche real [H].

## 5. Pendiente
- Llantas de tuneo de `WHEELS.glb` (165 piezas: 5ZIGEN, BBS, OZ…) montadas sobre la goma.
- Pintura compuesta real (vinilos, `CARSKIN` compuesta), escalado de ancho y caída.
- Nombres de los hashes que faltan.
