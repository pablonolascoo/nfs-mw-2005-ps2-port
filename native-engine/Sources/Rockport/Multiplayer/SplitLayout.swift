// Reparto de la pantalla (o de varias pantallas) entre jugadores.
//
// El original [V: HUD_Player1.fng / HUD_Player2.fng de GLOBAL\INGAMESPLITSCREEN.BUN]: dos jugadores, pantalla partida en
// HORIZONTAL (jugador 1 arriba, jugador 2 abajo). Cada HUD ocupa su mitad del lienzo de 640×480 (el del jugador 1 entre
// y = −240 y 0 con una raya de 1200×4 en y = 0 que separa las vistas; el del jugador 2 entre 0 y 240) y los dos se dibujan a
// pantalla completa. El radar solo existe en el del jugador 1, sobre la raya, con el coche del jugador 2 como segundo icono.
//
// Extensión del port: 3 y 4 jugadores en cuartos (2×2). Con 3, el cuarto libre enseña una vista aérea de la carrera.
// Los cuartos de arriba usan HUD_Player1 y los de abajo HUD_Player2 (cada uno con su media ventana del lienzo), sin radar.
//
// Varias pantallas: los jugadores se reparten por pantallas (4 en 2 = 2 + 2; 3 en 2 = 2 + 1) y cada pantalla se parte
// con la regla de arriba según cuántos le toquen. Una pantalla con un solo jugador lleva el HUD normal (HUD_SingleRace).
import Foundation
import simd

struct SplitSlot {
    /// Vista en su pantalla (fracción 0…1, origen arriba a la izquierda).
    var rect: RenderRect
    /// Paquete del HUD: .standard (pantalla para él solo), .split1 (arriba) o .split2 (abajo).
    var hud: FEHud.Kind
    /// Marco del HUD en la pantalla (fracción) y ventana del lienzo FEng que se encaja en él (x0, y0, x1, y1).
    var hudRect: RenderRect
    var canvas: SIMD4<Float>
    /// Recortar el HUD a su marco (cuartos) o no (dos jugadores: los dos HUD se dibujan a pantalla completa).
    var clip: Bool
    /// ¿Lleva radar? (solo el jugador 1 de dos, como el juego; en cuartos no hay sitio).
    var minimap: Bool
}

enum SplitLayout {
    static let fullCanvas = SIMD4<Float>(-320, -240, 320, 240)

    /// Huecos de una pantalla con `n` jugadores (1…4). Con 3 se devuelven 3 (el cuarto libre es `overviewRect`).
    static func slots(_ n: Int) -> [SplitSlot] {
        switch n {
        case ..<2:
            return [SplitSlot(rect: .full, hud: .standard, hudRect: .full, canvas: fullCanvas, clip: false, minimap: true)]
        case 2:
            // Original: horizontal, jugador 1 arriba [V]
            return [SplitSlot(rect: RenderRect(x: 0, y: 0, w: 1, h: 0.5), hud: .split1, hudRect: .full, canvas: fullCanvas, clip: false, minimap: true),
                    SplitSlot(rect: RenderRect(x: 0, y: 0.5, w: 1, h: 0.5), hud: .split2, hudRect: .full, canvas: fullCanvas, clip: false, minimap: false)]
        default:
            let quads = [RenderRect(x: 0, y: 0, w: 0.5, h: 0.5), RenderRect(x: 0.5, y: 0, w: 0.5, h: 0.5),
                         RenderRect(x: 0, y: 0.5, w: 0.5, h: 0.5), RenderRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5)]
            let top = SIMD4<Float>(-320, -240, 320, 0), bottom = SIMD4<Float>(-320, 0, 320, 240)
            return (0..<min(4, n)).map { i in
                let up = i < 2
                return SplitSlot(rect: quads[i], hud: up ? .split1 : .split2, hudRect: quads[i], canvas: up ? top : bottom, clip: true, minimap: false)
            }
        }
    }

    /// Cuarto libre con 3 jugadores en una pantalla (vista aérea).
    static let overviewRect = RenderRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5)

    /// Cuántos jugadores van a cada pantalla: lo más parejo posible, las primeras con uno más.
    static func distribute(players n: Int, displays d: Int) -> [Int] {
        let d = max(1, min(d, n))
        return (0..<d).map { n / d + ($0 < n % d ? 1 : 0) }
    }
}
