// Policía como AICopManager + AIPursuit del juego [D: AI/Activities/AICopManager.cpp, AI/Common/AIPursuit.cpp,
// AIVehicleCopCar.cpp, AIRoadBlockSetups.cpp]. Valores por nivel de calor de pursuitlevels heat_01…heat_10 [V: ai.json].
//
//  Patrulla   NumPatrolCars coches conducen como el tráfico (AIGoalPatrol = AIActionTraffic) y vigilan.
//  Detección  cada 0,25 s: a menos de frontLOSdistance si estás delante (dot > −0,3) o de rearLOSdistance si no, con línea
//             de visión libre de muros y fuera de un escondite. Empieza la persecución si vas a 65 mph o más, has chocado
//             con el tráfico hace menos de 1 s, el calor es > 3 o has embestido a un policía.
//  Persecución calor += dt / (TimePerHeatLevel × ScaleEscalationPerBucket[bin]); refuerzos cada TimeBetweenCopSpawn hasta
//             min(Σ cops.Count, FullEngagementCopCount, 8); formaciones (CopFormations) a menos de 60 m; colapso si vas
//             por debajo de CollapseSpeed.
//  Arresto    visto, por debajo de BustSpeed y con un policía a menos de 15 m: el contador sube 1/s y baja 2/s; a 5 s, BUSTED.
//  Huida      sin que te vean 7 s → enfriamiento; evasión = (tiempo sin verte + escondite × HiddenZoneTimeMultiplier) /
//             evadetimeout; a 1, EVADED (calor × EvadeSuccessHeatAdjust, 60 s sin policía nueva).
//  Controles  cada 8–12 s, tras MinimumSupportDelay, con probabilidad roadblockprobability: 250 m por delante en la red,
//             en un tramo recto ≥ 40 m, montaje según el ancho de la calzada (tabla de AIRoadBlockSetups.cpp), con pinchos
//             si roadblockspikechance.
import Foundation
import simd

final class PoliceManager {
    enum State: Equatable { case none, chase, cooldown, busted, evaded }

    struct Prop { var pos: float3; var yaw: Float; var spike: Bool }
    final class Roadblock {
        var center: float3
        var travel: float3               // sentido en el que llega el jugador
        var cops: [AIVehicle] = []
        var props: [Prop] = []
        var age: Float = 0
        var nearTime: Float = 0
        var dodged = false
        var spikesHit = false
        init(center: float3, travel: float3) { self.center = center; self.travel = travel }
    }

    unowned let world: AIWorld
    private(set) var state: State = .none
    var heat: Float = 1
    private(set) var bustTimer: Float = 0       // 0…5 s
    private(set) var evade: Float = 0           // 0…1
    private(set) var meter: Float = 0           // medidor de persecución (−0,5 evasión … +0,5 arresto) [D: P:2068-2093]
    private(set) var timeSinceSeen: Float = 0
    private var hiddenTime: Float = 0
    private var seenStreak: Float = 0
    private(set) var stateTime: Float = 0
    private(set) var pursuitTime: Float = 0
    private var lockout: Float = 0
    private var tick: Float = 0
    private var spawnTimer: Float = 0
    private var patrolTimer: Float = 0
    private var fleeTimer: Float = 0
    private var roadblockTimer: Float = 10
    private var lastKnown = float3(0, 0, 0)
    private var trafficHitTime: Float = -100
    private var rammed = false
    private var field: [Float]?
    private var fieldTimer: Float = 0
    private var fieldNode = -1
    private(set) var roadblock: Roadblock?
    private var formation = 7
    private var formationClock: Float = 0
    private var formationAge: Float = 0
    private var pickWeighted = false
    private(set) var costToState = 0
    private(set) var infractions = Set<String>()
    // Choques (Crash/): policías dañados y destruidos en esta persecución [D: AIPursuit mNumCopsDamaged, mCopsDestroyed,
    // IncNumCopsDestroyed (bonificación ×1…×3 durante DestroyCopBonusTime), CalcTotalCostToState: 5000 por destruido,
    // 250 por dañado, 2000 por helicóptero]
    private(set) var copsDamaged = 0, copsDestroyed = 0
    private(set) var copDestroyedMultiplier = 1
    private(set) var lastCopDestroyedType = "", lastCopDestroyedRep = 0
    private var copDestroyedBonusTimer: Float = 0
    /// Aviso: policía destruido (multiplicador de la bonificación) → HUD y sonido.
    var onCopDestroyed: ((AIVehicle, Int) -> Void)?
    var seen = false
    /// El helicóptero ve al jugador (Crash/Heli.swift): cuenta como visto en la persecución [D: AIVehicleHelicopter::CanSeeTarget].
    var heliSpotting = false
    var lastKnownPosition: float3 { lastKnown }

    /// Avisos: persecución sí/no (luz del mando, música…) y arresto (el motor decide qué hacer con el jugador).
    var onBusted: (() -> Void)?

    static let bustedTimeout: Float = 5          // kBustedTimeout [D]
    static let bustedRadius: Float = 15          // [D: P:1608]
    static let unseenToCooldown: Float = 7       // [D]
    static let formationDistance: Float = 60     // kFormationCandidateDistance [D]

    init(world: AIWorld) { self.world = world }

    var inPursuit: Bool { state == .chase || state == .cooldown }
    var level: PursuitLevel? { world.tables.level(heat) }
    var copsInPursuit: Int { world.vehicles.filter { $0.kind == .cop && $0.copRole == .pursuit }.count }

    /// AIPursuit::NotifyCopDamaged [D]: una vez por policía (SetDamagedByPerp).
    func notifyCopDamaged(_ c: AIVehicle) {
        guard !c.damagedByPerp else { return }
        c.damagedByPerp = true
        world.stats.copsDamaged += 1
        if inPursuit { copsDamaged += 1; costToState += 250 }
    }

    /// AIPursuit::IncNumCopsDestroyed [D]. El coche ya está destruido (EVehicleDestroyed).
    func notifyCopDestroyed(_ c: AIVehicle) {
        world.stats.copsDestroyed += 1
        c.lights = false
        if c.copRole == .pursuit || c.copRole == .roadblock { c.copRole = .flee }
        guard inPursuit else { onCopDestroyed?(c, 1); return }
        if copDestroyedBonusTimer > 0 { copDestroyedMultiplier = min(3, copDestroyedMultiplier + 1) } else { copDestroyedMultiplier = 1 }
        copDestroyedBonusTimer = level?.num("DestroyCopBonusTime", 10) ?? 10
        copsDestroyed += 1
        costToState += 5000
        // RepPointsForDestroying[nivel] × multiplicador [D]
        let reps = world.tables.aiVehicle[c.typeName]?.repPointsForDestroying ?? []
        let lvl = max(0, min(reps.count - 1, Int(heat) - 1))
        lastCopDestroyedType = c.typeName
        lastCopDestroyedRep = (reps.isEmpty ? 0 : reps[lvl]) * copDestroyedMultiplier
        onCopDestroyed?(c, copDestroyedMultiplier)
    }

    /// Helicóptero en la persecución (+2000 al coste para el estado) [D: CalcTotalCostToState mNumHeliSpawns].
    func notifyHeliSpawned() { if inPursuit { costToState += 2000 } }

    /// Daños a la propiedad (rompibles): COST_TO_STATE del smackable [D: AIPerpVehicle::OnCausedCollision].
    func addPropertyDamage(_ cost: Int) {
        guard inPursuit, cost > 0 else { return }
        costToState += cost
        infractions.insert("damage")
    }

    func reportTrafficHit() { trafficHitTime = world.time; if inPursuit { costToState += 500; infractions.insert("hit_and_run") } }
    func reportCopHit(_ cop: AIVehicle, closing: Float) {
        rammed = true
        costToState += max(50, Int(2000 * rampf(closing, 4, 30) / 50) * 50)
        if inPursuit { infractions.insert("assault") }
        else if lockout <= 0 && world.player.exists { startPursuit(by: cop) }
    }

    // MARK: Fotograma

    func update(dt: Float) {
        let w = world
        guard let lv = level else { return }
        lockout -= dt
        stateTime += dt
        copDestroyedBonusTimer -= dt
        tick += dt
        let doTick = tick >= 0.25
        if doTick { tick = 0 }

        if doTick { seen = false }
        // Visión de cada policía (cada 0,25 s)
        if doTick && w.player.exists {
            let hidden = w.tables.inZone("hidden", float2(w.player.pos.x, w.player.pos.y))
            if heliSpotting && inPursuit { seen = true }
            for c in w.vehicles where c.kind == .cop && c.copRole != .flee {
                let sees = !hidden && canSee(c, lv)
                if c.copRole == .roadblock, simd_distance(c.pos, w.player.pos) < 60, !hidden { seen = true }
                if sees {
                    if c.copRole == .pursuit { seen = true }
                    if !inPursuit && state != .busted && lockout <= 0 && triggers(lv) { startPursuit(by: c) }
                    else if inPursuit && c.copRole == .patrol { join(c) }
                }
            }
            if !inPursuit && state != .busted && lockout <= 0, w.tables.inZone("pursuitStart", float2(w.player.pos.x, w.player.pos.y)),
               let c = w.vehicles.first(where: { $0.kind == .cop && $0.copRole == .patrol && simd_distance($0.pos, w.player.pos) < lv.frontLOS }) {
                startPursuit(by: c)   // MForcePursuitStart [D: AV:2170-2177]
            }
        }

        // Patrullas y retiradas fuera de pantalla y a más de 375 m (150 m si se retiran) del punto 75 m por delante [D: CM]
        let ahead = w.center + w.centerFwd * 75
        for c in w.vehicles where c.kind == .cop && (c.copRole == .flee || (c.copRole == .patrol && !inPursuit)) {
            let far = simd_distance(c.pos, ahead) > (c.copRole == .flee ? 150 : 375)
            if c.offscreenTime > 2 && far { w.remove(c) }
        }
        switch state {
        case .none, .evaded:
            if state == .evaded && stateTime > 3 { state = .none }
            patrol(dt: dt, lv: lv)
        case .busted:
            for c in w.vehicles where c.kind == .cop { c.speed = max(0, c.speed - 12 * dt); c.braking = true; c.lights = false }
            if stateTime > 3 { endPursuit(evaded: false) }   // kBustedHUDTime [D]
        case .chase, .cooldown:
            pursue(dt: dt, lv: lv, doTick: doTick)
        }
        driveCops(dt: dt, lv: lv)
        updateRoadblock(dt: dt, lv: lv)
        world.stats.maxHeat = max(world.stats.maxHeat, heat)
    }

    // MARK: Visión y arranque

    private func canSee(_ c: AIVehicle, _ lv: PursuitLevel) -> Bool {
        let p = world.player.pos
        let to = p - c.pos
        let d = simd_length(float2(to.x, to.y))
        if d > max(lv.frontLOS, lv.rearLOS) { return false }
        if d > lv.rearLOS {
            guard d < lv.frontLOS, simd_dot(c.fwd, simd_normalize(float3(to.x, to.y, 0) + 1e-6)) > -0.3 else { return false }
        }
        // Línea de visión: ningún muro de colisión entre los dos coches (a 0,5 m de altura) [D: CC:155]
        let a = c.pos + float3(0, 0, 1.0), b = p + float3(0, 0, 1.0)
        let n = max(1, Int(d / 25) + 1)
        for k in 0..<n {
            let s = a + (b - a) * (Float(k) / Float(n)), e = a + (b - a) * (Float(k + 1) / Float(n))
            if world.collision.hitsWall(from: s, to: e) { return false }
        }
        return true
    }

    /// Camino directo sin muros de colisión (a 0,6 m de altura), por tramos de 25 m.
    func clearPath(_ a0: float3, _ b0: float3) -> Bool {
        let a = a0 + float3(0, 0, 0.6), b = b0 + float3(0, 0, 0.6)
        let n = max(1, Int(simd_distance(a, b) / 25) + 1)
        for k in 0..<n where world.collision.hitsWall(from: a + (b - a) * (Float(k) / Float(n)), to: a + (b - a) * (Float(k + 1) / Float(n))) { return false }
        return true
    }

    private func triggers(_ lv: PursuitLevel) -> Bool {
        let w = world
        return abs(w.player.speed) >= AITables.mph(65) || w.time - trafficHitTime < 1 || heat > 3 || rammed
    }

    private func startPursuit(by cop: AIVehicle) {
        let w = world
        state = .chase; stateTime = 0; pursuitTime = 0
        bustTimer = 0; evade = 0; timeSinceSeen = 0; hiddenTime = 0; seenStreak = 0
        spawnTimer = 2; roadblockTimer = 8 + w.rng.range(0, 4); formationClock = 0
        infractions = []; costToState = 0
        copsDamaged = 0; copsDestroyed = 0; copDestroyedMultiplier = 1; copDestroyedBonusTimer = 0
        if abs(w.player.speed) >= AITables.mph(65) { infractions.insert("speeding") }
        if rammed { infractions.insert("assault") }
        lastKnown = w.player.pos
        join(cop)
        // Las patrullas cercanas se suman
        for c in w.vehicles where c.kind == .cop && c.copRole == .patrol && simd_distance(c.pos, w.player.pos) < 250 { join(c) }
        w.stats.pursuitsStarted += 1
        w.onPursuitChanged?(true)
    }

    /// La persecución empieza ya (MForcePursuitStart [D]): desafíos de la Serie y pruebas con PursuitRace (Race/).
    /// Usa un policía que ya esté cerca o hace aparecer uno de persecución.
    func forcePursuit() {
        guard !inPursuit, state != .busted, let lv = level, world.player.exists else { return }
        lockout = 0
        if let c = world.vehicles.filter({ $0.kind == .cop && $0.copRole != .flee }).min(by: { simd_distance($0.pos, world.player.pos) < simd_distance($1.pos, world.player.pos) }),
           simd_distance(c.pos, world.player.pos) < 400 { startPursuit(by: c); return }
        if spawnPursuitCop(lv), let c = world.vehicles.last(where: { $0.kind == .cop }) { startPursuit(by: c) }
    }

    private func join(_ c: AIVehicle) {
        c.copRole = .pursuit
        c.lights = true
        costToState += 250
    }

    private func endPursuit(evaded: Bool) {
        let w = world
        for c in w.vehicles where c.kind == .cop {
            c.copRole = .flee; c.lights = false
            if c.mode == .free { relane(c) }
            c.cruise = AITables.mph(35)
        }
        if let rb = roadblock { for c in rb.cops where c.mode == .parked { relane(c) }; roadblock = nil }
        if evaded {
            state = .evaded; stateTime = 0
            heat = max(1, heat * (level?.evadeSuccessHeatAdjust ?? 0.95))
            lockout = 60   // kCopLockoutTime [D]
            w.stats.evaded += 1
        } else {
            state = .none; stateTime = 0
            heat = 1        // tras el arresto se vuelve a calor 1 [I]
            lockout = 20
        }
        rammed = false
        bustTimer = 0; evade = 0
        w.onPursuitChanged?(false)
    }

    // MARK: Patrulla

    private func patrol(dt: Float, lv: PursuitLevel) {
        let w = world
        patrolTimer -= dt
        let patrols = w.vehicles.filter { $0.kind == .cop && $0.copRole == .patrol }.count
        if patrols < lv.numPatrolCars && patrolTimer <= 0 && lockout <= 0 {
            patrolTimer = 1
            if let (type, model) = pickCop(lv), let p = world.traffic.pattern ?? world.tables.trafficPatterns["default"],
               let c = w.traffic.spawn(model: model, typeName: type, pattern: p, kind: .cop) {
                c.copRole = .patrol
                world.traffic.setCruise(c, p)
            }
        }
    }

    /// Tipo de policía al azar ponderado por Chance (sin helicóptero) [D: CopRequest].
    private func pickCop(_ lv: PursuitLevel) -> (String, AIModel)? {
        let opts = lv.cops.filter { $0.model != "COPHELI" && !$0.model.isEmpty }
        guard !opts.isEmpty else { return nil }
        let total = opts.reduce(0) { $0 + max(1, $1.chance) }
        var r = Int(world.rng.next() % UInt64(total))
        var pick = opts[0]
        for o in opts { r -= max(1, o.chance); if r < 0 { pick = o; break } }
        guard let m = world.models.model(pick.model) else { return nil }
        return (pick.type, m)
    }

    // MARK: Persecución

    private func pursue(dt: Float, lv: PursuitLevel, doTick: Bool) {
        let w = world
        let p = w.player
        pursuitTime += dt
        if seen { timeSinceSeen = 0; lastKnown = p.pos } else { timeSinceSeen += dt }
        let unseen = timeSinceSeen > 0.3

        // Calor por tiempo de persecución (no en enfriamiento) [D: P:1660-1688]
        if state == .chase {
            heat = min(AIConfig.maxOpenWorldHeat, heat + dt / max(1, lv.timePerHeatLevel * lv.scaleEscalation(bucket: AIConfig.careerBucket)))
        }

        // Arresto
        let speedKmh = abs(p.speed) * 3.6
        let near = w.vehicles.contains { $0.kind == .cop && $0.copRole == .pursuit &&
            simd_length(float2($0.pos.x - p.pos.x, $0.pos.y - p.pos.y)) < PoliceManager.bustedRadius && abs($0.pos.z - p.pos.z) < 1.5 }
        if !unseen && speedKmh < lv.bustSpeedKmh && near { bustTimer += dt } else { bustTimer = max(0, bustTimer - 2 * dt) }
        if bustTimer >= PoliceManager.bustedTimeout {
            state = .busted; stateTime = 0
            w.stats.busted += 1
            onBusted?()
            return
        }

        // Medidor de persecución [D: P:2068-2093]
        let dNear = w.vehicles.filter { $0.kind == .cop && $0.copRole == .pursuit }.map { simd_distance($0.pos, p.pos) }.min() ?? 999
        if dNear > lv.meterDeadZoneEvade {
            let ratio = (dNear - lv.meterDeadZoneEvade) / max(1, lv.frontLOS - lv.meterDeadZoneEvade)
            meter = max(-0.5, min(-0.1, -0.1 - 0.4 * ratio))
        } else if dNear < lv.meterDeadZoneBusted && speedKmh <= 70 * 1.609 {
            let D = max(0, min(1, (lv.meterDeadZoneBusted - dNear) / max(1, lv.meterDeadZoneBusted - 15)))
            let S = max(0, min(1, (100 - speedKmh) / max(1, 100 - lv.bustSpeedKmh)))
            meter = (0.3 * D + 0.7 * S) * 0.4 + 0.1
        } else { meter = 0 }

        // Enfriamiento y evasión [D: P:2027-2066]
        if state == .chase && timeSinceSeen > PoliceManager.unseenToCooldown {
            state = .cooldown; stateTime = 0; infractions.insert("resisting_arrest"); seenStreak = 0
            evade = max(0.05, timeSinceSeen / max(1, lv.evadeTimeout))
        }
        if state == .cooldown {
            // evasión = (tiempo sin verte + escondido × HiddenZoneTimeMultiplier) / evadetimeout; si te ven, × 0,93 cada 0,25 s
            let hidden = w.tables.inZone("hidden", float2(p.pos.x, p.pos.y))
            if !unseen {
                seenStreak += dt
                if doTick { evade *= 0.93 }
                if seenStreak > 2.5 { state = .chase; stateTime = 0; hiddenTime = 0; evade = 0 }
            } else {
                seenStreak = 0
                let rate = 1 + (hidden ? lv.hiddenZoneTimeMultiplier : 0)
                if hidden { hiddenTime += dt * lv.hiddenZoneTimeMultiplier }
                evade = max(0.05, evade + dt * rate / max(1, lv.evadeTimeout))
            }
            if evade >= 1 { endPursuit(evaded: true); return }
        }

        // Refuerzos [D: GetAdjustedCopCounts, CopRequest]
        let nominal = lv.cops.filter { $0.model != "COPHELI" }.reduce(0) { $0 + $1.count }
        let want = state == .cooldown ? max(lv.numPatrolCars, min(nominal, 2)) : min(nominal, lv.fullEngagementCopCount, AIConfig.maxCops)
        let active = copsInPursuit
        spawnTimer -= dt
        if state == .chase && active < want && w.count(.cop) < AIConfig.maxCops && spawnTimer <= 0 {
            if spawnPursuitCop(lv) { spawnTimer = lv.timeBetweenCopSpawn } else { spawnTimer = 1 }
        }
        // Sobran (enfriamiento): se retiran de uno en uno
        fleeTimer -= dt
        if active > want && fleeTimer <= 0, let far = w.vehicles.filter({ $0.kind == .cop && $0.copRole == .pursuit })
            .max(by: { simd_distance($0.pos, p.pos) < simd_distance($1.pos, p.pos) }) {
            far.copRole = .flee; far.lights = false; if far.mode == .free { relane(far) }; fleeTimer = 2
        }
        // Se acaba si ya no queda nadie y no te ven [D: ShouldEnd]
        if active == 0 && roadblock == nil && state == .cooldown && stateTime > 10 { endPursuit(evaded: true) }

        // Controles de carretera [D: P:2459-2506]
        roadblockTimer -= dt
        if roadblockTimer <= 0 {
            roadblockTimer = 8 + w.rng.range(0, 4)
            let delay = AIConfig.careerBucket >= 0 ? (w.tables.supportDelay.indices.contains(Int(heat) - 1) ? w.tables.supportDelay[Int(heat) - 1] : 10) : 10
            if roadblock == nil && pursuitTime > delay {
                let chance: Float = !unseen ? lv.roadblockProbability
                    : lv.num("SearchModeRoadblockChance", 0) * max(0, (lv.num("SearchModeRoadblockRadius", 1000) - simd_distance(p.pos, lastKnown)) / lv.num("SearchModeRoadblockRadius", 1000))
                if w.debug { print(String(format: "  control: tirada %.0f %%, visto %@", chance, unseen ? "no" : "sí")) }
                if w.rng.float() * 100 < chance { if w.debug { print("  control: ¡sale!") }; buildRoadblock(lv, spikes: state == .chase && w.rng.float() * 100 < lv.roadblockSpikeChance) }
            }
        }

        // Campo de distancias por la red hacia el jugador (o al último punto visto) para la persecución lejana
        fieldTimer -= dt
        if fieldTimer <= 0 {
            fieldTimer = 1
            let goal = state == .cooldown ? lastKnown : p.pos
            if let hit = w.net.nearest(goal, maxDist: 80, filter: { w.net.copsAllowed($0) }) {
                let s = w.net.segs[hit.seg]
                let node = hit.t < 0.5 ? s.n0 : s.n1
                if node != fieldNode || field == nil { field = w.net.distanceField(to: node, cops: true); fieldNode = node }
            }
        }

        // Formaciones
        formationClock -= dt; formationAge += dt
        if formationClock <= 0 {
            pickWeighted.toggle()
            if pickWeighted, !lv.formations.isEmpty {
                let tot = lv.formations.reduce(Float(0)) { $0 + max(0.01, $1.frequency) }
                var r = w.rng.float() * tot
                var f = lv.formations[0]
                for x in lv.formations { r -= max(0.01, x.frequency); if r <= 0 { f = x; break } }
                formation = f.type; formationClock = max(4, f.duration) + w.rng.range(0, 3)
            } else {
                formation = 7; formationClock = lv.num("StaggerFormationTime", 10) + w.rng.range(0, 3)
            }
            formationAge = 0
        }
    }

    /// Un policía de refuerzo en la red, a 150–320 m, mejor fuera de la vista y por detrás o por delante del jugador.
    private func spawnPursuitCop(_ lv: PursuitLevel) -> Bool {
        let w = world
        guard let (type, model) = pickCop(lv) else { return false }
        let p = w.player
        for attempt in 0..<8 {
            let base: Float = attempt % 2 == 0 ? .pi : 0          // detrás, luego delante
            let a = p.yaw + base + w.rng.range(-1.0, 1.0)
            let d = w.rng.range(150, 320)
            let pt = p.pos + float3(cos(a), sin(a), 0) * d
            if w.tables.inZone("noCopSpawn", float2(pt.x, pt.y)) { continue }
            guard let hit = w.net.nearest(pt, maxDist: 60, filter: { w.net.copsAllowed($0) && !w.net.segs[$0].has(RoadSegFlags.decision) }) else { continue }
            let q = w.net.point(hit.seg, hit.t)
            if simd_distance(q, p.pos) < 120 || w.onScreen(q, radius: 3) && attempt < 6 { continue }
            // De cara al jugador
            let tan = w.net.tangent(hit.seg, hit.t)
            var forward = simd_dot(tan, p.pos - q) >= 0
            if w.net.segs[hit.seg].has(RoadSegFlags.oneWay) { forward = true }
            let lanes = w.net.laneOffsets(hit.seg, forward: forward, end: forward ? 0 : 1)
            let v = AIVehicle(id: w.newID(), kind: .cop, model: model, typeName: type)
            v.place(net: w.net, seg: hit.seg, forward: forward, t: hit.t, lane: lanes.isEmpty ? 0 : Int(w.rng.next() % UInt64(lanes.count)), collision: w.collision)
            if !v.groundOK { continue }
            if w.vehicles.contains(where: { simd_distance($0.pos, v.pos) < 12 }) { continue }
            v.copRole = .pursuit; v.lights = true
            v.speed = AITables.mph(60)   // salen lanzados a 60 mph [D]
            w.vehicles.append(v)
            w.stats.copsSpawned += 1
            w.stats.modelsUsed.insert(model.name)
            return true
        }
        return false
    }

    // MARK: Conducción de los policías

    /// Huecos de formación en el espacio del jugador: x = derecha, z = delante [D: P:179-439].
    private func slots(_ lv: PursuitLevel) -> [float2] {
        let t = lv.boxinTightness
        switch formation {
        case 1: return [float2(4, -2.7), float2(-4, -2.7)]                                         // PIT
        case 2: return [float2(0, 14), float2(-3.5, 0), float2(3.5, 0), float2(0, -7.5)].map { $0 * (1.15 - 0.3 * t) }   // BOX_IN
        case 3: return [float2(0, 14), float2(-2.5, 14), float2(2.5, 10), float2(-5, 14), float2(5, 14)]              // ROLLING_BLOCK
        case 6: return [float2(-3, 0), float2(-3, 5), float2(-3, -5)]                                                 // HERD
        case 7: return [float2(0, -13), float2(0, 13), float2(3.5, -13), float2(-3.5, 13), float2(-3.5, -13), float2(3.5, 13)]  // STAGGER
        default: return [float2(0, -13), float2(-3.5, -13), float2(3.5, -13), float2(0, -17), float2(-3.5, -17), float2(3.5, -17)] // FOLLOW
        }
    }

    private func driveCops(dt: Float, lv: PursuitLevel) {
        let w = world
        let p = w.player
        let pf = p.fwd, pr = float3(pf.y, -pf.x, 0)
        let lead = p.vel * 0.25
        // Asignación de huecos a los policías cercanos
        var assigned: [Int: float3] = [:]
        var ram = Set<Int>()
        if inPursuit && p.exists {
            let near = w.vehicles.filter { $0.kind == .cop && $0.copRole == .pursuit && simd_distance($0.pos, p.pos) < PoliceManager.formationDistance && abs($0.pos.z - p.pos.z) < 5 }
                .sorted { simd_distance($0.pos, p.pos) < simd_distance($1.pos, p.pos) }
            let collapse = abs(p.speed) * 3.6 < lv.collapseSpeedKmh && timeSinceSeen < 1
            var free: [float2]
            if collapse {
                // Colapso: en círculo alrededor del jugador [D: P:1239-1337]
                let n = max(1, min(near.count, Int(lv.num("MaxCopsCollapsing", 6))))
                free = (0..<n).map { k in let a = Float(k) / Float(n) * 2 * .pi; return float2(cos(a), sin(a)) * (lv.collapseInnerRadius + 1.5) }
            } else { free = slots(lv) }
            let finisher = !collapse && (formation == 2 || formation == 1) && formationAge > 4
            for c in near {
                guard !free.isEmpty else { break }
                let worldOf = { (s: float2) in p.pos + pr * s.x + pf * s.y + lead }
                let k = free.indices.min { simd_distance(worldOf(free[$0]), c.pos) < simd_distance(worldOf(free[$1]), c.pos) }!
                assigned[c.id] = worldOf(free[k])
                if finisher { ram.insert(c.id) }
                free.remove(at: k)
            }
        }
        var row = 0
        for c in w.vehicles where c.kind == .cop {
            if c.copCrashStep(world: w, police: self, dt: dt) { continue }   // choque, destruido o inmovilizado (Crash/)
            let attr = w.tables.aiVehicle[c.typeName] ?? w.tables.aiVehicle["cops"]
            let cap = (attr?.maxSpeedKmh ?? 200) / 3.6
            let topMul = attr?.topSpeedMultiplier ?? 1
            let acc: Float = 6 * (attr?.accelerationMultiplier ?? 1)
            switch c.copRole {
            case .roadblock:
                c.mode = .parked; c.speed = 0; c.braking = true
            case .patrol, .flee:
                if c.mode != .lane { relane(c) }
                w.stepLane(c, dt: dt, cops: false, field: nil, mu: 0.6, accel: 2.5)
            case .pursuit:
                guard p.exists else { break }
                c.laneLock -= dt
                c.lastSeenCheck -= dt
                if c.lastSeenCheck <= 0 {
                    c.lastSeenCheck = 0.25
                    c.directOK = simd_distance(c.pos, p.pos) < PoliceManager.formationDistance + 25 && clearPath(c.pos, p.pos)
                }
                if state == .busted { c.speed = 0; break }
                let d = simd_distance(c.pos, p.pos)
                let catchUp = max(0, min(25, (d - 20) * 0.15))
                // En enfriamiento buscan a SearchModeCityMPH / SearchModeHwyMPH [D: AIActionTraffic.cpp 191-194], no a tu velocidad
                let lanesHere = w.net.laneOffsets(c.seg, forward: true, end: 0).count + w.net.laneOffsets(c.seg, forward: false, end: 0).count
                let search = AITables.mph(lanesHere >= 4 ? lv.num("SearchModeHwyMPH", 71) : lv.searchModeCityMph)
                let chase = state == .cooldown ? min(cap, search)
                    : min(cap, max(abs(p.speed) * min(topMul, 1.15), AITables.mph(45)) + catchUp)
                if c.mode == .parked { relane(c) }
                if c.laneLock <= 0, c.directOK, let slot = assigned[c.id] ?? (state == .chase && d < PoliceManager.formationDistance && abs(c.pos.z - p.pos.z) < 5 ? chaseSlot(&row, p) : nil) {
                    // Persecución directa (AIActionPursuitOffRoad): al hueco o embistiendo
                    if c.mode != .free { c.mode = .free }
                    c.target = ram.contains(c.id) ? p.pos + p.vel * 0.3 : slot
                    let ahead = simd_dot(c.target - c.pos, c.fwd)
                    var want = max(0, simd_dot(p.vel, c.fwd)) + max(-12, min(25, ahead * 0.9))
                    if ram.contains(c.id) { want = abs(p.speed) + 8 }
                    want = min(want, cap)
                    if want > c.speed { c.speed = min(want, c.speed + acc * 1.5 * dt) } else { c.speed = max(want, c.speed - 14 * dt) }
                    c.braking = want < c.speed - 0.5
                    c.driveFree(collision: w.collision, dt: dt, mu: 1.6)
                    c.spin += c.speed * dt / c.model.wheelRadius
                    if d > PoliceManager.formationDistance + 25 { relane(c) }
                    else if c.blockedTime > 1.5 { relane(c); c.laneLock = 3; c.blockedTime = 0 }   // GetUnstuck [D]
                } else {
                    if c.mode == .free { relane(c) }
                    c.cruise = chase
                    w.stepLane(c, dt: dt, cops: true, field: field, mu: 1.6, accel: acc)
                }
            }
        }
    }

    /// Hueco de persecución para los que no tienen formación: x = c·3,5, z = −(25 + 5·fila) [D: P:1581-1586].
    private func chaseSlot(_ row: inout Int, _ p: AIPlayer) -> float3 {
        let c = Float(row % 3 - 1), r = Float(row / 3)
        row += 1
        let pf = p.fwd, pr = float3(pf.y, -pf.x, 0)
        return p.pos + pr * (c * 3.5) - pf * (25 + 5 * r) + p.vel * 0.25
    }

    /// Vuelve a la red tras ir en directo: segmento más cercano en el sentido del morro, sin salto lateral.
    func relane(_ c: AIVehicle) {
        let w = world
        guard let hit = w.net.nearest(c.pos, maxDist: 80, filter: { w.net.copsAllowed($0) }) else { c.mode = .free; return }
        let tan = w.net.tangent(hit.seg, hit.t)
        var forward = simd_dot(tan, c.fwd) >= 0
        if w.net.segs[hit.seg].has(RoadSegFlags.oneWay) { forward = true }
        let keep = c.pos
        c.place(net: w.net, seg: hit.seg, forward: forward, t: hit.t, lane: 0, collision: w.collision)
        let ax = c.axis(w.net, c.dist)
        let right = simd_normalize(float3(ax.t.y, -ax.t.x, 0) + 1e-9)
        c.lat = simd_dot(keep - ax.p, right)
        c.pos = keep
        c.mode = .lane
    }

    // MARK: Controles de carretera

    private struct Item { let kind: Character; let x: Float; let z: Float; let a: Float }
    private struct Setup { let minWidth: Float; let cars: Int; let items: [Item] }
    private static func S(_ w: Float, _ n: Int, _ it: [(Character, Float, Float, Float)]) -> Setup { Setup(minWidth: w, cars: n, items: it.map { Item(kind: $0.0, x: $0.1, z: $0.2, a: $0.3) }) }
    /// Montajes de AIRoadBlockSetups.cpp [D]: ancho mínimo, coches, y por elemento (C coche, B caballete, S pinchos) x, z, ángulo (vueltas).
    private static let normalSetups: [Setup] = [
        S(8, 2, [("C", -3, 0, 0.75), ("C", 2, -0.35, 0.27)]),
        S(12, 3, [("C", -5.2, -2, 0.875), ("C", 0, -2, 0.12), ("C", 4.5, -1, 0.87), ("B", -2.9, 0.2, 0.48)]),
        S(5.5, 2, [("C", -2, 0, 0.26), ("C", 2, 5, 0.48), ("B", 1.5, 1.7, 0.61)]),
        S(6.5, 2, [("C", -2, 0, 0.75), ("C", 3, 4, 0.25), ("B", 1.5, 1.7, 0.61)]),
        S(8.5, 2, [("C", -0.9, 0, 0.72), ("C", 4, 0, 0.32), ("B", -4.8, -0.8, 0.54)]),
        S(15, 4, [("C", -5, 0, 0.71), ("C", 1, 0, 0.29), ("C", 5, 6, 0.24), ("C", 8, 2, 0.5), ("B", 4.1, -1.4, 0.57), ("B", 6.1, -1.4, 0.43)]),
        S(13, 3, [("C", -4, 1, 0.26), ("C", -0.9, -4.2, 0.75), ("C", 5, -4, 0.26), ("B", -3.3, -2.2, 0.4), ("B", -5, -4, 0.46)]),
        S(11.4, 3, [("C", -4.4, -1.2, 0.65), ("C", 0, 2.4, 0.24), ("C", 4.4, -1.2, 0.35), ("B", 0, -2.7, 0.49), ("B", 2.1, 0, 0.35), ("B", -2.1, 0, 0.65)]),
        S(12.1, 3, [("C", -4.5, 0, 0.75), ("C", 1, 0, 0.25), ("C", 4, 4.5, 0.72), ("B", 4.3, -1.2, 0.48), ("B", 4.9, 0.3, 0.04)]),
        S(10, 4, [("C", -4.5, 0, 0.27), ("C", -0.3, -4, 0.75), ("C", 4.2, -4, 0.24), ("C", 4, 0, 0.26), ("B", -4.9, -5, 0.51), ("B", -4.2, -3.3, 0.53)]),
        S(14, 4, [("C", -4.5, 0, 0.25), ("C", 1, 0, 0.75), ("C", 0, 5.4, 0.25), ("C", 5.3, 5.4, 0.22), ("B", -2, 2.2, 0.37), ("B", 5.4, -0.2, 0.53)]),
        S(12, 4, [("C", -4.3, 0, 0.74), ("C", -5, 4, 0.75), ("C", 0.2, 4, 0.27), ("C", 4, 0, 0.25), ("B", -0.7, -1, 0.355), ("B", 0.7, -1, 0.635)]),
        S(22, 4, [("C", -9, 0, 0.74), ("C", -3, 0, 0.25), ("C", 3, 0, 0.75), ("C", 9, 0, 0.25), ("B", 0, -3, 0.5)]),
        S(15, 3, [("C", -5.9, 0, 0.74), ("C", 0, 0, 0.25), ("C", 5.9, 0, 0.75), ("B", 3, -2, 0.51)]),
        S(28, 5, [("C", -12, 0, 0.75), ("C", -6, 0, 0.25), ("C", 0, 0, 0.75), ("C", 6, 0, 0.25), ("C", 12, 0, 0.75), ("B", -3, -3.4, 0.5)]),
    ]
    private static let spikeSetups: [Setup] = [
        S(8, 1, [("C", -3, 0, 0.75), ("S", 2, -0.35, 0.52)]),
        S(15, 3, [("S", -5, 0, 0.5), ("C", 1, 0, 0.29), ("C", 5, 6, 0.24), ("C", 8, 2, 0.5), ("B", 4.1, -1.4, 0.57), ("B", 6.1, -1.4, 0.43)]),
        S(15, 2, [("C", -4, 1, 0.26), ("C", -0.9, -4.2, 0.75), ("S", 5, -4, 0.5), ("B", -3.3, -2.2, 0.4), ("B", -5, -4, 0.46)]),
        S(14.1, 2, [("S", -4.8, 0, 0.5), ("C", 1, 0, 0.25), ("C", 4, 4.5, 0.72), ("B", 4.3, -1.2, 0.48), ("B", 4.9, 0.3, 0.04)]),
        S(12, 3, [("C", -4.5, 0, 0.27), ("S", -0.3, -4.4, 0.5), ("C", 4.2, -4, 0.24), ("C", 4, 0, 0.26)]),
        S(13, 3, [("S", -4, 0, 0.51), ("C", -5, 4, 0.75), ("C", 0.2, 4, 0.27), ("C", 4, 0, 0.25), ("B", -0.7, -1, 0.355), ("B", 0.7, -1, 0.635)]),
        S(21, 2, [("S", -9, 0, 0.5), ("C", -3, 0, 0.75), ("C", 3, 0, 0.25), ("S", 9, 0, 0.5), ("B", 0, -3, 0.5)]),
        S(15, 2, [("S", -5.2, 0, 0.5), ("C", 0, 0, 0.25), ("C", 5.9, 0, 0.75), ("B", 3, -2, 0.51)]),
        S(28, 4, [("C", -12, 0, 0.75), ("C", -6, 0, 0.25), ("S", -1, 0, 0.51), ("C", 5, 0, 0.75), ("C", 11, 0, 0.25)]),
    ]

    /// 250 m por delante del jugador por la red, en un tramo apto [D: CM:1100-1307].
    func buildRoadblock(_ lv: PursuitLevel, spikes: Bool) {
        let w = world
        let p = w.player
        guard let hit = w.net.nearest(p.pos, maxDist: 40, filter: { w.net.copsAllowed($0) && !w.net.segs[$0].has(RoadSegFlags.decision) })
                ?? w.net.nearest(p.pos, maxDist: 40, filter: { w.net.copsAllowed($0) }) else { return }
        var seg = hit.seg
        var forward = simd_dot(w.net.tangent(seg, hit.t), p.fwd) >= 0
        // distancia recorrida hasta el INICIO del tramo actual (negativa en el primero: ya vamos por dentro)
        var before = -(forward ? w.net.distance(seg, atT: hit.t) : w.net.segs[seg].length - w.net.distance(seg, atT: hit.t))
        var heading = p.fwd
        var found: (Int, Bool, Float)? = nil
        for _ in 0..<80 {
            let s = w.net.segs[seg]
            if before + s.length >= 250, w.net.trafficAllowed(seg), !s.has(RoadSegFlags.intersection), !s.has(RoadSegFlags.decision), s.length >= 30 {
                let local = max(15, min(s.length - 15, 250 - before))     // metros dentro del tramo, en el sentido de marcha
                let d = forward ? local : s.length - local
                found = (seg, forward, w.net.t(seg, atDistance: d)); break
            }
            if before > 700 { break }
            let node = forward ? s.n1 : s.n0
            // la continuación más recta
            var cands = w.net.nodeSegs[node].filter { $0 != seg && w.net.canEnter($0, from: node, cops: true) }
            if cands.isEmpty { cands = w.net.nodeSegs[node].filter { $0 != seg && $0 < w.net.count && !w.net.blocked($0) } }
            guard let nx = cands.max(by: { a, b in
                let da = simd_normalize(w.net.nodePos[w.net.otherNode(a, node)] - w.net.nodePos[node] + 1e-6)
                let db = simd_normalize(w.net.nodePos[w.net.otherNode(b, node)] - w.net.nodePos[node] + 1e-6)
                return simd_dot(da, heading) < simd_dot(db, heading)
            }) else { if w.debug { print("  control: sin salida en nodo \(node) (\(w.net.nodeSegs[node].count) tramos) tras \(Int(before)) m, tramo \(seg) flags \(s.flags) blocked \(w.net.blocked(seg))") }; break }
            heading = simd_normalize(w.net.nodePos[w.net.otherNode(nx, node)] - w.net.nodePos[node] + 1e-6)
            before += s.length
            seg = nx; forward = w.net.segs[nx].n0 == node
        }
        guard let (rs, fwd, t) = found else { if w.debug { print("  control: sin tramo apto a 250 m") }; return }
        let center = w.net.point(rs, t)
        var travel = w.net.tangent(rs, t); if !fwd { travel = -travel }
        // Ancho de la calzada en ese punto (|L − R| + 1) y su centro, en metros a la derecha del sentido nodo 0 → 1
        guard let e0 = w.net.roadExtents(rs, end: 0), let e1 = w.net.roadExtents(rs, end: 1) else { return }
        let lo = e0.0 + (e1.0 - e0.0) * t, hi = e0.1 + (e1.1 - e0.1) * t
        let width = hi - lo + 1
        let segRight = simd_normalize(float3(w.net.tangent(rs, t).y, -w.net.tangent(rs, t).x, 0) + 1e-6)
        let mid = center + segRight * ((lo + hi) / 2)
        // Coches del control aparte del tope de 8 de la persecución (el PS2 los saca del mismo cupo [D]; aquí hasta 6 más [I])
        let available = AIConfig.maxCops + 6 - w.count(.cop)
        let list = spikes ? PoliceManager.spikeSetups : PoliceManager.normalSetups
        guard let setup = list.filter({ $0.cars <= available && width - $0.minWidth > 0 }).min(by: { width - $0.minWidth < width - $1.minWidth })
                ?? list.filter({ $0.cars <= available }).min(by: { abs(width - $0.minWidth) < abs(width - $1.minWidth) }) else { return }
        let scale = max(1, min(1.14, width / setup.minWidth))
        // Marco del control: z = hacia el jugador (de cara a él), x = derecha de ese sentido
        let zAxis = -travel, xAxis = float3(zAxis.y, -zAxis.x, 0)
        let yaw0 = atan2(zAxis.y, zAxis.x)
        let rb = Roadblock(center: mid, travel: travel)
        for it in setup.items {
            var pos = mid + xAxis * (it.x * scale) + zAxis * it.z
            if let g = w.collision.ground(x: pos.x, y: pos.y, z: pos.z + 1, step: 2) { pos.z = g.z }
            let yaw = yaw0 + it.a * 2 * .pi
            if it.kind == "C" {
                guard let (type, model) = pickCop(lv) else { continue }
                let c = AIVehicle(id: w.newID(), kind: .cop, model: model, typeName: type)
                c.pos = pos; c.yaw = yaw; c.mode = .parked; c.copRole = .roadblock; c.lights = true; c.speed = 0
                w.vehicles.append(c); rb.cops.append(c)
                w.stats.copsSpawned += 1; w.stats.modelsUsed.insert(model.name)
            } else {
                rb.props.append(Prop(pos: pos, yaw: yaw, spike: it.kind == "S"))
            }
        }
        roadblock = rb
        w.stats.roadblocks += 1
    }

    private func updateRoadblock(dt: Float, lv: PursuitLevel) {
        guard let rb = roadblock else { return }
        let w = world
        rb.age += dt
        let p = w.player.pos
        let along = simd_dot(rb.center - p, rb.travel)
        let d = simd_distance(rb.center, p)
        if d < 300 { rb.nearTime += dt }
        // Pinchos: pasar por encima de una tira (4 m × 0,6 m) [I: el juego revienta las ruedas; aquí frena en seco]
        if !rb.spikesHit {
            for pr in rb.props where pr.spike {
                let rel = p - pr.pos
                let ax = float3(cos(pr.yaw), sin(pr.yaw), 0)
                if abs(rel.z) < 2, abs(simd_dot(rel, ax)) < 0.6 + w.player.halfLength * 0.5, abs(simd_dot(rel, float3(ax.y, -ax.x, 0))) < 2.2 {
                    rb.spikesHit = true; w.stats.spikesHit += 1; w.playerSpeedFactor *= 0.35
                    for c in rb.cops.prefix(3) { join(c); c.mode = .lane; relane(c) }   // hasta 3 se suman [D: P:2791]
                }
            }
        }
        if !rb.dodged && along < -5 {
            rb.dodged = true; w.stats.roadblocksDodged += 1
            for c in rb.cops where c.copRole == .roadblock { join(c); relane(c) }
        }
        // Esperar cerca más de 20 s o enfriamiento: el más cercano se suma [D: AIRoadBlock.cpp 110-117]
        if !rb.dodged && (rb.nearTime > 20 || state == .cooldown), let c = rb.cops.filter({ $0.copRole == .roadblock }).min(by: { simd_distance($0.pos, p) < simd_distance($1.pos, p) }) {
            join(c); relane(c); rb.nearTime = 0
        }
        // Se recoge cuando queda lejos y fuera de la vista
        if (rb.dodged && d > 300) || d > 900 || !inPursuit {
            for c in rb.cops where c.copRole == .roadblock { w.remove(c) }
            roadblock = nil
        }
    }
}
