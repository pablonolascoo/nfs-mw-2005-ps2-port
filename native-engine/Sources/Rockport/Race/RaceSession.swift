// Una prueba en curso: salida, cuenta atrás, reglas de cada tipo, posiciones, vueltas, eliminaciones, radares, peajes,
// sentido contrario, reinicio, policía y tráfico de la prueba, resultados y recompensas.
// Reglas del juego [D: GRaceStatus.h, GRacerInfo, GRace::Type] y de los datos de cada prueba [V: races.json]; lo que no
// está en la decomp lleva [I] en el comentario. El HUD lo dibuja la interfaz (UI/RaceHUD.swift): aquí solo se le llama.
import Foundation
import simd

/// Un participante (GRacerInfo [D]).
final class RaceRacer {
    let name: String
    let isPlayer: Bool
    let car: Car
    var driver: RaceDriver?
    let opponent: RaceOpponent?

    var progress: Float = 0          // metros en la ruta (todas las vueltas)
    var lateral: Float = 0
    var gap: Float = 0               // distancia a la ruta
    var nextGate = 0                 // índice de la siguiente puerta (punto de control o meta) en `RaceSession.gates`
    var lapsCompleted = 0
    var lapStart: Double = 0
    var bestLap: Double?
    var lapTimes: [Double] = []
    var finished = false
    var finishTime: Double?
    var knockedOut = false
    var dnf = false                  // motor roto, siniestro total, arrestado o tiempo agotado
    var dnfReason = ""
    var speedtrapSpeeds: [Int: Float] = [:]
    var speedtrapTotal: Float { speedtrapSpeeds.values.reduce(0, +) }
    var wrongWayTime: Float = 0
    var offRouteTime: Float = 0
    var resets = 0
    var lastPos = float3(0, 0, 0)
    var topSpeed: Float = 0
    var trafficHits = 0
    var position = 0

    init(name: String, isPlayer: Bool, car: Car, opponent: RaceOpponent?) {
        self.name = name; self.isPlayer = isPlayer; self.car = car; self.opponent = opponent
    }
    var active: Bool { !finished && !knockedOut && !dnf }
}

/// Cómo se arrancó la prueba (GRace::Context [D]).
enum RaceContext { case career, quickRace, test }

struct RaceOutcome {
    let event: RaceEvent
    let context: RaceContext
    let playerWon: Bool
    let playerPosition: Int
    let playerTime: Double?
    let abandoned: Bool
    let rows: [RaceResultRow]
    let cash: Int
    let bounty: Int
    let milestoneValue: Float?
}

final class RaceSession {
    enum Phase: Equatable { case countdown, racing, finishing, results, done }

    unowned let system: RaceSystem
    let event: RaceEvent
    let context: RaceContext
    let route: RaceRoute
    let barriers: RaceBarrierLines
    private(set) var racers: [RaceRacer] = []
    var player: RaceRacer { racers.first { $0.isPlayer }! }
    /// Puertas en orden de paso (todas las vueltas): puntos de control y meta.
    private(set) var gates: [(marker: RaceMarker, dist: Float, isFinish: Bool, lap: Int)] = []
    private(set) var phase: Phase = .countdown
    private(set) var clock: Double = 0             // tiempo de carrera (desde «¡YA!»)
    private var phaseTime: Double = 0
    private var countdownShown = 99
    private(set) var timeRemaining: Double = 0     // peaje
    private var finishHold: Double = 0
    var autopilot = false                          // pruebas: el jugador lo conduce un RaceDriver
    private var autoDriver: RaceDriver?
    var onEnd: ((RaceOutcome) -> Void)?
    var log: (String) -> Void = { print($0) }
    // Drag
    private var dragLane = 0
    private var dragLanes: [Float] = [0]
    private(set) var engineTemp: Float = 0
    private var lastGear = 0
    private(set) var shiftQuality = 0
    // Persecución (desafíos y carreras con policía)
    private var pursuitStartTime: Double?
    private var pursuitPeak: (cost: Int, infractions: Int, roadblocks: Int, spikes: Int, copsHit: Int) = (0, 0, 0, 0, 0)
    private var statsAtStart: AIStats?
    private(set) var milestoneValue: Float = 0
    private var savedTraffic: (Int, Float, Bool)?
    private var hudWrongWay = false
    private var crashWindow: [Float] = []

    var isTimeTrial: Bool { event.kind == .tollbooth }
    var hasRoute: Bool { event.kind != .challenge || event.finish != nil }

    init?(system: RaceSystem, event: RaceEvent, context: RaceContext, opponents requested: Int? = nil) {
        self.system = system; self.event = event; self.context = context
        let engine = system.engine
        guard let net = engine.ai?.net else { fputs("Carreras: sin red de carreteras (roads.json)\n", stderr); return nil }
        guard let start = event.start ?? event.checkpoints.first ?? event.finish else { fputs("Carreras: \(event.id) sin salida\n", stderr); return nil }
        barriers = system.world.lines(for: event.barriers)
        // Puertas de una vuelta: puntos de control + meta. Desafío de persecución sin meta: sin ruta (solo hitos).
        var lap = event.checkpoints
        if let f = event.finish { lap.append(f) }
        let wander = lap.isEmpty
        if wander { lap = RaceSession.wanderGates(net: net, from: start, meters: 8000) }   // desafío sin meta: solo para el piloto automático
        let laps = max(1, event.laps)
        route = RaceRoute(net: net, barriers: barriers, start: start, gates: lap, laps: laps)
        if wander {
            gates = []
            guard setupRacers(start: start, requested: requested) else { return nil }
            return
        }
        var gi: [(RaceMarker, Float, Bool, Int)] = []
        for l in 0..<laps { for (k, g) in lap.enumerated() {
            let idx = l * lap.count + k
            let d = idx < route.gateDistances.count ? route.gateDistances[idx] : route.length
            gi.append((g, d, event.finish != nil && k == lap.count - 1, l + 1))
        } }
        gates = gi.map { (marker: $0.0, dist: $0.1, isFinish: $0.2, lap: $0.3) }
        guard setupRacers(start: start, requested: requested) else { return nil }
    }

    /// Puntos por la red siguiendo las reglas del tráfico desde la salida (persecuciones de la Serie de desafíos, que no
    /// tienen ruta): solo los usa el piloto automático de las pruebas [I].
    static func wanderGates(net: RoadNet, from m: RaceMarker, meters: Float) -> [RaceMarker] {
        guard let h = net.nearest(m.p, maxDist: 80, filter: { net.trafficAllowed($0) }) else { return [m] }
        var rng = SplitMix(seed: 0xC4A5E)
        var seg = h.seg
        var fwd = simd_dot(float2(net.tangent(seg, h.t).x, net.tangent(seg, h.t).y), float2(m.dir.x, m.dir.y)) >= 0
        var out: [RaceMarker] = [], total: Float = 0, next: Float = 300
        for _ in 0..<400 where total < meters {
            total += net.segs[seg].length
            let node = fwd ? net.segs[seg].n1 : net.segs[seg].n0
            if total >= next {
                let p = net.nodePos[node]
                var t = net.tangent(seg, fwd ? 1 : 0); if !fwd { t = -t }
                out.append(RaceMarker(name: nil, pos: [p.x, p.y, p.z], yaw: atan2(t.y, t.x) * 180 / .pi, dims: nil, timeBonus: nil, radius: nil, width: nil))
                next = total + 300
            }
            guard let n = net.next(from: seg, at: node, cops: false, rng: &rng) else { break }
            seg = n; fwd = net.segs[n].n0 == node
        }
        return out.isEmpty ? [m] : out
    }

    // MARK: Salida

    private func setupRacers(start: RaceMarker, requested: Int?) -> Bool {
        let engine = system.engine
        engine.loadCar()
        guard let pcar = engine.car else { fputs("Carreras: sin coche del jugador\n", stderr); return false }
        if engine.mode != .drive { engine.toggleMode() }
        var opps = event.opponents
        if let n = requested { opps = Array(opps.prefix(max(0, n))) }
        if event.kind == .tollbooth || event.kind == .challenge { opps = [] }
        let p0 = route.sample(0)
        let fwd = p0.tangent, right = float3(fwd.y, -fwd.x, 0)
        // Parrilla de dos en fondo, 8 m entre filas, el jugador detrás [I: GRacerInfo::ForceStartPosition sin datos de parrilla]
        let total = opps.count + 1
        let half = min(2.6, max(1.6, min(p0.left, p0.right) - 1.2))
        func slot(_ i: Int) -> (float3, Float) {
            let row = i / 2, side: Float = total == 1 ? 0 : (i % 2 == 0 ? -half : half)
            let d = -Float(row) * 8
            return (start.p + fwd * d + right * side, Float(row) * 8)
        }
        let yaw = atan2(fwd.y, fwd.x)
        var list: [RaceRacer] = []
        for (i, o) in opps.enumerated() {
            guard let car = system.opponentCar(o, index: i, event: event) else { continue }
            let (p, _) = slot(i)
            car.place(p + float3(0, 0, 1.5), yaw: yaw, collision: engine.collision, probe: 3)
            let name = o.racerName ?? (o.boss == true ? (system.db.bins.first { $0.boss == o.name }?.bossName ?? "Rival") : RaceSystem.prettyName(o.name))
            let r = RaceRacer(name: name, isPlayer: false, car: car, opponent: o)
            let skill = system.baseSkill(for: o, event: event, context: context)
            r.driver = RaceDriver(car: car, route: route, skill: skill, catchUp: RaceCatchUpParams(event.catchUp),
                                  laneOffset: 0, drag: event.kind == .drag, player: pcar,
                                  minPerformance: o.minPerformance ?? 0)
            list.append(r)
        }
        let (pp, _) = slot(total - 1)
        pcar.place(pp + float3(0, 0, 1.5), yaw: yaw, collision: engine.collision, probe: 3)
        list.append(RaceRacer(name: system.playerName, isPlayer: true, car: pcar, opponent: nil))
        racers = list
        for r in racers {
            let pr = route.project(r.car.position, hint: 0, back: 0, ahead: 120)
            r.progress = pr.dist; r.lateral = pr.lateral; r.lastPos = r.car.position
            if let d = r.driver { d.laneOffset = max(-p0.left + 1.5, min(p0.right - 1.5, pr.lateral)) }
        }
        // Salida lanzada (desafíos): velocidad inicial (InitialPlayerSpeed, mph [I])
        if event.rollingStart || event.initialSpeed > 0, let v = pcar.vehicle {
            let sp = PM.mph2mps(event.initialSpeed > 0 ? event.initialSpeed : 40)
            v.rb.linearVel = v.rb.rotate(V3(0, 0, sp)); v.engine.matchSpeed(sp)
        }
        // Drag: carriles cada 3,5 m dentro de la calzada; cambio manual [D: STYLE_DRAG, kLaneDrag]
        if event.kind == .drag {
            let n = max(2, Int((p0.left + p0.right) / 3.5))
            dragLanes = (0..<n).map { -p0.left + 1.75 + Float($0) * 3.5 }
            dragLane = dragLanes.indices.min { abs(dragLanes[$0] - player.lateral) < abs(dragLanes[$1] - player.lateral) } ?? 0
            pcar.vehicle?.engine.automatic = false
        }
        return true
    }

    /// Empieza: vallas, tráfico, policía, HUD y cuenta atrás.
    func begin() {
        let engine = system.engine
        system.world.setRaceBarriers(event.barriers)
        // Tráfico (TrafficLevel %) y policía (CopsInRace / ForceHeatLevel / MaxHeatLevel) [V: datos de la prueba]
        savedTraffic = (AIConfig.maxTraffic, AIConfig.density, AIConfig.police)
        AIConfig.density = max(0, event.trafficLevel) / 100
        AIConfig.police = event.copsInRace || event.kind == .challenge
        if let ai = engine.ai {
            if AIConfig.police {
                let h = event.forceHeat > 0 ? event.forceHeat : (event.useWorldHeat ? ai.police.heat : 1)
                ai.police.heat = max(1, min(max(1, event.maxHeat), h))
            }
            statsAtStart = ai.stats
        }
        engine.driverFilter = { [weak self] d, reset, dt in self?.filterInput(&d, &reset, dt) }
        if let hud = system.hud {
            let kind: RaceKind = switch event.kind {
            case .sprint: .sprint
            case .circuit: .circuit
            case .knockout: .knockout
            case .drag: .drag
            case .speedtrap: .speedtrap
            case .tollbooth: .tollbooth
            case .challenge: .pursuit
            }
            hud.beginRace(RaceHUDSetup(kind: kind, laps: event.laps, racers: racers.map { RaceHUDRacer(name: $0.name, isPlayer: $0.isPlayer) },
                                       eventName: event.eventId, showMinimap: hasRoute,
                                       timeLimit: isTimeTrial ? Double(max(event.timeLimit, 1)) : nil,
                                       checkpointCount: event.kind == .speedtrap ? event.speedtraps.count : (isTimeTrial ? event.checkpoints.count : 0)))
            if hasRoute { hud.setRoute(route.minimapPoints()) }
        }
        if ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_LEGS"] != nil {
            var prevP = (event.start ?? gates[0].marker).p, prevD: Float = 0
            for g in gates { log(String(format: "  tramo → %@: ruta %.0f m · recta %.0f m", g.marker.name ?? "?", g.dist - prevD, simd_distance(prevP, g.marker.p))); prevP = g.marker.p; prevD = g.dist }
        }
        if let dbg = ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_ROUTE"] {
            var d: Float = Float(dbg) ?? 0
            let end = d + 200
            while d < end { let q = route.sample(d); log(String(format: "  ruta %.0f m: (%.1f, %.1f, %.1f) t (%.2f, %.2f) izq %.1f dcha %.1f", d, q.p.x, q.p.y, q.p.z, q.tangent.x, q.tangent.y, q.left, q.right)); d += 8 }
        }
        timeRemaining = Double(event.timeLimit > 0 ? event.timeLimit : 90)
        if !event.doCountdown || event.rollingStart || event.kind == .challenge { startRacing() }
        else { phase = .countdown; phaseTime = 0 }
        log(String(format: "Carrera %@ (%@): %d corredores · ruta %.0f m (dato RaceLength %.0f m) · %d puertas · %d vallas (%d líneas) · tramos sin camino %d",
                   event.eventId, event.id, racers.count, route.length, event.length, gates.count, event.barriers.count, barriers.count, route.legErrors))
    }

    private func startRacing() {
        phase = .racing; phaseTime = 0; clock = 0
        for r in racers { r.lapStart = 0 }
        system.hud?.showCountdown(-1)
        if event.kind == .challenge || event.pursuitRace, let ai = system.engine.ai {
            ai.police.forcePursuit()
            pursuitStartTime = 0
        }
    }

    // MARK: Entrada del jugador

    private func filterInput(_ d: inout DriverInput, _ reset: inout Bool, _ dt: Float) {
        if reset { reset = false; resetRacer(player) }
        if autopilot, let ad = autoDriver ?? makeAutoDriver() {
            let o = others(for: player)
            let staging = phase == .countdown
            let a = ad.drive(dt: dt, progress: player.progress, lateralNow: player.lateral, others: o, stop: phase != .countdown && phase != .racing, staging: staging)
            if ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_AVOID"] != nil, Int(clock * 60) % 6 == 0, let ai = system.engine.ai {
                let f = player.car.forward
                for v in ai.vehicles where simd_distance(v.pos, player.car.position) < 150 {
                    let rel = v.pos - player.car.position
                    log(String(format: "    t %.2f %@ delante %.0f lado %.1f dz %.1f v %.0f modo %@", clock, v.typeName, simd_dot(rel, f), simd_dot(rel, float3(f.y, -f.x, 0)), rel.z, v.speed, "\(v.mode)"))
                }
            }
            let keepShift = (d.shiftUp, d.shiftDown)
            d = a
            if event.kind == .drag { autoShift(&d) } else { (d.shiftUp, d.shiftDown) = keepShift }
        }
        switch phase {
        case .countdown:
            // Parados hasta «¡YA!»: se puede acelerar en vacío (freno de mano) [I]
            d.handBrake = 1; d.brake = 0; d.steerLeft = 0; d.steerRight = 0; d.nos = false
        case .racing:
            if event.kind == .drag && !autopilot { dragAssist(&d, dt) }
        case .finishing, .results, .done:
            if !player.active || player.finished { d.gas = 0; d.nos = false; d.brake = max(d.brake, 0.4) }
        }
    }

    private func makeAutoDriver() -> RaceDriver? {
        let d = RaceDriver(car: player.car, route: route, skill: 0.75, catchUp: RaceCatchUpParams(), laneOffset: 0, drag: event.kind == .drag, player: nil, minPerformance: 1)
        var c = RaceCatchUpParams(); c.enabled = false; d.catchUp = c
        autoDriver = d
        return d
    }

    /// Piloto automático en drag: cambia de marcha en el punto de cambio óptimo (pruebas).
    private func autoShift(_ d: inout DriverInput) {
        guard let v = player.car.vehicle else { return }
        let g = v.engine.gear
        d.shiftDown = false
        d.shiftUp = g >= Gear.first && g < v.engine.topGear && v.engine.rpm >= v.engine.shiftPoint(from: g, to: g + 1) - 50 && !v.engine.isGearChanging
    }

    /// Drag: la dirección la lleva el juego; izquierda/derecha cambian de carril [D: STYLE_DRAG, kLaneDrag].
    private var dragPrevSteer: Float = 0
    private func dragAssist(_ d: inout DriverInput, _ dt: Float) {
        let s = d.steerRight - d.steerLeft
        if abs(s) > 0.5 && abs(dragPrevSteer) <= 0.5 && !autopilot {
            dragLane = max(0, min(dragLanes.count - 1, dragLane + (s > 0 ? 1 : -1)))
        }
        dragPrevSteer = s
        let want = dragLanes[min(dragLane, dragLanes.count - 1)]
        // Dirección asistida hacia el carril (mismo controlador que la IA)
        let look = max(14, min(60, 10 + abs(player.car.speed) * 0.8))
        let tp = route.sample(player.progress + look)
        let target = tp.p + float3(tp.tangent.y, -tp.tangent.x, 0) * want
        let to = simd_normalize(float2(target.x - player.car.position.x, target.y - player.car.position.y) + 1e-6)
        let f2 = simd_normalize(float2(player.car.forward.x, player.car.forward.y) + 1e-6)
        let cross = f2.x * to.y - f2.y * to.x
        let steer = max(-1, min(1, -cross * 2.2))
        d.steerRight = max(steer, 0); d.steerLeft = max(-steer, 0)
        d.handBrake = 0
    }

    // MARK: Fotograma

    func update(dt: Float) {
        // Arresto: la interfaz abre su pantalla de BUSTED (pausa), así que se mira antes del paso de tiempo
        if phase == .racing, AIConfig.police, let pol = system.engine.ai?.police, pol.state == .busted { dnf(player, "arrestado") }
        guard dt > 0, phase != .done else { return }
        phaseTime += Double(dt)
        let engine = system.engine
        // Rivales: conducir y simular (la física del juego a 60 Hz)
        let playerPct = racePct(player)
        for r in racers where !r.isPlayer {
            guard let drv = r.driver else { continue }
            if r.active && phase == .racing {
                drv.updateGlue(dt: dt, myPct: racePct(r), playerPct: playerPct, raceLength: route.length, speedtrap: event.kind == .speedtrap)
            }
            let stop = !(phase == .racing || phase == .countdown) || !r.active
            let inp = drv.drive(dt: dt, progress: r.progress, lateralNow: r.lateral, others: others(for: r), stop: stop, staging: phase == .countdown)
            r.car.update(dt: dt, input: Car.Input(driver: inp), collision: engine.collision)
            if r.active && phase == .racing && (drv.stuckTime > 4 || r.car.position.z < -40) { resetRacer(r) }
        }
        resolveCarContacts()
        // Progreso, puertas y reglas
        for r in racers { track(r, dt: dt) }
        switch phase {
        case .countdown:
            let left = 3 - Int(phaseTime)
            if left != countdownShown { countdownShown = left; system.hud?.showCountdown(max(0, left)); if left > 0 { log("  cuenta atrás \(left)") } }
            if phaseTime >= 3 { system.hud?.showCountdown(0); log("  ¡YA!"); startRacing() }
        case .racing:
            clock += Double(dt)
            rules(dt: dt)
        case .finishing:
            clock += Double(dt)
            finishHold -= Double(dt)
            if finishHold <= 0 || racers.allSatisfy({ !$0.active }) { showResults() }
        case .results, .done: break
        }
        updateHUD()
        updateRacerDraw()
    }

    private func racePct(_ r: RaceRacer) -> Float { route.length > 0 ? 100 * min(1, r.progress / route.length) : 0 }

    private func others(for r: RaceRacer) -> [(pos: float3, vel: float3, halfWidth: Float)] {
        var out: [(pos: float3, vel: float3, halfWidth: Float)] = []
        for o in racers where o !== r { out.append((o.car.position, o.car.velocity, o.car.halfWidth)) }
        if let ai = system.engine.ai {
            for v in ai.vehicles where simd_distance_squared(v.pos, r.car.position) < 48400 {
                out.append((v.pos, v.fwd * v.speed, v.model.halfWidth))
            }
        }
        return out
    }

    /// Progreso en la ruta, puertas (checkpoints/meta), radares, peajes, sentido contrario y salida de ruta.
    private func track(_ r: RaceRacer, dt: Float) {
        let pos = r.car.position
        defer { r.lastPos = pos }
        guard route.length > 1 else { return }
        let pr = route.project(pos, hint: r.progress, back: 40, ahead: 120)
        if pr.gap < 60 { r.progress = max(r.progress - 30, pr.dist); r.lateral = pr.lateral }
        r.gap = pr.gap
        r.topSpeed = max(r.topSpeed, abs(r.car.speed))
        guard phase == .racing || phase == .finishing, r.active, hasRoute else { return }
        // Puertas en orden: cruzar el plano dentro de la caja (GTrigger de checkpoint), o pasar 80 m por delante de ella
        // en la ruta (red de seguridad [I])
        while r.nextGate < gates.count {
            let g = gates[r.nextGate]
            let crossed = crossesGate(g.marker, from: r.lastPos, to: pos)
            if !(crossed || r.progress > g.dist + 80) { break }
            passGate(r, index: r.nextGate)
            r.nextGate += 1
            if !r.active { break }
        }
        // Radares (speedtrap)
        if event.kind == .speedtrap {
            for (i, t) in event.speedtraps.enumerated() where r.speedtrapSpeeds[i] == nil {
                if simd_distance(float2(pos.x, pos.y), float2(t.p.x, t.p.y)) < max(t.radius, 12) && abs(pos.z - t.p.z) < 12 {
                    let v = simd_length(r.car.velocity)
                    r.speedtrapSpeeds[i] = v
                    if r.isPlayer { system.hud?.showMessage(.speedtrap(mps: v)); log(String(format: "  radar %d: %.0f km/h", i + 1, v * 3.6)) }
                }
            }
        }
        if r.isPlayer, ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_RACE"] != nil, Int(clock * 60) % 120 == 0 {
            let p2 = SIMD2(pos.x, pos.y)
            let near = system.engine.collision.dynamicWalls.filter { w in
                let ab = w.b - w.a, u = max(0, min(1, simd_dot(p2 - w.a, ab) / max(simd_length_squared(ab), 1e-6)))
                return simd_distance(w.a + ab * u, p2) < 12 }
            log(String(format: "  dbg pos (%.1f, %.1f, %.1f) v %.1f gas? prog %.0f gap %.1f lat %.1f · muros dinámicos cerca: %d %@", pos.x, pos.y, pos.z, r.car.speed, r.progress, pr.gap, pr.lateral, near.count,
                       near.map { String(format: "[(%.0f,%.0f)-(%.0f,%.0f) z %.0f..%.0f]", $0.a.x, $0.a.y, $0.b.x, $0.b.y, $0.zMin, $0.zMax) }.joined(separator: " ")))
        }
        // Sentido contrario (flecha del HUD) y fuera de ruta
        if r.isPlayer {
            let t = route.sample(r.progress).tangent
            let vAlong = simd_dot(r.car.velocity, t)
            r.wrongWayTime = vAlong < -3 ? r.wrongWayTime + dt : max(0, r.wrongWayTime - dt * 2)
            let ww = r.wrongWayTime > 1.5
            if ww != hudWrongWay { hudWrongWay = ww; system.hud?.showMessage(.wrongWay(ww)) }
            r.offRouteTime = pr.gap > 80 ? r.offRouteTime + dt : 0
            if r.offRouteTime > 6 || pos.z < -40 { resetRacer(r) }
            // resetplayertrigger: plano de reinicio (ancho Width) detrás de la salida [V: datos; regla I]
            for m in event.resets {
                let n = m.dir, rel = float2(pos.x - m.p.x, pos.y - m.p.y)
                let along = simd_dot(rel, float2(n.x, n.y)), side = abs(simd_dot(rel, float2(-n.y, n.x)))
                if abs(along) < 2.5 && side < (m.width ?? 150) / 2 && abs(pos.z - m.p.z) < 20 { resetRacer(r); break }
            }
        }
    }

    private func crossesGate(_ m: RaceMarker, from a: float3, to b: float3) -> Bool {
        let n = float2(m.dir.x, m.dir.y), c = float2(m.p.x, m.p.y)
        let da = simd_dot(float2(a.x, a.y) - c, n), db = simd_dot(float2(b.x, b.y) - c, n)
        guard da < 0 && db >= 0 else { return false }
        let t = da / (da - db)
        let p = a + (b - a) * t
        let side = abs(simd_dot(float2(p.x, p.y) - c, float2(-n.y, n.x)))
        return side <= m.halfWidth * 1.25 + 4 && abs(p.z - m.p.z) <= max(m.halfHeight, 10) + 4
    }

    private func passGate(_ r: RaceRacer, index i: Int) {
        let g = gates[i]
        if g.isFinish {
            r.lapsCompleted += 1
            let lapTime = clock - r.lapStart
            r.lapTimes.append(lapTime)
            r.bestLap = min(r.bestLap ?? lapTime, lapTime)
            r.lapStart = clock
            if r.isPlayer { log(String(format: "  vuelta %d: %.2f s (posición %d)", r.lapsCompleted, lapTime, r.position)) }
            if r.lapsCompleted >= max(1, event.laps) { finish(r) }
            else {
                if r.isPlayer && r.lapsCompleted == event.laps - 1 { system.hud?.showMessage(.finalLap) }
                if event.kind == .knockout { knockoutCheck(lap: r.lapsCompleted) }
            }
        } else {
            if r.isPlayer {
                if let tb = g.marker.timeBonus, isTimeTrial {
                    timeRemaining += Double(tb)
                    system.hud?.showMessage(.tollbooth(timeAdded: Double(tb)))
                    log(String(format: "  peaje %@: +%.0f s (quedan %.1f s)", g.marker.name ?? "", tb, timeRemaining))
                } else {
                    system.hud?.showMessage(.checkpoint)
                    log(String(format: "  punto de control %d/%d a %.1f s (posición %d)", i + 1, gates.count, clock, r.position))
                }
            }
        }
    }

    private func finish(_ r: RaceRacer) {
        guard !r.finished else { return }
        r.finished = true
        r.finishTime = clock
        log(String(format: "  %@ %@ termina en %.2f s", r.isPlayer ? "JUGADOR" : "rival", r.name, clock))
        if r.isPlayer { enterFinishing() }
        else if event.kind == .drag || event.kind == .sprint || event.kind == .circuit || event.kind == .knockout {
            // Si los rivales terminan todos y el jugador no, sigue la carrera (el jugador puede acabar último)
        }
    }

    /// Eliminación (KnockoutsPerLap): cuando todos menos los N últimos han cerrado la vuelta, los N últimos quedan fuera [D: KnockOut].
    private func knockoutCheck(lap: Int) {
        let alive = racers.filter { !$0.knockedOut && !$0.dnf }
        let done = alive.filter { $0.lapsCompleted >= lap }
        let k = max(1, event.knockoutsPerLap)
        guard done.count >= alive.count - k else { return }
        for r in alive where r.lapsCompleted < lap {
            r.knockedOut = true
            system.hud?.showMessage(.knockedOut(name: r.name))
            log("  eliminado: \(r.name) (vuelta \(lap))")
            if r.isPlayer { enterFinishing() }
        }
        // Si solo queda uno, gana
        let left = racers.filter { !$0.knockedOut && !$0.dnf }
        if left.count == 1, let w = left.first, !w.finished { w.finished = true; w.finishTime = clock; if w.isPlayer { enterFinishing() } }
    }

    private func dnf(_ r: RaceRacer, _ why: String) {
        guard r.active else { return }
        r.dnf = true; r.dnfReason = why
        log("  \(r.name): \(why)")
        if r.isPlayer { enterFinishing() }
    }

    private func enterFinishing() {
        guard phase == .racing else { return }
        phase = .finishing
        finishHold = event.kind == .drag || racers.count == 1 ? 1.5 : 6
    }

    /// Reglas por fotograma: tiempo (peaje), drag (motor), persecución (hitos), arresto.
    private func rules(dt: Float) {
        let p = player
        if isTimeTrial {
            timeRemaining -= Double(dt)
            if timeRemaining <= 0 { timeRemaining = 0; dnf(p, "tiempo agotado") }
        }
        if event.kind == .drag, let v = p.car.vehicle {
            let red = v.specs.engine.RED_LINE
            let ratio = v.engine.rpm / max(red, 1)
            // Temperatura del motor: sube en la zona roja, baja fuera [I: el juego la tiene en HUD_Drag; sin decomp]
            engineTemp = max(0, min(1, engineTemp + (ratio > 0.97 ? 0.45 : -0.12) * dt))
            if engineTemp >= 1 { dnf(p, "motor roto") }
            // Calidad del cambio: al subir de marcha, cerca del punto óptimo = perfecto [I]
            let g = v.engine.gear
            if g > lastGear && lastGear >= Gear.first {
                let opt = v.engine.shiftPoint(from: lastGear, to: g)
                let rpmAtShift = v.engine.rpm * (v.engine.gearRatio(lastGear) / max(v.engine.gearRatio(g), 0.01))
                let rel = abs(rpmAtShift - opt) / max(opt, 1)
                shiftQuality = rel < 0.04 ? 2 : (rel < 0.12 ? 1 : 0)
            }
            lastGear = g
            // Siniestro total: choque frontal fuerte (Δv > 14 m/s en un fotograma) [I]
            // (pérdida de velocidad hacia delante > 14 m/s en 0,1 s yendo a más de 15 m/s)
            let fwd = p.car.speed
            crashWindow.append(fwd); if crashWindow.count > 6 { crashWindow.removeFirst() }
            if let first = crashWindow.first, first > 15, first - fwd > 14 {
                log(String(format: "  choque: %.1f → %.1f m/s en (%.0f, %.0f) a %.0f m de ruta (desvío %.1f m)", first, fwd, p.car.position.x, p.car.position.y, p.progress, p.lateral))
                if let near = system.engine.ai?.vehicles.min(by: { simd_distance($0.pos, p.car.position) < simd_distance($1.pos, p.car.position) }) { log(String(format: "  coche de la IA más cercano: %@ a %.1f m", near.typeName, simd_distance(near.pos, p.car.position))) }
                dnf(p, "siniestro total")
            }
        }
        if let ai = system.engine.ai, AIConfig.police, let pol = ai.police {
            if pol.state == .busted { dnf(p, "arrestado") }
            if event.kind == .challenge, let ch = event.challenge, let metric = ch.milestone {
                let m = RaceMilestones.value(metric, police: pol, stats: ai.stats, base: statsAtStart, pursuitTime: pursuitStartTime.map { clock - $0 })
                milestoneValue = m
                let done = ch.biggerIsBetter ? m >= ch.threshold : (pol.state == .evaded && m <= ch.threshold)
                if pol.state == .evaded && !ch.biggerIsBetter && m > ch.threshold { dnf(p, "evasión demasiado lenta") }
                if done && ch.threshold > 0 { p.finished = true; p.finishTime = clock; log(String(format: "  desafío cumplido: %@ = %.0f (objetivo %.0f)", metric, m, ch.threshold)); enterFinishing() }
                if !pol.inPursuit && pol.state != .evaded && pursuitStartTime != nil && clock > 5 { ai.police.forcePursuit() }
            }
        }
        // Rivales: si el jugador ya no compite, la carrera termina cuando se acabe la espera
        if !p.active && phase == .racing { enterFinishing() }
    }

    // MARK: Reinicio

    /// Recoloca un corredor en la ruta (tecla R, fuera de ruta, atascado) [D: idea de ResetPlayer/AIActionGetUnstuck].
    func resetRacer(_ r: RaceRacer) {
        guard hasRoute else { r.car.reset(); return }
        let s = route.sample(max(0, r.progress - 5))
        let off = max(-s.left + 1.5, min(s.right - 1.5, r.driver?.laneOffset ?? 0))
        let p = s.p + float3(s.tangent.y, -s.tangent.x, 0) * off
        r.car.place(p + float3(0, 0, 1.5), yaw: atan2(s.tangent.y, s.tangent.x), collision: system.engine.collision, probe: 4)
        r.driver?.resetState()
        r.resets += 1
        r.lastPos = r.car.position
        r.wrongWayTime = 0; r.offRouteTime = 0
        if r.isPlayer { log("  reinicio del jugador en la ruta (\(Int(r.progress)) m)") }
    }

    // MARK: Choques entre coches de la carrera

    /// Cajas orientadas en planta; separa y reparte el impulso por masas (la física del juego no trae choques entre coches [I]).
    private func resolveCarContacts() {
        for i in racers.indices { for j in (i + 1)..<max(i + 1, racers.count) {
            let a = racers[i].car, b = racers[j].car
            guard let va = a.vehicle, let vb = b.vehicle else { continue }
            if simd_distance_squared(a.position, b.position) > 64 || abs(a.position.z - b.position.z) > 2.5 { continue }
            guard let (n, pen) = AIWorld.obbOverlap(float2(a.position.x, a.position.y), a.yaw, float2(a.halfLength, a.halfWidth),
                                                    float2(b.position.x, b.position.y), b.yaw, float2(b.halfLength, b.halfWidth)) else { continue }
            let ma = va.specs.mass, mb = vb.specs.mass
            let n3 = float3(n.x, n.y, 0)
            let push = n3 * (pen + 0.02)
            va.rb.position -= PM.toGame(push * (mb / (ma + mb)))
            vb.rb.position += PM.toGame(push * (ma / (ma + mb)))
            let ng = PM.toGame(n3)
            let rel = simd_dot(vb.rb.linearVel - va.rb.linearVel, ng)
            if rel < 0 {
                let e: Float = 0.3
                let j = -(1 + e) * rel / (1 / ma + 1 / mb)
                va.rb.linearVel -= ng * (j / ma)
                vb.rb.linearVel += ng * (j / mb)
            }
        } }
    }

    // MARK: Posiciones y HUD

    private func ranking() -> [RaceRacer] {
        racers.sorted { a, b in
            if a.finished != b.finished { return a.finished }
            if a.finished && b.finished {
                if event.rankByPoints { return a.speedtrapTotal > b.speedtrapTotal }
                return (a.finishTime ?? 1e9) < (b.finishTime ?? 1e9)
            }
            if a.knockedOut != b.knockedOut || a.dnf != b.dnf { return !(a.knockedOut || a.dnf) }
            if event.rankByPoints && a.speedtrapTotal != b.speedtrapTotal { return a.speedtrapTotal > b.speedtrapTotal }
            return a.progress > b.progress
        }
    }

    private var hudTimer: Float = 0
    private func updateHUD() {
        let rank = ranking()
        for (i, r) in rank.enumerated() { r.position = i + 1 }
        guard let hud = system.hud else { return }
        let p = player
        hud.setPosition(p.position, of: racers.count)
        hud.setLap(min(max(1, event.laps), p.lapsCompleted + 1), of: max(1, event.laps))
        hud.setTimer(raceTime: isTimeTrial ? timeRemaining : clock, lapTime: event.isLapRace ? clock - p.lapStart : nil, bestLap: p.bestLap)
        hud.setProgress(racePct(p))
        hud.setRacers(rank.map { RaceHUDRacer(name: $0.name, isPlayer: $0.isPlayer, knockedOut: $0.knockedOut || $0.dnf, gap: $0.progress - p.progress, position: $0.position) })
        hud.setRacerBlips(racers.filter { !$0.isPlayer }.map(\.car.position))
        if p.nextGate < gates.count, hasRoute { hud.setNextCheckpoint(gates[p.nextGate].marker.p) } else { hud.setNextCheckpoint(nil) }
        if event.kind == .speedtrap { hud.setSpeedtrap(totalMps: p.speedtrapTotal, passed: p.speedtrapSpeeds.count, of: event.speedtraps.count) }
        if event.kind == .drag { hud.setDrag(shiftQuality: shiftQuality, engineTemp: engineTemp) }
    }

    private func updateRacerDraw() {
        system.engine.extraCars = racers.filter { !$0.isPlayer }.map { ($0.car.mesh, $0.car.partMatrices, $0.car.shadowMatrix) }
    }

    // MARK: Resultados

    private func showResults() {
        guard phase == .finishing || phase == .racing else { return }
        phase = .results
        // Los que no terminaron: tiempo estimado con su velocidad media (SkipToEndOfRaceForRacer [D: idea]) [I]
        for r in racers where r.active && !r.isPlayer {
            let avg = max(5, r.progress / Float(max(clock, 1)))
            r.finishTime = clock + Double((route.length - r.progress) / avg)
            r.finished = true
        }
        let rank = ranking()
        for (i, r) in rank.enumerated() { r.position = i + 1 }
        let p = player
        let won: Bool
        switch event.kind {
        case .tollbooth: won = p.finished && !p.dnf
        case .challenge: won = p.finished && !p.dnf
        default: won = p.finished && !p.dnf && !p.knockedOut && p.position == 1
        }
        let rows = rank.map { r in
            RaceResultRow(position: r.position, name: r.name, isPlayer: r.isPlayer,
                          totalTime: (r.dnf || r.knockedOut) ? nil : r.finishTime, bestLap: r.bestLap,
                          speedTrapMps: event.kind == .speedtrap ? r.speedtrapTotal : nil)
        }
        let cash = won && context == .career ? Int(event.cash) : 0
        let bounty = won && context == .career ? Int(event.reputation) : 0
        let outcome = RaceOutcome(event: event, context: context, playerWon: won, playerPosition: p.position, playerTime: p.finishTime,
                                  abandoned: false, rows: rows, cash: cash, bounty: bounty, milestoneValue: event.kind == .challenge ? milestoneValue : nil)
        log(String(format: "Resultado %@: %@ · posición %d/%d · tiempo %@ · dinero %d · recompensa %d", event.eventId, won ? "GANADA" : "perdida",
                   p.position, racers.count, p.finishTime.map { String(format: "%.2f s", $0) } ?? "—", cash, bounty))
        for row in rows { log(String(format: "   %d. %@ %@", row.position, row.name, row.totalTime.map { String(format: "%.2f s", $0) } ?? (row.speedTrapMps.map { String(format: "%.0f km/h", $0 * 3.6) } ?? "DNF"))) }
        if let hud = system.hud {
            hud.showResults(RaceResults(kind: kindForHUD, eventName: event.eventId, playerWon: won, rows: rows, cash: cash, bounty: bounty)) { [weak self] in
                self?.end(outcome)
            }
        } else { end(outcome) }
    }

    private var kindForHUD: RaceKind {
        switch event.kind {
        case .sprint: .sprint
        case .circuit: .circuit
        case .knockout: .knockout
        case .drag: .drag
        case .speedtrap: .speedtrap
        case .tollbooth: .tollbooth
        case .challenge: .pursuit
        }
    }

    /// Abandonar (pausa → salir de la prueba).
    func abandon() {
        guard phase != .done else { return }
        let o = RaceOutcome(event: event, context: context, playerWon: false, playerPosition: racers.count, playerTime: nil, abandoned: true,
                            rows: [], cash: 0, bounty: 0, milestoneValue: nil)
        log("Carrera \(event.eventId) abandonada")
        end(o)
    }

    private func end(_ o: RaceOutcome) {
        guard phase != .done else { return }
        phase = .done
        let engine = system.engine
        engine.driverFilter = nil
        engine.extraCars = []
        player.car.vehicle?.engine.automatic = true
        system.world.setRaceBarriers([])
        if let s = savedTraffic { AIConfig.maxTraffic = s.0; AIConfig.density = s.1; AIConfig.police = s.2 }
        system.hud?.endRace()
        onEnd?(o)
    }
}
