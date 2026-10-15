# 20 · Iluminación y efectos: color del PS2, coches, cielo, sombras y tratamiento visual

Etiquetas: **[V]** verificado en bytes de SLES-53559 o medido · **[D]** decomp · **[I]** inferido · **[H]** hipótesis.
Paso del conversor: `bun src/cli/fx.ts <iso> <ID>` → `map-data/<ID>/fx/` (`fx.json` + 32 PNG, < 1 s). `DATA_FORMAT` = 8.
Motor: `native-engine/Sources/Rockport/SceneShading.swift` (prólogo MSL común, `FXData`, `SceneLighting`), `Shaders.swift`,
`Renderer.swift`, `AIRender.swift`, `Garage/GarageRender.swift`. Lo que exporta el paso `effects` (partículas, destellos del
mundo, niebla y tinte por zona) está en el doc 24.

## 1. Qué se veía mal y por qué

| Defecto | Causa | Arreglo |
|---|---|---|
| Cajas verdes translúcidas de bordes duros en el refugio | Los rayos de luz aditivos (`CRIB1_LIGHTRAYS01/02`, `SFX_LIGHTRAY`) se sumaban en **lineal**: color de vértice 255 (= 4,55 lineal) × textura × alfa 0,05 ≈ +0,17 lineal ≈ +115/255 en pantalla. Además el shader del garaje ignoraba el alfa de vértice | La escena se escribe **codificada** y se mezcla en gamma como el GS: Cs (saturado a 255) × As sumado en pantalla ≈ +12/255. Alfa = textura × vértice (`fs_gadd`, `fs_additive`) |
| Sombras horneadas (`SHD_*`) flojas, todo «aplanado» | Mezcla normal en lineal: con alfa 0,5 la calle quedaba a 0,73 en pantalla (el PS2 la deja a 0,5) | Mezcla en gamma (§2) |
| Banda gris abajo al entrar en el refugio | El hueco de la puerta (`corridor` de `WorldGarage.swift`) bajaba 10 cm bajo la calle y recortaba el suelo ±2,5 m alrededor de la persiana, donde el interior no llega: se veía el mar | El hueco empieza 12 cm sobre la calle |
| Coches planos | Luz PBR del visor sin mapa de entorno | Material de luz del juego por tira + mapa de entorno esférico (§3) |
| Cielo de degradado propio | Se creía que las texturas del cielo no estaban en el disco | Están en `GLOBAL\DYNTEX.BIN` (§5) |
| Sombra del coche: mancha propia | — | `CARSHADOW` del disco, en la caja del coche, desplazada por el sol (§4) |
| Imagen sin el «look» amarillo y contrastado | Solo el tono PS2 propio | Tratamiento visual del juego (`visuallook`) antes del tono PS2 (§6) |
| Estrías del cielo del menú principal | **No es un fallo de UV** [V]: la cúpula `QRACE_MIDDAYSKY` de `PLATFORMCRIB` es un octógono con proyección plana (u = 0,5 ± 0,5·x/r, el anillo alto a 0,707 del ecuador) y la textura se estira de canto. `wrap` 0 (recorte) correcto | Sin cambio; la escena del menú se recompone en otro trabajo (escenas de garaje) |

## 2. Espacio de color de la escena = el del PS2 [D][V]
- El GS mezcla `(Cs − Cd)·As + Cd` sobre el framebuffer de 8 bits, es decir, en espacio de pantalla. Las texturas y el color de
  vértice se multiplican también en ese espacio (128 = 1,0; el conversor guarda `COLOR_0 = (c/128)^2,2`, doc 02).
- El motor sigue muestreando en lineal (texturas sRGB) y multiplicando en lineal, que es lo mismo para productos, pero ahora
  **cada shader de escena escribe su color codificado** (`sceneRGB`/`ps2Encode` de `scenePreludeMSL`) en la textura de escena
  `rgba16Float`, y la mezcla del hardware ocurre en gamma, como en el PS2. `fs_post` ya no codifica.
- La niebla también se mezcla en gamma (el GS hace la niebla después de la textura).
- Regla para cualquier shader nuevo que dibuje en la escena: incluir `scenePreludeMSL` y devolver `sceneRGB(F, colorLineal, mundo)`
  (o `ps2Encode(...)·k` en aditivos).

## 3. Coches: material de luz y mapa de entorno
### 3.1 Material de luz por tira [V][D]
- Cada tira de un sólido apunta a un material de luz (`eStripEntry +15` → tabla de hashes `0x00134013` del sólido) [V: solid-ps2.ts].
- Los materiales están en `GLOBAL\GLOBALB.BUN` chunk `0x00135200` (`eLightMaterial`, 0xA8 B, 156): nombre y `eLightMaterialData`
  (30 floats: difusa mín./máx. RGB × escala y alfa, potencia especular, especular mín./máx., potencia del entorno, entorno
  mín./máx., `MetallicScale`, `SpecularHotSpot`) [D: Ecstasy/eLight.hpp][V: `fx.json` → `lightMaterials`].
- El conversor separa ahora los materiales de los coches por (textura, material de luz) y escribe `extras.luz` [V: BMW M3 GTR:
  `WINDSHIELD`, `CHROME`, `MOLDINGS`, `RUBBER`, `MAGSILVER`, `BRAKEDISC`, `HEADLIGHTGLASS`, `CARBONFIBER2`…].
- La piel (`<COCHE>_SKIN1`) trae un material sin nombre (`d6d6080a`): el juego usa `LightMaterial_CarSkin`, que sale del
  `LIGHT_MATERIAL_NAME` de la pintura del preset (`METPAINTSILVER`, `REGPAINTBLACK`, `PEARL8`…) [D: CarRender.cpp][V: presets.json].
  Los cristales tintados toman `WINDSHIELD_TINT_*` (su difusa ya es el color del tinte: L2_RED = (1, 0, 0) × 0,5, alfa 0,75) [V].
  Tráfico y policía: `TRAFFIC` si la pintura no trae uno conocido [I].
- Valores de ejemplo [V]:

| Material | Difusa mín./máx. | Especular (pot., mín./máx.) | Entorno (pot., mín./máx.) |
|---|---|---|---|
| `METPAINTSILVER` | 0,75 / 1 | 3 · 0,7 / 0,3 | 0,15 · 3,5 / 0,2 |
| `REGPAINTBLACK` | 1 / 1 | 8 · 0,1 / 0 | 0,2 · 3 / 0,3 |
| `PEARL8` | (0,04; 0,32; 1,68)·0,74 / (0; 1,5; 0)·0,91 | 3,54 · … | 0,15 · 3,5 / 0,1 |
| `WINDSHIELD` | alfa 0,4 | 2,5 · 0 | 1 · 3 / 0,5 |
| `CHROME` | 1 / 1 | 1,5 · 0 | 0,5 · 2 / 2 |

### 3.2 Cómo se usa (shader `carShade`) [I]
El código PS2 que consume `eLightMaterialData` no está decompilado (`eLightE.cpp` vacío). Interpretación:
- t = N·V. Difusa y especular van de **Mín. (canto) a Máx. (frente)**; el entorno con `t^EnvmapPower`. Así `METPAINTSILVER`
  refleja ×0,2 de frente y ×3,5 en los cantos: es el Fresnel del juego.
- Exponente especular `2^(SpecularPower+2)`; `MetallicScale` tiñe el reflejo con el color de la pintura (50 %).
- El alfa de la piel compuesta es el brillo (`GLOSS` ×2, `CompositeSkin` [D]): multiplica especular y reflejo (zonas mate de
  los vinilos).
- Reflejo: `ec² × 1,6 × fuerza` (`Config.envStrength` = 0,6): contraste para que las luces del techo y el cielo queden y los tonos
  medios del garaje no laven la pintura [I: ajustado a capturas del juego].

### 3.3 Mapas de entorno [V][D]
| Dónde | Textura | Proyección |
|---|---|---|
| Refugio | `CAREER_CARSELECTENVMAP` (128×128, `GLOBAL\DYNTEX.BIN`) | Esfera en espacio de vista (`elSetupEnvMap`: matriz local → vista, ojo a 2,78–8 m) [D] |
| Taller | `CSHOP_CARSELECTENVMAP` | idem |
| Concesionario | `CARLOT_CARSELECTENVMAP` | idem |
| Menú / carrera rápida | `QRACE_CARSELECTENVMAP` | idem |
| Calle | `SMALLENVMAP` (64×64, `GLOBALB.BUN`): cielo arriba, negro abajo | Acimut/elevación [I] |

En el juego los mapas de la calle se generan en tiempo real (`EVIEW_ENVMAP*` dibuja la cúpula del cielo, `SkyRender.cpp`);
`SMALLENVMAP` es la versión fija del disco [I].

### 3.4 Luces [I]
- Calle: ambiente de dos colores + sol. Dirección del sol = `SunChunkInfo` «MIDDAY» de `GLOBALB.BUN` chunk `0x00034202`
  (posición 5300, −3550, 3000) [V] menos la cámara.
- Garajes: el juego usa «shaper rigs» (`ShaperLightsSafehouse`, `…CShop`, `…CarLot`, `…QRace`, `eShaperLightRig`: 4 luces con
  modo, θ, φ, color y escala) [D]. Están en BSS y se rellenan en tiempo de ejecución: sus valores no se han encontrado en el disco.
  `SceneLighting.frontEnd` usa una luz principal cálida desde las ventanas, relleno frío y contraluz, ajustados a capturas [I].

## 4. Sombra del coche [D][V]
- `CarRenderInfo::DrawAmbientShadow`: textura `CARSHADOW` (64×32, `GLOBALB.BUN`) sobre la caja del coche × 1,05, rejilla 4×4
  pegada al suelo; se alarga hacia el lado contrario al sol `SunScale = (1 − sol.z)·0,5` m.
- Alfa: `CarBaseShadowAlphaMaxIG` = 100 (0x80 = opaco) en la calle, 255 en el frontend [D].
- Motor: jugador, rivales y coches de exposición (`Renderer`), tráfico y policía instanciados (`AIRender`, `fs_ishadow`).
- La sombra proyectada «Keith» (`DrawKeithProjShadow`, casco convexo) no está hecha.

## 5. Cielo y sol
- `SkyRender.cpp` [D]: la cúpula `SKYDOME` cambia de texturas por capa (`SKY_MIDDAY_A_GRADIENT_A`, `…_CAP_A`, `…_CLOUDS_A`,
  `…_ENVIRONMENT_A`, `…_REFLECTION`). Están en `GLOBAL\DYNTEX.BIN` con nombres truncados a 23 letras; `fx.ts` los resuelve por
  hash [V]. El doc 03 decía que no estaban en el disco: era falso.
- Motor (`fs_sky`) [I]: degradado por elevación, banda de nubes con alfa del horizonte a ~35° (se mueve despacio) y casquete
  arriba. La geometría `SKYDOME` del mundo se sigue omitiendo en el conversor.
- Sol: capas de `SunChunkInfo` MIDDAY [V]: centro (`SUNCENTER`, 60 m, color 255/200/100) y halo (`SUNHALO`, 320 m, 130/110/25 ×0,5),
  como cuadrados en su posición, sumados y tapados por la escena. Los rayos (texturas 2–4) no tienen textura en el disco.

## 6. Tratamiento visual (`visuallook`) [V][D][I]
- `GLOBAL\ATTRIBUTES.BIN`, clases `visuallook` (5), `visuallookeffect` (7), `visualrgbtweaker`, `visuallooktransition` [V] →
  `fx.json`. `IVisualTreatment` [D: World/VisualTreatment.cpp] usa Midday `0xEEC2271A` (no está en el disco PAL; el VLT cae en
  «default»), Sunset `0xCEDA4E4F`, Uves, CopCam `0xEE6074A3`. Curvas = Bézier sobre las y de 4 puntos (`GetValueFromSpline`).
- «default»: `ColourBloomTint` (0,87; 0,68; 0,04), intensidad 0,32; `BlackBloomIntensity` 0,38; `Desaturation` 0,25.
- PS2: `eVisualTreatment.cpp` existe en la lista de fuentes de PS2 pero está vacío en la decomp [H: qué hace exactamente].
- Motor: reducción a 1/4 con paso de brillo (`ColourBloomCurve` sobre la luminancia), desenfoque separable 9+9, y en `fs_post`:
  «black bloom» como curva en S de `BlackBloomCurve` (más contraste en sombras), bloom teñido en suma de pantalla
  (× `Config.bloomGain` 1,6), desaturación (× 0,6) y luego el tono PS2 de siempre (siempre activo).
- `ROCKPORT_LOOK=0` lo apaga (depuración); `ROCKPORT_ENV=<n>` cambia la fuerza de los reflejos.

## 7. Rendimiento
Ver la tabla del informe en el README del motor (§ Luz y efectos). El tratamiento visual son 3 pasadas a 1/4 de resolución.

## 8. Pendiente
- Valores reales de los «shaper rigs» de cada garaje (BSS: buscar quién los rellena en el ELF).
- Mapa de entorno dinámico de la calle (el juego dibuja el cielo en `EVIEW_ENVMAP`), sombra proyectada «Keith», rayos del sol y
  destellos de lente, destellos de farolas y coches (`light_flares_cg` + doc 24 §4), tinte de pantalla y niebla por zona de los
  ParameterMaps (doc 24 §6.2), geometría `SKYDOME` del mundo.
