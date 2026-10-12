// Tráfico como AITrafficManager del juego [D: AI/Activities/AITrafficManager.cpp]:
//  - Cada 0,5 s: densidad (1,0 en libre, ×0,75 con persecución), patrón del barrio (zona TRAFFIC_PATTERN), temporizadores
//    por vehículo del patrón (+dt × TrafficDensitySpawnRates(densidad)), un intento de aparición por tic.
//  - Un vehículo del patrón puede salir si su temporizador > Rate, hay menos de MaxInstances (0 = sin límite) y respeta
//    su porcentaje (Percent) del total [V: ai.json trafficPatterns].
//  - Punto de aparición: delante del centro de tráfico, 200 ± 50 m + velocidad, girado al azar ±45°; a veces de cara
//    (probabilidad Lerp(1, 0,5, Ramp(v, 0, 50))); nunca a menos de 150 m del centro ni a menos de 20 m de otro coche.
//  - Carril al azar entre los de tráfico del sentido elegido; sale a min(calle, autopista) × 0,75.
//  - Se borra fuera de pantalla más de OffScreenTime(densidad) s y a más de OffScreenDistance(densidad) m.
import Foundation
import simd

final class TrafficManager {
    unowned let world: AIWorld
    private var tick: Float = 0
    private var timers = [Float](repeating: 0, count: 10)
    private var cursor = 0
    private(set) var pattern: TrafficPattern?

    // Tablas por densidad 0…1 en 11 pasos [D: AITrafficManager.cpp 34-47]
    static let spawnRates: [Float] = [0, 0.05, 0.1, 0.125, 0.2, 0.4, 0.6, 1, 3, 5, 8]
    static let offScreenDistance: [Float] = [130, 120, 110, 100, 90, 80, 70, 60, 55, 45, 40]
    static let offScreenTime: [Float] = [12, 10, 9, 8, 7, 6.5, 6, 5.5, 5, 4.5, 4]
    static func table(_ t: [Float], _ d: Float) -> Float {
        let x = max(0, min(1, d)) * 10, i = min(Int(x), 9)
        return t[i] + (t[i + 1] - t[i]) * (x - Float(i))
    }

    init(world: AIWorld) { self.world = world }

    var density: Float { AIConfig.density * (world.police.inPursuit ? 0.75 : 1) }

    func update(dt: Float) {
        tick += dt
        if tick >= 0.5 { managerTick(tick); tick = 0 }
        // Conducción de cada coche de tráfico
        for v in world.vehicles where v.kind == .traffic {
            if v.mode == .parked { v.speed = 0; v.braking = true; v.applyKnock(collision: world.collision, dt: dt); continue }
            world.stepLane(v, dt: dt, cops: false, field: nil, mu: 0.6, accel: 2)
        }
    }

    private func managerTick(_ dT: Float) {
        let d = density
        // Patrón del barrio
        let p = world.tables.pattern(at: float2(world.center.x, world.center.y))
        if p?.name != pattern?.name {
            pattern = p
            for i in timers.indices { timers[i] = (p.map { i < $0.vehicles.count ? $0.vehicles[i].rate : 0 } ?? 0) * world.rng.float() }
        }
        if let p { world.stats.patternsUsed.insert(p.name) }
        // Borrado
        let offT = TrafficManager.table(TrafficManager.offScreenTime, d), offD = TrafficManager.table(TrafficManager.offScreenDistance, d)
        for v in world.vehicles where v.kind == .traffic {
            let dist = simd_distance(v.pos, world.center)
            if (v.offscreenTime > offT && dist > offD) || dist > AIConfig.hardDespawn || v.deadEnd || (v.crashed && v.offscreenTime > 4 && dist > 30) {
                world.remove(v)
            }
        }
        guard d > 0, let p, !p.vehicles.isEmpty else { return }
        let rate = TrafficManager.table(TrafficManager.spawnRates, d)
        for i in 0..<min(p.vehicles.count, timers.count) { timers[i] += dT * rate }
        guard world.count(.traffic) < AIConfig.maxTraffic else { return }
        // Siguiente vehículo del patrón que cumple las reglas (rotando) [D: NextSpawn]
        let n = min(p.vehicles.count, timers.count)
        let total = world.count(.traffic)
        for k in 0..<n {
            let i = (cursor + k) % n
            let rec = p.vehicles[i]
            guard rec.rate > 0, timers[i] > rec.rate else { continue }
            let same = world.vehicles.filter { $0.kind == .traffic && $0.typeName == rec.name }.count
            if rec.maxInstances > 0 && same >= rec.maxInstances { continue }
            if rec.percent > 0 && same >= max(1, (AIConfig.maxTraffic + 10 - total) * rec.percent / 100) { continue }
            guard let model = world.models.model(rec.model) else { continue }
            cursor = (i + 1) % n
            if spawn(model: model, typeName: rec.name, pattern: p) != nil {
                for j in 0..<n where p.vehicles[j].name == rec.name { timers[j] = 0 }
            }
            break
        }
    }

    /// Busca un punto de aparición en la red [D: FindSpawnPoint, CanTrafficSpawn, FindCollisions].
    @discardableResult
    func spawn(model: AIModel, typeName: String, pattern: TrafficPattern, kind: AIVehicle.Kind = .traffic) -> AIVehicle? {
        let w = world
        let speed = simd_length(w.centerVel)
        for _ in 0..<4 {
            let a = (w.rng.float() * 2 - 1) * (.pi / 4)
            let f = w.centerFwd
            let dir = float3(f.x * cos(a) - f.y * sin(a), f.x * sin(a) + f.y * cos(a), 0)
            let dist = 200 + w.rng.range(-50, 50) + max(simd_dot(w.centerVel, dir), 0)
            let pt = w.center + dir * dist
            let oncoming = w.rng.float() < lerpf(1, 0.5, rampf(speed, 0, 50))
            let travel = oncoming ? -dir : dir
            guard let hit = w.net.nearest(pt, maxDist: 60, filter: { w.net.trafficAllowed($0) && !w.net.segs[$0].has(RoadSegFlags.decision) }) else { continue }
            let tan = w.net.tangent(hit.seg, hit.t)
            let forward = simd_dot(tan, travel) >= 0
            if w.net.segs[hit.seg].has(RoadSegFlags.oneWay) && !forward { continue }
            let lanes = w.net.laneOffsets(hit.seg, forward: forward, end: forward ? 0 : 1)
            if lanes.isEmpty { continue }
            if kind == .cop && w.tables.inZone("noCopSpawn", float2(pt.x, pt.y)) { continue }
            let v = AIVehicle(id: w.newID(), kind: kind, model: model, typeName: typeName)
            v.place(net: w.net, seg: hit.seg, forward: forward, t: hit.t, lane: Int(w.rng.next() % UInt64(lanes.count)), collision: w.collision)
            if !v.groundOK { continue }
            if simd_distance(v.pos, w.center) < 150 { continue }
            if w.vehicles.contains(where: { simd_distance($0.pos, v.pos) < 20 }) { continue }
            setCruise(v, pattern)
            v.speed = min(pattern.speedStreet, pattern.speedHighway) * 0.75
            w.vehicles.append(v)
            if kind == .traffic { w.stats.trafficSpawned += 1 } else { w.stats.copsSpawned += 1 }
            w.stats.modelsUsed.insert(model.name)
            return v
        }
        return nil
    }

    /// Velocidad del tramo: autopista si el segmento tiene 4 o más carriles de tráfico (contando ambos sentidos) [D].
    func setCruise(_ v: AIVehicle, _ p: TrafficPattern?) {
        let net = world.net
        let lanes = max(net.laneOffsets(v.seg, forward: true, end: 0).count + net.laneOffsets(v.seg, forward: false, end: 0).count,
                        net.laneOffsets(v.seg, forward: true, end: 1).count + net.laneOffsets(v.seg, forward: false, end: 1).count)
        let street = p?.speedStreet ?? AITables.mph(35), hwy = p?.speedHighway ?? AITables.mph(55)
        v.cruise = lanes >= 4 ? hwy : street
    }
}
