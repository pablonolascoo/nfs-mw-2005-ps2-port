# 20 · Iluminación y efectos: color del PS2, coches, cielo, sombras, tratamiento visual, partículas y destellos

Etiquetas: **[V]** verificado en bytes de SLES-53559 o medido · **[D]** decomp · **[I]** inferido · **[H]** hipótesis.
Paso del conversor: `bun src/cli/fx.ts <iso> <ID>` → `map-data/<ID>/fx/` (`fx.json` + 32 PNG, < 1 s). `DATA_FORMAT` = 8.
Motor: `native-engine/Sources/Rockport/SceneShading.swift` (prólogo MSL común, `FXData`, `SceneLighting`), `Shaders.swift`,
`Renderer.swift`, `AIRender.swift`, `Garage/GarageRender.swift`. Lo que exporta el paso `effects` (partículas, destellos del
mundo, niebla y tinte por zona) está en el doc 24; su uso en el motor (partículas, destellos, niebla y tinte por zona, `Effects/`),
en el §9.

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
- Mapa de entorno dinámico de la calle (el juego dibuja el cielo en `EVIEW_ENVMAP`), sombra proyectada «Keith», geometría
  `SKYDOME` del mundo. Partículas, destellos, niebla y tinte por zona: hechos (§9); lo que queda de ellos, en §9.7.

## 9. Partículas, destellos, niebla y tinte por zona (motor nativo, `Effects/`, 2026-10-15)
Código: `native-engine/Sources/Rockport/Effects/` (`EffectsLibrary`, `Particles`, `CarEffects`, `LightFlares`, `ZoneFog`,
`GarageShafts`, `EffectsGPU`, `EffectsSystem`, `EffectsTests`). Datos: `effects.json` + `effects/particles/` (paso `effects`,
doc 24) y `fx/fx.json` (`light_flares_cg`). No cambia el formato de datos. Se engancha como una capa más del Renderer
(`RenderOverlay`): simula una vez por fotograma y dibuja en cada vista dentro de la pasada de escena, en el espacio de color del
PS2 (§2). `ROCKPORT_FX=0` la quita; `ROCKPORT_FX=hide` simula sin dibujar (capturas «antes»).

### 9.1 Partículas: `EmitterSystem.cpp` portado [D][V][I]
| Parte | Cómo [etiqueta] |
|---|---|
| Curvas por vida | `CalculateBases`: color (4 RGBA en bytes) y tamaño/giro (`Size`/2, `RelativeAngle`×182,04) son un polinomio cúbico que pasa por los 4 valores en `KeyPositions`/3 (`hermite_basis` = U⁻¹·P) [D]. t = 1 − vida restante / `Life` del emisor; el color se satura a 0…255 [D] |
| Encendido | `EmitterControl::Update`: retardo, ciclo encendido/apagado con variación, un disparo [D] |
| Cuántas | `SpawnParticles`: `NumParticles` × intensidad × dt (con acumulación si sale < 1), el disparo único usa `Life` en vez de dt [D] |
| Salida | volumen (`VolumeCenter` ± `VolumeExtent`/2), cono (eje Z del emisor ± `SpreadAngle`/2) o disco con `Speed`; si no, `VelocityStart` ± `VelocityDelta` por los ejes del emisor y aceleración en ejes del mundo [D] |
| Movimiento | arrastre `v += v·max(−1, −dt·Drag·|v|)`; con `Gravity` ≠ 0 solo baja z, si no `v += a·dt`; velocidad heredada del coche (`MotionInherit`) [D]. `MotionLive`: las partículas siguen al emisor [I] |
| Muerte | vida o alfa ≤ `AlphaToKillAt` salvo `NoKillAtAlpha` [D] |
| Animación | rejilla N×N (`ParticleAnimationInfo`), fotograma por FPS y arranque al azar (`GetAnimatedUVs`) [D] |
| Mundo | 1 535 emisores (0x0003BC00): se crean a `FarClip` + 20 m por delante (coseno 0,55) y se borran al alejarse; partículas fuera de `FarClip` mueren (`ServiceWorldEffects`, `UpdateParticles`) [D]. 23 con disparador por cercanía de un coche (radio, reinicio) dan una ráfaga [D][I] |
| Garajes del frontend | 41 emisores de `FRONTEND\PLATFORMS\*.BIN` en el espacio del interior: niebla baja y vapor del patio del menú (`fxenv_fog_fe1`, `fxenv_small_steam1`), vapor del refugio (`fxenv_small_steam2` ×7), taller, concesionario [V]. En los garajes del mundo solo los que caen dentro de la caja del interior. Se crean calientes (hasta 10 s simulados) [I] |
| Dibujo | billboards de cara a la cámara girados `mAngle` o en un plano XY/XZ/YZ (`AxisConstraint`, `GetConstraintBasis`) [D]; medio lado = `mSize` [D]. Una llamada instanciada para las de mezcla normal (ordenadas de lejos a cerca) y otra para las aditivas; las 42 texturas usadas en un array de 64×64 [I] |
| Color | textura × color/128 del vértice en gamma (como el resto de vértices del PS2, doc 02) y alfa/128 [I: el código de PS2 de `PlatAddParticle` no está decompilado]. Mezcla normal o suma según el `AlphaBlendType` de la textura del TPK [V] |
| Tope | el PS2 tiene 1 024 partículas y 500 emisores [D]; aquí 2 048 partículas [I] |

Coches (`CarEffects.swift`):
- Ruedas (`TireState::DoFX`, `SetSurface`, `Effect::Update` [D]): tres efectos por rueda en el suelo con intensidad
  `Ramp(valor, velMín, velMáx)` del registro de la superficie: deslizamiento lateral (`TireSlideEffects`), patinaje
  (`TireSlipEffects`) y rodadura (`TireDriveEffects`). La colisión exportada no guarda el material: «asphalt» [I]
  (`fxtd_sk_asphalt` 1–2, `fxtd_sl_asphalt` 0,125–5 [V]). `SlipFX`/`SkidFX` (atributo `ecar`, no exportado) = 0,5 [I]; patinaje =
  `Tire.slip` (m/s), deslizamiento = `Tire.lateralSpeed` (m/s). Una quemada parado (gas + freno) patina a ~22 m/s: 80–95
  partículas de humo, como el juego (10 por segundo y rueda, 2,4 s de vida, alfa 12–40 de 128) [V: medido].
- Nitro: `NOSEffect` = `carexhaustnos` → `fxcar_nos` (`emcar_nos_fire` + `emcar_nos_glow`) en cada marcador `*_EXHAUST` del
  modelo, dirección = su eje Z [D][V] (el M3 GTR los lleva en el lateral derecho).
- Golpes: ráfaga de `carhitwall` → `fxcar_impactl` (chispas y brillo) en el lado del choque cuando la velocidad cambia más de
  4 m/s en un fotograma [I: el juego lo dispara desde la colisión; el motor aún no publica los contactos].
- Polvo, tierra y agua: salen solos si la superficie no es asfalto (`dirt`, `grass`, `water`…), pero falta el material del suelo.

### 9.2 Destellos (`LightFlares.swift`) [D][V][I]
- Mundo: los 2 242 marcadores de sólido (doc 24 §4) [V]: 955 ámbar, 340 rojos (semáforos `XO_TRAFFICLIGHT*`), 199 verdes,
  748 catadióptricos. **No hay destellos de farola** en el PS2: ningún marcador es `ELF_LAMPPOST` y `lamppost_outer` tiene color 0 [V].
- Intermitentes (`eResestLightFlarePool` [D]): tres relojes de 0,5 / 0,4 / 0,45 s; ámbar usa el de |x| mod 3, rojo el primero y
  verde el tercero.
- Coches (`CreateCarLightFlares`, `RenderFlaresOnCar` [D]): marcadores `LEFT/RIGHT/CENTRE_HEADLIGHT` (faro, 1), `*_BRAKELIGHT`
  (piloto: 0,5 y +16 al frenar, tope 1; el del tráfico usa `brakelight_traffic_inner`), `*_REVERSE` (marcha atrás) y la barra de
  policía (`COPLIGHT*`, hashes `1e4150b4` rojo, `e662c161` azul, `b4348dba` blanco [V]) con `coplightflicker2`: rojo y azul
  alternos (cos(8t) > 0,2), pulso cos²(24t), blanco = sin(3·parpadeo) [D]. Jugador, rivales, pantalla partida, tráfico y policía.
- Halo de la barra: `RenderFlaresOnCar` con `renderFlareFlags & 1` vuelve a dibujar solo las luces de policía a ×10 [D]; aquí
  ×6 con `HEADLIGHTGLOW` y peso 0,15 [I]. Los grupos `fxcar_coplight*` (vida 0,01 s) no los usa nadie en la decomp: no se usan.
- Sol: `ELF_SUN_FLARE` con `sun_flare` en la dirección del `SunChunkInfo` [V], intensidad 1 sobre el horizonte [I].
- Parámetros de `light_flares_cg` [V]: color, `MinSize`/`MaxSize`, `MinScale`/`Maxscale`, `Power`, `ZBias`, `flare_texture`.
  `eRenderLightFlare` es código de PS2 sin decompilar, así que el dibujo es [I]: diámetro en píxeles de una pantalla de 480 líneas
  = `MaxSize` × (0,35 + 0,65·k) × min(1, max(0,35, 30 m / distancia)); k = intensidad × (frente)^`Power` en faros y pilotos;
  Cs = textura × color×2 (satura como el GS) sumado con peso alfa×2·k; adelantado `ZBias` m hacia la cámara y con prueba de
  profundidad (oclusión); se apaga entre 500 y 800 m. Texturas 0/1/2 = `HEADLIGHTGLOW` / `HEADLIGHTFLAREOUTER` /
  `HEADLIGHTFLAREINNER` [H: orden de `eLightFlareTextureNameHashes`].

### 9.3 Niebla y tinte por zona (`ZoneFog.swift`) [V][D][I]
- Capas `Normal Fog` (3 conjuntos de 8 valores), `Screen Tint Midday` (219, 206, 87 en todo Rockport) y `Fog Blend Distance`
  (50 m) [V], buscadas por (x, y) de la cámara en su árbol cuaternario.
- Mezcla del juego (`ParameterAccessorBlendByDistance::CaptureData` [D]): el valor se acerca al de la zona nueva en la proporción
  recorrido / 50 m, con un accesor por vista (`FogAccessor[2]` [D]).
- Campos de la niebla [I]: [0] densidad máxima (0,5 / 0,6 / 0,2), [1] inicio (200 / 202 / 243 m), [2…4] color (128 y 135 grises),
  [5] caída → escala 2 600 m × 0,75 / caída; [6] y [7] sin uso conocido [H] (`FogQuery::CalculateFogInfo` está vacía).
- Tinte: sustituye el ámbar fijo del tono PS2 por el color de la zona normalizado por su luminancia, con fuerza 0,3 (con
  219, 206, 87 da (1,035; 1,015; 0,833), casi el (1,07; 1,03; 0,86) de antes) [I]. En los garajes del frontend no se usa.

### 9.4 Garajes: franja oscura del refugio, luz del umbral y haces de las ventanas
- **Franja oscura abajo al entrar en el refugio** (captura «dentro» de `--garage-test zone_safehouse_1`): no era el suelo de la
  calle ni la sombra horneada `SHD_*` de la puerta [V: con `ROCKPORT_WORLD_HIDE=SHD` seguía], sino dos cosas: (1) la caja de
  recorte del interior empezaba 0,3 m dentro de la persiana y entre ella y la línea de la puerta se veía el suelo del mundo, oscuro
  por la luz horneada del edificio; (2) el umbral de la escena (`APRON`, color medido en el interior) es mucho más oscuro que el
  suelo iluminado del interior [V: sin la escena desaparecía]. Arreglo: el mundo ya no dibuja el suelo bajo el hueco de la puerta
  (`GarageCutout.threshold`, tercera caja del `Cutout` de los shaders), la caja del interior se alarga 0,8 m hacia la calle
  (`GarageRenderer.doorReach`) y el umbral recibe la luz del interior que sale por el hueco (×6 junto a la puerta, se apaga en
  1,8 m: `GarageDrawItem.spill`) [I]. Medido: la banda de 22 px (35–77 de 255) desaparece; el suelo llega al borde [V].
- **Haces de luz de las ventanas** de nuestras paredes (calcomanías `*WINDOW*` de `garage-scenes`, hoy las del taller): dos planos
  aditivos cruzados por ventana que bajan a 50° hacia dentro, con degradado y polvo [I] (`GarageShafts.swift`). Los rayos propios de
  los interiores del disco (`CRIB1_LIGHTRAYS*`, `SFX_LIGHTRAY`, `CSHOP_LIGHTRAYS01`…) ya se dibujaban (§1).
- La bruma de las referencias (patio del menú, refugio) la ponen ahora las partículas del propio juego (`fxenv_fog_fe1`,
  `fxenv_small_steam1/2`); la bruma baja propia del menú (`fogHeight`, §6) se mantiene para el tono amarillo del suelo [I].

### 9.5 Pruebas
- `Rockport --fx-test burnout|street|pursuit --screenshot base.png [--size WxH]`: quemada parado y nitro (`base-quemada`,
  `base-nitro`), cruce con más semáforos (`base-calle`), tres patrullas con la barra encendida (`base-persecucion`), con GPU con y
  sin efectos en el mismo proceso. `--fx-test stats`: curvas y recuento sin dibujar.
- Menú, refugio y garajes con las pruebas de siempre (`--ui-test MainMenu`, `--garage-scene career_safehouse --fe-angle
  career_car_select`, `--garage-test zone_safehouse_1`, `--garage-test zone_customshop_1`).
- Depuración: `ROCKPORT_WORLD_HIDE=TEXTO,…` (no dibuja materiales del mundo; `*` = todos), `ROCKPORT_DEBUG_CAM=1` (posición de la cámara).
- Capturas antes/después en `native-engine/.build/shots/fx/` (`cmp-*.png`, `cmp-resumen.png`).

### 9.6 Rendimiento [V: M4, máquina compartida con otras tareas: medidas con ruido]
| Prueba | Sin efectos | Con efectos |
|---|---|---|
| Vuelo 12 s, 2940×1912 (GPU med.) | 5,98–6,01 ms | 5,90–6,67 ms |
| Pantalla partida 2 jugadores, 2940×1912 (GPU med.) | 6,28–6,70 ms | 6,44–6,74 ms |
| Mismo proceso, 1920×1080, quemada / persecución / calle | 1,36 / 1,20 / 2,25 ms | 1,76 / 1,40 / 2,28 ms |

Coste: +0,1–0,4 ms de GPU y < 0,1 ms de CPU (≤ 2 048 partículas, ≤ 4 llamadas por vista). Lejos de los 16,7 ms.

### 9.7 Pendiente
- Material del suelo en la colisión (polvo, tierra, agua de las ruedas) y contactos reales para chispas y roces (`OnScrapeGround`,
  `carscrapewall`); reventón y muerte del coche de policía (`carblowtire`, `cardeath1`).
- Rompibles (`smokeables`) con sus efectos; disparadores de sonido; lluvia y nubes por zona (el PS2 no llueve en la zona libre [I]).
- Qué hace exactamente `eRenderLightFlare` (tamaños y escala) y `PlatAddParticle` (escala del color) en el PS2: código sin decompilar.
