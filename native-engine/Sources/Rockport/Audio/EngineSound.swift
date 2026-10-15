// Sonido del motor de un coche, con la lógica del juego [D: EAXSound/sfxctl/SFXCTL_Physics, SFXCTL_Engine, SFXCTL_Shifting,
// SFXCTL_HybridMotor y CARSFX/CARSFX_Engine (CARSFX_DualGinsuEng), CARSFX_Turbo, CARSFX_Nitrous].
//
// Cadena (todo a 30 Hz, una vez por fotograma del juego en PS2 [H]):
//   física → % de RPM (ralentí…corte) → curva PhysicsRPM_Map (Bézier) → «RPM de audio» 1000–10 000
//   → SFXCTL_Engine (cambios de marcha, compresión) → SFXCTL_HybridMotor: ΔRPM medio y par (= acelerador × 100) deciden la
//   mezcla acelerando / desacelerando (GINSUMix_*, DECEL_GINSUMix_*, cruce DecelCrossfadeMix) y los volúmenes
//   → RPM del .GIN = (audio − 1000)/9000 × (MaxRPM − MinRPM) + MinRPM → dos GinsuSynth (acelerando y desacelerando).
// Lo que no se porta (falta en el disco o no se ejecuta): la capa AEMS (bancos CAR_NN_ENG_MB_*, módulos MIPS) y su muestra
// de corte de encendido; los LFO de después del cambio; AccelTrans (arrancada desde ralentí); los mapas de mezcla (MIXMAPS).
import Foundation
import simd

/// Estado del coche que necesita el sonido (sale de PVehicle o de la IA).
struct SFXCarState {
    var position = float3(0, 0, 0)       // mundo del motor (Z arriba)
    var velocity = float3(0, 0, 0)
    var forward = float3(1, 0, 0)
    var rpm: Float = 800
    var idle: Float = 800
    var redline: Float = 7000
    var gear = 2                          // índice de Gear (0 marcha atrás, 1 punto muerto, 2 primera…)
    var throttle: Float = 0               // 0…1
    var brake: Float = 0
    var nos = false
    var nosEmpty = false
    var wheelsOnGround = 4
    var slipForward: Float = 0            // m/s de patinaje longitudinal (medio)
    var slipSide: Float = 0               // m/s laterales (medio)
    var onLimiter = false
    var speed: Float { simd_length(velocity) }
    var speedMPH: Float { speed * 2.2369363 }

    /// Desde la física del juego (Physics/).
    init(vehicle v: PVehicle) {
        position = PM.toWorld(v.rb.position); velocity = PM.toWorld(v.rb.linearVel)
        forward = PM.toWorld(v.rb.forward)
        rpm = v.engine.rpm; idle = v.specs.engine.IDLE; redline = v.specs.engine.RED_LINE
        gear = v.engine.gear
        throttle = v.controls.gas; brake = v.controls.brake
        nos = v.engine.isNOSEngaged; nosEmpty = v.engine.hasNOS && v.engine.nosCapacity <= 0.001
        wheelsOnGround = v.susp.numWheelsOnGround
        var sf: Float = 0, ss: Float = 0, n: Float = 0
        for t in v.susp.tires where t.isOnGround { sf += abs(t.slip); ss += abs(t.lateralSpeed); n += 1 }
        if n > 0 { slipForward = sf / n; slipSide = ss / n }
        onLimiter = v.engine.rpm > v.specs.engine.RED_LINE - 150 && v.controls.gas > 0.5
    }
    init() {}
}

/// Interpolador por tramos del juego (cInterpLine): de `a` a `b` en `ms` milisegundos, lineal o «potencia igual al cuadrado».
struct SFXInterp {
    var a: Float = 0, b: Float = 0, ms: Float = 1, t: Float = 0, eq = false
    init() {}
    init(_ a: Float, _ b: Float, _ ms: Float, eq: Bool = false) { self.a = a; self.b = b; self.ms = max(1, ms); self.eq = eq; t = 0 }
    mutating func update(_ dt: Float, target: Float? = nil) { t = min(ms, t + dt * 1000); if let target { b = target } }
    var finished: Bool { t >= ms }
    var value: Float {
        var u = t / ms
        if eq { u = sinf(u * .pi / 2); u *= u }   // EQ_PWR_SQ [I]
        return a + (b - a) * u
    }
}

/// Gráfica por puntos (Graph de Table.hpp): x creciente, valor lineal entre puntos.
struct SFXGraph {
    var pts: [SIMD2<Float>]
    func value(_ x: Float) -> Float {
        guard let f = pts.first, let l = pts.last else { return 0 }
        if x <= f.x { return f.y }
        if x >= l.x { return l.y }
        for i in 1..<pts.count where x <= pts[i].x {
            let p0 = pts[i - 1], p1 = pts[i]
            return p1.x > p0.x ? p0.y + (p1.y - p0.y) * (x - p0.x) / (p1.x - p0.x) : p1.y
        }
        return l.y
    }
}

/// Media móvil (Average de Table.hpp).
struct SFXAverage {
    var slots: [Float]; var k = 0; var n = 0
    init(_ size: Int) { slots = [Float](repeating: 0, count: size) }
    mutating func record(_ v: Float) { slots[k] = v; k = (k + 1) % slots.count; n = min(n + 1, slots.count) }
    mutating func flush(_ v: Float) { for i in slots.indices { slots[i] = v }; n = slots.count }
    var value: Float { n == 0 ? 0 : slots.prefix(n == slots.count ? slots.count : n).reduce(0, +) / Float(n == slots.count ? slots.count : n) }
    var last: Float { slots[(k + slots.count - 1) % slots.count] }
}

@inline(__always) func sfxSmooth(_ cur: Float, _ target: Float, _ d: Float) -> Float { target > cur + d ? cur + d : target < cur - d ? cur - d : target }

/// Atributos de engineaudio de un coche (sound.json → engines).
struct EngineAudioSpec {
    var accel: String?, decel: String?
    var minRPM: Float = 1000, maxRPM: Float = 8000
    var decelMinRPM: Float = 0, decelMaxRPM: Float = 0, decelFadeIn: Float = 0.02, decelFadeOut: Float = 0.25
    var ginsuMixS: Float = 0.05, ginsuMixL: Float = 1, decelGinsuMixS: Float = 0.18, decelGinsuMixL: Float = 0.75
    var aclNegS: Float = 0.15
    var aemsMixS: Float = 0.9, aemsMixL: Float = 0.25, decelAemsMixS: Float = 0.8, decelAemsMixL: Float = 0.6
    var aemsVol: Float = 16000, decelAemsVol: Float = 12000
    var accelVol: Float = 24000, decelVol: Float = 18000, masterVol: Float = 32767
    var accelThreshold: Float = 150, decelThreshold: Float = 150
    var lowPassCutoff: Float = 24000
    var rpmMap: [Float] = [0, 0.2, 0.6, 1]       // Y de los 4 puntos de PhysicsRPM_Map (curva de Bézier)
    var sweet: String?, sputterVol: Float = 13500, shiftSweetVol: Float = 15000
    var name = ""

    init(name: String, _ e: [String: Any]) {
        func f(_ k: String, _ d: Float) -> Float { (e[k] as? NSNumber)?.floatValue ?? d }
        self.name = name
        accel = e["Filename_GinsuAccel"] as? String; decel = e["Filename_GinsuDecel"] as? String
        minRPM = f("MinRPM", 1000); maxRPM = f("MaxRPM", 8000)
        decelMinRPM = f("GINSU_Decel_MinRPM", 0); decelMaxRPM = f("GINSU_Decel_MaxRPM", 0)
        decelFadeIn = f("GINSU_DECEL_FADE_IN", 0.02); decelFadeOut = f("GINSU_DECEL_FADE_OUT", 0.25)
        ginsuMixS = f("GINSUMix_S_RPM", 0.05); ginsuMixL = f("GINSUMix_L_RPM", 1)
        decelGinsuMixS = f("DECEL_GINSUMix_S_RPM", 0.18); decelGinsuMixL = f("DECEL_GINSUMix_L_RPM", 0.75)
        aclNegS = f("Ginsu_ACL_Neg_S_RPM", 0.15)
        aemsMixS = f("AEMSMix_S_RPM", 0.9); aemsMixL = f("AEMSMix_L_RPM", 0.25)
        decelAemsMixS = f("DECEL_AEMSMix_S_RPM", 0.8); decelAemsMixL = f("DECEL_AEMSMix_L_RPM", 0.6)
        aemsVol = f("AEMSVol", 16000); decelAemsVol = f("DECEL_AEMSVol", 12000)
        accelVol = f("GINSUAccelVol", 24000); decelVol = f("GinsuDecelVol", 18000); masterVol = f("Master_Vol", 32767)
        accelThreshold = max(1, f("AccelDeltaRPMThreshold", 150)); decelThreshold = max(1, f("DecelDeltaRPMThreshold", 150))
        lowPassCutoff = f("GINSU_LowPassCutoff", 24000)
        if let m = e["PhysicsRPM_Map"] as? [NSNumber], m.count >= 16 { rpmMap = [m[1].floatValue, m[5].floatValue, m[9].floatValue, m[13].floatValue] }
        sweet = (e["SweetBank"] as? [Any])?.first as? String
        sputterVol = f("Vol_Sputters", 13500); shiftSweetVol = f("Vol_ShiftSweets", 15000)
    }
}

/// shiftpattern (sound.json → shifts).
struct ShiftSpec {
    var bank: String?
    var upDisengage: [(rpm: Float, time: Float, curve: [Float])] = []
    var upEngage: (rpm: Float, time: Float, curve: [Float]) = (1000, 150, [0, 1, 0.38, 1.84, 0.65, 0.26, 1, 0])
    var upAttackVol: Float = 0.4, upAttackT: Float = 500
    var upVol: Float = 28000, downVol: Float = 22000
    var upDelay: Float = 0.05, downDelay: Float = 0.05
    var downFallRPM: Float = 800, downFallT: Float = 250, downRiseRPM: Float = 600, downRiseT: Float = 600
    var downEngFallRPM: Float = 500, downEngFallT: Float = 370, downReattach: Float = 0.85

    init(_ s: [String: Any]?) {
        guard let s else { return }
        func f(_ k: String, _ d: Float) -> Float { (s[k] as? NSNumber)?.floatValue ?? d }
        bank = s["BankName"] as? String
        // Curvas: matriz 4×4 → puntos de control (x, y) de una Bézier cúbica [D: FillGraphFromSpline]
        func curve(_ m: Any?) -> [Float] {
            guard let a = m as? [NSNumber], a.count >= 16 else { return [0, 0, 0.33, -0.33, 0.66, -0.66, 1, -1] }
            return [a[0], a[1], a[4], a[5], a[8], a[9], a[12], a[13]].map(\.floatValue)
        }
        let curves = (s["Up_DisengageFall_Curve"] as? [Any]) ?? []
        for (i, p) in ((s["Up_DisengageFall"] as? [[String: Any]]) ?? []).enumerated() {
            upDisengage.append(((p["rpm"] as? NSNumber)?.floatValue ?? 1000, (p["time"] as? NSNumber)?.floatValue ?? 200, curve(i < curves.count ? curves[i] : nil)))
        }
        if let e = s["Up_Engage"] as? [String: Any] {
            upEngage = ((e["rpm"] as? NSNumber)?.floatValue ?? 1000, (e["time"] as? NSNumber)?.floatValue ?? 150, curve(s["Up_Engage_Curve"]))
        }
        upAttackVol = f("Up_Engaging_Attack_Vol", 0.4); upAttackT = f("Up_Engaging_Attack_T", 500)
        upVol = f("Up_Vol_Shift", 28000); downVol = f("Down_Vol_Shift", 22000)
        upDelay = f("Up_Shift_Sound_Delay", 0.05); downDelay = f("Down_Shift_Sound_Delay", 0.05)
        downFallRPM = f("Down_Disengage_Fall_RPM", 800); downFallT = f("Down_Disengage_Fall_T", 250)
        downRiseRPM = f("Down_Engaging_Rise_RPM", 600); downRiseT = f("Down_Engaging_Rise_T", 600)
        downEngFallRPM = f("Down_Engaging_Fall_RPM", 500); downEngFallT = f("Down_Engaging_Fall_T", 370)
        downReattach = f("Down_Reattach_Scale", 0.85)
    }

    /// FillGraphFromSpline: 7 puntos de la Bézier, x × tiempo, y × RPM.
    static func graph(_ c: [Float], time: Float, rpm: Float) -> SFXGraph {
        var pts: [SIMD2<Float>] = []
        for n in 0..<7 {
            let t = Float(n) / 6, u = 1 - t
            let w = [u * u * u, 3 * t * u * u, 3 * t * t * u, t * t * t]
            var x: Float = 0, y: Float = 0
            for k in 0..<4 { x += w[k] * c[2 * k]; y += w[k] * c[2 * k + 1] }
            pts.append(SIMD2(x * time, y * rpm))
        }
        return SFXGraph(pts: pts)
    }
}

/// Lo que el sonido de un coche quiere en este instante (lo lee SFXCarSound para fijar las voces).
struct EngineAudioOut {
    var ginsuFreq: Float = 1000        // RPM del .GIN
    var pitchBelowMin: Float = 1       // fPitchBelowMinFreq
    var accelGain: Float = 0           // 0…1 (SNDvol/127)
    var decelGain: Float = 0
    /// Volumen que el juego da a la capa AEMS (bucles por bandas de RPM, no portada): el port lo reparte entre los
    /// dos .GIN para no perder cuerpo (sobre todo al ralentí) [H: decisión del port].
    var aemsGain: Float = 0
    /// Cruce del .GIN de desaceleración (0 fuera de su banda de RPM).
    var decelCross: Float = 0
    var lowpass: Float = 24000
    var audioRPM: Float = 1000
    var torque: Float = 0
}

/// Controladores del motor de un coche (SFXCTL_Physics + Engine + Shifting + HybridMotor), a 30 Hz.
final class EngineAudio {
    let spec: EngineAudioSpec
    let shift: ShiftSpec
    let isPlayer: Bool
    private(set) var out = EngineAudioOut()
    // SFXCTL_Physics
    private var physTRQ: Float = 0
    private(set) var physRPM: Float = 1000
    private var lastGear = 1
    // SFXCTL_Engine
    private var trq = SFXAverage(3)
    private(set) var engRPM: Float = 1000
    private var prevRPM: Float = 1000
    private var engineVol: Float = 32767
    private var compression = SFXInterp(), compression2 = SFXInterp(), compressionPending = false
    // SFXCTL_HybridMotor
    private var avgDelta = SFXAverage(4)
    private var prevPhysRPM: Float = 0
    private var mixAccel: Float = 0, mixDecel: Float = 0, mixCutoff: Float = 24000, mixAems: Float = 0
    private var volAccel: Float = 0, volDecel: Float = 0, volAems: Float = 0
    private let decelXfade: SFXGraph
    private var steadySince: Float = 0, steadyFrames = 0, clock: Float = 0
    // SFXCTL_Shifting
    enum ShiftState { case none, upDisengage, upEngaging, downDisengage, downRise, downFall, downReattach }
    private(set) var shiftState = ShiftState.none
    private var stage = 0, tStage: Float = 0, rpmOffset: Float = 0
    private var graph = SFXGraph(pts: [])
    private var shiftRPM = SFXInterp(), shiftTRQ = SFXInterp(), shiftVol = SFXInterp()
    /// Sonidos que hay que lanzar (los recoge SFXCarSound): (muestra del banco de cambios, volumen 0…1, retardo s)
    var pendingShiftSounds: [(sample: Int, vol: Float, delay: Float)] = []
    var pendingSputters = 0
    private var rng = SplitMix(seed: 0x5eed)
    private var tick: Float = 0

    init(spec: EngineAudioSpec, shift: ShiftSpec, isPlayer: Bool, seed: UInt64 = 1) {
        self.spec = spec; self.shift = shift; self.isPlayer = isPlayer
        rng = SplitMix(seed: seed)
        // DecelCrossfadeMix [D: SFXCTL_HybridMotor::SetupSFX]
        let lo = spec.decelMinRPM, hi = spec.decelMaxRPM, diff = hi - lo
        decelXfade = SFXGraph(pts: [SIMD2(0, 0), SIMD2(lo, 0), SIMD2(lo + diff * spec.decelFadeOut, 1), SIMD2(hi - diff * spec.decelFadeIn, 1), SIMD2(hi, 0)])
    }

    var isShifting: Bool { shiftState != .none }

    /// Avanza `dt` segundos con el estado del coche (internamente en pasos de 1/30 s).
    func update(_ s: SFXCarState, dt: Float) {
        tick += dt
        var steps = 0
        while tick >= 1.0 / 30 && steps < 8 { tick -= 1.0 / 30; step(s, 1.0 / 30); steps += 1 }
        if steps == 8 { tick = 0 }
    }

    private func step(_ s: SFXCarState, _ t: Float) {
        clock += t
        // SFXCTL_Physics::UpdateParams: par = acelerador % (con paso máximo 100), RPM de audio por la curva del coche
        let lastTRQ = physTRQ
        physTRQ = sfxSmooth(physTRQ, s.throttle * 100, 100)
        let range = s.redline - s.idle
        let pct = range > 0 ? min(1, max(0, (s.rpm - s.idle) / range)) : 0
        let u = 1 - pct
        let m = spec.rpmMap
        let remapped = isPlayer ? u * u * u * m[0] + 3 * pct * u * u * m[1] + 3 * pct * pct * u * m[2] + pct * pct * pct * m[3] : pct
        physRPM = remapped * 9000 + 1000

        // SFXCTL_Shifting::UpdateParams: cambio detectado por la marcha
        let g = s.gear
        if g > lastGear && lastGear >= Gear.first { beginUpShift() } else if g < lastGear && g >= Gear.first { beginDownShift(g) }
        lastGear = g
        updateShift(t)

        // SFXCTL_Engine::UpdateRPM / UpdateTorque / UpdateVolume
        var cur = isShifting ? shiftRPM.value : physRPM
        compression.update(t); if compression.finished && compressionPending { compression = compression2; compressionPending = false }
        cur += compression.finished && !compressionPending ? 0 : compression.value
        prevRPM = engRPM; engRPM = cur
        if isShifting { trq.flush(shiftTRQ.value) } else { trq.record(physTRQ) }
        out.torque = trq.value
        engineVol = 32767
        if isShifting { engineVol += engineVol * shiftVol.value }

        // SFXCTL_HybridMotor::UpdateDeltaRPM (caso normal: ΔRPM de la física; en el cambio, la del sonido)
        let dPhys = physRPM - prevPhysRPM; prevPhysRPM = physRPM
        let dAud = engRPM - prevRPM
        switch shiftState {
        case .downRise: avgDelta.flush(dAud)
        case .upEngaging: avgDelta.record(abs(dAud))
        case .none: avgDelta.record(dPhys)
        default: avgDelta.record(dAud)
        }

        // UpdateParams: RPM del .GIN
        let aems = min(10000, max(1000, engRPM))
        let ginsuRPM = (aems - 1000) / 9000 * (spec.maxRPM - spec.minRPM) + spec.minRPM
        updateDualMix(ginsuRPM, noSmoothing: shiftState == .upEngaging)

        // CompressionRPM: a velocidad constante (> 30 mph y |ΔRPM| < 30) durante 3 s, «golpes» de 25–125 RPM [D: UpdateMixerOutputs]
        if s.speedMPH > 30 && abs(avgDelta.value) < 30 {
            if clock > steadySince + 3 {
                if steadyFrames == 0 {
                    steadyFrames = Int(rng.next() % 150) + 60
                    let dur = Float(rng.next() % 100) + 25, d = Float(rng.next() % 100) + 25
                    compression = SFXInterp(0, d, dur, eq: true); compression2 = SFXInterp(d, 0, dur, eq: true); compressionPending = true
                }
                steadyFrames -= 1
            }
        } else { steadySince = clock }

        // CARSFX_DualGinsuEng::SetGinsuParams
        out.ginsuFreq = ginsuRPM
        out.pitchBelowMin = 1
        if let minF = minGinsuFreq, ginsuRPM < minF { out.ginsuFreq = minF; out.pitchBelowMin = ginsuRPM / minF }
        let master = spec.masterVol / 32767
        out.accelGain = min(127, max(0, volAccel * master / 256)) / 127
        out.decelGain = min(127, max(0, volDecel * master / 256)) / 127
        out.aemsGain = min(127, max(0, volAems * master / 256)) / 127
        out.lowpass = mixCutoff
        out.audioRPM = engRPM
        // Petardeo al soltar el acelerador en alto (CAR_Sputter, Vol_Sputters) [H: disparo y frecuencia propios]
        if physTRQ < 5 && lastTRQ > 60 && engRPM > 5500 && !isShifting && rng.float() < 0.6 { pendingSputters += 1 + Int(rng.next() % 3) }
    }

    /// RPM mínima del .GIN de aceleración (la pone SFXCarSound al cargar).
    var minGinsuFreq: Float?

    private func updateDualMix(_ ginsuRPM: Float, noSmoothing: Bool) {
        let trqMix = min(1, max(0, out.torque / 35))                    // Slope(0, 1, 0, TRQ_THRESHOLD = 35)
        let d = avgDelta.value
        let pA = min(1, max(0, 1 - (spec.accelThreshold - abs(d + 10)) / spec.accelThreshold))
        let pD = min(1, max(0, 1 - (spec.decelThreshold - abs(d + 10)) / spec.decelThreshold))
        let accelAccel = pA * (spec.ginsuMixL - spec.ginsuMixS) + spec.ginsuMixS
        let xf = decelXfade.value(ginsuRPM)
        let decelDecel = xf * (pD * (spec.decelGinsuMixL - spec.decelGinsuMixS) + spec.decelGinsuMixS)
        let decelAccel = spec.aclNegS                                   // (L − L)·p + S: así está en el juego [D]
        let cutoffDecel = min(spec.lowPassCutoff, 24000)
        let nA = decelAccel + (accelAccel - decelAccel) * trqMix
        let nD = decelDecel * (1 - trqMix)
        let nC = cutoffDecel + (25000 - cutoffDecel) * trqMix
        // Capa AEMS (THRESHOLDMIX(AEMS) / FILTER_SCALE(xf, THRESHOLDMIX_DECEL(AEMS))) [D]
        let aemsA = pA * (spec.aemsMixL - spec.aemsMixS) + spec.aemsMixS
        let aemsD = (1 - xf) + xf * (pD * (spec.decelAemsMixL - spec.decelAemsMixS) + spec.decelAemsMixS)
        let nE = aemsD + (aemsA - aemsD) * trqMix
        out.decelCross = xf
        if noSmoothing { mixAccel = nA; mixDecel = nD; mixCutoff = nC; mixAems = nE }
        else { mixAccel = sfxSmooth(mixAccel, nA, 0.2); mixDecel = sfxSmooth(mixDecel, nD, 0.2); mixCutoff = sfxSmooth(mixCutoff, nC, 6000); mixAems = sfxSmooth(mixAems, nE, 0.2) }
        let ev = engineVol / 32767
        let vA = mixAccel * spec.accelVol * ev, vD = mixDecel * spec.decelVol * ev
        let vE = mixAems * (spec.decelAemsVol + (spec.aemsVol - spec.decelAemsVol) * trqMix) * ev
        if noSmoothing { volAccel = vA; volDecel = vD; volAems = vE }
        else { volAccel = sfxSmooth(volAccel, vA, 7000); volDecel = sfxSmooth(volDecel, vD, 7000); volAems = sfxSmooth(volAems, vE, 7000) }
    }

    // MARK: Cambios de marcha [D: SFXCTL_Shifting.cpp]

    private func beginUpShift() {
        cleanUp()
        guard physRPM >= 3000, !shift.upDisengage.isEmpty else { return }
        shiftState = .upDisengage
        let at = prevRPM
        engRPM = at
        let p = shift.upDisengage[0]
        graph = ShiftSpec.graph(p.curve, time: p.time, rpm: p.rpm)
        stage = 0; tStage = 0; rpmOffset = at
        shiftRPM = SFXInterp(at, at, 0)
        shiftVol = SFXInterp(0, 0, 1)
        shiftTRQ = SFXInterp(physTRQ, 0, 100)
        pendingShiftSounds.append((1, shift.upVol / 32767, shift.upDelay))   // AEMS_SHIFTING_UP = 1
        if spec.sweet != nil && rng.float() < 0.5 { pendingSputters += 1 }    // Vol_ShiftSweets [H]
    }

    private func beginDownShift(_ g: Int) {
        guard g != Gear.neutral else { return }
        cleanUp()
        shiftState = .downDisengage
        let at = prevRPM
        engRPM = at
        shiftTRQ = SFXInterp(physTRQ, 0, 50)
        shiftRPM = SFXInterp(at, min(10000, max(1000, at - shift.downFallRPM)), shift.downFallT)
        shiftVol = SFXInterp(0, 0, 1)
        if physRPM > 3000 { pendingShiftSounds.append((0, shift.downVol / 32767, shift.downDelay)) }   // AEMS_SHIFTING_DOWN = 0
    }

    private func cleanUp() { shiftState = .none }

    private func updateShift(_ t: Float) {
        guard shiftState != .none else { return }
        switch shiftState {
        case .upDisengage, .upEngaging, .downDisengage, .downRise, .downFall: shiftRPM.update(t)
        case .downReattach: shiftRPM.update(t, target: physRPM)
        case .none: break
        }
        switch shiftState {
        case .upEngaging, .downReattach: shiftTRQ.update(t, target: physTRQ)
        default: shiftTRQ.update(t)
        }
        shiftVol.update(t)
        tStage += t * 1000
        let last = graph.pts.last?.x ?? 0
        switch shiftState {
        case .upDisengage:
            if tStage > last {
                stage += 1
                if stage < shift.upDisengage.count {
                    let p = shift.upDisengage[stage]
                    graph = ShiftSpec.graph(p.curve, time: p.time, rpm: p.rpm)
                    tStage = t * 1000; rpmOffset = shiftRPM.value
                } else {
                    shiftState = .upEngaging
                    let e = shift.upEngage
                    graph = ShiftSpec.graph(e.curve, time: e.time, rpm: e.rpm)
                    tStage = 0; rpmOffset = physRPM
                    shiftTRQ = SFXInterp(physTRQ, physTRQ, 0)
                    shiftVol = SFXInterp(shift.upAttackVol, 0, shift.upAttackT)
                    return
                }
            }
            let r = min(10000, max(1000, rpmOffset + graph.value(tStage)))
            shiftRPM = SFXInterp(r, r, 0)
        case .upEngaging:
            if tStage > last { cleanUp(); return }   // SHFT_UP_LFO sin LFO: se termina aquí
            rpmOffset = physRPM
            let r = min(10000, max(1000, rpmOffset + graph.value(tStage)))
            shiftRPM = SFXInterp(r, r, 0)
        case .downDisengage:
            if shiftRPM.finished {
                shiftState = .downRise
                var len = shift.downRiseT
                if lastGear < Gear.first + 1 { len *= 0.7 }
                let low: Float = engRPM < 1500 ? 0 : 1
                shiftRPM = SFXInterp(engRPM, min(10000, max(1000, physRPM + shift.downRiseRPM * low)), len, eq: true)
                shiftTRQ = SFXInterp(out.torque, 100 * low, 215)
            }
        case .downRise:
            if shiftRPM.finished {
                shiftState = .downFall
                let low: Float = engRPM < 1500 ? 0 : 1
                shiftRPM = SFXInterp(engRPM, engRPM - shift.downEngFallRPM * low, shift.downEngFallT)
                shiftTRQ = SFXInterp(100 * low, 0, 215)
            }
        case .downFall:
            if shiftRPM.finished {
                shiftState = .downReattach
                let at = min(800, abs((engRPM - physRPM) * shift.downReattach))
                shiftRPM = SFXInterp(engRPM, physRPM, at, eq: true)
                shiftTRQ = SFXInterp(0, physTRQ, 60)
            }
        case .downReattach:
            if shiftRPM.finished { cleanUp() }
        case .none: break
        }
    }
}

/// Turbo y compresor [D: CARSFX_Turbo.cpp]: carga del turbo con el par, descarga (blow-off) al soltar.
final class TurboAudio {
    let chargeTime: Float, leakRate: Float, volSpool: Float, volBlow1: Float, volBlow2: Float
    private(set) var spoolPercent: Float = 0
    private var charge: Float = 0
    private var reachedPeak = false, peakTime: Float = 0
    enum State { case none, spooling, blowoff }
    private(set) var state = State.none
    /// Descarga pendiente: (id 1 = pequeña, 2–3 = grande, volumen 0…1)
    var pendingBlowoff: (id: Int, vol: Float)?
    var spoolGain: Float = 0
    private var rng = SplitMix(seed: 0x7b0)

    init(_ t: [String: Any]) {
        func f(_ k: String, _ d: Float) -> Float { (t[k] as? NSNumber)?.floatValue ?? d }
        chargeTime = max(1, f("ChargeTime", 20)); leakRate = f("Leak_Rate", 0.5)
        volSpool = f("Vol_Spool", 10000); volBlow1 = f("Vol_Blowoff1", 26000); volBlow2 = f("Vol_Blowoff2", 26000)
    }

    /// A 30 Hz, con el par del sonido (0…100) y las RPM de audio.
    func step(torque: Float, physRPM: Float, dt: Float) {
        let turbo = torque > 20 ? torque * 0.01 : 0
        charge += turbo > 0.01 ? turbo : -leakRate
        let rpmScale = min(1, max(0, (physRPM - 1000) * 0.01)) * 0.6 + 0.4
        charge = min(chargeTime * rpmScale, max(0, charge))
        if charge >= chargeTime * rpmScale - 1e-4 && !reachedPeak { reachedPeak = true; peakTime = 0 }
        else if charge < chargeTime * rpmScale - 1e-4 { reachedPeak = false }
        spoolPercent = charge / chargeTime
        var v = volSpool
        if reachedPeak { peakTime += dt; if peakTime > 1 { v *= 0.6 } }   // m_SpoolDuck: se sostiene 1 s y baja [I]
        spoolGain = v / 32767 * min(1, spoolPercent * 1.4)
        switch state {
        case .none: if torque > 20 { state = .spooling }
        case .spooling:
            if torque < 20 {
                state = .blowoff
                var id = 1
                if spoolPercent > 0.75 { id = Int(rng.next() % 2) + 2 }
                let vol = (id == 1 ? volBlow1 : volBlow2) * spoolPercent / 32767
                if vol > 0.02 { pendingBlowoff = (id, vol) }
                charge = 0
            }
        case .blowoff: state = .none
        }
    }
}
