# Conducción y garajes sin pantallas de carga

Etiquetas: [V] verificado con bytes de SLES-53559 o medido · [D] sacado de la decomp · [I] inferido · [H] hipótesis.

## Conducción (prototipo del visor) — `viewer/src/drive.ts`
- Control arcade (el motor nativo ya usa la física del juego: doc 13).
- Suelo y choques por rayos contra la geometría real de las casillas cercanas. El BVH (estructura de aceleración) se construye en el hilo de carga y llega serializado: conducir no baja de 60 fps.
- Teclas: W/S, A/D, Espacio (freno de mano), R (volver a la carretera), E (garaje), Esc (salir).

## 1. Garajes en el juego original [D]
- La zona `menu_gate_*` (refugio, concesionario, taller) llama a `EQuitToFE(GARAGETYPE_*)`: sale del mundo y carga el frontend.
- `FEManager::GetGarageNameFromType`: cada tipo de garaje es un escenario de `FRONTEND\PLATFORMS\`:

| Tipo | Escenario | Giro del escenario (`GetGeometryZAngle`) | Giro del coche (`GetCarRotationZ`) |
|---|---|---|---|
| `GARAGETYPE_MAIN_FE` (menú principal, carrera rápida) | `PLATFORMCRIB.BIN` (patio industrial de noche: depósitos de agua, casetas de chapa, carretilla, pintadas; texturas `QRACE_*`) | 134,4125° | 304,96979° |
| `GARAGETYPE_CAREER_SAFEHOUSE` | `CAREER_SAFEHOUSE.BIN` | 302,85309° | 304,96979° |
| `GARAGETYPE_CUSTOMIZATION_SHOP` / `…_BACKROOM` | `CUSTOMIZATION_SHOP(_BACKROOM).BIN` | 0° | 304,96979° |
| `GARAGETYPE_CAR_LOT` | `CAR_LOT.BIN` | 0° (Y +0,075) | 340° (X −0,38°) |

- El coche va en el origen a la altura de sus ruedas (`radio medio − z media de las ruedas − 0,025`) con las ruedas delanteras
  giradas `CarSelectTireSteerAngle` = 21,6723° (`GarageMainScreen::UpdateRenderingCarParameters`) [D].
- `FEGeometryModels::Init("BACKDROP")` toma **todos** los sólidos cuyo nombre empieza por `BACKDROP` y `Render` se salta los
  `NEXTGEN` en la generación actual; los `CAST_SHADOW_MAP` además van a la pasada de sombra [D: `FEPkg_GarageMain.cpp`].
  `BACKDROP_CURRGEN` es el fondo de la generación actual (cúpula del cielo `…_SKY`, caja exterior del refugio
  `CRIB1_OFFICE_TEXTURE`, mapa de sombras del suelo del taller `CSHOP_SHADOWMAP`) [D][V].

### 1.0 Qué hay en cada escenario (`FRONTEND\PLATFORMS\*.BIN`) [V]
Los `BACKDROP_CAST_SHADOW_MAP*` **no son sombras**: son los objetos del escenario que además proyectan sombra, y no repiten
geometría de `BACKDROP_CRIB` (comparando vértices: 45 de 7 714 compartidos en el menú). Hasta ahora el conversor solo sacaba
`BACKDROP_CRIB` y faltaban casi todos los objetos que se ven en las capturas del juego.

| Escenario | Sólidos que dibuja el juego | Qué trae cada uno |
|---|---|---|
| `PLATFORMCRIB` (menú principal) | `BACKDROP_CRIB`, `BACKDROP_CAST_SHADOW_MAP`, `BACKDROP_CURRGEN` | Casetas de chapa, depósitos de agua `QRACE_WATERTOWER` (dos juegos), carretilla `QRACE_FORK`, farolas, pila de neumáticos, vagón de tren, árboles; cielo `QRACE_MIDDAYSKY` |
| `CAREER_SAFEHOUSE` (refugio, «Mis coches») | `BACKDROP_CRIB`, `…CAST_SHADOW_MAP`, `…MAP2`, `…MAP3`, `BACKDROP_REFLECTION`, `BACKDROP_CURRGEN` (`…MAP_NEXTGEN` no) | Nave con cerchas y ventanales; `MAP2`: pilas de neumáticos con llanta `CRIB1_WHEEL_TREAD`, sofá, banco, cajas `CRIB1_TOOLBOX` rojas, bidones, cartones, tele, nevera; `MAP3`: tuberías y vigas; `REFLECTION`: copia invertida bajo el suelo semitransparente (`CRIB1_FLOOR`, alfa ≈ 0,96) |
| `CUSTOMIZATION_SHOP` / `_BACKROOM` (taller) | `BACKDROP_CRIB`, `BACKDROP_CAST_SHADOW_MAP`, `BACKDROP_CURRGEN` | Fundas de coche `CSHOP_CARCOVER`, capas, cajas, extintor, gato, bidones, cajas de herramientas rojas |
| `CAR_LOT` (concesionario) | `BACKDROP_CRIB`, `BACKDROP_CAST_SHADOW_MAP`, `BACKDROP_CURRGEN` | Aparcamiento con pilares, señales, árboles; `OBJECT01` (sombra del coche) no empieza por `BACKDROP`: el juego no lo dibuja |

Capturas de referencia (PC/X360) que corresponden a estos escenarios [V por texturas y comparando encuadre]:
- Patio de noche con dos depósitos de agua, casetas, pintadas y carretilla → `PLATFORMCRIB` (menú principal).
- Selección de coche dentro de la nave con neumáticos y llantas, bidones, cajas rojas, cartones, pared de chapa con ventanas y
  rayos de luz → `CAREER_SAFEHOUSE` con la cámara `career_car_select` (`angle4_d`): «Mis coches» del refugio.
- Texturas sin nombre en el escenario: `0x00163C76` = `GREY` (solo viene en el paquete de `CAR_LOT`; lo usan todos) [V];
  `0x578BC664` (1 520 vértices del menú) sigue sin encontrarse.

### 1.1 Cámara del frontend (`SelectCarCameraMover`) [D][V]
- Los parámetros están en la clase `frontend` de **`GLOBAL\FE_ATTRIB.BIN`** (el esquema, en `GLOBAL\ATTRIBUTES.BIN`) [V]:
  108 ángulos con `cam_orbit_vertical`, `cam_orbit_horizontal`, `cam_orbit_radius`, `cam_lookat_x/y/z`, `cam_roll_angle`,
  `cam_fov`, `cam_anim_speed`, `cam_damping`, `cam_periods`, `cam_user_rotate`, y 186 pantallas que apuntan a un ángulo con
  `cam_angle` (`mainmenu` → `angle3`, `career_mainmenu_sub` → `angle10`, `customize_customizemain` → `angle13`,
  `carlot_car_select` → `angle_carlot_car_select`…). Cada garaje tiene `angle_entry_<garaje>` y `angle_final_<garaje>`.
  `FindScreenInfo` añade el prefijo del modo (`career_`, `carlot_`, `customize_`…) al nombre del paquete.
- `CreateCameraMatrix` (SLUS 0x1772B0, ensamblador) [V]: `M = RotZ(H)·RotX(V)·Trans(0, 0, R)`; ojo = traslación de `M⁻¹`;
  arriba = `ComputeBankedUpVector(ojo, lookAt, roll)`; vista = `eCreateLookAtMatrix`. Con la convención de filas de
  `bMatrix4` queda ojo = (−R·sinV·sinH, −R·sinV·cosH, −R·cosV) [I: signos comprobados en pantalla: el coche sale de tres
  cuartos por delante y la cámara a 0,7 m del suelo, como en el juego].
- `cam_fov` se toma como campo horizontal en 4:3 y en panorámico se conserva el vertical [I].
- `cam_user_rotate` es falso en el menú principal: el juego **no** gira el coche solo en ese menú [V].
- La animación entre ángulos (`anim_speed` s, `damping`, `periods`) se aproxima con un muelle amortiguado [I: el mover no está
  decompilado].
- La misma clase trae los coches del concesionario: `Cost`, `UnlockedAt` (bin de la Lista Negra) y `manufacturer` (34) [V].

## 2. Datos (`tools/src/cli/garages.ts`, `tools/src/cli/fe-cameras.ts`, `tools/src/cli/garage-scenes.ts`, `DATA_FORMAT` 10)

| Paso | Cómo |
|---|---|
| Zona | 15 zonas de `GAMEPLAY.BIN` (doc 05) [V] |
| Edificio | El más cercano de su tipo: `XB_CT_SafehouseA` (refugio 1), `XB_SafeHouse` (2), `XB_FishSafehouse` (4), `XB_TC_SafeHouse` (5), `XB_CarParkDealership`, `XB_ChopShopA` (caja orientada con la matriz de la instancia) [V] |
| Puerta real | Triángulos del edificio con la textura `ARC_HOSPITAL_GARAGEDOOR` (la usan todos), agrupados; se elige el grupo más cercano a la zona: centro, normal, 5,7–8 m × 3,3–6 m [V] |
| Sin edificio | Ya no queda ninguno: los refugios 2, 4 y 5 tienen su propio edificio con persiana (antes no se reconocían por el nombre). Si faltara, se usa la persiana real más cercana de otro edificio (a menos de 160 m) y, si no, la puerta mira al punto de reaparición [H] |
| Cámaras | `fe-cameras.json`: ángulos, pantallas y coches del concesionario de `FE_ATTRIB.BIN` [V] |
| Interiores | `convert.ts interior`: todos los `BACKDROP*` salvo `NEXTGEN` → `interiors/<NOMBRE>.glb`; `BACKDROP_REFLECTION` aparte en `interiors/<NOMBRE>.reflection.glb` (no cuenta para colocar ni para chocar) [D][V] |
| Escenas conducibles | `garage-scenes.ts` → `garage-scenes/<zona>.glb/.json/.bin` (§5) |

**Arreglo del conversor** [V]: las tiras con la posición en **V4-32** (floats; cabecera VIF `[nv, packs, 9, …]`) ya vienen en
metros; antes se escalaban por 1/256 y se quedaban en un punto. Lo usan las piezas de más de ±128 m: la cúpula del cielo y la
caja exterior de los garajes, y **5 071 tiras del mundo** (`SKYDOME`, `SKY_SPECULAR`, rascacielos `XB_CITYMODERN*`,
`XB_CITYTOWERA*`, `XB_BENTALLTOWERA`…: el perfil del centro). `tools/src/lib/solid-ps2.ts`.

## 3. Motor nativo — `native-engine/Sources/Rockport/Garage/`

| Archivo | Qué hace |
|---|---|
| `GarageSystem.swift` | Se engancha al motor: capa de dibujo, `Engine.frameOverrides`, `Engine.frameHooks` y ganchos de colisión |
| `GarageRender.swift` | Interiores (`InteriorLibrary`), capa de dibujo con caja de recorte y el recorte del mundo (`GarageCutout`, buffer 3 de los shaders del mundo) |
| `FEGarage.swift` | Escenario del frontend (`FEStage`) y cámara (`FECameraMover`, `FECameraAngle`) |
| `WorldGarage.swift` | Garajes del mundo: colocación, persiana, recorte, colisión, fases |
| `GarageMenus.swift` | Menús de cada sitio con los paquetes originales |
| `CarTuning.swift` | Tuneo (pintura, vinilo, llantas, alerón, kit) y barra de luz |
| `GarageScenes.swift` | Escenas conducibles (§5): paredes, techo, marco y umbral propios, su colisión, el reflejo del escenario del menú y el cambio de coche animado |
| `GarageTests.swift` | `--garage-test` sin ventana |
| `GarageScenesTests.swift` | `--garage-scene` (escenario del frontend con cualquier cámara) y `--garage-swap-test` (cambio de coche) sin ventana |

### 3.1 Fondo de los menús
`Pulsa START`, el menú principal y el menú de la carrera ya no enseñan la ciudad: el escenario `PLATFORMCRIB` (patio industrial
con depósitos de agua, casetas, carretilla y la cúpula del cielo) con el coche del jugador (preset de la partida con su tuneo; por defecto el BMW M3 GTR
de la historia), la cámara de entrada → final y luego la de cada pantalla. El escenario se dibuja lejos del mapa
(−30 km, −30 km) sin mundo alrededor; la cámara del motor se queda sobre el refugio para que la ciudad siga cargada.

### 3.2 Garajes sin carga
1. A menos de 150 m de una zona se coloca su interior (sin el fondo `BACKDROP_CURRGEN` del frontend) dentro del edificio,
   orientado por su lado abierto (16 rayos) y recortado a una caja del volumen interior.
2. Al llegar despacio delante de la puerta (dentro de la zona o a menos de 14 m de la persiana, por debajo de 45 km/h y
   acercándose; solo si antes se estuvo fuera de la zona) se activa el recorte del mundo —hueco de la puerta + volumen
   interior— y la persiana nueva (listones con la textura original) sube con aceleración suave.
3. Colisión: se ignoran los muros del edificio que cruzan el hueco o caen dentro del volumen; se añaden la fachada a los lados
   de la puerta, los muros del interior (triángulos casi verticales a la altura del coche) y un muro en la persiana mientras
   no esté abierta; el suelo del interior es un plano a la altura de la calle.
4. Parado en la plaza (menos de 4 m, menos de 2 km/h durante 0,5 s): la persiana baja, la simulación se para y la cámara pasa
   sin cortes de la de persecución a `angle_final_<garaje>` alrededor del coche (en el sistema del coche, como en el
   frontend). Si un coche de exposición o un muro tapa la vista, la cámara gira lo justo (o se acerca) [I].
5. «Volver a la zona libre»: la persiana sube, se sale marcha atrás y, a más de 2 m de la puerta, se cierra y el recorte se quita.

### 3.3 Menús de cada sitio
| Sitio | Paquete | Opciones [D] |
|---|---|---|
| Refugio | `MainMenu_Sub` (`uiCareerCrib`, título 0xE596C4A3, datos `CAREER_DATA`/`BOUNTY_DATA`/`CASH_DATA`) | Volver a la zona libre · Lista Negra (`InGameReputationOverview`) · Mis coches (`Car_Select` con los coches de la partida) · Guardar |
| Concesionario | `Car_Select` (`UIQRCarSelect` en modo concesionario) | ← → coches de `FE_ATTRIB.BIN` por precio, logotipo de la marca `CARSELECT_MANUFACTURER_*` y del modelo `SECONDARY_LOGO_<colección>`, n/N, dinero y precio, candado con «Desbloquea este coche derrotando a … nº N» (texto 0x4EF2A115, `UnlockedAt + 1`); ✕ compra (texto 0x40FA955D si no llega el dinero) |
| Taller | `CustomizeMain` → `CustomizeCategory` → `CustomizeParts` | Piezas (kits, alerones, llantas) · Rendimiento (en gris) · Visual (pintura, vinilos, **barra de luz del mando**); ← → monta la pieza en el coche al momento, ✕ la instala, △ deja la que había |

- Textos y títulos del juego (en minúsculas como `CustomizationScreenHelper::DrawTitle`); cámaras de cada pantalla de
  `fe-cameras.json` (`career_mainmenu_sub`, `carlot_car_select`, `customize_customizemain`, `customize_customizeparts_257`…).
- Piezas: las 48 pinturas de los presets del disco, los vinilos de los presets del mismo coche, las llantas de los paquetes
  `WHEELS` (una por modelo) y los alerones de los paquetes `SPOILER*`; el tuneo se guarda por coche en
  `~/Library/Application Support/Rockport/garage.json` y se aplica al empezar la carrera profesional. Precio de las piezas: 0 [I].
- Mods: `mods/garajes-unicos/mod.json` (nombre, interior, tinte y coches de exposición) se lee de `mods/` del repositorio, de
  `~/Library/Application Support/Rockport/mods/` o de `ROCKPORT_MODS`.

### 3.4 Pruebas sin ventana
```bash
R=".build/release/Rockport --data ../map-data/SLES-53559 --size 1920x1080"
$R --garage-test zone_safehouse_1 --screenshot g.png                    # entra conduciendo: g-1-fuera, g-2-dentro, g-3-aparcado
$R --garage-test zone_customshop_2 --garage-mode inside --garage-screen paint --garage-select 3 --screenshot t.png
$R --garage-test x --garage-mode list                                     # coloca los 15 garajes y escribe medidas
#   --garage-screen blacklist | carlot | mycars | customize | parts | visual | paint | rims | spoiler | vinyl | kit | lightbar
ROCKPORT_FE_CAM="V,H,R,lx,ly,lz[,fov]" …   # depuración: fija la cámara del frontend
ROCKPORT_GARAGE_NOCLIP=1 …                 # depuración: interior sin caja de recorte
```
```bash
$R --garage-scene career_safehouse --fe-angle career_car_select --scene-car MUSTANGGT --screenshot r.png   # escenario del menú
$R --garage-swap-test zone_safehouse_1 --scene-car MUSTANGGT --screenshot s.png   # «Mis coches»: s-swap-0…6
$R --garage-swap-test zone_carlot_1 --screenshot s.png                            # concesionario: el coche siguiente
ROCKPORT_SCENE_OFF=1 …                     # depuración: sin la escena conducible (solo el interior recortado)
```
Resultado (2026-10-15, con las escenas de §5): 13 de los 15 garajes se entran conduciendo con el piloto automático de la prueba
y abren su menú. Faltan el refugio 4 (una viga de madera del mundo cruza delante de la persiana a 1 m) y el taller 4 (el piloto,
que va en línea recta desde 18 m, se queda en el bordillo de la acera); con `--garage-mode inside` los 15 abren su menú.

Antes de las escenas: 12 de los 15 garajes se entran conduciendo con el piloto automático de la prueba y abren su menú
(refugios 1, 2 y 5, los 3 concesionarios y los talleres 2, 3, 5, 6, 7 y 8). En el refugio 4 y los talleres 1 y 4 la persiana se
abre pero el piloto (que va en línea recta) se atasca con nasas o el bordillo; con `--garage-mode inside` los 15 abren su menú.

## 4. Pendiente
- Reflejos del coche en el frontend: hechos con `<GARAJE>_CARSELECTENVMAP` (doc 20). Falta: valores reales de las luces del garaje («shaper rigs», en BSS).
- Partículas del escenario (`FX_*_EMITTER`, pájaros) y la pasada de sombra de los `BACKDROP_CAST_SHADOW_MAP*` (ya se dibujan como objetos).
- Escenas: ventanas con luz real, rayos de luz propios y rótulos; refugio 4 (viga del mundo delante de la puerta); textura `0x578BC664` del menú.
- Precios y calor de las piezas, carrito de la compra, rendimiento, calcomanías, cristales tintados, color de llanta.
- Mapa de la carrera (`WorldMap_Main`), hoja de antecedentes (`RapSheet*`) y el selector de partidas.

## 5. Escenas de garaje conducibles (propias)
En el juego la zona `menu_gate_*` corta a una pantalla de carga y el garaje es solo un escenario de menú [D]: **no existe** ningún
camino de la calle al interior. Lo construimos nosotros, con datos:

| Qué | Original del disco | Nuestro |
|---|---|---|
| Edificio, persiana, calle | `STREAML2RA.BUN` (mundo), textura `ARC_HOSPITAL_GARAGEDOOR` | Recorte del edificio y persiana animada (§3.2) |
| Interior y objetos | `FRONTEND\PLATFORMS\*.BIN` (`BACKDROP*`) | Colocación dentro del edificio |
| Paredes, techo, vigas, pilares, suelo y carteles del volumen | Solo las **texturas** (`CRIB1_BRICK1`, `CSHOP_CORUGATEDMETAL`, `CARLOT_WALLCONCONCRETE`…) | Geometría, tamaño y colocación |
| Marco del hueco (jambas, dintel) | Texturas (`CRIB1_PIPE`, `CSHOP_METALYELLOW`, `CARLOT_YELLOWPILLAR`) | Geometría |
| Umbral / rampa de la calle a la puerta | Textura del suelo del interior | Geometría y colisión, a partir de la altura real de la calle (colisión del mundo) |
| Cambio de coche sin pantalla de carga | Modelos y física de los coches | Animación (cámara al techo, el coche entra rodando) |

**Paso `garage-scenes`** (`tools/src/cli/garage-scenes.ts`, después de `collision`):
1. Marco de la puerta de `garages.json`: x hacia fuera, y a la izquierda, z arriba, origen en el centro de la persiana a ras de suelo.
2. **Volumen real** detrás de la puerta con la colisión del mundo [V]: rayos desde dentro hacia el fondo y los lados contra los
   muros de `collision/`, sin salir de la caja del edificio. Ejemplo: refugio 1 = nave de 8 × 22,5 m detrás del arco «FLEA
   MARKET» (las alas de la fachada están 6 m más atrás; con la caja del edificio, 30 m de ancho, el recorte se las comía).
   Sin muros cerca se usa la caja del edificio, como antes (refugios 2 y 4).
3. Geometría con las texturas del interior del disco. El **tamaño de cada textura** (m por repetición) y su **luz horneada**
   (color de vértice medio) se miden en los sólidos del propio interior que la usan, así casan con lo que hay al lado.
4. **Umbral**: se mide la calle con la colisión del mundo en tres líneas delante del hueco; si está más alta o más baja que la
   puerta (refugio 1: +0,31 m; taller 1: −0,58 m) o hay escalón, una rampa la salva (visual + triángulos de colisión).
5. Salida: `garage-scenes/<zona>.glb` (nodos `SHELL`, `FRAME`, `APRON`), `<zona>.bin` (NFSC v1 en mundo: tris del umbral, muros
   del volumen), `<zona>.json` (marco, volumen, umbral) e `index.json`. Texturas en `garage-scenes/textures/` (no se suben).

**Motor** (`GarageScenes.swift`): el volumen de la escena manda en `WorldGarages.place` (recorte 8 cm por dentro de las paredes
de la escena, caja del interior dentro de ellas); el umbral se ve siempre que el garaje está colocado y su suelo va antes que el
del garaje; paredes y marco solo con la fachada recortada; los muros se añaden a `CollisionWorld.garageWalls`. La orientación
del interior busca ahora un pasillo libre del ancho de un coche (±1 m) a 0,45 y 1,2 m (pretiles y elevadores bloqueaban).

**Cambio de coche** («Mis coches» y concesionario): la cámara del frontend sube la mirada a las vigas (0,45 s; solo cambia la
altura del punto de mira, así no salta la corrección de muros de la cámara), el coche nuevo aparece unos metros detrás de la
plaza (hacia la puerta, fuera de cuadro) y entra rodando con su propia física hasta la plaza mientras la cámara vuelve
(~3 s). Al confirmar, el coche del jugador se cambia en el mismo sitio.

**Cómo editar las escenas**: `tools/data/garage-layouts.json` (nuestro: solo números y nombres de texturas). Por tipo
(`safehouse`, `customshop`, `carlot`): `floor`, `walls`, `wallsTop` (banda alta desde `from` m), `ceiling`, `beams` (`every`,
`size`), `pillars`, `frame` (`width`), `apron` y `decals` (`texture`, `wall` back/left/right/front, `at` 0…1, `z`, `size`).
`shade` = [abajo, arriba] oscurece la pared hacia el suelo; `repeat` y `color` fuerzan tamaño y luz si no se quieren medir.
Por zona (`zones`): `apronLength`, `noApron`, `extraDecals`. Después: `bun src/cli/garage-scenes.ts <iso> <ID>` (menos de 1 s).
