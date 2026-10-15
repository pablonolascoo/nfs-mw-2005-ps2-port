# Driving physics (the game's model)

Tags: [V] verified in bytes or measured · [D] from the decomp · [I] inferred · [H] hypothesis.

Source: decomp `dbalatoni13/nfsmw` (SLUS-21351 ELF), folder `src/Speed/Indep/Src/Physics/`.
Port code: `native-engine/Sources/Rockport/Physics/*.swift`. Data: `map-data/<ID>/physics.json`.

## 1. What was ported

| Game piece [D] | Decomp file | Port (Swift) | Match vs. PS2 binary [V: report.json] |
|---|---|---|---|
| Wheel + tyre (`Tire::UpdateLoaded`, `UpdateFree`, `ComputeLateralForce`, `CheckForBrakeLock`, `GetPilotFactor`) | `Behaviors/SuspensionRacer.cpp` | `Physics/Tire.swift:141-282` | 93–100 % |
| Suspension and wheel forces (`DoWheelForces`) | `SuspensionRacer.cpp` | `Physics/SuspensionRacer.swift:393` | 89 % |
| Drive and differentials (`DoDriveForces`, `Differential::CalcSplit`) | `SuspensionRacer.cpp` | `SuspensionRacer.swift:334-391` | 98–99 % |
| Grip, handbrake, burnout (`TuneWheelParams`, `YawFrictionBoost`, `Burnout::Update`) | `SuspensionRacer.cpp` | `SuspensionRacer.swift:249-305` | 87–97 % |
| Drifting (`DoDrifting`) | `SuspensionRacer.cpp` | `SuspensionRacer.swift:307` | 72 % |
| Player steering (`DoHumanSteering`, `CalculateMaxSteering`, `CalculateSteeringSpeed`, `ComputeAckerman`, `DoWallSteer`) | `SuspensionRacer.cpp`, `Chassis.cpp` | `SuspensionRacer.swift:162-236` | 70–76 % |
| Chassis (`SetCOG`, `ComputeState`, `DoAerodynamics`, `DoJumpStabilizer`, `DoSleep`, `ComputeMaxSlip`, grip scales) | `Behaviors/Chassis.cpp` | `SuspensionRacer.swift:104-160, 484-535` | 96–100 % |
| Engine, clutch, gearbox, nitrous, turbo (`EngineRacer::OnTaskSimulate`, `AutoShift`, `DoNos`, `DoInduction`, `Engine_SmoothRPM`, `Clutch`) | `Behaviors/EngineRacer.cpp` | `Physics/EngineRacer.swift` | 69–100 % |
| Torque curve, inertia, shift points, speedometer, wheel diameter | `PhysicsInfo.cpp` | `EngineRacer.swift:85-172` | 86–100 % |
| Rigid body (`DoIntegration`, `Resolve*`, `Damp`, `Inertia::Box`) | `Behaviors/RigidBody.cpp`, `Dynamics/Inertia.h` | `Physics/RigidBody.swift` | 56 % (integration) |
| Player input (`InputPlayer::FetchInput`, `DoAutoReverse`, `DoAutoBraking`) | `Behaviors/PInput.cpp` | `Physics/PVehicle.swift:64` | 99.9 % |
| Tables (`Table`, `Graph`, `tGraph`, `AverageWindow`) | `Misc/Table.cpp` | `Physics/PhysicsMath.swift` | — |

Everything runs in **game space** ("Bond": x right, y up, z forward) so each formula stays literal.
Only collision queries and rendering convert to engine world space (X = z, Y = −x, Z = y) with `PM.toWorld` / `PM.toGame`.
That mapping flips handedness (determinant −1), which is why the whole simulation stays in game space [I].

## 2. Update loop

- **Fixed 1/60 s step** [V]: `Scheduler::Init(float)` receives `0x3C888889` (= 1/60) in the PS2 ELF (`zMisc.cpp.s`).
- Per-step order, as in the `pvehicle` `BEHAVIOR_ORDER` [V]: `RIGIDBODY → AI → INPUT → ENGINE → SUSPENSION → DAMAGE → DRAW → SOUND`.
  1. `RigidBody::OnBeginFrame`: gravity `rigidbodyspecs.GRAVITY × mass` (−9.8128 m/s² for `racers`) [V].
  2. `InputPlayer::FetchInput`: dead zone, automatic reverse, auto-brake [D].
  3. `EngineRacer::OnTaskSimulate`: engine torque → wheel torque (`mDriveTorque`) [D].
  4. `SuspensionRacer::OnTaskSimulate`: CG, state, aero, drive, steering, wheels, jump stabilizer, sleep [D].
  5. Integration (semi-implicit Euler, quaternion rotation about the CG) [D, 56 %].
- Rendering **interpolates** the pose between the last two steps (`Car.update`: linear position, `slerp` rotation), smooth at 60/90/120 Hz.
- Measured cost: < 30 µs per step on an M4 [V]. The game keeps 60 fps.

## 3. Tyre [D]

Each wheel keeps angular velocity, load, slip and a **traction** state (1 = gripping, < 1 = sliding).

- Full traction: longitudinal force = total torque / radius; lateral force from **load-sensitivity tables**:
  7 tables (slip angle 0, 2, 4… 12°) × load 0–10 kN, times `GRIP_SCALE × 1000 × 2.5 × grip_boost`.
- Sliding: dynamic friction `DYNAMIC_GRIP × traction_boost × pilot / skid speed`.
- **Friction circle**: limit `load × STATIC_GRIP × traction_boost × drift_friction × pilot`; above it everything is scaled and `traction` drops.
- **Ellipse**: with drive torque along the motion, longitudinal force counts × 1.5 in the circle (`TireForceEllipseRatio`).
- `GetPilotFactor`: driven rear wheels at 85 % below 30 mph, 100 % at 50 mph.
- Brakes: `BRAKES × 1.3558 × 4` N·m per wheel; handbrake `EBRAKE × 1.3558 × 10`, rear only.
  Lock when brake torque × 1.2 (× `BRAKE_LOCK`) exceeds ground force × radius + |ω| × 100.
- Diameter: `RIM_SIZE × 0.0254 + SECTION_WIDTH × 0.001 × 2 × ASPECT_RATIO/100` (BMW: 0.687 m) [D][V].

| Attribute (`tires` class) | BMW M3 GTR [V] | Used for |
|---|---|---|
| `STATIC_GRIP` | 2.2 / 2.3 | friction-circle limit |
| `DYNAMIC_GRIP` | 2 / 2 | sliding friction |
| `GRIP_SCALE` | 1.175 / 1.225 | lateral force from the tables |
| `YAW_CONTROL` | 0.3 0.65 1 1.2 | rear grip assist vs. % of top speed |
| `YAW_SPEED` | 0.25 | tyre yaw torque is scaled by this |
| `STEERING` | 0.9 | scales steering angle and rate |
| `RIM_SIZE`, `SECTION_WIDTH`, `ASPECT_RATIO` | 19", 255, 40 | radius |

## 4. Suspension [D]

- Wheel arm: x = ±(`TRACK_WIDTH` − `SECTION_WIDTH`/1000)/2, y = bottom face of the body box, z = `FRONT_AXLE` and `FRONT_AXLE − WHEEL_BASE`.
- Compression = `RIDE_HEIGHT × upness + penetration`, capped at `TRAVEL`; bottoming out lifts the body (`ModifyYPos`).
- Progressive spring: `c × k × (c × SPRING_PROGRESSION + 1)`, k = `SPRING_STIFFNESS × 175.1268` (lb/in → N/m).
- Damper: `SHOCK_STIFFNESS` in bump, `SHOCK_EXT_STIFFNESS` in rebound, digressive above `SHOCK_VALVING` (in/s) with exponent `1 − SHOCK_DIGRESSION`; zeroed above `SHOCK_BLOWOUT × 9.81 × mass`.
- Anti-roll bar: left/right compression difference × `SWAYBAR_STIFFNESS`.
- A wheel only counts as grounded when the ground normal is < 78° from the car's up (`ENABLE_ROLL_STOPS_THRESHOLD` 0.2) [D].
- Total tyre yaw torque is multiplied by `YAW_SPEED` before it is applied [D].
- CG: height `ROLL_CENTER − (half height + RIDE_HEIGHT)` from the centre, longitudinal from `FRONT_WEIGHT_BIAS` (50 % when airborne).

## 5. Engine, clutch and gearbox [D]

- Torque: `TORQUE` table (ft·lb) spread over `IDLE…MAX_RPM`, rpm clamped to `IDLE…RED_LINE`, × 1.3558.
  BMW: 170 251 340 428 **467** 452 411 375 350 ft·lb; idle 800, red line 8500, max 9500 [V].
- Engine inertia `(FLYWHEEL_MASS × 0.025 + 0.25)` (× 0.35 in neutral).
- Engine braking: `ENGINE_BRAKING` interpolated over rpm, × (1 − throttle).
- Transmission speed: `ω_idle + ω_wheels × ratio × (1 − IDLE/RED_LINE)` — the game's own mapping.
- Torque converter: ratio × (1 + `TORQUE_CONVERTER` × throttle × (1 − ramp idle→peak-torque rpm)).
- Three-state clutch (engaged, engaging 0.25 s / 0.05 s in 1st, disengaged), stiffness 20, clutch play in 1st/reverse (`CLUTCH_SLIP`).
- Automatic gearbox with `Info::ShiftPoints` (up-shift when next-gear torque beats current) and 65 % coasting down-shift.
  Shift time `SHIFT_SPEED × ratio` (¼ when down-shifting).
- `GEAR_RATIO`: 0 = reverse 3.2 · 1 = neutral · 2…7 = 4.1 2.53 1.67 1.23 1 0.83; `FINAL_GEAR` 3.4 [V].
- `Info::MaxInductedTorque` is not decompiled: peak-torque rpm is searched every 50 rpm [I].
- Nitrous (`nos[0]` = 0x1efbd807 on the BMW): torque × (1 + `TORQUE_BOOST` 0.75) for `NOS_CAPACITY` 2.5 s; recharges between `RECHARGE_MIN/MAX_SPEED` (mph). Always allowed to recharge [I: `IPlayer::CanRechargeNOS`].
- Turbo/supercharger (`induction`): ported; the stock BMW has none (`induction[0]` = default) [V].

## 6. Aerodynamics [D, 100 %]

- Drag: `F = −v × |v| × DRAG_COEFFICIENT`, doubled off-throttle and applied 0.1 m lower off-throttle.
- **Linear** downforce: `|v| × 2 × AERO_COEFFICIENT × 1000` N (BMW: 600 N per m/s) at `AERO_CG` % between axles; down to 40 % when sideways, × 0.8 airborne.

## 7. Steering, handbrake and drifting [D]

- Max angle from forward speed (table 40° standing → 2.9° at 160 m/s), widened when braking/lifting, when counter-steering (up to the rear slip angle), reduced after a crash.
- Steering rate 180°/s × speed table × average stick speed (0.15 s window). A keyboard steers as fast as the game allows (digital input).
- The joystick remap table only feeds the input average, not the angle [D].
- Handbrake: `EBRAKE` on the rear (+0.5 when already > 0.3 rad sideways below 80 mph); lowers "yaw control" to 0.5.
- Drift state machine out/enter/in/exit; inside, a yaw-damping torque (table × 4) and rear friction from `DriftRearFriction`.
- Cornering traction control (max angle 16°, slip 20 m/s) and first-gear burnout.

## 8. Not from the game (or missing)

- **Wall and body-ground collisions**: own impulses using `WALL_FRICTION`, `WALL_ELASTICITY`, `WORLD_MOMENT_SCALE`, `GROUND_*` [I].
  `RigidBody::DoBarrierCollision` / `ResolveGroundCollision` are not ported; the steering reactions of `OnCollision` are.
- **Body box** (`dimension`): the model's bounding box [I]; `PVehicle.cpp` is empty in the decomp.
- **Surface**: exported collision has no material; every wheel uses `simsurface/default` (1, 1, 1) [V values].
- No tunings (`Physics::Tunings`), no speedbreaker, no damage or blown tyres.
- Only the **racer** model (`SuspensionRacer` + `EngineRacer`); traffic (`SuspensionTraffic`), on-rail AI (`*Spline`) and trailers are not.
- `DoSleep` matches the binary 100 % and is copied as is, even though adding through `Resolve` doubles the accumulated vertical and longitudinal force below 1 m/s [D].

## 9. Data: `physics.json`

`tools/src/cli/physics-attribs.ts` (step "Física de los coches" in `build-all.ts` and `install.ts`) reads `GLOBAL\ATTRIBUTES.BIN`:

- Per `pvehicle` (113): `MASS`, `TENSOR_SCALE`, `MODEL`, behaviours, and the **index 0** collection of
  `chassis`, `tires`, `engine`, `transmission`, `brakes`, `induction`, `nos` with inheritance resolved (`BehaviorSpecsPtr<T>(this, 0)`) [D].
  Other array entries are upgrade levels (`upgrades`).
- `rigidbodyspecs` (gravity, collision friction/elasticity) and the `ecar` `camerainfo` cameras.
- `controller/drive`: `ControllerDataRecord {mDeviceID, mUpdateType, mLowerDZ, mUpperDZ}` [D: `Misc/MWAttribUserTypes.h`].
- `AxlePair` = [front, rear]. Game units: inches, lb/in, ft·lb, mm.
- Not committed (`.gitignore`: `map-data/**/physics.json`).

## 10. Measurements (`--physics-test`, flat plane, no walls) [V measured · references H]

`./.build/release/Rockport --data ../map-data/SLES-53559 --physics-test [CAR] [--physics-trace]`

| Test | BMW M3 GTR (E46) | Reference |
|---|---|---|
| Rest: front/rear compression | 0.025 / 0.025 m (computed 0.025 / 0.024) | — |
| 0–60 mph | **3.03 s** | ≈ 3.9 s in game [H: from memory, not measured] |
| 0–100 km/h | **3.12 s** | — |
| 0–200 km/h | 6.92 s (with NOS from 50 km/h: 5.20 s) | — |
| Quarter mile | 10.17 s | — |
| Top speed (60 s flat out) | **389.9 km/h** in 6th at the limiter (8500 rpm) | drag does not cap it, the limiter does [I] |
| Braking 100→0 km/h | **14.5 m** in 1.27 s | — |
| Full-lock turn (0.6 throttle, 3 s from 100 km/h) | 65.6 km/h, 3.6 g lateral | linear downforce gives a lot of grip at low speed [D] |
| Handbrake 0.6 s at 100 km/h, then throttle | max slip 21°, drift state "exit" | — |

Others: Carrera GT 0–100 3.10 s, top 348 km/h; COPMIDSIZE (police) 0–100 1.3 s (police cars have huge torque; AI drives them with another behaviour) [V measured].

The 0–60 comes out ~0.9 s quicker than the reference. Possible causes: the inferred body box and inertia,
an automatic gearbox without the real shift animation pauses, or the reference itself [H].

## 11. To do

- Port `RigidBody::DoBarrierCollision`/`ResolveGroundCollision` (walls and body vs. ground). Car vs. car: §12.
- Ground material in the exported collision (for `LATERAL_GRIP`, `DRIVE_GRIP`).
- Tunings, speedbreaker, blown tyres (`SpikeStrip`). Damage: §12.
- Measure 0–60 and braking in the real game (emulator) with the same car to close the reference.

## 12. Car-to-car and car-to-object collisions (data format 11)

Code: `native-engine/Sources/Rockport/Crash/` (`CrashWorld`, `CrashGeometry`, `Damage`, `CrashAI`, `Smackables`,
`PursuitBreakers`, `Heli`, `CrashTests`). Runs once per frame after everything has moved (`AIWorld.update`).

| Game piece | Source | Port |
|---|---|---|
| Collision volumes (`CollisionGeometry::Bounds`) | `bounds.json` [V], `Physics/Bounds.h` [D] | Only non-`Internal`/`Disabled` `PrimVsObjects` boxes and spheres; "Internal" ones belong to detachable parts [I] |
| `RigidBody::OnObjectOverlap` | `RigidBody.cpp` [D] | Bounding-sphere pairs; deepest contact between volumes [I: the game resolves every pair] |
| `Geometry::FindIntersection` | `Geometry.cpp` empty [D] | 15-axis SAT (box-box), sphere-box, sphere-sphere; point = mean of inside corners [I] |
| `ResolveObjectCollision` | `RigidBody.cpp` 1032-1166 [D] | Friction `Ks = √(μs·μs)`, `Kd = √(μk·μk)`, plane `(min(Ks, Kd), Ks)`; elasticity = `|normal in body axes ⊙ OBJ_ELASTICITY|`; `ModifyCollision` (`OBJ_MOMENT_SCALE` xyz → inertia, w → mass); `Separate` by mass or the mobile one entirely |
| `Moment::React` | not decompiled | Impulse with restitution (average of both) and static/dynamic Coulomb friction [I] |
| `DamageVehicle::OnImpact` | `DamageVehicle.cpp` [D] | Literal: zone from arm and normal (0.5/0.8 thresholds), `ratio = force / (FORCE·1000)`, visual levels and hit points from `damagespecs` [V]. "Force" = impulse in N·s [I] (a cop dies after 2 hard rams, as in the game) |
| Damage layer and glass | `CarRender.cpp SetPlayerDamage` [D] | `DAMAGE0_FRONT/REAR/…` (already in the GLBs) shown with damage > 0; `WINDOW_DAMAGE0` (crash/, GLOBALB [V]) with damage > 1 [D]; all windows share one texture [I] |
| Cop broken panels | `VehiclePartDamage.cpp mSlotZoneMapList` [D] | `DAMAGE1_<PART>` (new in the GLBs, format 11) per zone; a broken light bar stops the flashers |

- Player and racers: the game physics (PVehicle). Impulses are applied in "Bond" space (angular velocity flips sign when mapped to the world: pseudovector).
- Traffic and police: kinematic with a planar body (mass and inertia `Box × TENSOR_SCALE` [D]). Small hit → only the speed changes; hard hit (lateral > 1.5 m/s, spin > 0.35 rad/s or Δv > 4 m/s) → tyre-friction slide with wall bounces until it stops [I]. Traffic: accident (ACCIDENT_OVER [D]); police: back to the network (GetUnstuck [D]) or, destroyed, brakes at 0.25 (AIActionTooDamaged [D]).
- Car-car normals kept nearly horizontal and separation ≤ 0.5 m per step [I]: a vertical normal pushed a car under the ground.

`--crash-test all` (1600×900, M4) [V measured]:

| Scenario | Result |
|---|---|
| head-on (90 km/h into traffic at 50) | 21 kN·s impulse, player 90 → 51 km/h, traffic spins (1.27 rad/s), player FRONT zone level 1, residual penetration 0.6 mm |
| T-bone (100 km/h into a COPMIDSIZE's side) | 1st: LEFT zone level 2, 13 DAMAGE1 panels, life 0.59; 2nd: **destroyed** (1.24), game message and HUD counter |
| PIT (COPGTO into the rear quarter at 110 km/h) | player heading +23°, peak yaw 2.1 rad/s |
| breakables (BMW at 80 km/h through a real row) | 6/6 knocked down (fences, bags, dumpster) |
| pursuit breaker (scaffolding) | 3 pieces fall, 2 cops immobilized, cost to state 18,700 |
| performance (20 cars with collisions) | `CrashWorld.step` median 0.04–0.10 ms, p95 0.12–0.36 ms; GPU 5.6 ms at 2940×1912 |

Disable with `--no-crash` (previous kinematic push). Debug: `ROCKPORT_DEBUG_CRASH=1`.
