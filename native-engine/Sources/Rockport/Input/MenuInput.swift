// Entrada de menús (interfaz FEng): cruceta / stick, aceptar, atrás y Start, con flancos propios (no roban los de conducción).
// Como el juego [D: FEJoyInput / FEngine]: ✕ (A en Xbox) acepta, △/○ (B) vuelve atrás, Start pausa o confirma.
// Teclado: flechas, Intro/Espacio aceptar, Esc/Retroceso atrás, Esc/P pausa en el juego.
import Foundation
import GameController
import IOKit.hid

struct MenuButtons {
    var up = false, down = false, left = false, right = false, accept = false, back = false, start = false
    var any: Bool { up || down || left || right || accept || back || start }
    mutating func merge(_ o: MenuButtons) {
        up = up || o.up; down = down || o.down; left = left || o.left; right = right || o.right
        accept = accept || o.accept; back = back || o.back; start = start || o.start
    }
}

/// Pantalla partida (Multiplayer/): qué mandos pueden mover los menús del juego (FEUI). nil = todos (lo de siempre).
/// Los menús de carrera rápida los lleva el jugador 1; en la carrera, cualquiera de los jugadores puede pausar (como el
/// juego, que lee los dos puertos en pantalla partida [D: cFEngJoyInput::HandleJoy]).
enum MenuOwners { static var allowed: Set<ObjectIdentifier>? }

extension Controllers {
    /// Pulsaciones nuevas de menú en todos los mandos (GameController + HID).
    func pollMenu() -> MenuButtons {
        start()
        var out = MenuButtons()
        for p in pads {
            if let a = MenuOwners.allowed, !a.contains(ObjectIdentifier(p)) { continue }
            out.merge(menuButtons(p, prefix: "menu."))
        }
        out.merge(hid.pollMenu())
        return out
    }

    /// Menú de un solo mando con flancos propios (`prefix` separa a quien lee: la interfaz o la pantalla de unirse).
    func menuButtons(_ p: Pad, prefix: String) -> MenuButtons {
        var out = MenuButtons()
        do {
            guard let g = p.controller.extendedGamepad else { return out }
            func edge(_ k: String, _ v: Bool) -> Bool { let key = prefix + k; let was = p.prev[key] ?? false; p.prev[key] = v; return v && !was }
            let sx = g.leftThumbstick.xAxis.value, sy = g.leftThumbstick.yAxis.value
            out.up = out.up || edge("up", g.dpad.up.isPressed || sy > 0.6)
            out.down = out.down || edge("down", g.dpad.down.isPressed || sy < -0.6)
            out.left = out.left || edge("left", g.dpad.left.isPressed || sx < -0.6)
            out.right = out.right || edge("right", g.dpad.right.isPressed || sx > 0.6)
            out.accept = out.accept || edge("accept", g.buttonA.isPressed)
            out.back = out.back || edge("back", g.buttonB.isPressed || g.buttonY.isPressed)
            out.start = out.start || edge("start", g.buttonMenu.isPressed)
        }
        return out
    }
}

extension HIDPads {
    func pollMenu() -> MenuButtons {
        var out = MenuButtons()
        for p in pads {
            if let a = MenuOwners.allowed, !a.contains(ObjectIdentifier(p)) { continue }
            out.merge(menuButtons(p, prefix: "menu."))
        }
        return out
    }

    /// Menú de un solo mando HID con flancos propios.
    func menuButtons(_ p: Pad, prefix: String) -> MenuButtons {
        var out = MenuButtons()
        do {
            func edge(_ k: String, _ v: Bool) -> Bool { let key = prefix + k; let was = p.prev[key] ?? false; p.prev[key] = v; return v && !was }
            if p.kind == .ds3 {
                let r = p.report
                guard r[0] == 0x01 else { return out }
                let b1 = r[2], b2 = r[3]
                out.up = out.up || edge("up", b1 & 0x10 != 0); out.down = out.down || edge("down", b1 & 0x40 != 0)
                out.left = out.left || edge("left", b1 & 0x80 != 0); out.right = out.right || edge("right", b1 & 0x20 != 0)
                out.accept = out.accept || edge("accept", b2 & 0x40 != 0)
                out.back = out.back || edge("back", b2 & 0x10 != 0 || b2 & 0x20 != 0)
                out.start = out.start || edge("start", b1 & 0x08 != 0)
            } else {
                let ps2 = p.kind == .ps2
                func btn(_ n: Int) -> Bool { p.buttons[n] ?? false }
                let (tri, cir, cro) = ps2 ? (1, 2, 3) : (4, 2, 1)
                let x = p.axes[kHIDUsage_GD_X] ?? 0, y = p.axes[kHIDUsage_GD_Y] ?? 0
                out.up = out.up || edge("up", p.hat == 0 || y < -0.6); out.down = out.down || edge("down", p.hat == 4 || y > 0.6)
                out.left = out.left || edge("left", p.hat == 6 || x < -0.6); out.right = out.right || edge("right", p.hat == 2 || x > 0.6)
                out.accept = out.accept || edge("accept", btn(cro))
                out.back = out.back || edge("back", btn(tri) || btn(cir))
                out.start = out.start || edge("start", btn(10))
            }
        }
        return out
    }
}

/// Teclado → botones de menú (flancos).
final class MenuKeyboard {
    private var prev = Set<UInt16>()
    func poll(keys: Set<UInt16>) -> MenuButtons {
        func e(_ codes: UInt16...) -> Bool { codes.contains { keys.contains($0) && !prev.contains($0) } }
        var m = MenuButtons()
        m.up = e(126); m.down = e(125); m.left = e(123); m.right = e(124)
        m.accept = e(36, 76, 49)          // Intro, Intro del teclado numérico, Espacio
        m.back = e(51, 53)                // Retroceso, Esc
        m.start = e(53, 35)               // Esc, P
        prev = keys
        return m
    }
}
