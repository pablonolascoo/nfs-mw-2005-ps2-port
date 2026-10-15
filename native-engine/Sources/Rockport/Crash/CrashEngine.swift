// Enganche de los choques en el motor: dibujo de los rompibles, mensajes de la HUD (derrumbe, policía destruido) y
// las opciones de línea de órdenes. La simulación la llama AIWorld.update (CrashWorld.step) y la lista de coches con
// física la rellena Engine.updateAI (AIEngine.swift).
//   --no-crash   sin choques del juego (vuelve el empujón cinemático de antes)
//   --no-heli    sin helicóptero
//   --crash-test [ESCENARIO|all]   pruebas sin ventana (Crash/CrashTests.swift)
//   --heli-test N                  persecución de calor 5 con helicóptero durante N s (Crash/CrashTests.swift)
import Foundation
import Metal

enum CrashOptions {
    static var args: [String] { CommandLine.arguments }
    static var crashTest: String? {
        guard let i = args.firstIndex(of: "--crash-test") else { return nil }
        return i + 1 < args.count && !args[i + 1].hasPrefix("-") ? args[i + 1] : "all"
    }
    static var heliTest: Double? {
        guard let i = args.firstIndex(of: "--heli-test") else { return nil }
        return i + 1 < args.count ? Double(args[i + 1]) ?? 60 : 60
    }
}

extension Engine {
    func setupCrash(_ w: AIWorld, outputFormat: MTLPixelFormat) {
        guard let crash = w.crash else { return }
        if crash.smackables.enabled {
            do {
                let r = try SmackableRenderer(device: device, data: data, textures: textures, field: crash.smackables, outputFormat: outputFormat)
                // Antes que la IA: los rompibles son escenario
                renderer.overlays.insert(r, at: 0)
                crash.renderer = r
            } catch { fputs("Choques: no se pudo crear el dibujo de los rompibles: \(error)\n", stderr) }
        }
        // Derrumbe: mensaje del juego LANGUAGE_HUD_PURSUIT_BREAKER_BONUS (0xDF4AC87C) [D: Generated/LanguageHashes.hpp]
        crash.breakers.onTrigger = { [weak self] b in
            guard let self, let hud = self.ui?.hud else { return }
            let text = self.ui?.assets.string(0xDF4AC87C) ?? "PURSUIT BREAKER"
            hud.requestMessage(text, priority: 4)
            _ = b
        }
    }
}
