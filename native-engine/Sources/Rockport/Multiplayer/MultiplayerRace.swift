// Arranque de una carrera rápida con 1…4 jugadores humanos (lo usan las pantallas de carrera rápida y las pruebas sin
// ventana). Con un jugador y una pantalla es la carrera rápida de siempre; con más, monta la pantalla partida.
import Foundation
import simd

/// Un jugador listo para correr: su dispositivo, su coche y su nombre en la tabla.
struct MPEntry {
    var device: PlayerDevice
    var car: Car
    var name: String
}

enum MultiplayerRace {
    /// Coche de la lista de la carrera rápida: preset del juego (Lista Negra, el de la historia) o modelo de serie.
    static func makeCar(engine: Engine, id: String, paint: SIMD3<Float> = Config.playerPaint) -> Car? {
        let data = engine.data
        if let p = CarPresets.named(id, in: data) {
            return Car(device: engine.device, data: data, textures: engine.textures, name: p.car, paint: paint, preset: p)
        }
        return Car(device: engine.device, data: data, textures: engine.textures, name: id, paint: paint)
    }

    /// Pintura de serie por jugador para los coches sin preset [I: el juego usa la pintura del registro del coche].
    static let stockPaints: [SIMD3<Float>] = [SIMD3(0.72, 0.74, 0.78), SIMD3(0.75, 0.08, 0.06), SIMD3(0.08, 0.28, 0.75), SIMD3(0.95, 0.75, 0.05)]

    private static var previousCar: Car?

    /// Empieza la prueba. `onEnd` se llama al cerrar la pantalla de resultados (o al abandonar).
    @discardableResult
    static func start(engine: Engine, event: RaceEvent, entries: [MPEntry], settings: QRSettings, displays: Int = 1,
                      autopilot: Bool = false, onEnd: ((RaceOutcome) -> Void)? = nil) -> RaceSession? {
        guard let sys = RaceSystem.attach(engine), let p1 = entries.first else { return nil }
        if previousCar == nil { previousCar = engine.car }
        engine.car = p1.car
        sys.quickRaceDifficulty = settings.skill
        var opts = QuickRaceOptions()
        if event.isLapRace && event.kind != .knockout { opts.laps = settings.laps }
        opts.traffic = QRSettings.trafficDensity[max(0, min(3, settings.traffic))]
        opts.police = settings.police
        opts.catchUp = settings.catchUp
        var split: SplitScreen?
        if entries.count > 1 || displays > 1 {
            let ss = SplitScreen(engine: engine, players: entries.map { ($0.device, $0.car, $0.name) }, displays: displays)
            for p in ss.players { p.autopilot = autopilot }
            ss.begin()
            opts.humans = ss.otherHumans
            split = ss
        }
        let oldName = sys.playerName
        if entries.count > 1 { sys.playerName = p1.name }
        // En pantalla partida el juego no pone rivales de la IA (SetNumOpponents(1) = el otro jugador [D]); aquí son opcionales
        let opponents = max(0, min(event.opponents.count, settings.opponents))
        engine.ui?.startGame()
        if engine.mode != .drive { engine.mode = .drive }
        let session = sys.start(event, context: .quickRace, opponents: opponents, options: opts) { o in
            split?.end()
            if let prev = previousCar { engine.car = prev; previousCar = nil }
            sys.playerName = oldName
            onEnd?(o)
        }
        if session == nil { split?.end(); if let prev = previousCar { engine.car = prev; previousCar = nil } }
        session?.autopilot = autopilot
        return session
    }
}
