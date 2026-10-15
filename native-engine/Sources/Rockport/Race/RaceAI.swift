// Conductor de la IA para los rivales de carrera: conduce un coche con la física del juego (Car + PVehicle) igual que
// el juego conduce a sus corredores, sin atajos cinemáticos.
//
//  - Velocidad deseada (AIActionRace::Update) [D: AI/Actions/AIActionRace.cpp]: fPotentialSpeed sale de la curvatura de la
//    ruta por delante con GetSpeedLimit(curvatura, f0 = agarre estático, f1 = (agarre aerodinámico − f0)/punta), escalada
//    por AiSpeedScaleTable(habilidad); fSpeedLimit sube como mucho a la aceleración potencial (AiAccelScaleTable ×
//    AiCatchupAcceleration(trampa de alcance)) con el exponente Lerp(1,5, 2, habilidad), y nunca pasa de la potencial.
//    Añadido propio [I]: la potencial se anticipa con la distancia de frenada (v² = v_curva² + 2·a·d), porque aquí la
//    ruta es fija y el coche frena con la física real.
//  - Gas y freno (AIVehiclePid::OnGasBrake) [D: AIVehicleRacecar.cpp]: mThrottleBrake += −0,4·e − 0,01·∫e − 0,1·de/dt
//    con e = v − v_deseada (PidError de 4 términos), recortado a ±1.
//  - Dirección (AIVehiclePid::OnSteering) [D]: error de rumbo del cuerpo hacia el punto objetivo, PID con las tablas
//    PidProportional/Integral/DerivativeTable por debajo de 10 m/s; por encima, el juego adapta los coeficientes (MIT) entre
//    los límites SteeringPid{Min,Max}{P,I,D}Coefficient: aquí se fijan en su punto medio [I]. Salida / dirección máxima.
//  - Habilidad (AIPerpVehicle::ComputeSkill / Update) [D: AIVehicle.cpp]: base = SkillLevel/100 (carrera) o
//    Tweak_QuickRaceSkills[dificultad] (carrera rápida); «pegamento» (glue) = PID del error de distancia con el jugador
//    (RaceLength/100 × (%jugador − %rival)) cada 1 s, 10 términos de integral y 5 de derivada; ComputeCatchUpSkill no está
//    decompilado: se usa CatchUpSpread como escala del error y CatchUpIntegral/Derivative como ganancias, recortado a
//    ±CatchUpSkill [I]. Luego × CatchupGlueTable o SlowDownGlueTable [D]. Trampa de alcance =
//    Clamp(base + glue − 1, 0, 1) × 0,5 [D: GetCatchupCheat].
//  - NOS (AIActionRace::Update) [D]: se enciende si la diferencia de velocidad y de aceleración lo piden y ha pasado
//    Lerp(20, 4, habilidad) s apagado; se apaga tras Lerp(2, 4, habilidad) s si la diferencia baja.
import Foundation
import simd

/// PidError del juego: historial de muestras con integral (últimos N) y derivada (pendiente de los últimos M).
struct PidHistory {
    let nI: Int, nD: Int
    private var errs: [Float] = [], dts: [Float] = []
    init(integral: Int, derivative: Int) { nI = integral; nD = derivative }
    mutating func record(_ e: Float, _ dt: Float) {
        errs.append(e); dts.append(max(dt, 1e-4))
        let keep = max(nI, nD) + 1
        if errs.count > keep { errs.removeFirst(errs.count - keep); dts.removeFirst(dts.count - keep) }
    }
    var error: Float { errs.last ?? 0 }
    var integral: Float {
        var s: Float = 0
        for i in max(0, errs.count - nI)..<errs.count { s += errs[i] * dts[i] }
        return s
    }
    var derivative: Float {
        guard errs.count >= 2 else { return 0 }
        let k = min(nD, errs.count - 1)
        var t: Float = 0
        for i in (errs.count - k)..<errs.count { t += dts[i] }
        return (errs[errs.count - 1] - errs[errs.count - 1 - k]) / max(t, 1e-4)
    }
    mutating func reset() { errs.removeAll(); dts.removeAll() }
}

/// Tablas del juego [D: AIActionRace.cpp, AIVehicleRacecar.cpp, AIVehicle.cpp].
enum RaceAITables {
    static let speedScale = PTable([0.85, 1.0], 0, 1)
    static let accelScale = PTable([0.65, 1.0], 0, 1)
    static let accelScaleDrag = PTable([0.82, 1.0], 0, 1)
    static let catchupAccel = PTable([1.0, 1.33, 1.66, 2.0], 0, 1)
    static let corneringScale = PTable([0.36, 0.9], 0, 1)
    static let navLookAhead = PTable([30, 100], 0, 100)
    static let nosScale = PTable([0.25, 1.0], 0, 1)
    static let pidP = PTable([0.328, 0.22, 0.148, 0.115, 0.09, 0.074, 0.057, 0.049, 0.043, 0.04], 0, 160)
    static let pidD = PTable([0.0, 0.075829, 0.075829, 0.073826, 0.060403, 0.04698, 0.04698, 0.040268, 0.040268, 0.040268], 0, 160)
    static let pidI = PTable([0.21, 0.244, 0.267, 0.29, 0.305, 0.321, 0.328, 0.336, 0.341, 0.344], 0, 160)
    static let catchupGlue = PTable([0.33, 0.66, 1.0], 0, 1)
    static let slowDownGlue = PTable([1.0, 1.0, 0.66], 0, 1)
    static let catchupCheat = PTable([0.5, 0.5, 0.5], 0, 1)
    /// Tweak_QuickRaceSkills / …NoGlue por dificultad (fácil, media, difícil).
    static let quickRaceSkills: [Float] = [0.15, 0.4, 1.0]
    static let quickRaceSkillsNoGlue: [Float] = [0.15, 0.4, 0.8]

    /// GetSpeedLimit [D]: velocidad máxima en una curva de curvatura κ con agarre lateral f0 + f1·v (en g).
    static func speedLimit(curvature: Float, f0: Float, f1: Float, top: Float) -> Float {
        let g: Float = 9.8
        let gf1 = f1 * g, k = abs(curvature)
        let num = gf1 + sqrt(gf1 * gf1 + k * 4 * g * f0)
        return num / max(num / max(0.1, top), 2 * k)
    }
}

/// Parámetros de rubber-banding de la prueba (CatchUp*) [V].
struct RaceCatchUpParams {
    var enabled = true
    var skill: Float = 0.2
    var spread: Float = 1000
    var integral: Float = 0.00005
    var derivative: Float = 0.001
    init() {}
    init(_ c: RaceCatchUp) {
        enabled = c.enabled
        skill = c.skill.first ?? 0.2
        spread = max(1, c.spread.first ?? 1000)
        integral = c.integral; derivative = c.derivative
    }
}

final class RaceDriver {
    let car: Car
    unowned let route: RaceRoute
    let isDrag: Bool
    /// Habilidad base (fBaseSkill) 0…1.
    var baseSkill: Float
    private(set) var glueSkill: Float = 0
    var catchUp: RaceCatchUpParams
    /// Desplazamiento lateral preferido (m, + = derecha) para que los rivales no vayan en fila.
    var laneOffset: Float
    private var lateral: Float
    private var avoidTimer: Float = 0

    // Potencias (ComputePotentials) [D]
    private(set) var topSpeed: Float = 60
    private var startGrip: Float = 1.5, endGrip: Float = 2
    private var hasNOS = false

    // Estado de AIActionRace
    private(set) var speedLimit: Float = 0
    private(set) var potentialSpeed: Float = 0
    private var lastSpeed: Float = 0
    private var nosTimer: Float = 0
    private var nosOn = false
    // AIVehiclePid
    private var throttleBrake: Float = 0
    private var velErr = PidHistory(integral: 4, derivative: 4)
    private var bodyErr = PidHistory(integral: 5, derivative: 5)
    // Pegamento (glue)
    private var glueErr = PidHistory(integral: 10, derivative: 5)
    private var glueTimer: Float = 0
    /// Bloqueado (para reiniciar como AIActionGetUnstuck / reset fuera de pantalla).
    private(set) var stuckTime: Float = 0
    private var lastProgress: Float = 0

    init(car: Car, route: RaceRoute, skill: Float, catchUp: RaceCatchUpParams, laneOffset: Float, drag: Bool, player: Car?, minPerformance: Float) {
        self.car = car; self.route = route; baseSkill = max(0, min(1, skill)); self.catchUp = catchUp
        self.laneOffset = laneOffset; lateral = laneOffset; isDrag = drag
        car.vehicle?.susp.aiDriver = true
        computePotentials(player: player, minPerformance: minPerformance)
    }

    var skill: Float { max(0, min(1, baseSkill + glueSkill)) }
    var catchupCheat: Float { max(0, min(1, baseSkill + glueSkill - 1)) * RaceAITables.catchupCheat.value(baseSkill) }

    /// ComputePotentials [D]: con el sesgo de rendimiento (MinimumAIPerformance), la punta y el agarre del rival se
    /// acercan a los del jugador: Lerp(mín(jugador, propio), propio, sesgo) [I: Ramp de PerformaTor sin detalle].
    func computePotentials(player: Car?, minPerformance: Float) {
        guard let v = car.vehicle else { return }
        let bias = max(0, min(1, minPerformance))
        func grips(_ s: VehicleSpecs, top: Float) -> (Float, Float) {
            let g = s.rigidbody.GRAVITY > 0 ? s.rigidbody.GRAVITY : 9.81
            let start = min(s.tires.STATIC_GRIP.first ?? 1.5, s.tires.STATIC_GRIP.last ?? 1.5)
            let down = top * 2 * s.chassis.AERO_COEFFICIENT * 1000 / max(s.mass, 1) + g     // Info::AerodynamicDownforce
            return (start, start * down / g)
        }
        let myTop = v.engine.maxSpeedometer
        let (ms, me) = grips(v.specs, top: myTop)
        var top = myTop, sg = ms, eg = me
        if let pv = player?.vehicle {
            let pTop = pv.engine.maxSpeedometer
            let (ps, pe) = grips(pv.specs, top: pTop)
            top = PM.lerp(min(pTop, myTop), myTop, bias)
            sg = PM.lerp(min(ps, ms), ms, bias); eg = PM.lerp(min(pe, me), me, bias)
        }
        topSpeed = max(20, top); startGrip = sg; endGrip = eg
        hasNOS = v.engine.hasNOS
    }

    func resetState() {
        throttleBrake = 0; velErr.reset(); bodyErr.reset(); speedLimit = 0; lastSpeed = 0; stuckTime = 0
        nosOn = false; nosTimer = 0; lateral = laneOffset
    }

    /// Pegamento (AIPerpVehicle::Update): error en metros = longitud/100 × (%medio de los jugadores − %propio) [D].
    func updateGlue(dt: Float, myPct: Float, playerPct: Float, raceLength: Float, speedtrap: Bool) {
        guard catchUp.enabled else { glueSkill = 0; return }
        glueTimer += dt
        if glueTimer > 1 {
            let err = raceLength / 100 * (playerPct - myPct)
            glueErr.record(err, glueTimer)
            glueTimer -= 1
        }
        // ComputeCatchUpSkill [I]
        let x = glueErr.error / catchUp.spread + glueErr.integral * catchUp.integral + glueErr.derivative * catchUp.derivative
        var g = max(-1, min(1, x)) * max(0, catchUp.skill)
        if g > 0 { g *= speedtrap ? 0.5 : RaceAITables.catchupGlue.value(baseSkill) }
        else if g < 0 { g *= speedtrap ? 0.5 : RaceAITables.slowDownGlue.value(baseSkill) }
        glueSkill = g
    }

    /// Entrada del conductor para este fotograma. `progress` = distancia en la ruta; `others` = coches cercanos (rivales,
    /// jugador y tráfico) para no echarse encima.
    func drive(dt: Float, progress: Float, lateralNow: Float, others: [(pos: float3, vel: float3, halfWidth: Float)], stop: Bool, staging: Bool) -> DriverInput {
        var d = DriverInput()
        guard let v = car.vehicle, dt > 0 else { return d }
        let speed = v.forwardSpeed
        let sk = skill

        // — AIActionRace: velocidad potencial por curvatura (con frenada anticipada) —
        let decel: Float = 7.5 + 2 * sk
        var potential = topSpeed
        let horizon = max(40, speed * speed / (2 * decel) + 30)
        var dd: Float = 0
        while dd < horizon {
            let k = route.curvature(at: progress + dd, span: 12)
            let f0 = startGrip
            // Margen propio [I]: la física de este motor no da todo el agarre aerodinámico que supone la IA del juego
            let f1 = (PM.lerp(startGrip, endGrip, RaceAITables.corneringScale.value(sk) * 0.5) - startGrip) / max(topSpeed, 1)
            let vc = RaceAITables.speedLimit(curvature: k, f0: f0 * 0.9, f1: f1, top: topSpeed) * RaceAITables.speedScale.value(sk) * 0.9
            potential = min(potential, sqrt(vc * vc + 2 * decel * max(0, dd - 6)))
            dd += 8
        }
        if progress + 10 >= route.length { potential = min(potential, topSpeed) }
        potentialSpeed = potential
        let estAccel = max(0.5, 9 * (1 - (max(speed, speedLimit) / max(topSpeed, 1)) * (max(speed, speedLimit) / max(topSpeed, 1))))
        let accelScale = isDrag ? RaceAITables.accelScaleDrag.value(sk) : RaceAITables.accelScale.value(sk)
        let potentialAccel = max(0, estAccel * accelScale * (nosOn ? 1.3 : 1) * RaceAITables.catchupAccel.value(catchupCheat))
        let actualAccel = (speed - lastSpeed) / dt
        lastSpeed = speed
        if actualAccel < 0 && speedLimit < potential && speedLimit > speed {
            speedLimit += min(potentialAccel + actualAccel, 0) * dt
        }
        if speedLimit < potential {
            let t = max(0, min(1, speedLimit / max(potential, 0.1)))
            let e = PM.lerp(1.5, 2, sk)
            let delta = max(0, min(potentialAccel, potentialAccel - actualAccel * powf(t, e)))
            speedLimit += delta * dt
        }
        speedLimit = max(0, min(speedLimit, potential))
        var driveSpeed = stop ? 0 : speedLimit
        if staging { driveSpeed = 0 }

        // — Carril: separación de los demás coches (bSeparationBySteering) [D: idea; detalle propio I] —
        let here = route.sample(progress)
        let left = -here.left + 1.2, right = here.right - 1.2
        var want = laneOffset
        avoidTimer -= dt
        let fwd = here.tangent, rgt = float3(fwd.y, -fwd.x, 0)
        for o in others {
            let rel = o.pos - car.position
            if abs(rel.z) > 4 { continue }
            let ahead = simd_dot(rel, fwd)
            if ahead < 2 || ahead > max(25, speed * 1.6) { continue }
            let closing = speed - simd_dot(o.vel, fwd)
            if closing < 1 && ahead > 8 { continue }
            // lado del otro coche medido desde la ruta a su altura (no desde nuestro coche)
            let there = route.sample(progress + ahead)
            let side = simd_dot(o.pos - there.p, float3(there.tangent.y, -there.tangent.x, 0))
            if abs(side - lateral) < o.halfWidth + car.halfWidth + 0.6 + max(0, closing) * 0.04 {
                // hacia el lado con más hueco (dentro de la calzada)
                let gapW = o.halfWidth + car.halfWidth + 0.8
                let toLeft = max(left, min(right, side - gapW)), toRight = max(left, min(right, side + gapW))
                want = abs(toLeft - side) >= abs(toRight - side) ? toLeft : toRight
                avoidTimer = 1.0
                // Sin hueco suficiente: frenar a tiempo detrás de él
                let clear = abs(want - side) - o.halfWidth - car.halfWidth
                if clear < 0.4 && closing > 0 {
                    let theirs = simd_dot(o.vel, fwd)
                    let allowed = sqrt(max(0, theirs * abs(theirs) + 2 * decel * max(0, ahead - 8)))
                    driveSpeed = min(driveSpeed, max(0, allowed))
                }
            }
        }
        if avoidTimer <= 0 { want = laneOffset }
        want = max(left, min(right, want))
        let latRate: Float = 3 + abs(speed) * 0.06
        lateral += max(-latRate * dt, min(latRate * dt, want - lateral))

        // — AIVehiclePid::OnSteering —
        let look = max(12, min(45, 8 + abs(speed) * 0.55))
        let tgtP = route.sample(progress + look)
        let tr = float3(tgtP.tangent.y, -tgtP.tangent.x, 0)
        let target = tgtP.p + tr * lateral
        let to = simd_normalize(float2(target.x - car.position.x, target.y - car.position.y) + 1e-6)
        let f2 = simd_normalize(float2(car.forward.x, car.forward.y) + 1e-6)
        let cross = f2.x * to.y - f2.y * to.x            // + = objetivo a la izquierda
        var bodyError = asin(max(-1, min(1, cross)))
        if simd_dot(f2, to) < 0 { bodyError = bodyError >= 0 ? .pi - bodyError : -.pi - bodyError }
        bodyErr.record(bodyError, dt)
        let sp = abs(speed)
        let (p, i, dc): (Float, Float, Float) = sp < 10
            ? (RaceAITables.pidP.value(sp), RaceAITables.pidI.value(sp), RaceAITables.pidD.value(sp))
            : (0.7, 0.055, 0.25)
        let integ = max(-0.5, min(0.5, bodyErr.integral)), deriv = max(-10, min(10, bodyErr.derivative))
        let out = p * bodyError + i * integ + dc * deriv
        let maxSteer = 45 * (v.specs.tires.STEERING > 0 ? v.specs.tires.STEERING : 1) * .pi / 180
        // la física: steering > 0 = derecha; aquí bodyError > 0 = izquierda
        let steer = max(-1, min(1, -(out / maxSteer) * (sp < 10 ? 3 : 1)))
        d.steerRight = max(steer, 0); d.steerLeft = max(-steer, 0)
        if speed < -1 { d.steerRight = 0; d.steerLeft = 0 }

        // — AIVehiclePid::OnGasBrake —
        let err = speed - driveSpeed
        velErr.record(err, dt)
        if staging {
            throttleBrake = 0.8                                  // fAiStagingThrottle (con freno de mano: no se mueve)
        } else if driveSpeed < 0.5 {
            throttleBrake = -1
        } else if speed < -1 {
            throttleBrake = -1
        } else {
            let ii = max(-5, min(5, velErr.integral)), de = max(-10, min(10, velErr.derivative))
            throttleBrake += err * -0.4 + ii * -0.01 + de * -0.1
        }
        throttleBrake = max(-1, min(1, throttleBrake))
        d.gas = max(0, throttleBrake)
        d.brake = max(0, -throttleBrake)
        if staging { d.handBrake = 1 }

        // — NOS —
        if hasNOS && !stop && !staging && speed > 10 && speed < speedLimit + 0.01 {
            let skillScale = RaceAITables.nosScale.value(sk)
            let speedGap = skillScale * (potential - speed)
            let accelGap = skillScale * (potentialAccel - actualAccel)
            if !nosOn {
                if nosTimer < -PM.lerp(20, 4, sk) && speedGap > 15 && accelGap > potentialAccel * 0.5 && v.engine.nosCapacity > 0.3 { nosOn = true }
            } else if nosTimer > PM.lerp(2, 4, sk) && (speedGap < 5 || accelGap < potentialAccel * 0.15) { nosOn = false }
        } else { nosOn = false }
        if v.engine.nosCapacity <= 0 { nosOn = false }
        nosTimer = nosOn ? max(nosTimer + dt, 0) : min(nosTimer - dt, 0)
        d.nos = nosOn

        // — Bloqueo —
        if progress > lastProgress + 3 || stop || staging { stuckTime = 0; lastProgress = max(progress, lastProgress) }
        else { stuckTime += dt }
        _ = lateralNow
        return d
    }
}
