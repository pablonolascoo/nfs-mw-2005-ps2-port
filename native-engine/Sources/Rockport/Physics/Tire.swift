// Rueda + neumático [D: Physics/Wheel.h, Common/Wheel.cpp UpdatePosition, World/Common/WWorldPos.cpp Update;
// Behaviors/SuspensionRacer.cpp SuspensionRacer::Tire]. Copia línea a línea; espacio del juego (y arriba).
import simd

/// Suelo para la física: la colisión real (CollisionWorld) o un plano (pruebas).
protocol PhysicsGround: AnyObject {
    /// Suelo bajo (x, y) del mundo (Z arriba): triángulo más alto no más de `step` m por encima de z.
    func ground(x: Float, y: Float, z: Float, step: Float) -> (z: Float, normal: float3)?
    /// Muros verticales cerca de un punto: (a, b en planta, zMin, zMax).
    func walls(near p: SIMD2<Float>, radius: Float) -> [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)]
}

/// Plano infinito a altura `z` (prueba de física sin mapa).
final class FlatGround: PhysicsGround {
    let z: Float
    init(z: Float = 0) { self.z = z }
    func ground(x: Float, y: Float, z q: Float, step: Float) -> (z: Float, normal: float3)? { z <= q + step ? (z, float3(0, 0, 1)) : nil }
    func walls(near p: SIMD2<Float>, radius: Float) -> [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)] { [] }
}

// MARK: - Tablas del neumático [D: SuspensionRacer.cpp]

enum TireTables {
    /// Fuerza lateral según carga (kN, 0…10) y ángulo de deriva (0, 2, 4… 12°).
    static let loadSensitivity: [PTable] = [
        PTable([0, 0, 0, 0, 0, 0], 0, 10),
        PTable([0, 1.2, 2.3, 3.0, 3.0, 2.8], 0, 10),
        PTable([0, 1.7, 3.2, 4.3, 5.1, 5.2], 0, 10),
        PTable([0, 1.8, 3.5, 4.9, 5.8, 6.1], 0, 10),
        PTable([0, 1.83, 3.6, 5.0, 5.96, 6.4], 0, 10),
        PTable([0, 1.86, 3.7, 5.1, 6.13, 6.7], 0, 10),
        PTable([0, 1.9, 3.8, 5.2, 6.3, 7.1], 0, 10),
    ]
    static let newCorneringScale: Float = 1000
    static let loadFactor: Float = 0.8
    static let gripFactor: Float = 2.5          // PS2: sin la variable con DRM del PC
    static let brakingTorque: Float = 4
    static let eBrakingTorque: Float = 10
    static let rollingFriction: Float = 2
    static let wheelMomentOfInertia: Float = 10
    static let tireForceEllipseRatio: Float = 1.5
    static let staticToDynamicBrakeForceRatio: Float = 1.2
    static let brakeLockAngularVelocityFactor: Float = 100
}

final class Tire {
    // Wheel
    var normal = SIMD4<Float>(0, 1, 0, -1)    // xyz normal del suelo, w = penetración (WWorldPos::Update)
    var position = V3(0, 0, 0)
    var force = V3(0, 0, 0)
    var airTime: Float = 0
    var localArm = V3(0, 0, 0)
    var worldArm = V3(0, 0, 0)
    var velocity = V3(0, 0, 0)
    private(set) var compression: Float = 0
    var bottomOutTime: Float = 0
    func setCompression(_ c: Float) { compression = max(c, 0) }
    var isOnGround: Bool { compression > 0 }
    /// Superficie (simsurface): la colisión exportada no guarda el material → default = 1 [V: simsurface/default].
    var lateralGrip: Float = 1, driveGrip: Float = 1, rollingResistance: Float = 1

    // SuspensionRacer::Tire
    let radius: Float
    let wheelIndex: Int, axleIndex: Int
    let staticGrip: Float, dynamicGrip: Float, gripScale: Float
    let brakeSpec: Float, eBrakeSpec: Float, brakeLock: Float
    var brake: Float = 0, eBrake: Float = 0
    var av: Float = 0                  // rad/s
    var load: Float = 0
    var lateralForce: Float = 0, longitudeForce: Float = 0
    var driveTorque: Float = 0, brakeTorque: Float = 0
    var lateralBoost: Float = 1, tractionBoost: Float = 1
    var slip: Float = 0
    var lastTorque: Float = 0
    var roadSpeed: Float = 0
    var angularAcc: Float = 0
    var traction: Float = 1
    var slipAngle: Float = 0           // "Angle" (vueltas)
    var tractionCircle = SIMD2<Float>(1, 1)
    var maxSlip: Float = 0.5
    var gripBoost: Float = 1
    var driftFriction: Float = 1
    var lateralSpeed: Float = 0
    var brakeLocked = false
    var lastSign = 1                   // 0 positivo, 1 cero, 2 negativo
    var dragReduction: Float = 0

    init(radius: Float, index: Int, tires: VehicleSpecs.Tires, brakes: VehicleSpecs.Brakes) {
        self.radius = max(radius, 0.1)
        wheelIndex = index; axleIndex = index >> 1
        staticGrip = tires.STATIC_GRIP[axleIndex]; dynamicGrip = tires.DYNAMIC_GRIP[axleIndex]; gripScale = tires.GRIP_SCALE[axleIndex]
        brakeSpec = PM.ftlb2nm(brakes.BRAKES[axleIndex]) * TireTables.brakingTorque
        eBrakeSpec = PM.ftlb2nm(brakes.EBRAKE) * TireTables.eBrakingTorque
        brakeLock = brakes.BRAKE_LOCK[axleIndex]
    }

    var isSteeringWheel: Bool { wheelIndex < 2 }
    /// Ojo: en el juego IsSlipping() devuelve mTraction >= 1 [D].
    var isSlipping: Bool { traction >= 1 }
    var totalTorque: Float { driveTorque + brakeTorque }
    func applyDriveTorque(_ t: Float) { if !brakeLocked { driveTorque += t } }
    func applyBrakeTorque(_ t: Float) { if !brakeLocked { brakeTorque += t } }

    func reset() {
        av = 0; load = 0; slip = 0; traction = 1; brakeLocked = false; lastSign = 1; roadSpeed = 0; angularAcc = 0
        lastTorque = 0; compression = 0; normal = SIMD4(0, 1, 0, -1); airTime = 0
    }

    func matchSpeed(_ speed: Float) {
        av = speed / radius; roadSpeed = speed; traction = 1; brakeLocked = false; slip = 0
        angularAcc = 0; lastTorque = 0; brake = 0; eBrake = 0; lateralSpeed = 0
    }

    func beginFrame(maxSlip: Float, gripBoost: Float, tractionBoost: Float, dragReduction: Float) {
        self.maxSlip = maxSlip; driveTorque = 0; brakeTorque = 0; force = .zero
        lateralForce = 0; longitudeForce = 0; tractionCircle = SIMD2(1, 1)
        self.tractionBoost = tractionBoost; self.gripBoost = gripBoost; driftFriction = 1; self.dragReduction = dragReduction
    }

    /// Wheel::UpdatePosition: brazo en mundo, velocidad del punto y suelo bajo él (WWorldPos::Update → normal.w = penetración).
    func updatePosition(body: RigidBody, worldCog: V3, dT: Float, ground: PhysicsGround, vehicleHeight: Float) {
        worldArm = body.rotate(localArm)
        position = worldArm + body.position
        velocity = simd_cross(body.angularVel, worldArm - worldCog) + body.linearVel
        let tol = min(max(-velocity.y * dT, 0) + radius + simd_length(SIMD2(velocity.x, velocity.z)) * dT, vehicleHeight * 0.5)
        let w = PM.toWorld(position)
        if let g = ground.ground(x: w.x, y: w.y, z: w.z, step: tol) {
            var n = PM.toGame(g.normal)
            if n.y < 0 { n = -n }
            if n.y >= 0.9999 { n.y = 0.9999 }          // WWorldPos::UNormal
            // Punto de la cara bajo la rueda: misma planta, altura del suelo → w = (cara − pos) · n
            let face = PM.toGame(float3(w.x, w.y, g.z))
            normal = SIMD4(n.x, n.y, n.z, simd_dot(face - position, n))
        } else {
            normal.w = -1
        }
    }

    // MARK: SuspensionRacer::Tire

    func computeLateralForce(_ load: Float, _ slipAngle: Float) -> Float {
        let angle = PM.angle2deg(slipAngle)
        let norm = angle * 0.5
        let table = Int(norm)
        let kn = load * 0.001 * TireTables.loadFactor
        let extra = norm - Float(table)
        let k = gripScale * TireTables.newCorneringScale * gripBoost * TireTables.gripFactor
        if table > 5 { return k * TireTables.loadSensitivity[6].value(kn) }
        let lo = TireTables.loadSensitivity[table].value(kn), hi = TireTables.loadSensitivity[table + 1].value(kn)
        return k * (extra * (hi - lo) + lo)
    }

    func pilotFactor(_ speed: Float) -> Float {
        if brakeLocked || av < 0 || isSteeringWheel { return 1 }
        let v = PM.clamp((speed - PM.mph2mps(30)) / PM.mph2mps(20), 0, 1)
        return v * (1 - 0.85) + 0.85
    }

    func checkForBrakeLock(_ groundForce: Float) {
        let brakeLockSpec = brakeLock * brakeSpec
        let available = (brake * brakeLockSpec + eBrake * eBrakeSpec) * TireTables.staticToDynamicBrakeForceRatio
        if available > groundForce * radius + abs(av) * TireTables.brakeLockAngularVelocityFactor {
            brakeLocked = available > 1
            av = 0
        } else { brakeLocked = false }
    }

    func checkSign() {
        if lastSign == 0 { if av < 0 { av = 0 } } else if lastSign == 2 && av > 0 { av = 0 }
        lastSign = av > PM.epsilon ? 0 : (av < -PM.epsilon ? 2 : 1)
    }

    func updateFree(_ dT: Float) {
        load = 0; slip = 0; traction = 0; slipAngle = 0
        checkForBrakeLock(0)
        if brakeLocked { angularAcc = 0; av = 0 } else {
            let bt = brake * brakeSpec, ebt = eBrake * eBrakeSpec
            applyBrakeTorque(av > 0 ? -bt : bt)
            applyBrakeTorque(av > 0 ? -ebt : ebt)
            angularAcc = totalTorque / TireTables.wheelMomentOfInertia
            av += angularAcc * dT
        }
        checkSign()
        lateralForce = 0; longitudeForce = 0
    }

    func updateLoaded(latVel: Float, fwdVel: Float, bodySpeed: Float, load newLoad: Float, dT: Float) -> Float {
        if load <= 0 && !brakeLocked { av = fwdVel / radius }
        let fwdAcc = (fwdVel - roadSpeed) / dT
        roadSpeed = fwdVel
        load = max(newLoad, 0)
        lateralSpeed = latVel

        var bt = brake * brakeSpec, ebt = eBrake * eBrakeSpec
        let absFwd = abs(fwdVel)
        if absFwd < 1 {
            bt = -brake * newLoad * fwdVel / radius
            ebt = -eBrake * newLoad * fwdVel / radius
            applyDriveTorque(-driveTorque * eBrake)
            applyBrakeTorque(bt); applyBrakeTorque(ebt)
        } else {
            applyBrakeTorque(av > 0 ? -bt : bt)
            applyBrakeTorque(av > 0 ? -ebt : ebt)
        }

        slipAngle = PM.atan2a(latVel, absFwd)
        var groundFriction: Float = 0
        let slipSpeed = av * radius - fwdVel
        var dynamicFriction: Float = 1
        slip = slipSpeed
        let skidSpeed = (slipSpeed * slipSpeed + latVel * latVel).squareRoot()
        let pilot = pilotFactor(bodySpeed)
        if skidSpeed > PM.epsilon && (latVel != 0 || fwdVel != 0) {
            dynamicFriction = dynamicGrip * tractionBoost * pilot
            groundFriction = load * dynamicFriction / skidSpeed
            let slipGroundFriction = load * dynamicFriction / (fwdVel * fwdVel + latVel * latVel).squareRoot()
            checkForBrakeLock(absFwd * slipGroundFriction)
        }

        if traction < 1 || brakeLocked {
            longitudeForce = groundFriction * slipSpeed
            lateralForce = -groundFriction * latVel
            if bodySpeed < PM.mph2mps(1) && dynamicFriction > 0.1 { lateralForce /= dynamicFriction; longitudeForce /= dynamicFriction }
            longitudeForce = PM.limit(longitudeForce, totalTorque / radius)
        } else {
            brakeLocked = false
            longitudeForce = totalTorque / radius
            lateralForce = computeLateralForce(load, abs(slipAngle))
            if latVel > 0 { lateralForce = -lateralForce }
        }

        lateralForce *= lateralBoost
        if traction >= 1 && !brakeLocked {
            let accDiff = angularAcc * radius - fwdAcc
            longitudeForce += accDiff * TireTables.wheelMomentOfInertia / radius
        }
        var useEllipse = false
        if totalTorque * fwdVel > 0 && !brakeLocked { useEllipse = true; longitudeForce *= TireTables.tireForceEllipseRatio }
        lateralForce *= tractionCircle.x
        longitudeForce *= tractionCircle.y

        let lenForce = (lateralForce * lateralForce + longitudeForce * longitudeForce).squareRoot()
        let maxForce = load * staticGrip * tractionBoost * driftFriction * pilot
        traction = 1
        var maxSlipNow = maxSlip
        if lenForce > maxForce && lenForce > 0.001 {
            let ratio = maxForce / lenForce
            traction = ratio; lateralForce *= ratio; longitudeForce *= ratio
            maxSlipNow = ratio * ratio * maxSlipNow
        } else if useEllipse { longitudeForce /= TireTables.tireForceEllipseRatio }
        if abs(slipSpeed) > maxSlipNow { traction *= maxSlipNow / abs(slipSpeed) }

        lateralForce *= lateralGrip
        longitudeForce *= driveGrip
        if fwdVel > 1 {
            longitudeForce -= PM.sina(slipAngle) * lateralForce * dragReduction / gripScale
        } else {
            lateralForce *= min(abs(latVel), 1)
        }

        if brakeLocked { angularAcc = 0 } else {
            if traction < 1 {
                let torque = (totalTorque - longitudeForce * radius + lastTorque) * 0.5
                lastTorque = torque
                let effective = torque - av * TireTables.rollingFriction * rollingResistance
                angularAcc = effective / TireTables.wheelMomentOfInertia - traction * slip / (radius * dT)
            }
            angularAcc = PM.lerp(angularAcc, fwdAcc / radius, traction)
        }
        av += angularAcc * dT
        checkSign()
        return lateralForce
    }
}
