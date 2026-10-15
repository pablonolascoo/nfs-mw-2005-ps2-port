// API del HUD de carrera para el sistema de carreras y la carrera profesional (Race/, Career/).
// La implementación (FEHud + FEUI) dibuja SOLO paquetes y textos originales del juego: HUD_SingleRace / HUD_Drag (cuenta
// atrás 321_GO, posición, vuelta, tiempo, tabla de corredores, radar de velocidad, peaje, hitos, mensajes), las pantallas de
// resultados y las de la Lista Negra. El sistema de carreras no dibuja nada: solo llama a estos métodos.
//
// Uso desde Race/ o Career/:
//     guard let hud = engine.raceHUD else { return }      // nil si faltan los datos de frontend/ (sin interfaz)
//     hud.beginRace(RaceHUDSetup(kind: .circuit, laps: 3, racers: names))
//     hud.showCountdown(3) … hud.showCountdown(0)          // 0 = «¡YA!»
//     hud.setPosition(2, of: 4); hud.setLap(1, of: 3); hud.setTimer(raceTime: 41.2, lapTime: 41.2, bestLap: nil)
//     hud.showResults(RaceResults(...), onContinue: { … })
//     hud.endRace()
// Todo es en el hilo principal (el del fotograma). Las cadenas de texto que se pasan (nombres de corredores, de la carrera)
// se dibujan con la fuente del juego tal cual; lo demás sale de la tabla de textos del idioma del disco.
import Foundation
import simd

/// Tipo de prueba (GRaceParameters / GRace::Type de la decomp).
enum RaceKind: String, Codable, CaseIterable {
    case circuit        // vueltas
    case sprint         // punto a punto
    case drag           // aceleración: HUD_Drag (cuentarrevoluciones grande, luces de cambio)
    case knockout       // vueltas con eliminación del último
    case speedtrap      // radares de velocidad: suma de km/h
    case tollbooth      // contrarreloj por peajes
    case pursuit        // hitos de persecución (desafío / Lista Negra)
}

/// Un corredor en la tabla de posiciones (LeaderBoard).
struct RaceHUDRacer: Equatable {
    var name: String
    var isPlayer: Bool = false
    var knockedOut: Bool = false
    /// Distancia al jugador en metros (+ delante). Solo se usa para ordenar si `position` es 0.
    var gap: Float = 0
    var position: Int = 0
    /// Radares: suma de velocidades (m/s) de este corredor (la tabla la enseña en km/h o mph).
    var speedTrapMps: Float = 0
}

/// Datos para montar el HUD al empezar la prueba.
struct RaceHUDSetup {
    var kind: RaceKind
    var laps: Int = 1
    var racers: [RaceHUDRacer] = []
    /// Nombre de la prueba (p. ej. «Rosewood: Hollins Ave»): se ve en los resultados.
    var eventName: String = ""
    /// Hash del texto del juego para el nombre (preferido a `eventName` si no es 0).
    var eventNameHash: UInt32 = 0
    /// Si la prueba lleva minimapa con la ruta (las carreras sí; la zona libre usa el radar del HUD libre).
    var showMinimap: Bool = true
    /// Peaje / contrarreloj: tiempo inicial en segundos.
    var timeLimit: Double? = nil
    /// Nº de radares (speedtrap) o de peajes (tollbooth).
    var checkpointCount: Int = 0
    /// Id del evento en gameplay.json (p. ej. «1.2.1»): el radar usa su mapa con la ruta pintada, MINI_MAP_1_2_1
    /// (ChooseMinimapTextureName + FixDot [D]). Vacío = el mapa de la zona libre.
    var eventID: String = ""
    var minimap: String? { eventID.isEmpty ? nil : "MINI_MAP_" + eventID.replacingOccurrences(of: ".", with: "_").uppercased() }
}

/// Fila de la pantalla de resultados.
struct RaceResultRow: Equatable {
    var position: Int
    var name: String
    var isPlayer: Bool = false
    /// Tiempo total (s); nil = no terminó (DNF / eliminado).
    var totalTime: Double?
    var bestLap: Double? = nil
    /// Radar de velocidad: suma (km/h o mph según idioma, ya convertido por el HUD si `speedTrapMps` viene en m/s).
    var speedTrapMps: Float? = nil
}

struct RaceResults {
    var kind: RaceKind
    var eventName: String = ""
    var eventNameHash: UInt32 = 0
    var playerWon: Bool
    var rows: [RaceResultRow]
    /// Recompensa en dinero y reputación (puntos de bounty), si la hay.
    var cash: Int = 0
    var bounty: Int = 0
}

/// Ficha de un rival de la Lista Negra (BlackList «Rap Sheet»).
struct BlacklistRival {
    var rank: Int                 // 1…15
    var name: String              // «Razor», «Bull»…
    var carName: String = ""
    /// Requisitos para retarle (hitos y recompensa) — `done` / `required`.
    var racesWon: Int = 0, racesRequired: Int = 0
    var milestonesDone: Int = 0, milestonesRequired: Int = 0
    var bounty: Int = 0, bountyRequired: Int = 0
    var defeated: Bool = false
    var unlocked: Bool = false    // ¿se puede retar ya?
}

/// Botón pulsado en una pantalla de la Lista Negra o de resultados.
enum RaceHUDChoice { case accept, back }

/// Mensaje de hito o aviso en el centro del HUD (GenericMessage / MilestoneBoard).
enum RaceHUDMessage {
    case checkpoint                              // «Punto de control»
    case finalLap                                // «Última vuelta»
    case knockedOut(name: String)                // eliminado
    case speedtrap(mps: Float)                   // lectura del radar al pasar
    case tollbooth(timeAdded: Double)            // tiempo extra
    case wrongWay(Bool)                          // aviso de sentido contrario (on/off; aparece a los 2 s como en el juego)
    case text(hash: UInt32)                      // cualquier texto del juego por su hash
    case custom(String)                          // último recurso (mods)
}

/// Lo que el sistema de carreras puede pedir al HUD. Implementado por `FEUI` con los paquetes originales.
protocol RaceHUD: AnyObject {
    /// Monta el HUD de la prueba (HUD_SingleRace o HUD_Drag) y oculta los elementos de zona libre que el juego oculta.
    func beginRace(_ setup: RaceHUDSetup)
    /// Vuelve al HUD de zona libre.
    func endRace()
    /// Cuenta atrás: 3, 2, 1 y 0 = «¡YA!» (321_GO_GROUP). Valores < 0 la ocultan.
    func showCountdown(_ value: Int)
    func setPosition(_ position: Int, of total: Int)
    func setLap(_ lap: Int, of total: Int)
    /// Tiempo de carrera, vuelta actual y mejor vuelta (s). En peaje, `raceTime` es el tiempo que QUEDA.
    func setTimer(raceTime: Double, lapTime: Double?, bestLap: Double?)
    /// Sprint, radares y peajes: % recorrido (0…100), que el HUD enseña en lugar de la vuelta (RaceInformation [D]).
    func setProgress(_ percent: Float)
    /// Tabla de corredores (LeaderBoard). Se ordena por `position`.
    func setRacers(_ racers: [RaceHUDRacer])
    /// Próximo punto de control en el mundo (coordenadas del motor) para el minimapa y la flecha; nil = sin objetivo.
    func setNextCheckpoint(_ world: SIMD3<Float>?)
    /// Ruta de la carrera para dibujar en el minimapa (puntos del mundo en orden).
    func setRoute(_ points: [SIMD3<Float>])
    /// Posición de los rivales para los iconos del minimapa (MMICON_AIRACER_n).
    func setRacerBlips(_ positions: [SIMD3<Float>])
    /// Radar de velocidad: suma acumulada y nº de radares pasados.
    func setSpeedtrap(totalMps: Float, passed: Int, of total: Int)
    /// Drag: luz de cambio perfecta (0 = nada, 1 = buena, 2 = perfecta) y temperatura del motor 0…1.
    func setDrag(shiftQuality: Int, engineTemp: Float)
    func showMessage(_ message: RaceHUDMessage)
    /// Pantalla de resultados del juego; `onContinue` se llama al pulsar ✕ / Intro.
    func showResults(_ results: RaceResults, onContinue: @escaping () -> Void)
    /// Menú de la Lista Negra con los 15 rivales; `onChoice` recibe el rival elegido (rank) o nil si se vuelve atrás.
    func showBlacklist(_ rivals: [BlacklistRival], selected: Int, onChoice: @escaping (Int?) -> Void)
    /// «Coche ganado» (pink slips) tras vencer a un rival de la Lista Negra.
    /// (La firma del rival se busca por su nombre en la tabla de textos BLACKLIST_RIVAL_nn_AKA.)
    func showCarWon(carName: String, rivalName: String, onContinue: @escaping () -> Void)
    /// Cierra resultados / Lista Negra / coche ganado si están abiertos.
    func dismissScreens()
}

extension Engine {
    /// HUD de carrera original; nil si no hay interfaz (faltan los datos de frontend/ o `--no-ui`).
    var raceHUD: RaceHUD? { ui }
}
