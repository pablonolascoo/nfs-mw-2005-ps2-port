// Sistema de carreras: une los datos (races.json), las vallas del mundo, la prueba en curso y la carrera profesional con
// el motor. Lo crea `Engine.enableRaces()` (o el primer uso de la API) y avanza en `Engine.frameHooks`.
//
// API para los menús (UI/):
//     QuickRace.shared.start(eventID: "15.1.1")        // carrera rápida
//     QuickRace.shared.events                          // pruebas disponibles en carrera rápida
//     Career.shared.start()  /  Career.shared.newGame() // carrera profesional (Lista Negra), partida guardada
//     Career.shared.showBlacklist()                    // pantalla de la Lista Negra (RaceHUD.showBlacklist)
//     RaceSystem.shared?.abandon()                     // salir de la prueba (pausa)
// En la zona libre, las pruebas del bin actual se arrancan desde su marcador del mundo (engagetrigger del juego):
// se entra en el círculo y se pulsa Intro (o ✕ / A en el mando).
import Foundation
import simd

final class RaceSystem {
    static private(set) var shared: RaceSystem?

    unowned let engine: Engine
    let db: RaceDatabase
    let world: RaceWorld
    private(set) var session: RaceSession?
    var hud: RaceHUD? { engine.raceHUD }
    var playerName = "TÚ"
    /// Dificultad de la carrera rápida (GRace::Difficulty): 0 fácil, 1 media, 2 difícil.
    var quickRaceDifficulty = 1
    var log: (String) -> Void = { print($0) }
    /// Marcadores del mundo activos (pruebas que se pueden empezar en la zona libre).
    private(set) var worldEvents: [RaceEvent] = []
    private var promptEvent: String?
    private var prevAccept = false
    private var rng = SplitMix(seed: 0x4D57_2005)

    private init(engine: Engine, db: RaceDatabase) {
        self.engine = engine; self.db = db
        world = RaceWorld(engine: engine, db: db)
    }

    /// Crea (una vez) el sistema y lo engancha al fotograma del motor. nil si faltan races.json o la red de carreteras.
    @discardableResult
    static func attach(_ engine: Engine) -> RaceSystem? {
        if let s = shared, s.engine === engine { return s }
        guard let db = RaceDatabase.load(engine.data) else { return nil }
        let s = RaceSystem(engine: engine, db: db)
        shared = s
        engine.frameHooks.append { [weak s] dt in s?.update(dt: dt) }
        print("Carreras: \(db.events.count) pruebas · \(db.bins.count) bins · \(db.milestones.count) hitos · \(db.barrierGroups.count) grupos de vallas")
        return s
    }

    // MARK: Pruebas

    @discardableResult
    func start(_ event: RaceEvent, context: RaceContext, opponents: Int? = nil, onEnd: ((RaceOutcome) -> Void)? = nil) -> RaceSession? {
        if let s = session { s.abandon() }
        hud?.dismissScreens()
        guard let s = RaceSession(system: self, event: event, context: context, opponents: opponents) else { return nil }
        s.log = log
        s.onEnd = { [weak self] o in
            self?.session = nil
            self?.engine.extraCars = []
            onEnd?(o)
            if o.context == .career { Career.shared.record(o) }
        }
        session = s
        s.begin()
        return s
    }

    func abandon() { session?.abandon() }

    private func update(dt: Float) {
        if let s = session { s.update(dt: dt); return }
        guard engine.mode == .drive, let car = engine.car else { return }
        Career.shared.updateFreeRoam(dt: dt)
        // Marcadores del mundo: entrar en el círculo y pulsar Intro / ✕ [D: engagetrigger Radius, FireOnExit]
        let accept = engine.keys.contains(36) || engine.keys.contains(76) || Controllers.shared.pads.contains { $0.controller.extendedGamepad?.buttonA.isPressed == true }
        defer { prevAccept = accept }
        let near = worldEvents.first { e in
            guard let g = e.engage else { return false }
            return simd_distance(float2(g.p.x, g.p.y), float2(car.position.x, car.position.y)) < g.radius && abs(g.p.z - car.position.z) < 15
        }
        if near?.id != promptEvent {
            promptEvent = near?.id
            if let e = near { hud?.showMessage(.custom("\(e.eventId) · \(RaceSystem.kindName(e.kind)) — Intro / ✕")) }
        }
        if let e = near, accept && !prevAccept, ui_allowsStart {
            start(e, context: .career)
        }
    }

    private var ui_allowsStart: Bool { engine.ui?.capturesInput != true }

    /// Pruebas que se pueden empezar en el mundo: las del bin actual de la carrera profesional (y las ya ganadas).
    func setWorldEvents(_ events: [RaceEvent]) { worldEvents = events.filter { $0.engage != nil } }

    // MARK: Rivales

    /// Coche de un rival: PresetRide (Lista Negra, coches de la historia) o CarType; sin coche fijado, uno de la categoría
    /// del bin con pintura al azar [I: el juego elige coche y nombre al azar para los corredores genéricos].
    func opponentCar(_ o: RaceOpponent, index: Int, event: RaceEvent) -> Car? {
        let data = engine.data
        if let p = o.preset, let preset = CarPresets.named(p, in: data),
           let car = Car(device: engine.device, data: data, textures: engine.textures, name: preset.car, paint: float3(0.7, 0.7, 0.7), preset: preset), car.vehicle != nil || car.specs != nil {
            return car
        }
        if let t = o.carType?.uppercased(), FileManager.default.fileExists(atPath: data.url("cars/\(t).glb").path),
           Car.physicsFile(data)?.specs(model: t) != nil,
           let car = Car(device: engine.device, data: data, textures: engine.textures, name: t, paint: randomPaint()) { return car }
        let bin = event.binIndex ?? 15
        let pool = bin >= 13 ? RaceSystem.tier3 : (bin >= 8 ? RaceSystem.tier2 : RaceSystem.tier1)
        for k in 0..<pool.count {
            let name = pool[(Int(rng.next() % UInt64(pool.count)) + k) % pool.count]
            if Car.physicsFile(data)?.specs(model: name) != nil,
               let car = Car(device: engine.device, data: data, textures: engine.textures, name: name, paint: randomPaint()) { return car }
        }
        return nil
    }

    static let tier3 = ["GTI", "RX8", "IS300", "CLIO", "PUNTO", "COBALTSS", "ECLIPSEGT", "MONARO", "A3", "TT"]
    static let tier2 = ["SUPRA", "IMPREZAWRX", "LANCEREVO8", "MUSTANGGT", "RX7", "CAYMANS", "GTO", "911TURBO", "CORVETTE", "CLK500", "SL500", "ELISE", "A4", "CTS"]
    static let tier1 = ["GALLARDO", "MURCIELAGO", "CARRERAGT", "SLR", "DB9", "VIPER", "FORDGT", "CORVETTEC6R", "911GT2", "SL65", "BMWM3GTR", "997S"]

    private func randomPaint() -> float3 {
        let pal: [UInt32] = [0xb01818, 0x1f4fa8, 0xe8e8e8, 0x151515, 0xd9a400, 0x2f7d32, 0xff6a00, 0x6c6c78, 0x5a1f8a, 0x0f8fa0]
        let c = pal[Int(rng.next() % UInt64(pal.count))]
        return float3(Float((c >> 16) & 255), Float((c >> 8) & 255), Float(c & 255)) / 255
    }

    /// fBaseSkill (AIPerpVehicle::ComputeSkill) [D]: carrera = SkillLevel/100 del personaje; rápida = tabla por dificultad.
    func baseSkill(for o: RaceOpponent, event: RaceEvent, context: RaceContext) -> Float {
        switch context {
        case .quickRace:
            let t = event.catchUp.enabled ? RaceAITables.quickRaceSkills : RaceAITables.quickRaceSkillsNoGlue
            return t[max(0, min(2, quickRaceDifficulty))]
        case .career, .test:
            return max(0, min(1, (o.skill ?? 100) * 0.01))
        }
    }

    static func prettyName(_ collection: String) -> String {
        let last = collection.split(separator: "/").last.map(String.init) ?? collection
        if last.hasPrefix("opponent") || last.hasPrefix("character") {
            let n = last.filter(\.isNumber)
            return "RIVAL \(n.isEmpty ? "1" : n)"
        }
        return last.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func kindName(_ k: RaceEvent.Kind) -> String {
        switch k {
        case .sprint: "Sprint"; case .circuit: "Circuito"; case .knockout: "Eliminación"; case .drag: "Drag"
        case .speedtrap: "Radar"; case .tollbooth: "Peaje"; case .challenge: "Desafío"
        }
    }
}

/// Carrera rápida: cualquier prueba con AvailableQR (o todas en desarrollo).
final class QuickRace {
    static let shared = QuickRace()
    var events: [RaceEvent] { RaceSystem.shared?.db.events.filter { $0.availableQuickRace && $0.kind != .challenge } ?? [] }
    @discardableResult
    func start(eventID: String, engine: Engine? = nil) -> Bool {
        let sys = engine.flatMap { RaceSystem.attach($0) } ?? RaceSystem.shared
        guard let sys, let e = sys.db.event(eventID) else { fputs("Carrera rápida: no existe la prueba \(eventID)\n", stderr); return false }
        return sys.start(e, context: .quickRace) != nil
    }
}

extension Engine {
    /// Activa las carreras (races.json). La app lo llama al arrancar; las pruebas, con --race-test / --career-test.
    @discardableResult
    func enableRaces() -> RaceSystem? {
        let s = RaceSystem.attach(self)
        if s != nil { Career.shared.attach(self) }
        return s
    }
}
