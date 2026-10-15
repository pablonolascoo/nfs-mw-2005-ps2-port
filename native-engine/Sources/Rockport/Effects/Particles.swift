// Sistema de partículas del juego portado de Ecstasy/EmitterSystem.cpp [D] con los datos del VLT (EffectsLibrary.swift):
//  - EmitterGroup → Emitter → partículas, con el ciclo de encendido/apagado (EmitterControl::Update), el número por segundo con
//    acumulación (Emitter::SpawnParticles), volumen, cono o disco de salida, velocidad heredada, arrastre, gravedad, aceleración,
//    curvas de color y tamaño/giro por vida (polinomio de las 4 claves, CalculateBases) y animación en rejilla N×N.
//  - Grupos del mundo: se crean a FarClip + 20 m por delante de la cámara (coseno 0,55) y se borran al alejarse
//    (ServiceWorldEffects); las partículas mueren si el grupo queda más lejos que su FarClip (UpdateParticles).
//  - Tope global de partículas: el PS2 usa 1024 (ParticleSlotPool) [D]; aquí `maxParticles` (2048 [I]: hay GPU de sobra, pero
//    no hace falta más para la misma densidad).
// La simulación es de CPU (≤ 2048 partículas: < 0,1 ms) y el dibujo, billboards instanciados (EffectsRenderer.swift).
import Foundation
import simd

/// Generador del juego: bRandom(rango, &semilla) devuelve [0, rango) [D: bWare]. LCG propio [I] (no hace falta la misma serie).
@inline(__always) func bRandom(_ range: Float, _ seed: inout UInt32) -> Float {
    seed = seed &* 1664525 &+ 1013904223
    return Float(seed >> 8) * (1.0 / 16777216.0) * range
}

/// Banderas de creación del juego (CreationContextFlags [D]).
struct EmitterFlags: OptionSet {
    let rawValue: UInt32
    static let alwaysClose = EmitterFlags(rawValue: 0x20000)     // sin prueba de distancia (FE)
    static let gameplay = EmitterFlags(rawValue: 0x40000)        // prioridad alta (coche del jugador)
    static let forcedOneShot = EmitterFlags(rawValue: 0x400000)
    static let world = EmitterFlags(rawValue: 0x8000000)
    static let surface = EmitterFlags(rawValue: 0x40000000)      // humo de ruedas (TireState)
}

struct Particle {
    var pos: float3
    var vel: float3
    var acc: float3
    var life: Float          // segundos que le quedan
    var initialAngle: UInt8  // mInitialAngle (ángulo/256)
    var rotOffset: UInt8
    var animPhase: Float     // 0…1 del ciclo de la animación
    var size: Float = 0      // medio lado (m)
    var angle: UInt16 = 0    // bAngle (65536 = 360°)
    var colour = float4.zero // bytes 0…255
}

final class Emitter {
    let def: EmitterDef
    let defIndex: Int
    enum State { case notStarted, delaying, onCycle, offCycle, on, off }
    var state = State.notStarted
    var time: Float = 0
    var accumulation: Float = 0
    var seed: UInt32
    var particles: [Particle] = []
    var minIntensity: Float = 0, maxIntensity: Float = 999_999
    var forcedOneShot = false
    var lastOrigin: float3? = nil
    init(def: EmitterDef, index: Int, seed: UInt32) { self.def = def; defIndex = index; self.seed = seed }

    /// EmitterControl::Update [D]. Devuelve si hay que generar partículas y el tiempo sobrante.
    func control(_ dt: Float, _ rollover: inout Float, _ aseed: inout UInt32) -> Bool {
        rollover = 0
        let d = def
        var startDelay = d.startDelay
        if d.startDelayRandom { startDelay = bRandom(startDelay, &aseed) }
        let isOneShot = d.isOneShot || forcedOneShot
        let hasStartDelay = startDelay != 0
        var hasOn = d.onCycle != 0 || d.onCycleVariance != 0
        let hasOff = d.offCycle != 0 || d.offCycleVariance != 0
        if hasOn && !isOneShot && !hasOff { hasOn = false }
        switch state {
        case .notStarted:
            if hasStartDelay { state = .delaying; time = startDelay - dt; return false }
            if hasOn { state = .onCycle; time = max(0, d.onCycle + bRandom(d.onCycleVariance, &aseed) - dt); return true }
            time = 0; state = .on; return true
        case .delaying:
            time -= dt
            if time > 0 { return false }
            rollover = time
            if hasOn { state = .onCycle; time += d.onCycle + bRandom(d.onCycleVariance, &aseed); return true }
            time = 0; state = .on; return true
        case .onCycle:
            time -= dt
            if time > 0 { return true }
            rollover = time + dt
            if isOneShot { state = .off; time = 0; return true }
            state = .offCycle; time += d.offCycle + bRandom(d.offCycleVariance, &aseed)
            return true
        case .offCycle:
            time -= dt
            if time > 0 { return false }
            rollover = time
            state = .onCycle; time += d.onCycle + bRandom(d.onCycleVariance, &aseed)
            return true
        case .on: return true
        case .off: return false
        }
    }
}

final class EmitterGroup {
    let def: EmitterGroupDef
    var emitters: [Emitter]
    /// Matriz local → mundo (bMatrix4: columnas 0…2 = ejes del emisor, 3 = posición).
    var matrix: float4x4 = .identity
    var inheritVelocity = float3.zero
    var intensity: Float = 1
    let flags: EmitterFlags
    var autoUpdate = false
    var enabled = true
    /// Sin dueño (TireState lo soltó, SetOldSurfaceEffectFlag): se borra cuando no le quedan partículas.
    var orphan = false
    var position: float3 { float3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z) }
    var particleCount: Int { emitters.reduce(0) { $0 + $1.particles.count } }

    init(def: EmitterGroupDef, library: EffectsLibrary, flags: EmitterFlags, seed: inout UInt32) {
        self.def = def; self.flags = flags
        let setRanges = def.intensityRanges.count == def.emitters.count
        emitters = def.emitters.enumerated().map { (k, i) in
            let e = Emitter(def: library.emitter(i), index: i, seed: UInt32(bitPattern: Int32(truncatingIfNeeded: Int(bRandom(2.1474836e9, &seed)))))
            if setRanges {
                var r = def.intensityRanges[k]
                if r.x == r.y || r.x > r.y { r = SIMD2(0, 1) }
                e.minIntensity = r.x; e.maxIntensity = r.y
            }
            e.forcedOneShot = flags.contains(.forcedOneShot)
            return e
        }
    }
}

/// El sistema: grupos vivos, puntos de interés (cámaras) y simulación.
final class ParticleSystem {
    let library: EffectsLibrary
    private(set) var groups: [EmitterGroup] = []
    var maxParticles = 2048
    private(set) var totalParticles = 0
    private var seed: UInt32 = 0x1234_5678
    private var controlSeed: UInt32 = 0x0BAD_F00D
    /// Cámaras de este fotograma (posición, dirección): una por vista, como mInterestPoints [D].
    var interest: [(pos: float3, dir: float3)] = []

    /// Emisores del mundo (EmitterLibrary con SectionNumber ≠ 0) y su grupo vivo.
    private var world: [(placed: PlacedEmitter, group: EmitterGroup?, triggerState: [Int], triggerEnd: [Float])] = []
    private var worldGrid: [SIMD2<Int32>: [Int]] = [:]
    private let cell: Float = 250
    private var clock: Float = 0

    init(library: EffectsLibrary) {
        self.library = library
        world = library.worldEmitters.map { ($0, nil, Array(repeating: 1, count: $0.triggers.count), Array(repeating: 0, count: $0.triggers.count)) }
        for (i, w) in world.enumerated() {
            let p = w.placed.matrix.columns.3
            worldGrid[SIMD2(Int32(floor(p.x / cell)), Int32(floor(p.y / cell))), default: []].append(i)
        }
    }

    // MARK: Grupos

    func makeGroup(_ name: String, flags: EmitterFlags, matrix: float4x4 = .identity) -> EmitterGroup? {
        guard let d = library.groups[name], !d.emitters.isEmpty else { return nil }
        let g = EmitterGroup(def: d, library: library, flags: flags, seed: &seed)
        g.matrix = matrix
        groups.append(g)
        return g
    }
    func remove(_ g: EmitterGroup) {
        totalParticles -= g.particleCount
        groups.removeAll { $0 === g }
    }
    /// Suelta un grupo: deja de generar y se borra cuando sus partículas mueren (SetOldSurfaceEffectFlag + UnSubscribe).
    func release(_ g: EmitterGroup) { g.orphan = true; g.enabled = false }

    // MARK: Distancias (IsCloseEnough [D])

    private func closeEnough(_ p: float3, farClip: Float, frustum: Bool, cosFov: Float) -> Bool {
        if interest.isEmpty { return true }
        for c in interest {
            let d = simd_distance(p, c.pos)
            if d < farClip {
                if !frustum { return true }
                if d < 1e-3 || simd_dot((p - c.pos) / d, c.dir) > cosFov { return true }
            }
        }
        return false
    }
    private func closeEnough(_ g: EmitterGroup, frustum: Bool, cosFov: Float) -> Bool {
        g.flags.contains(.alwaysClose) || closeEnough(g.position, farClip: g.def.farClip, frustum: frustum, cosFov: cosFov)
    }

    // MARK: Paso

    /// ServiceWorldEffects + disparadores por cercanía (GetEmitterGroupsToTrigger) [D]. `triggerAt` = coches que disparan.
    func serviceWorld(triggerAt: [float3]) {
        guard !interest.isEmpty else { return }
        var near = Set<Int>()
        for c in interest {
            let r = Int32(ceil(220 / cell))
            let cx = Int32(floor(c.pos.x / cell)), cy = Int32(floor(c.pos.y / cell))
            for dy in -r...r { for dx in -r...r { for i in worldGrid[SIMD2(cx + dx, cy + dy)] ?? [] { near.insert(i) } } }
        }
        // Grupos vivos que ya no están en las casillas cercanas: fuera
        for i in world.indices where world[i].group != nil && !near.contains(i) { remove(world[i].group!); world[i].group = nil }
        for i in near {
            let w = world[i]
            guard let gd = library.groups[w.placed.group] else { continue }
            let p = float3(w.placed.matrix.columns.3.x, w.placed.matrix.columns.3.y, w.placed.matrix.columns.3.z)
            if !w.placed.triggers.isEmpty {
                // Disparadores: estado 1 armado → 2 activo (grupo vivo) → 3 esperando el reinicio
                for k in w.placed.triggers.indices {
                    let t = w.placed.triggers[k]
                    switch world[i].triggerState[k] {
                    case 1:
                        if triggerAt.contains(where: { simd_distance_squared($0, t.pos) < t.radius * t.radius }), world[i].group == nil {
                            world[i].triggerState[k] = 2
                            if let g = makeGroup(w.placed.group, flags: [.world, .forcedOneShot], matrix: w.placed.matrix) {
                                updateGroup(g, dt: 1.0 / 30)   // una ráfaga y se suelta
                                release(g)
                                world[i].group = g
                            }
                        }
                    case 2:
                        if world[i].group == nil || !groups.contains(where: { $0 === world[i].group }) { world[i].group = nil; world[i].triggerState[k] = 3; world[i].triggerEnd[k] = clock }
                    default:
                        if clock - world[i].triggerEnd[k] > t.reset { world[i].triggerState[k] = 1 }
                    }
                }
                continue
            }
            let soon = closeEnough(p, farClip: gd.farClip + 20, frustum: true, cosFov: 0.55)
            if soon, w.group == nil {
                if let g = makeGroup(w.placed.group, flags: [.world], matrix: w.placed.matrix) { g.autoUpdate = true; world[i].group = g }
            } else if !soon, let g = w.group {
                remove(g); world[i].group = nil
            }
        }
    }

    /// Un paso de `dt` s: grupos con actualización automática (mundo, frontend) y todas las partículas.
    func update(dt: Float) {
        guard dt > 0 else { return }
        clock += dt
        for g in groups where g.autoUpdate { updateGroup(g, dt: dt) }
        updateParticles(dt: dt)
        groups.removeAll { g in
            let dead = (g.orphan && g.particleCount == 0) || g.emitters.isEmpty
            return dead
        }
    }

    /// EmitterGroup::Update [D]: estado de cada emisor y nuevas partículas.
    func updateGroup(_ g: EmitterGroup, dt: Float) {
        guard g.enabled, dt > 0 else { return }
        let close = closeEnough(g, frustum: !g.flags.contains(.gameplay), cosFov: 0.7)
        for e in g.emitters {
            var roll: Float = 0
            let spawn = e.control(dt, &roll, &controlSeed)
            if spawn && close && dt + roll > 0 { spawnParticles(e, group: g, dt: dt + roll) }
        }
        g.emitters.removeAll { $0.state == .off && $0.particles.isEmpty }
        if g.emitters.contains(where: { $0.state == .off }) && g.emitters.allSatisfy({ $0.state == .off }) { g.orphan = true }
    }

    /// Emitter::SpawnParticles [D].
    private func spawnParticles(_ e: Emitter, group g: EmitterGroup, dt dtIn: Float) {
        let intensity = g.intensity
        guard intensity > 0, intensity <= e.maxIntensity, intensity >= e.minIntensity else { return }
        let d = e.def
        var rs = e.seed
        let angleRange = d.initialAngleRange * 182.04445
        let angle0 = -angleRange * 0.5
        let num = intensity * d.numParticles
        let numVar = d.numParticlesVariance * num
        let miVar = d.motionInheritVariance * d.motionInherit
        let lifeVar = d.lifeVariance * d.life
        let speedVar = d.speedVariance * d.speed
        let life = d.life - lifeVar, inherit0 = d.motionInherit - miVar, speed = d.speed - speedVar
        let oneShot = d.isOneShot || e.forcedOneShot
        var hasOn = d.onCycle != 0 || d.onCycleVariance != 0
        let hasOff = d.offCycle != 0 || d.offCycleVariance != 0
        if hasOn && !oneShot && !hasOff { hasOn = false }
        var useDt = dtIn
        if oneShot && !hasOn { useDt = life }
        let fnum = useDt * (num - numVar)
        var count = Int(fnum)
        if count == 0 {
            e.accumulation += fnum
            if e.accumulation > 1 { count = 1; e.accumulation -= 1 }
        }
        let m = g.matrix
        let ax = float3(m.columns.0.x, m.columns.0.y, m.columns.0.z), ay = float3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let az = float3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        for _ in 0..<count {
            var vel = float3.zero, acc = float3.zero
            let pspeed = speed + bRandom(speedVar, &rs)
            if speed != 0 {
                var dir: float3
                if d.spreadAsDisc {
                    // GetDiscVelocity: dirección en el plano XY local girada ±SpreadAngle/2 sobre Y
                    let at = (bRandom(d.spreadAngle, &rs) - d.spreadAngle * 0.5) * .pi / 180
                    let azm = (bRandom(360, &rs) - 180) * .pi / 180
                    let p = float3(cos(azm), sin(azm), 0)
                    let r = float3(p.x * cos(at) + p.z * sin(at), p.y, -p.x * sin(at) + p.z * cos(at))
                    dir = ax * r.x + ay * r.y + az * r.z
                } else {
                    // GetConeVelocity: eje Z del emisor girado al azar ±SpreadAngle/2 sobre X, Y y Z
                    let h = d.spreadAngle * 0.5
                    let rx = (bRandom(d.spreadAngle, &rs) - h) * .pi / 180, ry = (bRandom(d.spreadAngle, &rs) - h) * .pi / 180
                    let rz = (bRandom(d.spreadAngle, &rs) - h) * .pi / 180
                    let rot = simd_quatf(angle: rx, axis: float3(1, 0, 0)) * simd_quatf(angle: ry, axis: float3(0, 1, 0)) * simd_quatf(angle: rz, axis: float3(0, 0, 1))
                    dir = rot.act(az)
                }
                vel = dir * pspeed
            } else if d.eliminateRandomness {
                vel = d.velStart + float3(bRandom(d.velDelta.x, &rs), bRandom(d.velDelta.y, &rs), bRandom(d.velDelta.z, &rs))
                acc = d.accStart + float3(bRandom(d.accDelta.x, &rs), bRandom(d.accDelta.y, &rs), bRandom(d.accDelta.z, &rs))
            } else {
                let rz = d.velStart.z - d.velDelta.z + 2 * bRandom(d.velDelta.z, &rs)
                let ry = d.velStart.y - d.velDelta.y + 2 * bRandom(d.velDelta.y, &rs)
                let rx = d.velStart.x - d.velDelta.x + 2 * bRandom(d.velDelta.x, &rs)
                vel = az * rz + ay * ry + ax * rx
                acc = float3(d.accStart.x - d.accDelta.x + 2 * bRandom(d.accDelta.x, &rs),
                             d.accStart.y - d.accDelta.y + 2 * bRandom(d.accDelta.y, &rs),
                             d.accStart.z - d.accDelta.z + 2 * bRandom(d.accDelta.z, &rs))
            }
            let lp = d.volCenter + float3(bRandom(d.volExtent.x, &rs) - d.volExtent.x * 0.5, bRandom(d.volExtent.y, &rs) - d.volExtent.y * 0.5,
                                          bRandom(d.volExtent.z, &rs) - d.volExtent.z * 0.5)
            let wp = m * float4(lp, 1)
            var plife = life + bRandom(lifeVar, &rs)
            let fangle = angle0 + bRandom(angleRange, &rs)
            if d.motionInherit != 0 {
                let inh = min(max(inherit0 + bRandom(miVar, &rs), 0), 1)
                if !d.motionLive { vel += g.inheritVelocity * inh }
            }
            let angle16 = UInt16(truncatingIfNeeded: Int(fangle) & 0xfffe)
            var pangle = angle16
            let sm = UInt8(truncatingIfNeeded: Int(Float(angle16) * (1.0 / 256)))
            if d.randomRotationDirection { pangle = angle16 | UInt16(rs & 1) }
            plife = min(plife, 60)
            guard totalParticles < maxParticles else { continue }
            var p = Particle(pos: float3(wp.x, wp.y, wp.z), vel: vel, acc: acc, life: plife, initialAngle: sm,
                             rotOffset: UInt8(min(max(bRandom(d.rotationVariance, &rs), 0), 1) * 255), animPhase: 0)
            if d.animType > 0 {
                let frames = Float(d.animType * d.animType)
                p.animPhase = d.randomStartFrame ? bRandom(frames - 1, &rs) / max(frames - 1, 1) : 0
            }
            // GetInitialParticleColorAndSize (t = 0)
            let x = d.extra.eval(0)
            p.size = x.x
            let ad = UInt16(truncatingIfNeeded: Int(x.y))
            p.angle = pangle % 2 == 0 ? pangle &+ ad : pangle &- ad
            p.colour = simd_clamp(d.colour.eval(0), float4.zero, float4(repeating: 255))
            e.particles.append(p)
            totalParticles += 1
        }
        e.seed = rs
        if d.motionLive, e.lastOrigin == nil { e.lastOrigin = g.position }
    }

    /// EmitterSystem::UpdateParticles [D].
    private func updateParticles(dt: Float) {
        for g in groups {
            let keep = closeEnough(g, frustum: false, cosFov: 0.7)
            for e in g.emitters {
                if e.particles.isEmpty { e.lastOrigin = nil; continue }
                if !keep { totalParticles -= e.particles.count; e.particles.removeAll(keepingCapacity: true); continue }
                let d = e.def
                // MotionLive: las partículas siguen al emisor (llama del nitro pegada al escape) [I]
                var shift = float3.zero
                if d.motionLive { let o = g.position; if let l = e.lastOrigin { shift = o - l }; e.lastOrigin = o }
                let frames = d.animType * d.animType
                var n = 0
                for k in e.particles.indices {
                    var p = e.particles[k]
                    if p.life <= dt { continue }
                    if frames > 0 { p.animPhase += dt * d.animFPS / Float(frames); p.animPhase -= floor(p.animPhase) }
                    var v = p.vel
                    if d.drag > 0 { v += v * max(-1, -dt * d.drag * simd_length(v)) }
                    if d.gravity != 0 { v.z -= d.gravity * dt } else { v += p.acc * dt }
                    p.pos += v * dt + shift
                    p.vel = v
                    p.life -= dt
                    let t = 1 - p.life / max(d.life, 1e-4)
                    let x = d.extra.eval(t)
                    p.size = x.x
                    let base = UInt16(p.initialAngle) &* 257
                    let ad = UInt16(truncatingIfNeeded: Int(x.y + Float(p.rotOffset) / 255 * x.y))
                    p.angle = base % 2 == 0 ? base &+ ad : base &- ad
                    p.colour = simd_clamp(d.colour.eval(t), float4.zero, float4(repeating: 255))
                    if !d.noKillAtAlpha && Int(p.colour.w) <= Int(d.alphaToKillAt) { continue }
                    e.particles[n] = p; n += 1
                }
                totalParticles -= e.particles.count - n
                e.particles.removeLast(e.particles.count - n)
            }
        }
    }

    /// Calienta un grupo nuevo (los del frontend y los del mundo al empezar): `seconds` de simulación a 15 Hz sin culling.
    func prewarm(_ g: EmitterGroup, seconds: Float) {
        let saved = interest
        interest = []
        let steps = Int(seconds * 15)
        for _ in 0..<steps {
            updateGroup(g, dt: 1.0 / 15)
            let others = groups
            groups = [g]
            updateParticles(dt: 1.0 / 15)
            groups = others
        }
        interest = saved
    }

    /// Calienta los grupos del mundo que están vivos (primer fotograma de una vista nueva).
    func prewarmWorld(seconds: Float) { for w in world { if let g = w.group, w.placed.triggers.isEmpty { prewarm(g, seconds: seconds) } } }
}
