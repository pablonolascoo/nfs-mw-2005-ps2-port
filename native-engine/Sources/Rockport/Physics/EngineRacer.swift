// Motor, embrague, caja y nitro del coche del jugador [D: Physics/Behaviors/EngineRacer.cpp (EngineRacer, Clutch,
// Engine_SmoothRPM), Physics/PhysicsInfo.cpp (Torque, EngineInertia, ShiftPoints, Speedometer, InductionBoost, Nos*)].
// Atributos: engine (TORQUE, IDLE, RED_LINE, MAX_RPM, FLYWHEEL_MASS, ENGINE_BRAKING, SPEED_LIMITER), transmission
// (GEAR_RATIO, FINAL_GEAR, GEAR_EFFICIENCY, TORQUE_SPLIT, TORQUE_CONVERTER, CLUTCH_SLIP, SHIFT_SPEED), induction, nos, tires.
import Foundation

/// Marchas del juego [D: PhysicsTypes.h GearID].
enum Gear { static let reverse = 0, neutral = 1, first = 2 }

/// InputControls del juego (fGas, fBrake, fHandBrake, fSteering, fNOS) [D: IINput.h, PInput.cpp].
struct Controls {
    var gas: Float = 0, brake: Float = 0, handBrake: Float = 0, steering: Float = 0
    var nos = false
}

struct Clutch {
    enum State { case engaged, engaging, disengaged }
    var state = State.engaged, time: Float = 0, engageTime: Float = 0
    mutating func disengage() { if state == .engaged { state = .disengaged } }
    mutating func engage(_ t: Float) {
        if state == .disengaged { state = t > 0 ? .engaging : .engaged; time = t; engageTime = t }
    }
    mutating func reset() { state = .engaged; time = 0 }
    mutating func update(_ dT: Float) -> Float {
        if time > 0 { time -= dT; if time <= 0 && state == .engaging { state = .engaged } }
        switch state {
        case .disengaged: return 0.25
        case .engaging: return 1 - PM.ramp(time, 0, engageTime) * 0.75
        case .engaged: return 1
        }
    }
}

final class EngineRacer {
    let engine: VehicleSpecs.Engine, tranny: VehicleSpecs.Transmission, induction: VehicleSpecs.Induction
    let nosInfo: VehicleSpecs.Nos, tires: VehicleSpecs.Tires

    private(set) var driveTorque: Float = 0
    private(set) var gear = Gear.first
    private(set) var gearShiftTimer: Float = 0
    private(set) var throttle: Float = 0
    private(set) var spool: Float = 0, psi: Float = 0, inductionBoost: Float = 0
    private var shiftUpRPM = [Float](repeating: 0, count: 10), shiftDownRPM = [Float](repeating: 0, count: 10)
    private var angularVelocity: Float = 0, angularAcceleration: Float = 0
    private(set) var transmissionVelocity: Float = 0
    private(set) var nosCapacity: Float = 1
    private(set) var nosBoost: Float = 1
    private(set) var nosEngaged: Float = 0
    private var clutchRPMDiff: Float = 0
    private(set) var engineBraking = false
    private var sportShifting: Float = 0
    private(set) var rpm: Float = 0
    private var shiftPotential = 0     // 0 ninguno, 1 bajar, 2 subir (SHIFT_POTENTIAL_*)
    private(set) var peakTorque: Float = 0, peakTorqueRPM: Float = 0
    private var clutch = Clutch()
    var automatic = true

    // Tweaks [D: EngineRacer.cpp]
    static let clutchEngageTime: Float = 0.25, firstGearClutchEngageTime: Float = 0.05
    static let idleClutchRPM: Float = 800, seizeRPM: Float = 2000, clutchLimiter: Float = 300, clutchStiffness: Float = 20
    static let coastingPercent: Float = 0.65, minSpeedForNosMPH: Float = 10
    static let clutchPlay = PGraph([(-10, 1), (-7.5, 0.96), (-3.5, 0.925), (-0.3, 0.875), (-0.05, 0)])
    static let smoothRPMDecel: [Float] = [2.5, 15]

    init(_ s: VehicleSpecs) {
        engine = s.engine; tranny = s.transmission; induction = s.induction; nosInfo = s.nos; tires = s.tires
        reset()
        nosCapacity = nosInfo.NOS_CAPACITY > 0 ? 1 : 0
    }

    var numGearRatios: Int { tranny.GEAR_RATIO.count }
    var topGear: Int { numGearRatios - 1 }
    func gearRatio(_ i: Int) -> Float { i >= 0 && i < numGearRatios ? tranny.GEAR_RATIO[i] : 0 }
    func gearEfficiency(_ i: Int) -> Float { i < tranny.GEAR_EFFICIENCY.count ? tranny.GEAR_EFFICIENCY[i] : 1 }
    var rearWheelDrive: Bool { tranny.TORQUE_SPLIT < 1 }
    var frontWheelDrive: Bool { tranny.TORQUE_SPLIT > 0 }
    var isGearChanging: Bool { gearShiftTimer > 0 }
    var hasNOS: Bool { nosInfo.NOS_CAPACITY > 0 && nosInfo.TORQUE_BOOST > 0 }
    var isNOSEngaged: Bool { nosEngaged >= 1 }
    var speedLimiter: [Float] { engine.SPEED_LIMITER }

    // MARK: Physics::Info

    /// Par en ft·lb: tabla TORQUE entre IDLE y MAX_RPM, rpm limitadas a IDLE…RED_LINE [D: Info::Torque].
    static func torque(_ e: VehicleSpecs.Engine, _ rpmIn: Float) -> Float {
        let n = e.TORQUE.count
        guard n > 1 else { return 0 }
        let rpm = PM.clamp(rpmIn, e.IDLE, e.RED_LINE)
        var ratio = Float(n - 1) * (rpm - e.IDLE) / (e.MAX_RPM - e.IDLE)
        let i = Int(ratio); ratio -= Float(i)
        return PM.lerp(e.TORQUE[i], e.TORQUE[min(n - 1, i + 1)], ratio)
    }
    static func engineInertia(_ e: VehicleSpecs.Engine, loaded: Bool) -> Float { (loaded ? 1 : 0.35) * (e.FLYWHEEL_MASS * 0.025 + 0.25) }
    static func wheelDiameter(_ t: VehicleSpecs.Tires, front: Bool) -> Float {
        let a = front ? 0 : 1
        return PM.inch2m(t.RIM_SIZE[a]) + t.SECTION_WIDTH[a] * 0.001 * 2 * (t.ASPECT_RATIO[a] * 0.01)
    }
    var inductionType: Int { (induction.HIGH_BOOST > 0 || induction.LOW_BOOST > 0) ? (induction.SPOOL > 0 ? 1 : 2) : 0 }
    func inductionRPM() -> Float { induction.SPOOL * (engine.RED_LINE - engine.IDLE) + engine.IDLE }
    func inductionBoost(rpm: Float, spool spoolIn: Float) -> (boost: Float, psi: Float) {
        let spool = PM.clamp(spoolIn, 0, 1)
        var boost: Float = 0, psi: Float = 0
        let hi = induction.HIGH_BOOST, lo = induction.LOW_BOOST, drag = induction.VACUUM
        if hi > 0 || lo > 0 {
            let spoolRPM = inductionRPM()
            if rpm >= spoolRPM {
                let r = PM.ramp(rpm, spoolRPM, engine.RED_LINE)
                boost = r * hi + (1 - r) * lo
                psi = spool * induction.PSI * PM.ramp(boost, 0, max(hi, lo))
            } else if drag < 0 {
                let r = PM.ramp(rpm, engine.IDLE, spoolRPM)
                boost = r * drag
                psi = r * -induction.PSI * PM.ramp(-boost, 0, max(hi, lo))
            }
        }
        return (boost * spool, psi)
    }
    /// Info::Speedometer: velocidad del velocímetro para unas rpm y una marcha.
    func speedometer(rpm: Float, gear g: Int) -> Float {
        var speed: Float = 0
        let ratio = abs(gearRatio(g) * tranny.FINAL_GEAR), range = engine.RED_LINE - engine.IDLE
        if ratio > 0 && range > 0 {
            let r = (EngineRacer.wheelDiameter(tires, front: false) * 0.5 + EngineRacer.wheelDiameter(tires, front: true) * 0.5) * 0.5
            let clutchRPM = (rpm - engine.IDLE) / ratio / range * engine.RED_LINE
            speed = PM.rpm2rps(clutchRPM) * r
        }
        let lim = PM.mph2mps(speedLimiter.first ?? 0)
        return lim > 0 ? min(speed, lim) : speed
    }
    var maxSpeedometer: Float {
        guard numGearRatios > 0 else { return 0 }
        let lim = PM.mph2mps(speedLimiter.first ?? 0), m = speedometer(rpm: engine.RED_LINE, gear: numGearRatios - 1)
        return lim > 0 ? min(m, lim) : m
    }
    var speedometerNow: Float { speedometer(rpm: PM.rps2rpm(transmissionVelocity), gear: gear) }

    /// Info::ShiftPoints (incluido el cruce rpm/spool de InductionBoost que tiene el juego) [D].
    private func calcShiftPoints() {
        for i in 0..<10 { shiftUpRPM[i] = 0; shiftDownRPM[i] = 0 }
        let n = numGearRatios, redline = engine.RED_LINE, top = n - 1
        guard n <= 10, n > Gear.first else { return }
        for j in Gear.first..<top {
            let g1 = gearRatio(j), g2 = gearRatio(j + 1)
            var mx = (redline + engine.IDLE) * 0.5
            var flag = false
            if mx < redline {
                while !flag {
                    let cur = EngineRacer.torque(engine, mx) * (inductionBoost(rpm: 1, spool: mx).boost + 1)
                    var up: Float = 0
                    if abs(g1) > 0.00001 { let nr = g2 / g1 * mx; up = EngineRacer.torque(engine, nr) * (inductionBoost(rpm: 1, spool: nr).boost + 1) * g2 / g1 }
                    if up > cur { break }
                    mx += 50
                    flag = !(mx < redline)
                }
                if !flag { shiftUpRPM[j] = mx }
            } else { flag = true }
            if flag { shiftUpRPM[j] = redline - 100 }
            shiftDownRPM[j + 1] = abs(g1) > 0.00001 ? g2 / g1 * shiftUpRPM[j] : 0
        }
        shiftUpRPM[top] = redline
        // Info::MaxInductedTorque no está decompilado: barrido IDLE…RED_LINE cada 50 rpm [I]
        peakTorque = 0; peakTorqueRPM = engine.IDLE
        var r = engine.IDLE
        while r <= redline {
            let t = EngineRacer.torque(engine, r) * (1 + inductionBoost(rpm: r, spool: 1).boost)
            if t > peakTorque { peakTorque = t; peakTorqueRPM = r }
            r += 50
        }
        peakTorque = PM.ftlb2nm(peakTorque)
    }

    // MARK: EngineRacer

    func reset() {
        driveTorque = 0; angularVelocity = PM.rpm2rps(engine.IDLE); angularAcceleration = 0; rpm = engine.IDLE
        transmissionVelocity = 0; clutch.reset(); gearShiftTimer = 0; spool = 0; psi = 0; inductionBoost = 0
        shiftPotential = 0; gear = Gear.first; nosEngaged = 0; clutchRPMDiff = 0; throttle = 0; nosBoost = 1; sportShifting = 0
        calcShiftPoints()
    }

    func engineTorque(_ rpm: Float) -> Float { PM.ftlb2nm(EngineRacer.torque(engine, rpm)) * (1 + inductionBoost) * nosBoost }

    func brakingTorque(_ engineTorque: Float, _ rpm: Float) -> Float {
        let n = engine.ENGINE_BRAKING.count
        if n > 1 {
            var ratio = Float(n - 1) * (PM.clamp(rpm, engine.IDLE, engine.RED_LINE) - engine.IDLE) / (engine.MAX_RPM - engine.IDLE)
            let i = Int(ratio); ratio -= Float(i)
            let base = engine.ENGINE_BRAKING[i], step = engine.ENGINE_BRAKING[min(n - 1, i + 1)]
            return -engineTorque * PM.clamp(base + (step - base) * ratio, 0, 1)
        }
        return -engineTorque * (engine.ENGINE_BRAKING.first ?? 0)
    }

    func guessRPM(_ speed: Float, _ g: Int) -> Float {
        let r = (EngineRacer.wheelDiameter(tires, front: false) + EngineRacer.wheelDiameter(tires, front: true)) * 0.25
        guard r > 0 else { return engine.IDLE }
        let dw = abs(speed) / r, maxW = PM.rpm2rps(engine.RED_LINE), minW = PM.rpm2rps(engine.IDLE)
        let av = PM.rps2rpm(minW + dw * tranny.FINAL_GEAR * gearRatio(g) * (maxW - minW) / maxW)
        return PM.clamp(av, engine.IDLE, engine.RED_LINE)
    }
    func shiftPoint(from: Int, to: Int) -> Float {
        if from <= Gear.reverse || to <= Gear.neutral { return 0 }
        return to > from ? shiftUpRPM[from] : (to < from ? shiftDownRPM[from] : 0)
    }
    func guessGear(_ speed: Float) -> Int {
        if speed < 0 { return Gear.reverse }
        var g = Gear.first
        for i in Gear.first..<topGear { if guessRPM(speed, i) <= shiftPoint(from: i, to: i + 1) { break }; g = i + 1 }
        return g
    }
    func matchSpeed(_ speed: Float) {
        reset(); gear = guessGear(speed); rpm = guessRPM(speed, gear)
        angularVelocity = PM.rpm2rps(rpm); transmissionVelocity = angularVelocity; clutch.engage(0)
    }

    private func findShiftPotential(_ g: Int, _ rpm: Float) -> Int {
        if g <= Gear.neutral { return 0 }
        let up = shiftUpRPM[g]
        var down = shiftDownRPM[g]
        let lower = gearRatio(g - 1)
        if g != Gear.first && lower > 0 {
            let lowerUp = shiftUpRPM[g - 1] * gearRatio(g) / lower - 200
            let off = PM.lerp(engine.IDLE, down, EngineRacer.coastingPercent)
            down = min(PM.lerp(off, down, throttle), lowerUp)
        }
        if rpm >= up && g < topGear { return 2 }
        if rpm <= down && g > Gear.first { return 1 }
        return 0
    }

    @discardableResult func doGearChange(_ g: Int) -> Bool {
        if g > topGear || g < Gear.reverse || g >= numGearRatios || g == gear { return false }
        gearShiftTimer = g < gear ? tranny.SHIFT_SPEED * gearRatio(g) * 0.25 : tranny.SHIFT_SPEED * gearRatio(g)
        gear = g; clutch.disengage(); shiftPotential = 0
        return true
    }
    /// Cambio manual (secuencial). En automático va como SportShift [D: InputPlayer::DoShifting].
    func shift(_ dir: Int) {
        let desired = Int(PM.clamp(Float(gear + dir), 1, Float(topGear)))
        if gear == Gear.reverse || desired == gear || isGearChanging { return }
        if automatic {
            if desired > gear && shiftPotential == 1 { return }
            if desired < gear && shiftPotential == 2 { return }
            if desired <= Gear.neutral { return }
            if doGearChange(desired) { sportShifting = 1.25 }
        } else { doGearChange(desired) }
    }
    func shiftTo(_ g: Int) { doGearChange(g) }

    private func autoShift(_ susp: SuspensionRacer) {
        if gear == Gear.reverse || gearShiftTimer > 0 || sportShifting > 0 { return }
        if gear == Gear.neutral { gear = Gear.first; return }
        switch shiftPotential {
        case 1:
            var next = gear - 1
            if next > Gear.first {
                let cur = PM.rps2rpm(transmissionVelocity)
                func change(_ from: Int, _ to: Int) -> Float { let a = gearRatio(from), b = gearRatio(to); return a > 0 && b > PM.uEpsilon ? a / b : 0 }
                var r = cur * change(next, gear)
                while next > Gear.first && findShiftPotential(next, r) == 1 { next -= 1; r = cur * change(next, gear) }
            }
            doGearChange(next)
        case 2:
            var traction = true
            for i in 0..<4 { traction = traction && susp.tires[i].isOnGround && susp.tires[i].slip < 4 }
            if traction { doGearChange(gear + 1) }
        default: break
        }
    }

    private func differentialAngularVelocity(_ susp: SuspensionRacer, locked: Bool) -> Float {
        var into: Float = 0
        let rev = gear == Gear.reverse
        if frontWheelDrive {
            let w = (susp.wheelAngularVelocity(0) + susp.wheelAngularVelocity(1)) * 0.5
            if !locked { if abs(w) > 0 { into = w } } else { into = rev ? min(w, 0) : max(w, 0) }
        }
        if rearWheelDrive {
            let w = (susp.wheelAngularVelocity(2) + susp.wheelAngularVelocity(3)) * 0.5
            if !locked { if abs(w) > abs(into) { into = w } } else { into = rev ? min(w, into) : max(w, into) }
        }
        return into
    }
    private func driveWheelSlippage(_ susp: SuspensionRacer) -> Float {
        var r: Float = 0, n: Float = 0
        if rearWheelDrive { n += 2; r += susp.tires[2].slip + susp.tires[3].slip }
        if frontWheelDrive { n += 2; r += susp.tires[0].slip + susp.tires[1].slip }
        return n > 0 ? r / n : 0
    }
    private func setDifferentialAngularVelocity(_ susp: SuspensionRacer, _ w: Float, absSpeed: Float) {
        let diff = w - differentialAngularVelocity(susp, locked: false)
        let lockAtSpeed = PM.mps2mph(absSpeed) < 40
        for (on, a, b) in [(rearWheelDrive, 2, 3), (frontWheelDrive, 0, 1)] where on {
            var lock = lockAtSpeed
            if !susp.tires[a].isOnGround && !susp.tires[b].isOnGround { lock = true }
            var w1 = susp.tires[a].av, w2 = susp.tires[b].av
            if lock { w1 = (w1 + w2) * 0.5; w2 = w1 }
            susp.tires[a].av = w1 + diff; susp.tires[b].av = w2 + diff
        }
    }
    private func limitFreeWheels(_ susp: SuspensionRacer, _ w: Float) {
        for i in 0..<4 where !susp.tires[i].isOnGround {
            if i < 2 ? !frontWheelDrive : !rearWheelDrive { continue }
            var ww = susp.tires[i].av
            if ww * w < 0 { ww = 0 } else if ww > 0 { ww = min(ww, w) } else if ww < 0 { ww = max(ww, w) }
            susp.tires[i].av = ww
        }
    }

    private func doNos(_ dT: Float, engaged inEngaged: Bool, absSpeed: Float) -> Float {
        guard hasNOS else { return 1 }
        let mph = PM.mps2mph(absSpeed)
        var recharge: Float = 0
        if mph >= nosInfo.RECHARGE_MIN_SPEED && gear >= Gear.first {   // IPlayer::CanRechargeNOS → sí [I]
            recharge = PM.lerp(nosInfo.RECHARGE_MIN, nosInfo.RECHARGE_MAX, PM.ramp(mph, nosInfo.RECHARGE_MIN_SPEED, nosInfo.RECHARGE_MAX_SPEED))
        }
        var engaged = inEngaged
        if gear < Gear.first || throttle <= 0 { engaged = false }
        if (mph < EngineRacer.minSpeedForNosMPH && !isNOSEngaged) || (mph < EngineRacer.minSpeedForNosMPH * 0.5 && isNOSEngaged) { engaged = false }
        let discharge = nosInfo.NOS_CAPACITY
        var scale: Float = 1
        if discharge > 0 {
            if engaged && nosCapacity > 0 {
                nosCapacity = max(nosCapacity - dT / discharge, 0)
                scale = nosInfo.TORQUE_BOOST + 1
                nosEngaged = 1
            } else if nosEngaged > 0 && nosInfo.NOS_DISENGAGE > 0 {
                nosEngaged = max(nosEngaged - dT / nosInfo.NOS_DISENGAGE, 0)
            } else if nosCapacity < 1 && recharge > 0 {
                nosCapacity = min(nosCapacity + dT / recharge, 1); nosEngaged = 0
            } else { nosEngaged = 0 }
        } else { nosCapacity = 0; nosEngaged = 0 }
        return scale
    }

    private func doInduction(_ dT: Float) {
        guard inductionType != 0 else { spool = 0; inductionBoost = 0; psi = 0; return }
        var desired = PM.ramp(throttle, 0, 0.5)
        let r = PM.rps2rpm(angularVelocity)
        if isGearChanging { desired = 0 }
        if inductionType == 1 && r < inductionRPM() { desired = 0 }
        if spool > desired {
            spool = induction.SPOOL_TIME_DOWN > PM.uEpsilon ? max(spool - dT / induction.SPOOL_TIME_DOWN, desired) : desired
        } else if spool < desired {
            spool = induction.SPOOL_TIME_UP > PM.uEpsilon ? min(spool + dT / induction.SPOOL_TIME_UP, desired) : desired
        }
        spool = PM.clamp(spool, 0, 1)
        let b = inductionBoost(rpm: r, spool: spool)
        inductionBoost = b.boost
        psi = psi > b.psi ? max(psi - dT * 20, b.psi) : min(psi + dT * 20, b.psi)
    }

    private func doECU(speedometer: Float) {
        if gear <= Gear.neutral { return }
        let lim = PM.mph2mps(speedLimiter.first ?? 0)
        if lim > 0, speedLimiter.count > 1 {
            let cutoff = PM.mph2mps(speedLimiter[1])
            if cutoff > 0 && speedometer > lim { throttle *= 1 - PM.clamp((speedometer - lim) / cutoff, 0, 1) }
        }
    }

    static func smoothRPM(shifting: Bool, gear: Int, dT: Float, old: Float, new: Float, inertia: Float) -> Float {
        let fast = (shifting && gear > Gear.first) || gear == Gear.neutral
        let maxDecel = -smoothRPMDecel[fast ? 1 : 0] * 1000 / inertia
        var r = new
        if dT > 0 && (r - old) / dT < maxDecel { r = max(maxDecel * dT + old, r) }
        return r * 0.55 + old * 0.45
    }

    /// EngineRacer::OnTaskSimulate.
    func simulate(_ dT: Float, controls: Controls, susp: SuspensionRacer, absSpeed: Float) {
        throttle = controls.gas
        nosBoost = doNos(dT, engaged: controls.nos, absSpeed: absSpeed)
        doECU(speedometer: speedometerNow)
        doInduction(dT)
        // DoShifting
        if automatic { autoShift(susp) }
        if gearShiftTimer > 0 { gearShiftTimer = max(gearShiftTimer - dT, 0) }
        if sportShifting > 0 && shiftPotential != 0 { sportShifting = max(sportShifting - dT * (2 - controls.gas), 0) }

        let maxW = PM.rpm2rps(engine.RED_LINE)           // UseRevLimiter() = true
        let minW = PM.rpm2rps(engine.IDLE)
        let inertia = EngineRacer.engineInertia(engine, loaded: gear != Gear.neutral)
        let axleW = differentialAngularVelocity(susp, locked: false)
        let diffW = differentialAngularVelocity(susp, locked: true)
        let onGround = susp.numWheelsOnGround
        let wheelRatio = max(0.25, Float(onGround) * 0.25)
        let clutchRatio = clutch.update(dT)
        let dir: Float = gear == Gear.reverse ? -1 : 1
        var total = gearRatio(gear) * tranny.FINAL_GEAR * dir
        let r = PM.rps2rpm(angularVelocity)
        if tranny.TORQUE_CONVERTER > 0 {
            var conv = tranny.TORQUE_CONVERTER * throttle * (1 - PM.ramp(r, engine.IDLE, peakTorqueRPM))
            if isGearChanging { conv *= clutchRatio }
            total *= 1 + conv
        }
        if total == 0 && gear != Gear.neutral { return }

        if gear == Gear.reverse || gear == Gear.first {
            var idle = EngineRacer.idleClutchRPM; if gear == Gear.reverse { idle *= 3 }
            let idleW = PM.rpm2rps(idle) + minW
            if angularVelocity > idleW || transmissionVelocity > idleW || throttle >= 0.1 { clutch.engage(EngineRacer.firstGearClutchEngageTime) } else { clutch.disengage() }
        } else if gear == Gear.neutral { clutch.disengage() } else { clutch.engage(EngineRacer.clutchEngageTime) }

        let eTorque = engineTorque(r)
        var bTorque = brakingTorque(eTorque, r)
        let oldClutchV = transmissionVelocity
        transmissionVelocity = minW + diffW * total * (maxW - minW) / maxW
        let transAcc = (transmissionVelocity - oldClutchV) / dT
        if gear != Gear.neutral && clutch.state == .engaged && bTorque * axleW * dir > 0 { bTorque = -bTorque }

        let totalEngine = eTorque * throttle + bTorque * (1 - throttle)
        var drive: Float = 0, road: Float = 0
        engineBraking = totalEngine < 0
        if gear != Gear.neutral {
            switch clutch.state {
            case .engaged: clutchRPMDiff = 0; drive = totalEngine; road -= totalEngine * wheelRatio
            case .engaging:
                let diff = PM.clamp(angularVelocity - transmissionVelocity, -EngineRacer.clutchLimiter, EngineRacer.clutchLimiter)
                var stiff = EngineRacer.clutchStiffness
                let rpmDiff = PM.rps2rpm(transmissionVelocity - angularVelocity)
                if clutchRPMDiff != 0 && rpmDiff * clutchRPMDiff < 0 && abs(rpmDiff) > EngineRacer.seizeRPM && abs(clutchRPMDiff) > EngineRacer.seizeRPM { stiff *= 0.5 }
                clutchRPMDiff = rpmDiff
                let ct = diff * stiff * clutchRatio
                drive += ct; road -= ct * wheelRatio
            case .disengaged: clutchRPMDiff = 0
            }
            if clutch.state == .engaged {
                let ae = (totalEngine + road) / inertia
                let diff = ae - transAcc
                var response = 1 / inertia
                let split = 1 - tranny.TORQUE_SPLIT
                if frontWheelDrive { response += (1 - split) * 0.1 * total * total * 0.5 }
                if rearWheelDrive { response += split * 0.1 * total * total * 0.5 }
                let r1 = diff / response
                drive += min(r1, 0); road -= r1 * wheelRatio
            }
            if clutch.state == .engaged && onGround > 0 {
                let slip = driveWheelSlippage(susp)
                let delta = transmissionVelocity - angularVelocity
                if throttle > 0.2 && slip * dir > 0.1 && gear <= Gear.first && delta < 0 {
                    transmissionVelocity = angularVelocity
                    setDifferentialAngularVelocity(susp, angularVelocity / total, absSpeed: absSpeed)
                } else {
                    let m = abs(totalEngine)
                    road += PM.clamp(delta * EngineRacer.clutchStiffness, -m, m)
                }
            }
            if gear == Gear.first || gear == Gear.reverse {
                let td = totalEngine + road
                if road < totalEngine && td < 0 { road += EngineRacer.clutchPlay.value(td * 1000) * td * tranny.CLUTCH_SLIP }
            }
        }
        if gear != Gear.neutral && throttle > 0 && gear <= Gear.first && clutch.state == .engaged && road * totalEngine < 0 {
            var cs = tranny.CLUTCH_SLIP * throttle
            cs *= 1 - throttle * PM.ramp(r, engine.IDLE, peakTorqueRPM)
            let allowed = 1 - cs
            road *= allowed * allowed
        }

        angularAcceleration = (totalEngine + road) / inertia
        angularVelocity = PM.clamp(angularVelocity + angularAcceleration * dT, minW, maxW)
        if total != 0 { limitFreeWheels(susp, maxW / total) }
        if transmissionVelocity > maxW && total != 0 {
            if drive * total > 0 { drive = 0 }
            transmissionVelocity = maxW
            setDifferentialAngularVelocity(susp, maxW / total, absSpeed: absSpeed)
        }
        driveTorque = drive * total * gearEfficiency(gear)
        rpm = EngineRacer.smoothRPM(shifting: isGearChanging || clutch.state == .disengaged, gear: gear, dT: dT, old: rpm, new: PM.rps2rpm(angularVelocity), inertia: inertia)
        shiftPotential = clutch.state != .engaged ? 0 : findShiftPotential(gear, PM.rps2rpm(transmissionVelocity))
    }
}
