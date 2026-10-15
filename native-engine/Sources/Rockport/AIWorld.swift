// La IA de Rockport: tráfico (TrafficManager.swift) y policía (PoliceManager.swift) sobre la red de carreteras del juego.
// Engine.swift la crea si existen roads.json y ai.json, y cada fotograma llama a `update` con el estado del jugador.
// El motor de render dibuja los coches con AIRenderer (instanciado) y la HUD de persecución con PursuitHUD.
// Detalle y fuentes: docs/es/14-trafico-y-policia.md.
import Foundation
import Metal
import simd

/// Ajustes de la IA. Los valores del juego vienen de ai.json; aquí solo lo que el PS2 fija por hardware o lo que se elige.
enum AIConfig {
    /// Máximo de coches de tráfico a la vez. El PS2 limita a 10 vehículos activos de todo tipo (NeedsTraffic) [D];
    /// en el Mac se permiten más para una ciudad más viva (se cambia con --traffic-max).
    static var maxTraffic = 20
    /// Máximo de coches de policía activos: 8 [D: AICopManager.cpp 271-285].
    static var maxCops = 8
    /// Densidad de tráfico en libre (1,0 [D]); ×0,75 durante una persecución [D].
    static var density: Float = 1.0
    /// Calor máximo en libre: 5 (el juego guarda el calor recortado a 5 [D]); 6–10 son de eventos.
    static var maxOpenWorldHeat: Float = 5
    /// Tramo de la carrera (bin de la Lista Negra) para ScaleEscalationPerBucket: 0 = inicio de la historia [D].
    static var careerBucket = 0
    /// Activar la policía.
    static var police = true
    /// Distancia dura de borrado (m) para coches que siguen en pantalla muy lejos [I].
    static var hardDespawn: Float = 650
}

struct AIPlayer {
    var exists = false
    var pos = float3(0, 0, 0)
    var yaw: Float = 0
    var speed: Float = 0                 // m/s con signo
    var halfLength: Float = 2.3, halfWidth: Float = 1.0
    var fwd: float3 { float3(cos(yaw), sin(yaw), 0) }
    var vel: float3 { fwd * speed }
}

struct AIStats {
    var trafficSpawned = 0, trafficDespawned = 0, maxTrafficActive = 0
    var copsSpawned = 0, maxCopsActive = 0
    var laneSnaps = 0                    // saltos laterales > 0,6 m en un fotograma (modo carril)
    var wallCrossings = 0                // el paso de un fotograma cruza un muro de colisión (modo carril)
    var offGroundFrames = 0, laneFrames = 0
    var maxGroundError: Float = 0
    var aiOverlaps = 0                   // coches de la IA que se solapan (choques entre ellos)
    var playerHitsTraffic = 0, playerHitsCops = 0
    // Choques del juego (Crash/)
    var copsDamaged = 0, copsDestroyed = 0, carImpacts = 0, smackablesHit = 0, breakersTriggered = 0, copsImmobilized = 0, heliSpawned = 0
    var pursuitsStarted = 0, evaded = 0, busted = 0, maxHeat: Float = 1
    var roadblocks = 0, roadblocksDodged = 0, spikesHit = 0
    var patternsUsed = Set<String>()
    var modelsUsed = Set<String>()
}

final class AIWorld {
    let net: RoadNet
    let tables: AITables
    let models: AIModelLibrary
    let collision: CollisionWorld
    var vehicles: [AIVehicle] = []
    var rng = SplitMix(seed: 0x5EED_2005)
    var time: Float = 0
    var stats = AIStats()
    var player = AIPlayer()
    /// Pantalla partida (Multiplayer/): los demás coches humanos. El tráfico frena por ellos y se aparta al tocarlos
    /// (sin multas ni persecución: la policía sigue al jugador 1) [I].
    var others: [AIPlayer] = []
    var center = float3(0, 0, 0)         // "centro de tráfico": el jugador o la cámara [D: ITrafficCenter]
    var centerFwd = float3(1, 0, 0)
    var centerVel = float3(0, 0, 0)
    private var frustum: Frustum?
    private var nextID = 1
    /// Factor que el motor aplica a la velocidad del jugador tras un golpe (1 = nada). Se consume cada fotograma.
    var playerSpeedFactor: Float = 1
    /// Avisos para el resto del juego (mando con luz, sonido…): persecución activa sí/no.
    var onPursuitChanged: ((Bool) -> Void)?
    private var contacts = Set<Int>()
    var wallSegs: [Int: Int] = [:]
    let debug = ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_AI"] != nil

    var traffic: TrafficManager!
    var police: PoliceManager!
    /// Choques del juego entre coches y con los rompibles (Crash/CrashWorld.swift). Sustituye a `resolveContacts`.
    var crash: CrashWorld?
    /// Helicóptero de la policía (Crash/Heli.swift) y vehículos en el aire que se dibujan con AIRenderer.
    var heli: HeliManager?
    var airVehicles: [AIVehicle] = []

    init?(device: MTLDevice, data: GameData, textures: TextureCache, collision: CollisionWorld) {
        let ru = data.url("roads.json"), au = data.url("ai.json")
        guard FileManager.default.fileExists(atPath: ru.path), FileManager.default.fileExists(atPath: au.path) else {
            fputs("IA: faltan roads.json o ai.json en \(data.root.path) (bun src/cli/ai-attribs.ts <iso> <ID>)\n", stderr); return nil
        }
        do { net = try RoadNet(url: ru); tables = try AITables(url: au) } catch { fputs("IA: \(error)\n", stderr); return nil }
        models = AIModelLibrary(device: device, data: data, textures: textures)
        self.collision = collision
        net.wallTest = { [unowned collision] a, b in collision.hitsWall(from: a, to: b) }
        traffic = TrafficManager(world: self)
        police = PoliceManager(world: self)
        if !ProcessInfo.processInfo.arguments.contains("--no-crash") { crash = CrashWorld(ai: self, data: CrashData.shared(data)) }
        if !ProcessInfo.processInfo.arguments.contains("--no-heli") { heli = HeliManager(ai: self, root: data.root) }
        // Precarga: todos los modelos de los patrones de tráfico y de la tabla de calor
        var names = tables.trafficPatterns.values.flatMap { $0.vehicles.map(\.model) }
        names += tables.heatLevels.flatMap { $0.cops.map(\.model) }.filter { $0 != "COPHELI" }
        models.preload(names)
    }

    func newID() -> Int { nextID += 1; return nextID }

    // MARK: Fotograma
    func update(dt rawDt: Float, player p: AIPlayer, cameraPos: float3, cameraFwd: float3, viewProj: float4x4?) {
        let dt = min(rawDt, 0.1)
        guard dt > 0 else { return }
        time += dt
        player = p
        if p.exists { center = p.pos; centerFwd = p.fwd; centerVel = p.vel }
        else { center = cameraPos; centerFwd = simd_normalize(float3(cameraFwd.x, cameraFwd.y, 0) + 1e-6); centerVel = .zero }
        frustum = viewProj.map { Frustum($0) }
        traffic.update(dt: dt)
        if AIConfig.police { police.update(dt: dt); heli?.update(dt: dt, camera: cameraPos) }
        if let crash, crash.enabled { crash.step(dt: dt) } else { resolveContacts(dt: dt) }
        for v in vehicles {
            v.age += dt
            v.offscreenTime = onScreen(v.pos, radius: v.radius) ? 0 : v.offscreenTime + dt
        }
        stats.maxTrafficActive = max(stats.maxTrafficActive, count(.traffic))
        stats.maxCopsActive = max(stats.maxCopsActive, count(.cop))
    }

    func count(_ k: AIVehicle.Kind) -> Int { vehicles.reduce(0) { $0 + ($1.kind == k ? 1 : 0) } }

    func onScreen(_ p: float3, radius: Float) -> Bool {
        guard let frustum else { return simd_distance(p, center) < 120 }
        return frustum.intersects(AABB(min: p - float3(radius, radius, 0), max: p + float3(radius, radius, radius * 1.5)))
    }

    func remove(_ v: AIVehicle) {
        vehicles.removeAll { $0 === v }
        if v.kind == .traffic { stats.trafficDespawned += 1 }
    }

    // MARK: Conducción por carril (tráfico, patrulla, policía lejos)

    /// Velocidad máxima en curva: v = √(μg / |κ|) con μ = 0,6 tráfico, 1,6 policía [D: AIActionRace.cpp 466-472].
    func curveSpeed(_ v: AIVehicle, mu: Float, top: Float) -> Float {
        let look: Float = max(8, v.speed * 1.2)
        let a = v.axis(net, v.dist).t
        let L = net.segs[v.seg].length
        var b: float3
        if v.dist + look < L { b = v.axis(net, v.dist + look).t } else { b = v.axis(net, L).t }
        let ang = acos(max(-1, min(1, simd_dot(float2(a.x, a.y), float2(b.x, b.y)) / max(1e-4, simd_length(float2(a.x, a.y)) * simd_length(float2(b.x, b.y))))))
        let kappa = ang / look
        let mug = mu * 9.8
        return sqrt(mug / max(mug / (top * top), kappa))
    }

    /// Frenada por el coche (o jugador) de delante en el pasillo del carril [D: AIActionTraffic.cpp 226-243].
    func followLimit(_ v: AIVehicle, desired: Float, dt: Float, chasing: Bool = false) -> Float {
        var want = desired
        let f = v.fwd, r = float3(f.y, -f.x, 0)
        let look = max(lerpf(10, 30, rampf(v.speed, 0, 25)) + v.speed * dt + v.radius, v.speed * 3)
        func check(_ p: float3, _ vel: float3, _ hl: Float, _ hw: Float) {
            let rel = p - v.pos
            if abs(rel.z) > 3 { return }
            let ahead = simd_dot(rel, f), side = simd_dot(rel, r)
            guard ahead > 0, ahead < look + hl, abs(side) < v.model.halfWidth + hw + 0.5 else { return }
            let gap = max(ahead - v.model.halfLength - hl, 0)
            let stop = lerpf(3, 50, rampf(v.speed, 0, 80))
            if gap < stop {
                let theirs = max(0, simd_dot(vel, f))
                want = min(want, max(0, min(desired, theirs * gap / stop)))
            }
        }
        for o in vehicles where o !== v {
            let ov = o.mode == .parked || o.crashed ? float3(0, 0, 0) : o.fwd * o.speed
            check(o.pos, ov, o.model.halfLength, o.model.halfWidth)
        }
        if player.exists && !chasing { check(player.pos, player.vel, player.halfLength, player.halfWidth) }
        for o in others where o.exists { check(o.pos, o.vel, o.halfLength, o.halfWidth) }
        return want
    }

    /// Paso de un coche en modo carril con velocidad `cruise`; devuelve el paso hecho.
    func stepLane(_ v: AIVehicle, dt: Float, cops: Bool, field: [Float]?, mu: Float, accel: Float) {
        var want = min(v.cruise, curveSpeed(v, mu: mu, top: max(v.cruise, 1)))
        want = followLimit(v, desired: want, dt: dt, chasing: v.kind == .cop && v.copRole == .pursuit)
        if v.deadEnd { want = 0 }
        if want > v.speed { v.speed = min(want, v.speed + accel * dt) } else { v.speed = max(want, v.speed - 9 * dt) }
        v.braking = want < v.speed - 0.3 || v.speed < 0.5
        let prev = v.pos, prevLat = v.lat, prevSeg = v.seg
        v.advance(net: net, step: v.speed * dt, cops: cops, field: field, rng: &rng)
        if v.seg != prevSeg && (v.kind == .traffic || v.copRole == .patrol || v.copRole == .flee) { traffic.setCruise(v, traffic.pattern) }
        v.pose(net: net, collision: collision, dt: dt)
        v.spin += v.speed * dt / v.model.wheelRadius
        // Comprobaciones (estadísticas de la prueba sin ventana)
        stats.laneFrames += 1
        if !v.groundOK { stats.offGroundFrames += 1 }
        if abs(v.lat - prevLat) > 0.6 { stats.laneSnaps += 1 }
        if v.speed > 0.5, simd_distance(prev, v.pos) < 10, collision.hitsWall(from: prev + float3(0, 0, 0.5), to: v.pos + float3(0, 0, 0.5)) {
            stats.wallCrossings += 1
            wallSegs[v.seg, default: 0] += 1
            if debug && stats.wallCrossings <= 0 {
                print(String(format: "  muro: seg %d flags %@ lat %.1f carril %d %@ pos (%.1f, %.1f, %.1f) z eje %.1f", v.seg, "\(net.segs[v.seg].flags)", v.lat, v.lane, v.forward ? "→" : "←", v.pos.x, v.pos.y, v.pos.z, v.axis(net, v.dist).p.z))
            }
        }
    }

    // MARK: Choques

    /// Rectángulos orientados en planta (SAT): ¿se tocan? Devuelve la normal (de a hacia b) y la profundidad.
    static func obbOverlap(_ pa: float2, _ ya: Float, _ ea: float2, _ pb: float2, _ yb: Float, _ eb: float2) -> (float2, Float)? {
        let axA = [float2(cos(ya), sin(ya)), float2(-sin(ya), cos(ya))], axB = [float2(cos(yb), sin(yb)), float2(-sin(yb), cos(yb))]
        let d = pb - pa
        var best: (float2, Float)? = nil
        for ax in axA + axB {
            let ra = ea.x * abs(simd_dot(axA[0], ax)) + ea.y * abs(simd_dot(axA[1], ax))
            let rb = eb.x * abs(simd_dot(axB[0], ax)) + eb.y * abs(simd_dot(axB[1], ax))
            let dist = simd_dot(d, ax)
            let pen = ra + rb - abs(dist)
            if pen <= 0 { return nil }
            if best == nil || pen < best!.1 { best = (dist >= 0 ? ax : -ax, pen) }
        }
        return best
    }

    private func resolveContacts(dt: Float) {
        // IA contra IA: solo se cuentan (el seguidor cinemático no se sale del carril)
        for i in vehicles.indices { for j in (i + 1)..<max(i + 1, vehicles.count) {
            let a = vehicles[i], b = vehicles[j]
            if simd_distance_squared(a.pos, b.pos) > 64 || abs(a.pos.z - b.pos.z) > 2.5 { continue }
            if a.mode == .parked && b.mode == .parked { continue }
            if let (n, pen) = AIWorld.obbOverlap(float2(a.pos.x, a.pos.y), a.yaw, float2(a.model.halfLength * 0.9, a.model.halfWidth * 0.9),
                                  float2(b.pos.x, b.pos.y), b.yaw, float2(b.model.halfLength * 0.9, b.model.halfWidth * 0.9)) {
                // Los que van en directo (policía) se apartan: el seguidor de carril no puede salirse
                let push = float3(n.x, n.y, 0) * (pen + 0.05)
                if b.mode == .free, !collision.hitsWall(from: b.pos, to: b.pos + push) { b.pos += push; continue }
                if a.mode == .free, !collision.hitsWall(from: a.pos, to: a.pos - push) { a.pos -= push; continue }
                stats.aiOverlaps += 1
                if debug && stats.aiOverlaps % 100 == 1 {
                    print(String(format: "  solape: %@/%@ %@ seg %d lat %.1f v %.0f  ×  %@/%@ %@ seg %d lat %.1f v %.0f", a.typeName, "\(a.mode)", "\(a.copRole)", a.seg, a.lat, a.speed, b.typeName, "\(b.mode)", "\(b.copRole)", b.seg, b.lat, b.speed))
                }
            }
        } }
        // Otros humanos (pantalla partida): solo se separa al coche de la IA, que es cinemático
        for o in others where o.exists {
            for v in vehicles {
                if simd_distance_squared(v.pos, o.pos) > 100 || abs(v.pos.z - o.pos.z) > 2.5 { continue }
                guard let (n, pen) = AIWorld.obbOverlap(float2(o.pos.x, o.pos.y), o.yaw, float2(o.halfLength, o.halfWidth),
                                                       float2(v.pos.x, v.pos.y), v.yaw, float2(v.model.halfLength, v.model.halfWidth)) else { continue }
                let push = float3(n.x, n.y, 0) * (pen + 0.02)
                if !collision.hitsWall(from: v.pos, to: v.pos + push) { v.pos += push }
                if v.kind == .traffic, abs(o.speed) >= AITables.mph(5), !v.crashed {
                    v.crashed = true; v.mode = .parked; v.speed = 0
                    v.knock = float2(n.x, n.y) * max(2, abs(o.speed) * 0.4)
                    v.knockSpin = (rng.float() - 0.5) * 3
                }
            }
        }
        guard player.exists else { return }
        var now = Set<Int>()
        for v in vehicles {
            if simd_distance_squared(v.pos, player.pos) > 100 || abs(v.pos.z - player.pos.z) > 2.5 { continue }
            guard let (n, pen) = AIWorld.obbOverlap(float2(player.pos.x, player.pos.y), player.yaw, float2(player.halfLength, player.halfWidth),
                                                   float2(v.pos.x, v.pos.y), v.yaw, float2(v.model.halfLength, v.model.halfWidth)) else { continue }
            now.insert(v.id)
            // Separar al coche de la IA (es cinemático) en la dirección de la normal
            let push = float3(n.x, n.y, 0) * (pen + 0.02)
            if !collision.hitsWall(from: v.pos, to: v.pos + push) { v.pos += push }
            if contacts.contains(v.id) { continue }
            let closing = abs(player.speed) - simd_dot(v.fwd * v.speed, player.fwd)
            let hard = abs(player.speed) >= AITables.mph(5)
            if v.kind == .traffic {
                stats.playerHitsTraffic += 1
                if hard {
                    // Accidente: gira un instante y se queda frenado [D: AIActionTraffic.cpp 121-151, 360-384]
                    v.crashed = true; v.mode = .parked; v.speed = 0
                    v.knock = float2(n.x, n.y) * max(2, closing * 0.6) + float2(player.fwd.x, player.fwd.y) * abs(player.speed) * 0.3
                    v.knockSpin = (rng.float() - 0.5) * 3
                    police.reportTrafficHit()
                }
                playerSpeedFactor *= v.model.halfLength > 3.5 ? 0.45 : 0.75
            } else {
                stats.playerHitsCops += 1
                police.reportCopHit(v, closing: closing)
                v.knock = float2(n.x, n.y) * max(1, closing * 0.3)
                playerSpeedFactor *= 0.8
            }
        }
        contacts = now
    }
}
