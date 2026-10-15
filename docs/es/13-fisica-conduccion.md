# Física de conducción (modelo del juego)

Etiquetas: [V] verificado en bytes o medido · [D] sacado de la decomp · [I] inferido · [H] hipótesis.

Fuente: decomp `dbalatoni13/nfsmw` (ELF SLUS-21351), carpeta `src/Speed/Indep/Src/Physics/`.
Código del port: `native-engine/Sources/Rockport/Physics/*.swift`. Datos: `map-data/<ID>/physics.json`.

## 1. Qué se ha portado

| Pieza del juego [D] | Archivo de la decomp | Port (Swift) | Coincidencia con el binario PS2 [V: report.json] |
|---|---|---|---|
| Rueda + neumático (`Tire::UpdateLoaded`, `UpdateFree`, `ComputeLateralForce`, `CheckForBrakeLock`, `GetPilotFactor`) | `Behaviors/SuspensionRacer.cpp` | `Physics/Tire.swift:141-282` | 93–100 % |
| Suspensión y fuerzas de rueda (`DoWheelForces`) | `SuspensionRacer.cpp` | `Physics/SuspensionRacer.swift:393` | 89 % |
| Tracción y diferenciales (`DoDriveForces`, `Differential::CalcSplit`) | `SuspensionRacer.cpp` | `SuspensionRacer.swift:334-391` | 98–99 % |
| Agarre, freno de mano, «burnout» (`TuneWheelParams`, `YawFrictionBoost`, `Burnout::Update`) | `SuspensionRacer.cpp` | `SuspensionRacer.swift:249-305` | 87–97 % |
| Derrape (`DoDrifting`) | `SuspensionRacer.cpp` | `SuspensionRacer.swift:307` | 72 % |
| Dirección del jugador (`DoHumanSteering`, `CalculateMaxSteering`, `CalculateSteeringSpeed`, `ComputeAckerman`, `DoWallSteer`) | `SuspensionRacer.cpp`, `Chassis.cpp` | `SuspensionRacer.swift:162-236` | 70–76 % |
| Chasis (`SetCOG`, `ComputeState`, `DoAerodynamics`, `DoJumpStabilizer`, `DoSleep`, `ComputeMaxSlip`, escalas de agarre) | `Behaviors/Chassis.cpp` | `SuspensionRacer.swift:104-160, 484-535` | 96–100 % |
| Motor, embrague, caja, nitro, turbo (`EngineRacer::OnTaskSimulate`, `AutoShift`, `DoNos`, `DoInduction`, `Engine_SmoothRPM`, `Clutch`) | `Behaviors/EngineRacer.cpp` | `Physics/EngineRacer.swift` | 69–100 % |
| Curva de par, inercia, puntos de cambio, velocímetro, diámetro de rueda | `PhysicsInfo.cpp` | `EngineRacer.swift:85-172` | 86–100 % |
| Cuerpo rígido (`DoIntegration`, `Resolve*`, `Damp`, `Inertia::Box`) | `Behaviors/RigidBody.cpp`, `Dynamics/Inertia.h` | `Physics/RigidBody.swift` | 56 % (integración) |
| Entrada del jugador (`InputPlayer::FetchInput`, `DoAutoReverse`, `DoAutoBraking`) | `Behaviors/PInput.cpp` | `Physics/PVehicle.swift:64` | 99,9 % |
| Tablas (`Table`, `Graph`, `tGraph`, `AverageWindow`) | `Misc/Table.cpp` | `Physics/PhysicsMath.swift` | — |

Todo se escribe en el **espacio del juego** («Bond»: x derecha, y arriba, z adelante) para que cada fórmula quede literal.
Solo se pasa al mundo del motor (X = z, Y = −x, Z = y) al consultar la colisión y al dibujar (`PM.toWorld`, `PM.toGame`).
Ese paso invierte la orientación (determinante −1), así que la física se mantiene entera en espacio del juego [I].

## 2. Bucle de actualización

- **Paso fijo de 1/60 s** [V]: `Scheduler::Init(float)` recibe `0x3C888889` (= 1/60) en `zMisc.cpp.s` del ELF de PS2.
- Orden por paso, como `BEHAVIOR_ORDER` del `pvehicle` [V]: `RIGIDBODY → AI → INPUT → ENGINE → SUSPENSION → DAMAGE → DRAW → SOUND`.
  1. `RigidBody::OnBeginFrame`: gravedad `rigidbodyspecs.GRAVITY × masa` (−9,8128 m/s² en `racers`) [V].
  2. `InputPlayer::FetchInput`: zona muerta, marcha atrás automática, autofreno [D].
  3. `EngineRacer::OnTaskSimulate`: par de motor → par en ruedas (`mDriveTorque`) [D].
  4. `SuspensionRacer::OnTaskSimulate`: CG, estado, aero, tracción, dirección, ruedas, saltos, reposo [D].
  5. Integración (Euler semiimplícito, giro con cuaternión alrededor del CG) [D, 56 %].
- Dibujo: la pose se **interpola** entre los dos últimos pasos (`Car.update`, posición lineal y `slerp`).
  Así va igual de suave a 60, 90 o 120 Hz de pantalla.
- Coste medido: < 30 µs por paso en un M4 [V]. El juego sigue a 60 fps.

## 3. Neumático [D]

Cada rueda guarda velocidad angular, carga, deslizamiento y un estado de **tracción** (1 = agarra, < 1 = desliza).

- Con tracción plena: fuerza longitudinal = par total / radio; fuerza lateral de unas **tablas de sensibilidad a la carga**:
  7 tablas (deriva 0, 2, 4… 12°) × carga 0–10 kN, por `GRIP_SCALE × 1000 × 2,5 × grip_boost`.
- Deslizando: fricción dinámica `DYNAMIC_GRIP × traction_boost × pilot / velocidad de patinaje`.
- **Círculo de fricción**: límite `carga × STATIC_GRIP × traction_boost × drift_friction × pilot`. Si se pasa, todo se escala y `traction` baja.
- **Elipse**: con par motor a favor, la longitudinal cuenta × 1,5 en el círculo (`TireForceEllipseRatio`).
- `GetPilotFactor`: ruedas traseras motrices al 85 % por debajo de 30 mph, 100 % a 50 mph.
- Freno: `BRAKES × 1,3558 × 4` N·m por rueda; freno de mano `EBRAKE × 1,3558 × 10` solo detrás.
  Bloqueo si el par de freno × 1,2 (× `BRAKE_LOCK`) supera la fuerza del suelo × radio + |ω| × 100.
- Diámetro: `RIM_SIZE × 0,0254 + SECTION_WIDTH × 0,001 × 2 × ASPECT_RATIO/100` (BMW: 0,687 m) [D][V].

| Atributo (clase `tires`) | BMW M3 GTR [V] | Uso |
|---|---|---|
| `STATIC_GRIP` | 2,2 / 2,3 | límite del círculo de fricción |
| `DYNAMIC_GRIP` | 2 / 2 | fricción al deslizar |
| `GRIP_SCALE` | 1,175 / 1,225 | fuerza lateral de las tablas |
| `YAW_CONTROL` | 0,3 0,65 1 1,2 | ayuda de agarre trasero según % de velocidad máxima |
| `YAW_SPEED` | 0,25 | el par de giro de los neumáticos se escala por esto |
| `STEERING` | 0,9 | multiplica ángulo y velocidad de giro |
| `RIM_SIZE`, `SECTION_WIDTH`, `ASPECT_RATIO` | 19", 255, 40 | radio |

## 4. Suspensión [D]

- Brazo de cada rueda: x = ±(`TRACK_WIDTH` − `SECTION_WIDTH`/1000)/2, y = cara inferior de la caja del cuerpo, z = `FRONT_AXLE` y `FRONT_AXLE − WHEEL_BASE`.
- Compresión = `RIDE_HEIGHT × inclinación + penetración`, tope en `TRAVEL`. Al tocar fondo el cuerpo sube (`ModifyYPos`).
- Muelle progresivo: `c × k × (c × SPRING_PROGRESSION + 1)`, k = `SPRING_STIFFNESS × 175,1268` (lb/in → N/m).
- Amortiguador: `SHOCK_STIFFNESS` al comprimir, `SHOCK_EXT_STIFFNESS` al extender, digresivo por encima de `SHOCK_VALVING` (pulgadas/s) con exponente `1 − SHOCK_DIGRESSION`; se anula si pasa de `SHOCK_BLOWOUT × 9,81 × masa`.
- Estabilizadora: diferencia de compresión izquierda/derecha × `SWAYBAR_STIFFNESS`.
- Rueda en el suelo solo si la normal del suelo y el «arriba» del coche forman < 78° (`ENABLE_ROLL_STOPS_THRESHOLD` 0,2) [D].
- El par de giro (eje vertical) de todas las ruedas se multiplica por `YAW_SPEED` antes de aplicarse [D].
- CG: altura `ROLL_CENTER − (alto/2 + RIDE_HEIGHT)` desde el centro, posición longitudinal por `FRONT_WEIGHT_BIAS` (50 % en el aire).

## 5. Motor, embrague y caja [D]

- Par: tabla `TORQUE` (ft·lb) repartida entre `IDLE` y `MAX_RPM`, rpm limitadas a `IDLE…RED_LINE`, × 1,3558.
  BMW: 170 251 340 428 **467** 452 411 375 350 ft·lb; ralentí 800, corte 8500, máx. 9500 [V].
- Inercia del motor `(FLYWHEEL_MASS × 0,025 + 0,25)` (× 0,35 en punto muerto).
- Freno motor: `ENGINE_BRAKING` interpolado por rpm, × (1 − gas).
- Velocidad de la transmisión: `ω_ralentí + ω_ruedas × relación × (1 − IDLE/RED_LINE)` — así lo hace el juego.
- Convertidor de par: la relación sube × (1 + `TORQUE_CONVERTER` × gas × (1 − rampa ralentí→rpm de par máximo)).
- Embrague con tres estados (acoplado, acoplando 0,25 s / 0,05 s en 1.ª, desacoplado), rigidez 20, juego de embrague en 1.ª y marcha atrás (`CLUTCH_SLIP`).
- Cambio automático con los puntos de `Info::ShiftPoints` (se sube cuando el par en la marcha siguiente supera al actual) y bajada «costeando» al 65 %.
  Tiempo de cambio `SHIFT_SPEED × relación` (¼ al bajar).
- Marchas `GEAR_RATIO`: 0 = atrás 3,2 · 1 = punto muerto · 2…7 = 4,1 2,53 1,67 1,23 1 0,83; grupo `FINAL_GEAR` 3,4 [V].
- `Info::MaxInductedTorque` no está decompilado: las rpm de par máximo se buscan cada 50 rpm [I].
- Nitro (`nos[0]` = 0x1efbd807 en el BMW): par × (1 + `TORQUE_BOOST` 0,75) durante `NOS_CAPACITY` 2,5 s; recarga entre `RECHARGE_MIN/MAX_SPEED` (mph). Se puede recargar siempre [I: `IPlayer::CanRechargeNOS`].
- Turbo/compresor (`induction`): portado; el BMW de serie no lleva (`induction[0]` = default) [V].

## 6. Aerodinámica [D, 100 %]

- Resistencia: `F = −v × |v| × DRAG_COEFFICIENT`, doble sin gas, aplicada 0,1 m más abajo sin gas.
- Carga aerodinámica **lineal**: `|v| × 2 × AERO_COEFFICIENT × 1000` N (BMW: 600 N por m/s), en `AERO_CG` % entre ejes.
  Con el coche de lado baja hasta el 40 %; en el aire × 0,8.

## 7. Dirección, freno de mano y derrape [D]

- Ángulo máximo según velocidad hacia delante (tabla 40° parado → 2,9° a 160 m/s), ampliado al frenar o soltar gas, al contravolantear (hasta el ángulo de deriva trasero) y reducido tras un golpe.
- Velocidad de giro 180°/s × tabla por velocidad × media de lo rápido que se mueve el stick (ventana 0,15 s).
  Con teclado el giro es tan rápido como permite el juego (entrada digital).
- La tabla de remapeo del joystick solo afecta a la media de entrada, no al ángulo [D].
- Freno de mano: `EBRAKE` en las traseras (+0,5 si ya va cruzado > 0,3 rad por debajo de 80 mph); baja el «yaw control» hasta 0,5.
- Derrape (`DoDrifting`): estados fuera/entrando/dentro/saliendo; dentro, par que frena el giro (tabla × 4) y fricción trasera de la tabla `DriftRearFriction`.
- Control de tracción en curva (ángulo máx. 16°, deslizamiento 20 m/s) y «burnout» en 1.ª a fondo.

## 8. Lo que no es del juego (o falta)

- **Choques con muros y con el suelo del cuerpo**: impulsos propios con `WALL_FRICTION`, `WALL_ELASTICITY`, `WORLD_MOMENT_SCALE`, `GROUND_*` [I].
  `RigidBody::DoBarrierCollision` y `ResolveGroundCollision` no se han portado. Sí se portan las reacciones de dirección (`OnCollision`: menos dirección tras el golpe, giro de morro contra el muro).
- **Caja del cuerpo** (`dimension`): la caja del modelo [I]; `PVehicle.cpp` está vacío en la decomp.
- **Superficie**: la colisión exportada no guarda el material; todas las ruedas usan `simsurface/default` (1, 1, 1) [V valores].
- Sin reglajes (`Physics::Tunings`), sin «speedbreaker», sin daño ni ruedas pinchadas.
- Solo el modelo de **corredor** (`SuspensionRacer` + `EngineRacer`). Tráfico (`SuspensionTraffic`), IA en raíl (`*Spline`) y remolques no.
- `DoSleep` coincide al 100 % con el binario y se copia tal cual, aunque al sumar con `Resolve` duplica la fuerza vertical y longitudinal acumulada a < 1 m/s [D].

## 9. Datos: `physics.json`

`tools/src/cli/physics-attribs.ts` (paso «Física de los coches» de `build-all.ts` e `install.ts`) lee `GLOBAL\ATTRIBUTES.BIN`:

- Por cada `pvehicle` (113): `MASS`, `TENSOR_SCALE`, `MODEL`, comportamientos, y la colección del **índice 0** de
  `chassis`, `tires`, `engine`, `transmission`, `brakes`, `induction`, `nos` con herencia resuelta (`BehaviorSpecsPtr<T>(this, 0)`) [D].
  Las demás entradas de cada array son los niveles de mejora (`upgrades`).
- `rigidbodyspecs` (gravedad, fricción y elasticidad de choques) y las cámaras `camerainfo` del `ecar`.
- `controller/drive`: `ControllerDataRecord {mDeviceID, mUpdateType, mLowerDZ, mUpperDZ}` [D: `Misc/MWAttribUserTypes.h`].
- `AxlePair` = [delante, detrás]. Unidades del juego: pulgadas, lb/in, ft·lb, mm.
- No se sube a git (`.gitignore`: `map-data/**/physics.json`).

## 10. Medidas (`--physics-test`, plano sin muros) [V medido · referencias H]

`./.build/release/Rockport --data ../map-data/SLES-53559 --physics-test [COCHE] [--physics-trace]`

| Prueba | BMW M3 GTR (E46) | Referencia |
|---|---|---|
| Reposo: compresión del./tras. | 0,025 / 0,025 m (calculada 0,025 / 0,024) | — |
| 0–60 mph | **3,03 s** | ≈ 3,9 s en el juego [H: dato de memoria, no medido] |
| 0–100 km/h | **3,12 s** | — |
| 0–200 km/h | 6,92 s (con NOS desde 50 km/h: 5,20 s) | — |
| 1/4 de milla | 10,17 s | — |
| Punta (60 s a fondo) | **389,9 km/h** en 6.ª al corte (8500 rpm) | el juego no limita por aire sino por el corte [I] |
| Frenada 100→0 km/h | **14,5 m** en 1,27 s | — |
| Curva a tope (gas 0,6, 3 s desde 100 km/h) | 65,6 km/h, 3,6 g laterales | la carga aerodinámica lineal da mucho agarre a baja velocidad [D] |
| Freno de mano 0,6 s a 100 km/h y gas | deriva máx. 21°, estado de derrape «saliendo» | — |

Otros: Carrera GT 0–100 3,10 s, punta 348 km/h; COPMIDSIZE (policía) 0–100 1,3 s (los coches de policía tienen pares enormes; la IA los usa con otro comportamiento) [V medido].

Diferencias con la referencia: el 0–60 sale ~0,9 s más rápido. Posibles causas: la caja del cuerpo y la inercia (inferidas),
el cambio automático sin las pausas reales de la animación, o el dato de referencia [H].

## 11. Pendiente

- Portar `RigidBody::DoBarrierCollision`/`ResolveGroundCollision` (muros y suelo del cuerpo). Coches entre sí: §12.
- Material del suelo en la colisión exportada (para `LATERAL_GRIP`, `DRIVE_GRIP`).
- Reglajes, «speedbreaker», ruedas pinchadas (`SpikeStrip`). Daños: §12.
- Medir en el juego (emulador) 0–60 y frenada con el mismo coche para cerrar la referencia.

## 12. Choques entre coches y con objetos (formato de datos 11)

Código: `native-engine/Sources/Rockport/Crash/` (`CrashWorld`, `CrashGeometry`, `Damage`, `CrashAI`, `Smackables`,
`PursuitBreakers`, `Heli`, `CrashTests`). Se ejecuta una vez por fotograma tras mover a todos (`AIWorld.update`).

| Pieza del juego | Fuente | Port |
|---|---|---|
| Volúmenes de colisión (`CollisionGeometry::Bounds`) | `bounds.json` [V], `Physics/Bounds.h` [D] | Solo los `PrimVsObjects` que no son `Internal`/`Disabled` (cajas y esferas); los «Internal» son piezas sueltas (puertas, parachoques) [I] |
| `RigidBody::OnObjectOverlap` | `RigidBody.cpp` [D] | Pares por esfera envolvente; el contacto más profundo entre volúmenes [I: el juego resuelve cada par] |
| `Geometry::FindIntersection` | `Geometry.cpp` vacío [D] | SAT de 15 ejes (caja-caja), esfera-caja, esfera-esfera; punto = media de esquinas dentro [I] |
| `ResolveObjectCollision` | `RigidBody.cpp` 1032-1166 [D] | Fricción `Ks = √(μs·μs)`, `Kd = √(μk·μk)`, plano `(min(Ks, Kd), Ks)`; elasticidad = `|n en ejes del cuerpo ⊙ OBJ_ELASTICITY|`; `ModifyCollision` (`OBJ_MOMENT_SCALE` xyz → inercia, w → masa); `Separate` por masas o el móvil entero |
| `Moment::React` | no decompilado | Impulso con restitución (media de las dos) y Coulomb estática/dinámica [I] |
| `DamageVehicle::OnImpact` | `DamageVehicle.cpp` [D] | Literal: zona por brazo y normal (umbrales 0,5/0,8), `ratio = fuerza / (FORCE·1000)`, niveles visuales y puntos de vida con `damagespecs` [V]. «Fuerza» = impulso en N·s [I] (con esa unidad un policía cae en 2 embestidas fuertes, como en el juego) |
| Capa de golpes y cristales | `CarRender.cpp SetPlayerDamage` [D] | `DAMAGE0_FRONT/REAR/…` (ya en los GLB) visibles con daño > 0; `WINDOW_DAMAGE0` (crash/, GLOBALB [V]) con daño > 1 [D]; todas las lunas comparten textura [I] |
| Paneles rotos de la policía | `VehiclePartDamage.cpp mSlotZoneMapList` [D] | `DAMAGE1_<PIEZA>` (nuevo en los GLB, formato 11) por zona; sin barra de luces rota no hay destellos |

- Jugador y rivales: la física del juego (PVehicle). El impulso se aplica en su espacio «Bond» (la velocidad angular cambia de signo al pasar al mundo: pseudovector).
- Tráfico y policía: cinemáticos con un cuerpo en planta (masa e inercia `Box × TENSOR_SCALE` [D]). Golpe pequeño → solo cambia la velocidad; golpe fuerte (lateral > 1,5 m/s, giro > 0,35 rad/s o Δv > 4 m/s) → deslizamiento con fricción de neumáticos y rebote en muros hasta pararse [I]. Tráfico: accidente (ACCIDENT_OVER [D]); policía: vuelve a la red (GetUnstuck [D]) o, destruida, frena a 0,25 (AIActionTooDamaged [D]).
- Normales de coche contra coche casi horizontales y separación ≤ 0,5 m por paso [I]: una normal vertical metía un coche bajo el suelo.

Pruebas `--crash-test all` (1600×900, M4) [V medido]:

| Escenario | Resultado |
|---|---|
| frontal (90 km/h contra tráfico a 50) | impulso 21 kN·s, jugador 90 → 51 km/h, tráfico en trompo (1,27 rad/s), zona FRONT del jugador nivel 1, penetración residual 0,6 mm |
| lateral (100 km/h contra el costado de un COPMIDSIZE) | 1.ª: zona LEFT nivel 2, 13 paneles DAMAGE1, vida 0,59; 2.ª: **destruido** (1,24), mensaje «Patrulla ciudadana · Bolsa 250» y contador de la HUD |
| PIT (COPGTO contra la aleta trasera a 110 km/h) | rumbo del jugador +23°, giro máx. 2,1 rad/s, zona LEFT del jugador |
| rompibles (BMW a 80 km/h por una fila real) | 6/6 derribados (vallas, bolsas, contenedor) |
| derrumbe (andamio) | 3 piezas caen, 2 policías inmovilizados, coste para el estado 18 700 |
| rendimiento (20 coches con choques) | `CrashWorld.step` mediana 0,04–0,10 ms, p95 0,12–0,36 ms; GPU 5,6 ms a 2940×1912 |

Sin choques: `--no-crash` (vuelve el empujón cinemático anterior). Depuración: `ROCKPORT_DEBUG_CRASH=1`.
