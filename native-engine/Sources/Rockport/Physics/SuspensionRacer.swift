// Suspensión, neumáticos, dirección, deriva y aerodinámica del coche del jugador [D: Physics/Behaviors/SuspensionRacer.cpp,
// Physics/Behaviors/Chassis.cpp, Physics/PhysicsInfo.cpp]. Copia del código del juego en espacio del juego.
// Atributos: chassis (muelles, amortiguadores, estabilizadoras, recorrido, alturas, ejes, CG, aero), tires (agarre,
// medidas, YAW_CONTROL, YAW_SPEED, STEERING), brakes, transmission (reparto y diferenciales).
import simd

/// Chassis::State [D: Chassis.h].
struct ChassisState {
    var right = V3(1, 0, 0), up = V3(0, 1, 0), fwd = V3(0, 0, 1), position = V3(0, 0, 0)
    var localVel = V3(0, 0, 0), linearVel = V3(0, 0, 0), angularVel = V3(0, 0, 0), localAngularVel = V3(0, 0, 0)
    var cog = V3(0, 0, 0), worldCog = V3(0, 0, 0), dimension = V3(0, 0, 0), inertia = V3(0, 0, 0)
    var gas: Float = 0, brake: Float = 0, ebrake: Float = 0, steer: Float = 0
    var groundEffect: Float = 0, slipangle: Float = 0, mass: Float = 0, speed: Float = 0, time: Float = 0
    var gear = Gear.first, nosBoost: Float = 1, shiftBoost: Float = 1
    func rotate(_ v: V3) -> V3 { right * v.x + up * v.y + fwd * v.z }
}

final class SuspensionRacer {
    let chassis: VehicleSpecs.Chassis, tireInfo: VehicleSpecs.Tires, tranny: VehicleSpecs.Transmission
    let tires: [Tire]
    private(set) var numWheelsOnGround = 0
    private var gameBreaker: Float = 0
    // Steering
    private var steerPrevious: Float = 0
    private(set) var steerWheels: [Float] = [0, 0]   // radianes (l4.w, r4.w)
    private var steerLastMaximum: Float = 45, steerLastInput: Float = 0
    private let inputAverage = AverageWindow(0.55, 60), inputSpeedCoeffAverage = AverageWindow(0.15, 60)
    var collisionTimer: Float = 0
    var wallNoseTurn: Float = 0, wallSideTurn: Float = 0
    private var yawControl: Float = 1
    // Drift
    private(set) var driftState = 0     // 0 OUT, 1 ENTER, 2 IN, 3 EXIT
    private(set) var driftValue: Float = 0
    // Burnout
    private var boState = 0, boTime: Float = 0, boTraction: Float = 1, boAllow: Float = 0
    // Chassis
    private var jumpTime: Float = 0, jumpAltitude: Float = 0

    static let absoluteMaxSteering: Float = 45
    // Tablas de dirección [D]
    static let steeringRange = PTable([40, 20, 10, 5.5, 4.5, 3.25, 2.9, 2.9, 2.9, 2.9], 0, 160)
    static let steeringSpeedT = PTable([1, 1, 1, 0.56, 0.5, 0.35, 0.3, 0.3, 0.3, 0.3], 0, 160)
    static let steeringRangeCoeff = PTable([1, 1.05, 1.1, 1.2, 1.3, 1.4], 0, 1)
    static let steeringInputSpeedCoeff = PTable([1, 1.05, 1.1, 1.5, 2.2, 3.1], 0, 10)
    static let steeringInputCoeff = PTable([1, 1.05, 1.1, 1.2, 1.3, 1.4], 0, 1)
    /// JoystickInputToSteerRemap1: la única tabla de remapeo que usa MW (SteerInputRemapping = MEDIUM) [D].
    static let steerRemap = PTable([-1, -0.712, -0.453, -0.303, -0.216, -0.148, -0.116, -0.08, -0.061, -0.034, 0,
                                    0.034, 0.061, 0.08, 0.116, 0.148, 0.216, 0.303, 0.453, 0.712, 1], -1, 1)
    static let postCollisionSteer = PGraph([(0, 0.2), (0.2, 0.5), (0.5, 0.7), (0.7, 1)])
    static let burnoutFriction = PGraph([(0, 1), (5, 0.8), (9, 0.9), (12.6, 0.833), (17.1, 0.72), (25, 0.65)])
    static let driftStabilizer = PGraph([(0, 0), (0.2617994, 0.1), (0.52359879, 0.45), (0.78539819, 0.85), (1.0471976, 0.95), (1.5533431, 1.15), (1.5707964, 0)])
    static let driftRearFriction = PTable([1.1, 0.95, 0.87, 0.77, 0.67, 0.6, 0.51, 0.43, 0.37, 0.34], 0, 1)
    static let tractionVsSpeed = PTable([0.909, 1.045, 1.09, 1.09, 1.09, 1.09, 1.09, 1.045, 1, 1], 0, 1)
    static let gripVsSpeed = PTable([0.833, 0.958, 1.008, 1.0167, 1.033, 1.033, 1.033, 1.0167, 1, 1], 0, 1)
    static let jumpStabilization = PGraph([(0, 0), (0.4, 0.15), (2, 5)])
    static let enableRollStopsThreshold: Float = 0.2   // VehicleSystem::ENABLE_ROLL_STOPS_THRESHOLD [D]

    init(_ s: VehicleSpecs, dimension: V3) {
        chassis = s.chassis; tireInfo = s.tires; tranny = s.transmission
        tires = (0..<4).map { i in Tire(radius: EngineRacer.wheelDiameter(s.tires, front: i < 2) * 0.5, index: i, tires: s.tires, brakes: s.brakes) }
        // CreateTires: brazos en los ejes, en la cara inferior de la caja del cuerpo
        let wb = chassis.WHEEL_BASE, fa = chassis.FRONT_AXLE
        let awf = chassis.TRACK_WIDTH[0] - tireInfo.SECTION_WIDTH[0] * 0.001
        let awr = chassis.TRACK_WIDTH[1] - tireInfo.SECTION_WIDTH[1] * 0.001
        tires[0].localArm = V3(-awf * 0.5, -dimension.y, fa)
        tires[1].localArm = V3(awf * 0.5, -dimension.y, fa)
        tires[2].localArm = V3(-awr * 0.5, -dimension.y, fa - wb)
        tires[3].localArm = V3(awr * 0.5, -dimension.y, fa - wb)
        inputAverage.reset(0); inputSpeedCoeffAverage.reset(0)
    }

    func rideHeight(_ axle: Int) -> Float { PM.inch2m(chassis.RIDE_HEIGHT[axle]) }

    /// Compresión estática (peso/2 por rueda contra el muelle progresivo): para colocar el coche y dibujar las ruedas [I].
    func staticCompression(axle: Int, mass: Float, gravity: Float) -> Float {
        let bias = chassis.FRONT_WEIGHT_BIAS * 0.01
        let load = mass * abs(gravity) * (axle == 0 ? bias : 1 - bias) * 0.5
        let k = PM.lbin2nm(chassis.SPRING_STIFFNESS[axle]), p = chassis.SPRING_PROGRESSION[axle]
        // k·c·(p·c + 1) = load  →  p·k·c² + k·c − load = 0
        if p <= 0 { return load / k }
        return (-k + (k * k + 4 * p * k * load).squareRoot()) / (2 * p * k)
    }

    func wheelAngularVelocity(_ i: Int) -> Float {
        let t = tires[i]
        if t.brakeLocked { return 0 }
        if !t.isOnGround || !t.isSlipping { return t.av }
        return t.roadSpeed / t.radius
    }

    func reset() {
        for t in tires { t.reset() }
        steerPrevious = 0; steerWheels = [0, 0]; steerLastMaximum = 45; steerLastInput = 0
        inputAverage.reset(0); inputSpeedCoeffAverage.reset(0)
        collisionTimer = 0; wallNoseTurn = 0; wallSideTurn = 0; yawControl = 1
        driftState = 0; driftValue = 0; boState = 0; boTime = 0; boTraction = 1; boAllow = 0
        numWheelsOnGround = 0
    }
    func matchSpeed(_ v: Float) { for t in tires { t.matchSpeed(v) }; boState = 0; boTime = 0; boTraction = 1; boAllow = 0; driftState = 0; driftValue = 0 }

    // MARK: Chassis

    /// Chassis::SetCOG.
    func setCOG(_ rb: RigidBody) {
        let front = chassis.FRONT_AXLE, rear = front - chassis.WHEEL_BASE
        var bias = chassis.FRONT_WEIGHT_BIAS * 0.01
        if numWheelsOnGround == 0 { bias = 0.5 }
        let z = (front - rear) * bias + rear
        let y = PM.inch2m(chassis.ROLL_CENTER) - (rb.dimension.y + max(rideHeight(0), rideHeight(1)))
        rb.cog = V3(0, y, z)
    }

    func computeState(_ rb: RigidBody, _ dT: Float, _ c: Controls, gear: Int, nosBoost: Float) -> ChassisState {
        var s = ChassisState()
        s.time = dT; s.inertia = rb.inertia; s.dimension = rb.dimension
        s.right = rb.right; s.up = rb.up; s.fwd = rb.forward; s.position = rb.position
        s.linearVel = rb.linearVel; s.localVel = rb.toLocal(rb.linearVel)
        s.angularVel = rb.angularVel; s.localAngularVel = rb.toLocal(rb.angularVel)
        s.speed = simd_length(s.linearVel)
        s.slipangle = s.localVel.z < 1 ? 0 : PM.atan2a(s.localVel.x, s.localVel.z)
        s.gas = PM.clamp(c.gas, 0, 1); s.brake = PM.clamp(c.brake, 0, 1); s.ebrake = c.handBrake; s.steer = PM.clamp(c.steering, -1, 1)
        s.cog = rb.cog; s.worldCog = rb.worldCog
        s.groundEffect = Float(numWheelsOnGround) * 0.25
        s.mass = rb.mass; s.nosBoost = nosBoost; s.gear = gear
        return s
    }

    static func computeMaxSlip(_ s: ChassisState) -> Float { s.gear == Gear.reverse ? 71 : PM.ramp(s.speed, 10, 71) + 0.5 }
    static func lateralGripScale(_ s: ChassisState) -> Float { gripVsSpeed.value(PM.ramp(s.speed, 0, PM.mph2mps(85))) * 1.2 }
    static func tractionScale(_ s: ChassisState) -> Float {
        s.gear == Gear.reverse ? 2 : tractionVsSpeed.value(PM.ramp(s.speed, 0, PM.mph2mps(85))) * 1.1
    }

    /// Chassis::DoAerodynamics (drag_pct = 1, aero_pct = 1, sin reglajes).
    func doAerodynamics(_ s: ChassisState, _ rb: RigidBody) {
        let dragCoef = chassis.DRAG_COEFFICIENT
        var drag = s.speed * dragCoef
        drag += drag * (2 - 1) * (1 - s.gas)                         // OffThrottleDragFactor = 2
        var dc = s.cog
        if s.groundEffect >= 0.5 { dc.y += -0.1 * (1 - s.gas) }        // OffThrottleDragCenterHeight
        rb.resolveForce(s.linearVel * -drag, at: s.rotate(dc) + s.position)

        var upness = max(s.up.y, 0)
        if s.groundEffect >= 0.5 { upness = 1 }
        var dir = s.fwd
        if s.speed > 0.0001 { dir = s.linearVel / s.speed }
        var forwardness = max(simd_dot(dir, s.fwd), 0)
        forwardness = max(0.4, powf(forwardness, 0.5))                 // AeroDropOffMin, AeroDropOff
        var down = upness * forwardness * s.speed * 2 * chassis.AERO_COEFFICIENT * 1000   // Info::AerodynamicDownforce
        if s.groundEffect == 0 { down *= 0.8 }
        if down > 0 {
            var ac = s.cog
            if s.groundEffect != 0 {
                let fz = tires[0].localArm.z, rz = tires[2].localArm.z
                ac.z = (fz - rz) * (chassis.AERO_CG * 0.01) + rz
            }
            rb.resolveForce(s.rotate(V3(0, -down, 0)), at: s.rotate(ac) + s.position)
        }
    }

    /// Chassis::ComputeAckerman → vectores adelante de las ruedas delanteras y sus ángulos (rad).
    func ackerman(_ steering: Float, _ s: ChassisState) -> (left: V3, right: V3, la: Float, ra: Float) {
        let wb = chassis.WHEEL_BASE, track = chassis.TRACK_WIDTH[0]
        var inside = PM.angle2rad(steering)
        if inside > .pi { inside -= 2 * .pi }
        var goingRight = true
        if inside < 0 { goingRight = false; inside = -inside }
        let outside = wb * inside / (track * inside + wb)
        let s0: Float, s1: Float
        if goingRight { s0 = inside; s1 = outside } else { s1 = -inside; s0 = -outside }
        return (s.rotate(V3(sin(s1), 0, cos(s1))), s.rotate(V3(sin(s0), 0, cos(s0))), s1, s0)
    }

    // MARK: Dirección del jugador

    private func calculateMaxSteering(_ s: ChassisState) -> Float {
        var m = SuspensionRacer.steeringRange.value(s.localVel.z)
        let tb = 1 - (s.gas + 1 - (s.brake + s.ebrake) * 0.5) * 0.5
        m *= 1.45 * tb * SuspensionRacer.steeringSpeedT.value(s.localVel.z) + 1   // BrakeSteeringRangeMultiplier
        m *= SuspensionRacer.steeringRangeCoeff.value(abs(inputAverage.value))
        if collisionTimer > 0 {
            let secs = 1 - collisionTimer
            if secs < 1 && secs > 0 {
                let sc = 1 - min(1, s.localVel.z / (PM.mph2mps(170) * 0.7))
                let cc = SuspensionRacer.postCollisionSteer.value(secs)
                m *= sc * (1 - cc) + cc
            }
        }
        let yawL = PM.angle2deg(tires[2].slipAngle), yawR = PM.angle2deg(tires[3].slipAngle)
        if s.steer > 0 && yawR > 0 { m = min(max(m, yawR), SuspensionRacer.absoluteMaxSteering) }
        else if s.steer < 0 && yawL < 0 { m = min(max(m, -yawL), SuspensionRacer.absoluteMaxSteering) }
        else if abs(inputAverage.value) >= 0.5 { m = max(m, steerLastMaximum - s.time * 0) }   // HardTurnTightenSpeed = 0
        m = min(m, SuspensionRacer.absoluteMaxSteering)
        steerLastMaximum = m
        return m
    }

    private func calculateSteeringSpeed(_ s: ChassisState, now: Float) -> Float {
        let inputSpeed = (s.steer - steerLastInput) / s.time
        inputSpeedCoeffAverage.record(SuspensionRacer.steeringInputSpeedCoeff.value(abs(inputSpeed)), now)
        var sp: Float = 180                                                  // SteeringSpeed
        sp *= SuspensionRacer.steeringSpeedT.value(s.localVel.z)
        sp *= inputSpeedCoeffAverage.value
        return sp * SuspensionRacer.steeringInputCoeff.value(abs(inputAverage.value))
    }

    /// DoHumanSteering (mando o teclado: ISteeringWheel::kGamePad). Devuelve "Angle".
    private func doHumanSteering(_ s: ChassisState, now: Float) -> Float {
        var steer = steerPrevious
        if steer >= 180 { steer -= 360 }
        let coeff = tireInfo.STEERING
        var newsteer = s.steer * calculateMaxSteering(s) * coeff
        newsteer = PM.clamp(newsteer, -SuspensionRacer.absoluteMaxSteering, SuspensionRacer.absoluteMaxSteering)
        let remapped = SuspensionRacer.steerRemap.value(s.steer)
        let speed = calculateSteeringSpeed(s, now: now) * coeff * s.time
        newsteer = PM.clamp(newsteer, steer - speed, steer + speed)
        steerLastInput = remapped
        steerPrevious = newsteer
        inputAverage.record(steerLastInput, now)
        return PM.deg2angle(newsteer)
    }

    private func doWallSteer(_ s: ChassisState, _ rb: RigidBody) {
        var wall = wallNoseTurn
        if wall != 0 && numWheelsOnGround > 2 && s.gas > 0 {
            var dW = s.steer * s.gas * 0.125
            if wall * dW >= 0 { dW *= abs(wall); rb.angularVel = s.angularVel + s.rotate(V3(0, dW, 0)) }
        }
        wall = wallSideTurn
        if wall * s.steer * s.gas > 0 && numWheelsOnGround > 2 && s.gear == Gear.reverse {
            let dW = -s.steer * s.gas * 0.125 * abs(wall)
            rb.angularVel = s.angularVel + s.rotate(V3(0, dW, 0))
        }
    }

    // MARK: Agarre, freno de mano, deriva

    private func calcYawControlLimit(_ speed: Float, maxSpeedometer: Float) -> Float {
        guard maxSpeedometer > 0 else { return 0 }
        let pct = min(abs(speed) / maxSpeedometer, 1)
        let n = tireInfo.YAW_CONTROL.count
        guard n > 1 else { return tireInfo.YAW_CONTROL.first ?? 0 }
        var r = Float(n - 1) * pct
        let i1 = Int(r); r -= Float(i1)
        let i2 = min(n - 1, i1 + 1)
        return tireInfo.YAW_CONTROL[i1] + (tireInfo.YAW_CONTROL[i2] - tireInfo.YAW_CONTROL[i1]) * r
    }

    private static func yawFrictionBoost(_ yawIn: Float, _ ebrake: Float, _ speed: Float, _ yawcontrol: Float, _ grade: Float) -> Float {
        let yaw = abs(yawIn)
        let r = 1 + abs(grade)
        if ebrake > 0.5 && yaw < 20 * .pi / 180 { return r }
        let boost = 0 + (1 - 0) * ((speed - 0) / 30)          // LowSpeed 0, HighSpeed 30, boosts 0…1
        return r + min(yaw * yawcontrol * boost, 0.35)        // MaxYawBonus
    }

    private func updateBurnout(_ dT: Float, _ mph: Float, _ maxSlip: Float, _ wheel: Int, _ yaw: Float) {
        if boState != 0 {
            if mph > 5 && abs(PM.angle2rad(yaw)) > 0.5 { boState = 0; boTime = 0; boTraction = 1; boAllow = 0 }
            else if maxSlip < 0.5 { boAllow += dT; if boAllow > 1 { boState = 0; boTime = 0; boTraction = 1; boAllow = 0 } }
            else { boAllow = 0; boTime -= dT; if boTime < 0 { boState -= 1; boTime = 2 } }
        } else if mph < 20 && maxSlip > 0.5 {
            let c = SuspensionRacer.burnoutFriction.value(maxSlip)
            boTraction = c / 1.4
            boState = Int(6 * (1.5 - c)) + (wheel & 1)
            boTime = 2; boAllow = 0
        }
    }

    private func tuneWheelParams(_ s: ChassisState, maxSpeedometer: Float) {
        let ebrake = s.ebrake, t = s.time
        let mph = PM.mps2mph(s.localVel.z)
        let carYaw = PM.angle2rad(s.slipangle)
        var yc = yawControl
        if ebrake >= 0.5 { yc = max(yc - 20 * t, 0.5) } else { yc = min(yc + 1 * t, 1) }
        yawControl = yc
        let brakeBiased = [s.brake, s.brake]
        yc *= 1 - driftValue
        let limit = calcYawControlLimit(s.speed, maxSpeedometer: maxSpeedometer)
        var maxSlip: Float = 0, maxWheel = 0
        for i in 0..<4 {
            let tire = tires[i]
            if s.gas > 0.8 && s.brake > 0.5 && abs(mph) < 10 && i >= 2 && tranny.TORQUE_SPLIT < 1 || (s.gas > 0.8 && s.brake > 0.5 && abs(mph) < 10 && i < 2 && tranny.TORQUE_SPLIT > 0) {
                tire.brake = abs(mph) * 0.05
            } else { tire.brake = brakeBiased[i >> 1] }
            if i >= 2 {
                var b = ebrake
                if ebrake > 0.2 && carYaw > 0.3 && mph < 80 { b += 0.5 }   // EBrake180Yaw / Speed
                tire.eBrake = b
            } else { tire.eBrake = 0 }
            var friction: Float = 1
            if i >= 2 {
                let boost = SuspensionRacer.yawFrictionBoost(carYaw, tire.eBrake, s.speed, limit, s.fwd.y) - 1
                friction = yc * boost + 1
            }
            tire.tractionBoost *= friction
            tire.lateralBoost = 1
            tire.tractionBoost *= s.nosBoost * s.shiftBoost
            if tire.slip > maxSlip { maxSlip = tire.slip; maxWheel = i }
        }
        if s.gear == Gear.first && s.gas >= 1 { updateBurnout(s.time, PM.mps2mph(s.localVel.z), maxSlip, maxWheel, s.slipangle) }
        else { boState = 0; boTime = 0; boTraction = 1; boAllow = 0 }
        doDrifting(s)
    }

    private var driftRB: RigidBody?
    private func doDrifting(_ s: ChassisState) {
        let change: Float = (driftState == 1 || driftState == 2) ? 8 : -2
        driftValue += change * s.time
        if driftValue <= 0 { driftState = 0; driftValue = 0 } else if driftValue >= 1 { driftState = 2; driftValue = 1 }
        let minSpeed = PM.mph2mps(30), slipLimit = PM.deg2angle(12)
        if driftState > 1 {
            let avg = inputAverage.value
            if s.localAngularVel.y * s.slipangle < 0 && abs(s.slipangle) <= 0.25 && s.speed > minSpeed && avg * s.slipangle <= 0 && abs(s.slipangle) > slipLimit {
                driftState = 2
            } else if s.gas * s.steer * s.slipangle > slipLimit && s.speed > minSpeed { driftState = 2 }
            else if s.gas * abs(s.slipangle) > slipLimit { driftState = 1 }
            else { driftState = 3 }
        } else if s.speed > PM.mph2mps(30) && (s.ebrake > 0.5 || abs(s.slipangle) > slipLimit) { driftState = 1 }
        guard driftValue > 0, let rb = driftRB else { return }
        let yaw = PM.angle2rad(s.slipangle), av = s.localAngularVel.y
        if yaw * av < 0 && numWheelsOnGround >= 2 {
            let coef = SuspensionRacer.driftStabilizer.value(abs(yaw)) * 4      // DriftRotationalStabalizer
            rb.resolveTorque(s.up * (driftValue * -av * coef * s.inertia.y))
        }
        let counter: Float = s.steer * yaw > 0 ? abs(s.steer) : 0
        let dc = abs(yaw) * 0.5 + counter * 4 + abs(av) * 0.5
        let rear = SuspensionRacer.driftRearFriction.value(dc * driftValue)
        tires[2].driftFriction = rear; tires[3].driftFriction = rear
    }

    // MARK: Tracción

    private func calcSplit(_ av: [Float], _ traction: [Bool], bias: Float, factor: Float, locked: Bool) -> [Float] {
        if !traction[0] || !traction[1] || locked || factor <= 0 { return [bias, 1 - bias] }
        let a0 = av[0] * (1 - bias), a1 = av[1] * bias
        let c = abs(a0 + a1)
        guard c > PM.epsilon else { return [bias, 1 - bias] }
        return [PM.clamp((1 - factor) * bias + factor * abs(a1) / c, 0, 1), PM.clamp((1 - factor) * (1 - bias) + factor * abs(a0) / c, 0, 1)]
    }

    private func doDriveForces(_ s: ChassisState, driveTorque: Float) {
        guard driveTorque != 0 else { return }
        var center: [Float]
        let cf = tranny.DIFFERENTIAL.count > 2 ? tranny.DIFFERENTIAL[2] : 0
        if cf > 0 {
            center = calcSplit([tires[0].av + tires[1].av, tires[2].av + tires[3].av],
                               [tires[0].isOnGround || tires[1].isOnGround, tires[2].isOnGround || tires[3].isOnGround],
                               bias: tranny.TORQUE_SPLIT, factor: cf, locked: false)
        } else { center = [tranny.TORQUE_SPLIT, 1 - tranny.TORQUE_SPLIT] }
        for axle in 0..<2 {
            let axleTorque = driveTorque * center[axle]
            guard abs(axleTorque) > PM.epsilon else { continue }
            var bias: Float = 0.5, fwdSlip: Float = 0, latSlip: Float = 0
            var tc: [Float] = [1, 1], tb: [Float] = [1, 1]
            let factor = axle < tranny.DIFFERENTIAL.count ? tranny.DIFFERENTIAL[axle] : 0
            var av: [Float] = [0, 0], tr = [false, false]
            for i in 0..<2 {
                let t = tires[axle * 2 + i]
                av[i] = t.av; tr[i] = t.isOnGround
                fwdSlip += center[axle] * t.slip * 0.5
                latSlip += center[axle] * t.lateralSpeed * 0.5
            }
            var locked = false
            if boState & 1 != 0 { tb[1] = boTraction; bias = boTraction * 0.5; locked = true }
            else if boState & 2 != 0 { tb[0] = boTraction; bias = 1 - boTraction * 0.5; locked = true }
            else {
                // Control de tracción en curva [D: Tweak_TractionControlMaxAngle 16, Tweak_TractionFowardSlip 20]
                let dLat = latSlip - s.localVel.x
                if dLat * s.steer > 0 && axleTorque * fwdSlip > 0 {
                    let dFwd = fwdSlip - s.localVel.z
                    var lim = PM.ramp(dFwd, 1, 20)
                    if lim > 0 {
                        let ang = abs(s.steer * PM.atan2d(dLat, abs(dFwd)))
                        lim *= PM.ramp(ang, 1, 16)
                        if lim > 0 {
                            if dLat > 0 { tc[1] = 1 - lim; tc[0] = 1 - lim * 0.5; tb[0] = lim + 1 }
                            else { tc[0] = 1 - lim; tc[1] = 1 - lim * 0.5; tb[1] = lim + 1 }
                        }
                    }
                }
            }
            let split = calcSplit(av, tr, bias: bias, factor: factor, locked: locked)
            for i in 0..<2 {
                let t = tires[axle * 2 + i]
                if t.isOnGround { t.applyDriveTorque(axleTorque * split[i] * tc[i]); t.tractionBoost *= tb[i] }
            }
        }
    }

    // MARK: Fuerzas de rueda

    private func doWheelForces(_ s: inout ChassisState, _ rb: RigidBody, ground: PhysicsGround, now: Float, maxSpeedometer: Float, humanSteering: Bool) {
        let dT = s.time
        // DoSteering
        let truesteer = humanSteering ? doHumanSteering(s, now: now) : PM.deg2angle(SuspensionRacer.absoluteMaxSteering * tireInfo.STEERING * s.steer)
        let ack = ackerman(truesteer, s)
        steerWheels = [ack.la, ack.ra]
        doWallSteer(s, rb)
        tuneWheelParams(s, maxSpeedometer: maxSpeedometer)

        var onGround = 0, maxDelta: Float = 0
        var shock = [Float](repeating: 0, count: 2), shockExt = shock, valving = shock, digression = shock, spring = shock
        var sway = shock, travel = shock, rh = shock, prog = shock
        for i in 0..<2 {
            shock[i] = PM.lbin2nm(chassis.SHOCK_STIFFNESS[i]); shockExt[i] = PM.lbin2nm(chassis.SHOCK_EXT_STIFFNESS[i])
            valving[i] = PM.inch2m(chassis.SHOCK_VALVING[i]); digression[i] = 1 - chassis.SHOCK_DIGRESSION[i]
            spring[i] = PM.lbin2nm(chassis.SPRING_STIFFNESS[i]); sway[i] = PM.lbin2nm(chassis.SWAYBAR_STIFFNESS[i])
            travel[i] = PM.inch2m(chassis.TRAVEL[i]); rh[i] = PM.inch2m(chassis.RIDE_HEIGHT[i]); prog[i] = chassis.SPRING_PROGRESSION[i]
        }
        var swayF = [Float](repeating: 0, count: 4)
        swayF[0] = (tires[0].compression - tires[1].compression) * sway[0]; swayF[1] = -swayF[0]
        swayF[2] = (tires[2].compression - tires[3].compression) * sway[1]; swayF[3] = -swayF[2]
        let normals = [ack.left, ack.right, s.fwd, s.fwd]

        var resolve = false
        for i in 0..<4 {
            let axle = i / 2, w = tires[i]
            w.updatePosition(body: rb, worldCog: s.worldCog, dT: dT, ground: ground, vehicleHeight: s.dimension.y * 2)
            let gN = V3(w.normal.x, w.normal.y, w.normal.z), fN = normals[i]
            let lat = PM.unitCross(gN, fN)
            let pen = w.normal.w
            let upness = PM.clamp(simd_dot(gN, s.up), 0, 1)
            var c = rh[axle] * upness + pen
            let maxC = travel[axle]
            if w.compression == 0 { maxDelta = max(maxDelta, c - maxC) }
            c = max(c, 0)
            if c > maxC { maxDelta = max(maxDelta, c - maxC); c = maxC; w.bottomOutTime = now }
            if c > 0 && upness > SuspensionRacer.enableRollStopsThreshold {
                onGround += 1
                var rise = (c - w.compression) / dT
                let springF = c * spring[axle] * (c * prog[axle] + 1)
                if valving[axle] > PM.epsilon && digression[axle] < 1 {
                    let ar = abs(rise)
                    if ar > valving[axle] { let dg = valving[axle] * powf(ar / valving[axle], digression[axle]); rise = rise > 0 ? dg : -dg }
                }
                var damp = rise > 0 ? rise * shock[axle] : rise * shockExt[axle]
                if damp > chassis.SHOCK_BLOWOUT * 9.81 * s.mass { damp = 0 }
                let sf = max(damp + springF + swayF[i], 0)
                let vertical = s.up * sf
                var cc = simd_cross(fN, gN); cc = simd_cross(cc, fN)
                let load = max(simd_dot(cc, gN) * 4 - 3, 0.3) * sf
                let xs = simd_dot(w.velocity, lat), zs = simd_dot(w.velocity, fN)
                let tf = w.updateLoaded(latVel: xs, fwdVel: zs, bodySpeed: s.speed, load: load, dT: dT)
                let maxT = abs(xs / dT * (0.25 * s.mass))
                let lateralF = lat * PM.clamp(tf, -maxT, maxT)
                let driveF = PM.unitCross(lat, gN) * w.longitudeForce
                w.force = lateralF + driveF + vertical
                resolve = true
            } else {
                w.force = .zero
                w.updateFree(dT)
            }
            if c == 0 { w.airTime += dT } else { w.airTime = 0 }
            w.setCompression(c)
        }
        if resolve {
            var tf = V3(0, 0, 0), tt = V3(0, 0, 0)
            for i in 0..<4 {
                let w = tires[i]
                var p = w.localArm; p.y += w.compression - rh[i / 2]
                p = s.rotate(p) + s.position
                w.position = p
                tf += w.force; tt += simd_cross(p - s.worldCog - s.position, w.force)
            }
            // El par de giro (eje arriba) de los neumáticos se escala por YAW_SPEED [D]
            let yaw = simd_dot(s.up, tt)
            tt += s.up * (yaw * tireInfo.YAW_SPEED - yaw)
            rb.resolve(force: tf, torque: tt)
        }
        if maxDelta > 0 {
            for w in tires { w.position.y += maxDelta }
            rb.position.y += maxDelta                     // ModifyYPos
        }
        if onGround != 0 && numWheelsOnGround == 0 {
            var l = s.localAngularVel; l.z *= 0.5; l.y *= 0.5
            s.localAngularVel = l; s.angularVel = s.rotate(l); rb.angularVel = s.angularVel
        }
        numWheelsOnGround = onGround
    }

    // MARK: Estabilizador en saltos y reposo

    private func doJumpStabilizer(_ s: ChassisState, _ rb: RigidBody, ground: PhysicsGround) {
        // GetGroundNormal del cuerpo: suelo bajo el centro (w = −altura) [I: RigidBody no expone cómo lo calcula]
        let wp = PM.toWorld(s.position)
        var gn = V3(0, 1, 0), altitude: Float = 0
        if let g = ground.ground(x: wp.x, y: wp.y, z: wp.z, step: 0.5) { gn = PM.toGame(g.normal); if gn.y < 0 { gn = -gn }; altitude = wp.z - g.z }
        let groundDot = simd_dot(s.up, gn)
        var dTorque = V3(0, 0, 0), dForce = V3(0, 0, 0), resolve = false
        if numWheelsOnGround == 0 {
            jumpTime += s.time; jumpAltitude = max(jumpAltitude, altitude)
            var accel: Float = 3                                       // fExtraLandingGravity
            if jumpTime > 1 && groundDot > 0.96 && jumpAltitude > 2 && s.linearVel.y < 0 && altitude < 6 {
                accel += (1 - PM.ramp(altitude, 0, 6)) * 10 * PM.ramp(s.speed, 0, 20)
            }
            dForce += V3(0, -s.mass * accel, 0); resolve = true
        } else { jumpTime = 0; jumpAltitude = 0 }
        if numWheelsOnGround < 2 && s.up.y > 0.8 && numWheelsOnGround == 0 {
            let damping = PM.ramp(s.speed, 0, 5) * SuspensionRacer.jumpStabilization.value(simd_length(s.localAngularVel))
            var m = s.localAngularVel * s.inertia * -damping
            m.y = 0
            dTorque += s.rotate(m); resolve = true
        }
        if numWheelsOnGround == 0 && gn.y > 0.9 && s.up.y > 0.1 && groundDot > 0.8 && altitude > PM.uEpsilon {
            let altRamp = 1 - PM.ramp(altitude, 0, 15), spRamp = PM.ramp(s.speed, 0, 5)
            let flatFwd = PM.unitCross(s.right, gn)
            var dot = simd_dot(flatFwd, s.fwd)
            if dot < 0.99 { dTorque += PM.unitCross(flatFwd, s.fwd) * (s.mass * spRamp * altRamp * 40 * (dot - 1)); resolve = true }
            let flatRight = PM.unitCross(gn, s.fwd)
            dot = simd_dot(flatRight, s.right)
            if dot < 0.99 { dTorque += PM.unitCross(flatRight, s.right) * (s.mass * spRamp * 20 * altRamp * (dot - 1)); resolve = true }
        }
        if resolve { rb.resolve(force: dForce, torque: dTorque) }
    }

    /// Chassis::DoSleep (coincide al 100 % con el binario). Ojo: la rama lateral vuelve a sumar con Resolve la fuerza y el par
    /// locales con x (fuerza) e y (par) cambiados: en total la parte lateral queda × velocidad y el resto se duplica [D].
    private func doSleep(_ s: ChassisState, _ rb: RigidBody) {
        if s.speed < 0.5 && numWheelsOnGround == 4 && s.brake + s.ebrake > 0 && s.gas == 0 && simd_length(s.angularVel) < 0.25 && !rb.hadCollision {
            rb.damp(s.speed < PM.uEpsilon ? 1 : 1 - s.speed)
            for t in tires { t.av = 0 }
            return
        }
        if s.speed < 1 && simd_length(s.angularVel) < 0.25 && s.gas <= 0 {
            var v = s.localVel, w = s.localAngularVel
            let f = rb.toLocal(rb.force), t = rb.toLocal(rb.torque)
            v.x *= s.speed; w.y *= s.speed
            rb.resolve(force: s.rotate(V3(-f.x * (1 - s.speed), f.y, f.z)), torque: s.rotate(V3(t.x, -t.y * (1 - s.speed), t.z)))
            rb.linearVel = s.rotate(v); rb.angularVel = s.rotate(w)
        }
    }

    // MARK: Paso

    /// SuspensionRacer::OnTaskSimulate.
    /// Conductor de la IA (rivales de carrera): dirección directa (DoSteering sin DoHumanSteering) [D].
    var aiDriver = false

    func simulate(_ dT: Float, rb: RigidBody, controls: Controls, engine: EngineRacer, ground: PhysicsGround, now: Float) {
        setCOG(rb)
        var s = computeState(rb, dT, controls, gear: engine.gear, nosBoost: engine.nosBoost)
        collisionTimer = max(collisionTimer - dT, 0)
        let maxSlip = SuspensionRacer.computeMaxSlip(s), grip = SuspensionRacer.lateralGripScale(s), traction = SuspensionRacer.tractionScale(s)
        let steerDrag = PM.lerp(0.15, 1, gameBreaker)       // Tweak_SteerDragReduction
        for t in tires { t.beginFrame(maxSlip: maxSlip, gripBoost: grip, tractionBoost: traction, dragReduction: steerDrag) }
        doAerodynamics(s, rb)
        doDriveForces(s, driveTorque: engine.driveTorque)
        driftRB = rb
        doWheelForces(&s, rb, ground: ground, now: now, maxSpeedometer: engine.maxSpeedometer, humanSteering: !aiDriver)
        wallNoseTurn = 0; wallSideTurn = 0
        doJumpStabilizer(s, rb, ground: ground)
        doSleep(s, rb)
    }
}
