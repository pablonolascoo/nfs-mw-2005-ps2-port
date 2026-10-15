// Efectos de los coches con física (jugador, rivales de carrera, jugadores de la pantalla partida), como el juego:
//  - Ruedas: TireState::DoFX / SetSurface / Effect::Update [D: World/CarRenderConn.cpp]. Por rueda en el suelo, tres efectos de la
//    superficie (`simsurface`): deslizamiento lateral (TireSlideEffects), patinaje (TireSlipEffects) y rodadura (TireDriveEffects),
//    con intensidad UMath::Ramp(valor, velMín, velMáx) del registro. Humo de derrape y quemada de rueda = fxtd_sk_asphalt /
//    fxtd_sl_asphalt [V]. La colisión exportada no guarda el material del suelo: se usa «asphalt» [I].
//  - Escapes: VehicleRenderConn pipe effects [D]: con nitro, el grupo de NOSEffect (`carexhaustnos` → fxcar_nos [V]) en cada
//    marcador LEFT/RIGHT_EXHAUST del modelo (dirección = eje Z del marcador) [V: extras.marcadores].
//  - Golpes: chispas `carhitwall` (fxcar_impactl) [V] cuando la velocidad cambia de golpe (> 4 m/s en un fotograma) [I: el
//    motor aún no publica los contactos; el juego lo dispara desde la colisión].
import Foundation
import simd

/// Marcadores de un modelo de coche (cars/<NOMBRE>.glb, extras.marcadores): todos, también los repetidos (luces de policía).
enum CarMarkers {
    private static var cache: [String: [(name: String, matrix: float4x4)]] = [:]
    private static let lock = NSLock()
    static func of(_ model: String, data: GameData) -> [(name: String, matrix: float4x4)] {
        lock.lock(); if let m = cache[model] { lock.unlock(); return m }; lock.unlock()
        var out: [(String, float4x4)] = []
        let url = data.url("cars/\(model).glb")
        if let d = try? Data(contentsOf: url), d.count > 20 {
            let jl = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
            if d.count >= 20 + jl, let j = try? JSONSerialization.jsonObject(with: d.subdata(in: 20..<(20 + jl))) as? [String: Any] {
                var seen = Set<String>()
                for n in j["nodes"] as? [[String: Any]] ?? [] {
                    guard let ex = n["extras"] as? [String: Any], let ms = ex["marcadores"] as? [[String: Any]] else { continue }
                    for m in ms {
                        guard let nm = m["nombre"] as? String, let a = m["matriz"] as? [NSNumber], a.count == 16 else { continue }
                        let f = a.map(\.floatValue)
                        // El mismo marcador sale en cada variante de la pieza (BASE, KIT00_BODY…): uno por nombre y posición
                        let key = "\(nm)|\(Int(f[12] * 100))|\(Int(f[13] * 100))|\(Int(f[14] * 100))"
                        if !seen.insert(key).inserted { continue }
                        out.append((nm, float4x4(columns: (float4(f[0], f[1], f[2], f[3]), float4(f[4], f[5], f[6], f[7]),
                                                           float4(f[8], f[9], f[10], f[11]), float4(f[12], f[13], f[14], f[15])))))
                    }
                }
            }
        }
        lock.lock(); cache[model] = out; lock.unlock()
        return out
    }
}

final class CarEffects {
    /// TireState::Effect [D]: un grupo vivo por efecto mientras la intensidad > 0.
    final class TireFX {
        var key: String?
        var minV: Float = 0, maxV: Float = 0
        var group: EmitterGroup?
        func set(_ r: TireEffectRecord?) {
            minV = r?.minSpeed ?? 0; maxV = r?.maxSpeed ?? 0
            if key != r?.group { key = r?.group }
        }
    }
    final class State {
        weak var car: Car?
        var tires: [(slide: TireFX, slip: TireFX, drive: TireFX)] = (0..<4).map { _ in (TireFX(), TireFX(), TireFX()) }
        var pipes: [EmitterGroup?] = []
        var lastVel: float3?
        var hitCooldown: Float = 0
        var seen = 0
        init(car: Car) { self.car = car }
    }

    /// SlipFX / SkidFX del atributo `ecar` (no exportado): escala de patinaje y deslizamiento [I].
    static var slipFX: Float = 0.5, skidFX: Float = 0.5
    let particles: ParticleSystem
    let data: GameData
    private var states: [ObjectIdentifier: State] = [:]
    private var frame = 0
    var surface = "asphalt"

    init(particles: ParticleSystem, data: GameData) { self.particles = particles; self.data = data }

    func update(cars: [Car], dt: Float) {
        guard dt > 0 else { return }
        frame += 1
        let lib = particles.library
        let rec = lib.tireEffects[surface] ?? lib.tireEffects["default"]
        for car in cars {
            let id = ObjectIdentifier(car)
            let s = states[id] ?? { let n = State(car: car); states[id] = n; return n }()
            s.seen = frame
            let parts = car.partMatrices
            let body = parts[0]
            let vel = car.velocity
            let speed = simd_length(vel)
            let rot = float4x4(columns: (body.columns.0, body.columns.1, body.columns.2, float4(0, 0, 0, 1)))
            // Ruedas: física 0 FL, 1 FR, 2 RL, 3 RR → piezas 1 + [0, 1, 3, 2]
            if let v = car.vehicle {
                let partOf = [1, 2, 4, 3]
                for i in 0..<4 {
                    let t = v.susp.tires[i]
                    let fx = s.tires[i]
                    fx.slide.set(rec?.slide.first); fx.slip.set(rec?.slip.first); fx.drive.set(rec?.drive.first)
                    let hub = parts[partOf[i]].columns.3
                    let ground = float3(hub.x, hub.y, hub.z - car.wheelRadius)
                    if !t.isOnGround { for e in [fx.slide, fx.slip, fx.drive] { stop(e) }; continue }
                    let slip = abs(t.slip) * CarEffects.slipFX, skid = abs(t.lateralSpeed) * CarEffects.skidFX
                    run(fx.slip, value: slip, at: ground, rot: rot, vel: vel, dt: dt)
                    run(fx.slide, value: skid, at: ground, rot: rot, vel: vel, dt: dt)
                    run(fx.drive, value: speed, at: ground, rot: rot, vel: vel, dt: dt)
                }
            }
            // Escapes con nitro (pipe effects)
            let markers = CarMarkers.of(car.modelName, data: data).filter { $0.name.hasSuffix("_EXHAUST") }
            if s.pipes.count != markers.count { s.pipes.forEach { if let g = $0 { particles.release(g) } }; s.pipes = Array(repeating: nil, count: markers.count) }
            let nos = car.isNOSEngaged
            for (k, m) in markers.enumerated() {
                if nos {
                    if s.pipes[k] == nil { s.pipes[k] = particles.makeGroup(lib.effectGroups["carexhaustnos"] ?? "fxcar_nos", flags: [.gameplay]) }
                    if let g = s.pipes[k] {
                        g.matrix = body * m.matrix
                        g.inheritVelocity = vel
                        particles.updateGroup(g, dt: dt)
                    }
                } else if let g = s.pipes[k] { particles.release(g); s.pipes[k] = nil }
            }
            // Golpes: chispas en el lado del choque [I]
            s.hitCooldown -= dt
            if let lv = s.lastVel {
                let dv = vel - lv
                let horiz = float3(dv.x, dv.y, 0)
                if simd_length(horiz) > 4, s.hitCooldown <= 0 {
                    s.hitCooldown = 0.3
                    let dir = simd_normalize(-horiz)
                    let c = float3(body.columns.3.x, body.columns.3.y, body.columns.3.z)
                    let p = c + dir * (car.halfLength * 0.8) + float3(0, 0, 0.5)
                    let n = simd_normalize(horiz)
                    let side = simd_normalize(simd_cross(n, float3(0, 0, 1)) + float3(0, 0, 1e-4))
                    let m = float4x4(columns: (float4(side, 0), float4(simd_cross(n, side), 0), float4(n, 0), float4(p, 1)))
                    if let g = particles.makeGroup(lib.effectGroups["carhitwall"] ?? "fxcar_impactl", flags: [.gameplay, .forcedOneShot], matrix: m) {
                        g.intensity = min(1, simd_length(horiz) / 12)
                        g.inheritVelocity = vel
                        particles.updateGroup(g, dt: dt)      // una ráfaga (Effect::Fire) y se suelta
                        particles.release(g)
                    }
                }
            }
            s.lastVel = vel
        }
        // Coches que ya no están: sus efectos se sueltan
        for (k, s) in states where s.seen != frame || s.car == nil {
            for t in s.tires { for e in [t.slide, t.slip, t.drive] { stop(e) } }
            s.pipes.forEach { if let g = $0 { particles.release(g) } }
            states[k] = nil
        }
    }

    /// TireState::Effect::Update [D].
    private func run(_ e: TireFX, value: Float, at pos: float3, rot: float4x4, vel: float3, dt: Float) {
        let r = e.maxV - e.minV
        let intensity: Float = r > 1e-6 ? max(0, min((value - e.minV) / r, 1)) : 0
        guard intensity > 0, let key = e.key else { stop(e); return }
        if e.group == nil || e.group?.def.name != key {
            stop(e)
            e.group = particles.makeGroup(key, flags: [.surface])
        }
        guard let g = e.group else { return }
        var m = rot
        m.columns.3 = float4(pos, 1)
        g.matrix = m
        g.inheritVelocity = vel
        g.intensity = intensity
        particles.updateGroup(g, dt: dt)
    }
    private func stop(_ e: TireFX) { if let g = e.group { particles.release(g); e.group = nil } }
}
