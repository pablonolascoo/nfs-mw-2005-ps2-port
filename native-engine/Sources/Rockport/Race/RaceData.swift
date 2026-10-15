// Datos de las carreras y de la Lista Negra: map-data/<ID>/races.json (tools/src/cli/races.ts).
// Todo viene de GAMEPLAY.BIN (colecciones de la clase gameplay con su herencia resuelta) y de las vallas de TrackPath de
// L2RA.BUN. Formato y reglas: docs/es/18-carreras-y-lista-negra.md.
import Foundation
import simd

/// Marcador del juego: posición y rumbo (grados desde +X hacia +Y, como el yaw del motor) [V].
struct RaceMarker: Decodable {
    let name: String?
    let pos: [Float]
    let yaw: Float
    /// Caja del disparador: [fondo, ancho, alto] (m). La caja se orienta con `yaw` [I: fondo 2–3 m a lo largo de la marcha].
    let dims: [Float]?
    let timeBonus: Float?
    let radius: Float?
    let width: Float?

    var p: float3 { float3(pos[0], pos[1], pos.count > 2 ? pos[2] : 0) }
    var heading: Float { yaw * .pi / 180 }
    var dir: float3 { float3(cos(heading), sin(heading), 0) }
    /// Mitad del ancho de la puerta (m). Por defecto 20 m (checkpoint: Dimensions 40×40×40 [V]).
    var halfWidth: Float { (dims.map { $0.count > 1 ? $0[1] : 40 } ?? 40) * 0.5 }
    var halfHeight: Float { (dims.map { $0.count > 2 ? $0[2] : 40 } ?? 40) * 0.5 }
}

struct RaceOpponent: Decodable {
    let name: String
    let racerName: String?
    let preset: String?
    let carType: String?
    /// SkillLevel del personaje (0…100) [V]. Escala la habilidad de AIActionRace [D].
    let skill: Float?
    let minPerformance: Float?
    let boss: Bool?
}

struct RaceBarrierRef: Decodable {
    let group: String
    /// «*» delante del nombre en la lista Barriers: GRaceParameters::GetBarrierIsFlipped [D]. Invierte el arte (flechas).
    let flipped: Bool
}

struct RaceSpeedtrap: Decodable { let name: String; let pos: [Float]; let radius: Float; let threshold: Float; let bounty: Float
    var p: float3 { float3(pos[0], pos[1], pos[2]) } }
struct RaceShortcut: Decodable { let pos: [Float]; let min: Float; let max: Float }
struct RaceEngage: Decodable { let name: String; let pos: [Float]; let radius: Float
    var p: float3 { float3(pos[0], pos[1], pos[2]) } }

struct RaceCatchUp: Decodable {
    let enabled: Bool
    let override: Bool
    /// CatchUpSkill / CatchUpSpread: texto con hasta 11 valores (ParseCatchUpData) [D: GRaceStatus.h aCatchUpSkillData[11]].
    let skill: [Float]
    let spread: [Float]
    let integral: Float
    let derivative: Float
}

struct RaceChallenge: Decodable {
    let milestone: String?
    let threshold: Float
    let biggerIsBetter: Bool
    let epic: Bool
}

struct RaceTargets: Decodable { let gold: Float; let silver: Float; let bronze: Float }

/// Una prueba (GRaceParameters [D]).
struct RaceEvent: Decodable {
    enum Kind: String, Decodable { case sprint, circuit, knockout, drag, speedtrap, tollbooth, challenge }
    let id: String
    let eventId: String
    let kind: Kind
    let template: String?
    let bin: String
    let binIndex: Int?
    let bossRace: Bool
    let region: String?
    let laps: Int
    let length: Float
    let cash: Float
    let reputation: Float
    let looping: Bool
    let knockoutsPerLap: Int
    let timeLimit: Float
    let copsInRace: Bool
    let scriptedCops: Bool
    let pursuitRace: Bool
    let trafficLevel: Float
    let maxHeat: Float
    let forceHeat: Float
    let useWorldHeat: Bool
    let doCountdown: Bool
    let rollingStart: Bool
    let initialSpeed: Float
    let playerCar: String?
    let rankByPoints: Bool
    let rivalBestTime: Float
    let targets: RaceTargets
    let catchUp: RaceCatchUp
    let availableQuickRace: Bool
    let initiallyUnlocked: Bool
    let challengeSeries: Bool
    let unlockRaces: [String]
    let checkpointsVisible: Bool
    let start: RaceMarker?
    let finish: RaceMarker?
    let checkpoints: [RaceMarker]
    let speedtraps: [RaceSpeedtrap]
    let shortcuts: [RaceShortcut]
    let resets: [RaceMarker]
    let copSpawns: [RaceMarker]
    let opponents: [RaceOpponent]
    let barriers: [RaceBarrierRef]
    let engage: RaceEngage?
    let challenge: RaceChallenge?

    var isLapRace: Bool { kind == .circuit || kind == .knockout }
    /// Nombre corto para registros y resultados: «15.1.1 circuit».
    var label: String { "\(eventId) \(kind.rawValue)" }
}

struct RaceBinReward: Decodable { let id: String; let type: String?; let cash: Float; let carType: String? }
struct RaceBinHeat: Decodable { let base: Float; let max: Float; let scale: Float }

/// Un rival de la Lista Negra (GRaceBin [D]).
struct RaceBin: Decodable {
    let id: String
    let binIndex: Int
    let boss: String?
    let bossPreset: String?
    let bossSkill: Float?
    let bossRacerName: String?
    let worldRaces: [String]
    let bossRaces: [String]
    let requiredBounty: Int
    let requiredRacesWon: Int
    let requiredChallenges: Int
    let barriers: [RaceBarrierRef]
    let heat: RaceBinHeat
    let debugSpawn: RaceMarker?
    let rewards: [RaceBinReward]
    let milestones: [String]

    /// «race_bin_15/tony_ho» → «Tony Ho»; Razor y Bull tienen nombres de un solo término.
    var bossName: String {
        guard let b = boss?.split(separator: "/").last else { return "Rival \(binIndex)" }
        return b.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

struct RaceMilestone: Decodable {
    let id: String
    let binIndex: Int
    /// MilestoneName: pursuit_length, pursuit_evasion_time, cops_damaged, bounty_in_pursuit, cost_to_state_in_pursuit,
    /// roadblocks_dodged, tire_spikes_dodged, total_infractions [V]; «speedtrap» = radar de la zona libre del bin [V].
    let type: String
    let goalEasy: Float
    let goalHard: Float
    let bounty: Float
    /// Radar de la zona libre (type == "speedtrap"): posición y radio; el objetivo es ThreshholdSpeed (km/h [I]).
    let pos: [Float]?
    let radius: Float?
}

struct RaceBarrierGroup: Decodable {
    let hash: String
    /// GroupNumber del grupo de escenario: su colisión está en collision/groups/<número>.bin (tools/src/cli/collision.ts).
    let number: Int?
    let glb: String?
    let driveThrough: Bool
    let min: [Float]?
    let max: [Float]?
    /// Líneas TrackPathBarrier del grupo: [ax, ay, bx, by] [V].
    let lines: [[Float]]
}

final class RaceDatabase {
    let events: [RaceEvent]
    let bins: [RaceBin]
    let milestones: [RaceMilestone]
    let barrierGroups: [String: RaceBarrierGroup]
    private let byId: [String: Int]

    private struct File: Decodable {
        let events: [RaceEvent]; let bins: [RaceBin]; let milestones: [RaceMilestone]; let barrierGroups: [String: RaceBarrierGroup]
    }

    init(url: URL) throws {
        let f = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        events = f.events; bins = f.bins; milestones = f.milestones; barrierGroups = f.barrierGroups
        var m: [String: Int] = [:]
        for (i, e) in events.enumerated() { m[e.id] = i; if m[e.eventId] == nil { m[e.eventId] = i } }
        byId = m
    }

    static func load(_ data: GameData) -> RaceDatabase? {
        let u = data.url("races.json")
        guard FileManager.default.fileExists(atPath: u.path) else {
            fputs("Carreras: falta races.json en \(data.root.path) (bun src/cli/races.ts <iso> <ID>)\n", stderr); return nil
        }
        do { return try RaceDatabase(url: u) } catch { fputs("Carreras: races.json ilegible: \(error)\n", stderr); return nil }
    }

    /// Por nombre de colección («race_bin_15/15_1_1_circuit») o por EventID («15.1.1»).
    func event(_ key: String) -> RaceEvent? { byId[key].map { events[$0] } }
    func bin(_ index: Int) -> RaceBin? { bins.first { $0.binIndex == index } }
    func milestone(_ id: String) -> RaceMilestone? { milestones.first { $0.id == id } }
}
