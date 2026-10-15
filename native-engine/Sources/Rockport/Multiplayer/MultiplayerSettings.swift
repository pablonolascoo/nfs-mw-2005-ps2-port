// Ajustes de la pantalla partida: cuántas pantallas usar y cuántos jugadores con --race.
//
//   settings.json (~/Library/Application Support/Rockport/settings.json), clave «multiplayer»:
//     { "multiplayer": { "displays": "1" | "2" | "all", "maxPlayers": 4 } }
//   Opciones de arranque (mandan sobre el archivo, no se guardan):
//     --displays all|1|2     pantallas a usar en pantalla partida (todas las conectadas, una, dos)
//     --players N            con --race ID: empezar directamente en pantalla partida con N jugadores (2…4)
import Foundation
import AppKit

struct MultiplayerConfig: Codable {
    /// "1", "2"… o "all".
    var displays = "1"
    var maxPlayers = 4
}

final class MultiplayerSettings {
    static let shared = MultiplayerSettings()
    private(set) var config = MultiplayerConfig()

    private init() {
        if let any = SettingsFile.read(key: "multiplayer"), let d = try? JSONSerialization.data(withJSONObject: any),
           let c = try? JSONDecoder().decode(MultiplayerConfig.self, from: d) { config = c }
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--displays"), i + 1 < a.count { config.displays = a[i + 1].lowercased() }
    }

    /// Jugadores pedidos con --players (app, junto con --race).
    var launchPlayers: Int? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--players"), i + 1 < a.count, let n = Int(a[i + 1]) else { return nil }
        return max(1, min(4, n))
    }

    func setDisplays(_ v: String) { config.displays = v; SettingsFile.update(key: "multiplayer", value: config) }

    /// Pantallas conectadas ahora (sin ventana: 1).
    var connectedDisplays: Int { NSApp?.isRunning == true ? max(1, NSScreen.screens.count) : 1 }

    /// Pantallas a usar para `players` jugadores: lo pedido, sin pasar de las conectadas ni de los jugadores.
    func displaysFor(players: Int) -> Int {
        let want = config.displays == "all" ? connectedDisplays : (Int(config.displays) ?? 1)
        return max(1, min(want, connectedDisplays, players))
    }
}
