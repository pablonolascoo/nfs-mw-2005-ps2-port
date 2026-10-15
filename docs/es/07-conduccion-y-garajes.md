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
| `GARAGETYPE_MAIN_FE` (menú principal) | `PLATFORMCRIB.BIN` (azotea industrial con grúas) | 134,4125° | 304,96979° |
| `GARAGETYPE_CAREER_SAFEHOUSE` | `CAREER_SAFEHOUSE.BIN` | 302,85309° | 304,96979° |
| `GARAGETYPE_CUSTOMIZATION_SHOP` / `…_BACKROOM` | `CUSTOMIZATION_SHOP(_BACKROOM).BIN` | 0° | 304,96979° |
| `GARAGETYPE_CAR_LOT` | `CAR_LOT.BIN` | 0° (Y +0,075) | 340° (X −0,38°) |

- El coche va en el origen a la altura de sus ruedas (`radio medio − z media de las ruedas − 0,025`) con las ruedas delanteras
  giradas `CarSelectTireSteerAngle` = 21,6723° (`GarageMainScreen::UpdateRenderingCarParameters`) [D].
- `FEGeometryModels` dibuja los sólidos del escenario salvo los `NEXTGEN`; `BACKDROP_CURRGEN` es el fondo de la generación
  actual (cúpula del cielo `…_SKY`, caja exterior del refugio `CRIB1_OFFICE_TEXTURE`) [D][V].

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

## 2. Datos (`tools/src/cli/garages.ts`, `tools/src/cli/fe-cameras.ts`, `DATA_FORMAT` 7)

| Paso | Cómo |
|---|---|
| Zona | 15 zonas de `GAMEPLAY.BIN` (doc 05) [V] |
| Edificio | El más cercano de su tipo: `XB_CT_SafehouseA` (refugio 1), `XB_SafeHouse` (2), `XB_FishSafehouse` (4), `XB_TC_SafeHouse` (5), `XB_CarParkDealership`, `XB_ChopShopA` (caja orientada con la matriz de la instancia) [V] |
| Puerta real | Triángulos del edificio con la textura `ARC_HOSPITAL_GARAGEDOOR` (la usan todos), agrupados; se elige el grupo más cercano a la zona: centro, normal, 5,7–8 m × 3,3–6 m [V] |
| Sin edificio | Ya no queda ninguno: los refugios 2, 4 y 5 tienen su propio edificio con persiana (antes no se reconocían por el nombre). Si faltara, se usa la persiana real más cercana de otro edificio (a menos de 160 m) y, si no, la puerta mira al punto de reaparición [H] |
| Cámaras | `fe-cameras.json`: ángulos, pantallas y coches del concesionario de `FE_ATTRIB.BIN` [V] |

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
| `GarageTests.swift` | `--garage-test` sin ventana |

### 3.1 Fondo de los menús
`Pulsa START`, el menú principal y el menú de la carrera ya no enseñan la ciudad: el escenario `PLATFORMCRIB` (azotea con el
skyline industrial y la cúpula del cielo) con el coche del jugador (preset de la partida con su tuneo; por defecto el BMW M3 GTR
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
Resultado (2026-10-15): 12 de los 15 garajes se entran conduciendo con el piloto automático de la prueba y abren su menú
(refugios 1, 2 y 5, los 3 concesionarios y los talleres 2, 3, 5, 6, 7 y 8). En el refugio 4 y los talleres 1 y 4 la persiana se
abre pero el piloto (que va en línea recta) se atasca con nasas o el bordillo; con `--garage-mode inside` los 15 abren su menú.

## 4. Pendiente
- Reflejos del coche en el frontend (el juego usa mapa de entorno) y luces propias del garaje (`SetSelectCarLighting`).
- Partículas del escenario (`FX_*_EMITTER`, pájaros) y el mapa de sombras `BACKDROP_CAST_SHADOW_MAP`.
- Precios y calor de las piezas, carrito de la compra, rendimiento, calcomanías, cristales tintados, color de llanta.
- Mapa de la carrera (`WorldMap_Main`), hoja de antecedentes (`RapSheet*`) y el selector de partidas.
