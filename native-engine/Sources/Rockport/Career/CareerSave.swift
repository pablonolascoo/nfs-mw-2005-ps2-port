// Partida guardada de la carrera profesional: ~/Library/Application Support/Rockport/save.json.
// Lo que el juego guarda en la tarjeta de memoria (GRaceBin::Serialize, GRaceSaveInfo, UserProfile) reducido a lo que
// usa este motor: bin actual, pruebas ganadas, hitos, recompensa (bounty), dinero, coches y mejores tiempos [I: formato propio].
import Foundation

struct CareerSave: Codable {
    var version = 1
    /// Bin actual de la Lista Negra (15 = Sonny/«Tony Ho» … 1 = Razor). 0 = Lista Negra completada.
    var currentBin = 15
    var cash = 30000
    /// Recompensa acumulada (bounty): sube con las persecuciones evadidas y los hitos.
    var bounty = 0
    /// Pruebas ganadas en la carrera (nombre de colección).
    var racesWon: [String] = []
    /// Hitos (milestones/bin_NN/…) cumplidos.
    var milestonesDone: [String] = []
    /// Rivales de la Lista Negra vencidos (número de bin).
    var rivalsDefeated: [Int] = []
    /// Carreras del rival ya ganadas en el bin actual (BossRaces en orden).
    var bossRacesWon: [String] = []
    /// Coches del jugador: presets del juego (presets.json) o modelos de serie.
    var cars: [String] = ["M3GTRCAREERSTART"]
    var currentCar = "M3GTRCAREERSTART"
    /// Mejor tiempo por prueba (s).
    var bestTimes: [String: Double] = [:]
    /// Desafíos de la Serie completados.
    var challengesDone: [String] = []
    /// Películas de la historia y tutoriales ya vistos (Movies/Movies.swift). Opcional: las partidas antiguas no lo traen.
    var moviesSeen: [String]?
    var lastSaved: String = ""

    static var defaultURL: URL { DataLocator.appSupport.appendingPathComponent("save.json") }

    static func load(_ url: URL = defaultURL) -> CareerSave? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CareerSave.self, from: d)
    }

    mutating func save(_ url: URL = defaultURL) {
        lastSaved = ISO8601DateFormatter().string(from: Date())
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(self).write(to: url, options: .atomic)
        } catch { fputs("Partida: no se pudo guardar \(url.path): \(error)\n", stderr) }
    }
}
