// Dispositivos de entrada como jugadores: cada mando físico (GameController o IOKit HID) y el teclado son un `PlayerDevice`
// que se lee por separado. Así la entrada de un mando nunca llega a otro jugador (en un jugador, Input/GameInput.swift mezcla
// todo a propósito: cualquier mando conduce el coche).
//
// Lo que el juego hace con los puertos [D: uiQRPressStart.cpp, FEJoyInput.cpp]: «Jugador N pulsa START» guarda el puerto de
// quien pulsa (SetPlayersJoystickPort) y no deja que el jugador 2 use el mismo que el 1; en la carrera cada jugador lee su
// puerto. Aquí el «puerto» es el propio mando.
import Foundation
import AppKit
import GameController
import simd

/// Tipo de mando para enseñarlo en la pantalla de unirse y elegir colores (barra de luz, LED de jugador).
enum PlayerDeviceKind: String {
    case keyboard = "Teclado", xbox = "Xbox", dualSense = "DualSense", dualShock4 = "DualShock 4", mfi = "MFi"
    case dualShock3 = "DualShock 3", ps2Adapter = "Adaptador PS2", genericHID = "Mando HID"
    var english: String {
        switch self {
        case .keyboard: "Keyboard"; case .xbox: "Xbox"; case .dualSense: "DualSense"; case .dualShock4: "DualShock 4"; case .mfi: "MFi"
        case .dualShock3: "DualShock 3"; case .ps2Adapter: "PS2 adapter"; case .genericHID: "HID pad"
        }
    }
    /// ¿Tiene barra de luz que se pueda pintar?
    var hasLightBar: Bool { self == .dualSense || self == .dualShock4 }
}

/// Un dispositivo físico que puede ser un jugador.
final class PlayerDevice {
    enum Source { case keyboard, gc(Controllers.Pad), hid(HIDPads.Pad) }
    let source: Source
    let kind: PlayerDeviceKind
    let name: String
    private var prevKeys = Set<UInt16>()
    private let menuKeyboard = MenuKeyboard()

    init(_ s: Source) {
        source = s
        switch s {
        case .keyboard: kind = .keyboard; name = "Teclado"
        case .gc(let p):
            let g = p.controller.extendedGamepad
            kind = g is GCDualSenseGamepad ? .dualSense : g is GCDualShockGamepad ? .dualShock4 : g is GCXboxGamepad ? .xbox : .mfi
            name = p.controller.vendorName ?? kind.rawValue
        case .hid(let p):
            kind = p.kind == .ds3 ? .dualShock3 : p.kind == .ps2 ? .ps2Adapter : .genericHID
            name = p.name
        }
    }

    /// Identidad del objeto del sistema (mando enchufado). El teclado es siempre el mismo.
    var key: ObjectIdentifier? {
        switch source {
        case .keyboard: nil
        case .gc(let p): ObjectIdentifier(p)
        case .hid(let p): ObjectIdentifier(p)
        }
    }

    func same(_ o: PlayerDevice) -> Bool { key == o.key }

    /// ¿Sigue enchufado?
    var connected: Bool {
        switch source {
        case .keyboard: true
        case .gc(let p): Controllers.shared.pads.contains { $0 === p }
        case .hid(let p): Controllers.shared.hid.pads.contains { $0 === p }
        }
    }

    /// Nombre corto en el idioma del disco.
    func label(spanish: Bool) -> String {
        if case .keyboard = source { return spanish ? "Teclado" : "Keyboard" }
        return spanish ? kind.rawValue : kind.english
    }

    // MARK: Conducción

    /// Entrada de conducción de este dispositivo y de nadie más. `keys`: teclas pulsadas (solo las usa el teclado).
    func readDrive(keys: Set<UInt16>) -> GameInput.Frame {
        var f = GameInput.Frame()
        switch source {
        case .keyboard:
            typealias K = GameInput.K
            func k(_ c: UInt16) -> Bool { keys.contains(c) }
            func edge(_ c: UInt16) -> Bool { keys.contains(c) && !prevKeys.contains(c) }
            var d = DriverInput()
            d.gas = k(K.w) || k(K.up) ? 1 : 0
            d.brake = k(K.s) || k(K.down) ? 1 : 0
            let st: Float = (k(K.d) || k(K.right) ? 1 : 0) - (k(K.a) || k(K.left) ? 1 : 0)
            d.steerRight = max(st, 0); d.steerLeft = max(-st, 0)
            d.handBrake = k(K.space) ? 1 : 0
            d.nos = k(K.n) || k(K.shift)
            d.lookBack = k(K.x)
            d.shiftUp = k(K.e); d.shiftDown = k(K.q)
            f.driver = d
            f.reset = edge(K.r); f.nextCamera = edge(K.v)
            prevKeys = keys
        case .gc(let p):
            if let s = Controllers.shared.readPad(p) { apply(s, to: &f) }
        case .hid(let p):
            apply(Controllers.shared.hid.readPad(p), to: &f)
        }
        return f
    }

    private func apply(_ pad: PadState, to f: inout GameInput.Frame) {
        var d = DriverInput()
        d.gas = pad.gas; d.brake = pad.brake
        d.steerRight = max(pad.steer, 0); d.steerLeft = max(-pad.steer, 0)
        d.handBrake = pad.handBrake; d.nos = pad.nos; d.lookBack = pad.lookBack
        d.shiftUp = pad.shiftUp; d.shiftDown = pad.shiftDown
        f.driver = d
        f.reset = pad.reset; f.nextCamera = pad.nextCamera; f.prevCamera = pad.prevCamera; f.toggleFreeCamera = pad.toggleFreeCamera
    }

    // MARK: Menús

    /// Botones de menú de este dispositivo con flancos propios de `prefix` (no roban los de la interfaz).
    func readMenu(keys: Set<UInt16>, prefix: String) -> MenuButtons {
        switch source {
        case .keyboard: return menuKeyboard.poll(keys: keys)
        case .gc(let p): return Controllers.shared.menuButtons(p, prefix: prefix)
        case .hid(let p): return Controllers.shared.hid.menuButtons(p, prefix: prefix)
        }
    }

    // MARK: Luz, LED de jugador y vibración

    /// Barra de luz del color del jugador (DualShock 4 / DualSense) y LED de jugador (GCController.playerIndex: DualSense,
    /// Xbox con anillo… lo que el sistema soporte). `index` 0…3; nil = sin jugador.
    func setPlayer(_ index: Int?, color: SIMD3<Float>?) {
        guard case .gc(let p) = source else { return }
        if let index {
            p.controller.playerIndex = [GCControllerPlayerIndex.index1, .index2, .index3, .index4][max(0, min(3, index))]
        } else { p.controller.playerIndex = .indexUnset }
        if let color { Controllers.shared.lightOverride[ObjectIdentifier(p)] = color } else { Controllers.shared.lightOverride[ObjectIdentifier(p)] = nil }
        Controllers.shared.applyLight(p)
    }

    func feedback(_ f: PadFeedback) {
        switch source {
        case .keyboard: break
        case .gc(let p): Controllers.shared.feedback(f, pad: p)
        case .hid(let p): Controllers.shared.hid.rumble(p, strong: min(1, f.impact / 15 + (f.onLimiter ? 0.2 : 0)), weak: min(1, f.slip * 0.05 + (f.nos ? 0.3 : 0)))
        }
    }

    /// Para la vibración: silencio (pausa, fin de carrera).
    func quiet() { feedback(PadFeedback()) }
}

/// Lista de dispositivos ahora mismo: el teclado y todos los mandos enchufados (los objetos se reutilizan mientras el mando
/// siga enchufado, para que sus flancos no se pierdan).
final class PlayerDeviceList {
    static let shared = PlayerDeviceList()
    let keyboard = PlayerDevice(.keyboard)
    private var cache: [ObjectIdentifier: PlayerDevice] = [:]

    var all: [PlayerDevice] {
        Controllers.shared.start()
        var out = [keyboard]
        var alive = Set<ObjectIdentifier>()
        for p in Controllers.shared.pads {
            let k = ObjectIdentifier(p); alive.insert(k)
            if cache[k] == nil { cache[k] = PlayerDevice(.gc(p)) }
            out.append(cache[k]!)
        }
        for p in Controllers.shared.hid.pads {
            let k = ObjectIdentifier(p); alive.insert(k)
            if cache[k] == nil { cache[k] = PlayerDevice(.hid(p)) }
            out.append(cache[k]!)
        }
        cache = cache.filter { alive.contains($0.key) }
        return out
    }

    /// El mando «maestro» para el jugador 1 si nadie elige: Xbox primero (es el mando principal del dueño), luego cualquier
    /// mando, y si no hay mandos, el teclado.
    var preferredMaster: PlayerDevice {
        let l = all
        return l.first { $0.kind == .xbox } ?? l.first { $0.kind != .keyboard } ?? keyboard
    }
}
