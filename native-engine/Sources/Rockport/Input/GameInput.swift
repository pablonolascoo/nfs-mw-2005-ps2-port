// Teclado + mandos → entrada del coche (DriverInput) y acciones sueltas (cámara, reinicio, modo foto).
// El teclado da valores digitales (0/1); la dirección la suaviza la propia física (velocidad de giro de
// SuspensionRacer::CalculateSteeringSpeed), como en el juego con un mando digital.
import Foundation

final class GameInput {
    static let shared = GameInput()

    struct Frame {
        var driver = DriverInput()
        var reset = false, nextCamera = false, prevCamera = false, toggleFreeCamera = false
    }

    // Códigos de tecla de macOS (distribución física)
    enum K {
        static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, w: UInt16 = 13, q: UInt16 = 12, e: UInt16 = 14, r: UInt16 = 15
        static let x: UInt16 = 7, v: UInt16 = 9, n: UInt16 = 45, space: UInt16 = 49, shift: UInt16 = 56
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    private var prevKeys = Set<UInt16>()
    private var pendingToggle = false
    private var pendingPhoto = false

    /// Dos dedos en el panel táctil: modo foto también con la interfaz activa (Start queda para la pausa). Se consume una vez.
    func takePhotoRequest(polling: Bool) -> Bool {
        if polling && Controllers.shared.poll().photoMode { pendingPhoto = true }   // en modo foto nadie más lee los mandos
        defer { pendingPhoto = false }
        return pendingPhoto
    }

    /// Lee teclado y mandos una vez por fotograma.
    func poll(keys: Set<UInt16>) -> Frame {
        Controllers.shared.start()
        let pad = Controllers.shared.poll()
        func k(_ c: UInt16) -> Bool { keys.contains(c) }
        func edge(_ c: UInt16) -> Bool { keys.contains(c) && !prevKeys.contains(c) }
        var f = Frame()
        var d = DriverInput()
        d.gas = max(k(K.w) || k(K.up) ? 1 : 0, pad.gas)
        d.brake = max(k(K.s) || k(K.down) ? 1 : 0, pad.brake)
        let ks: Float = (k(K.d) || k(K.right) ? 1 : 0) - (k(K.a) || k(K.left) ? 1 : 0)
        let steer = abs(pad.steer) > abs(ks) ? pad.steer : ks
        d.steerRight = max(steer, 0); d.steerLeft = max(-steer, 0)
        d.handBrake = max(k(K.space) ? 1 : 0, pad.handBrake)
        d.nos = k(K.n) || k(K.shift) || pad.nos
        d.lookBack = k(K.x) || pad.lookBack
        d.shiftUp = k(K.e) || pad.shiftUp
        d.shiftDown = k(K.q) || pad.shiftDown
        f.driver = d
        f.reset = edge(K.r) || pad.reset
        f.nextCamera = edge(K.v) || pad.nextCamera
        f.prevCamera = pad.prevCamera
        f.toggleFreeCamera = pad.toggleFreeCamera
        if pad.toggleFreeCamera { pendingToggle = true }
        if pad.photoMode { pendingPhoto = true }
        prevKeys = keys
        return f
    }

    /// Botón Start/Options o dos dedos en el panel táctil: alternar cámara libre (modo foto). Se consume una vez.
    /// `polling`: en cámara libre nadie más lee los mandos, así que se leen aquí.
    func takeToggleRequest(polling: Bool) -> Bool {
        Controllers.shared.start()
        if polling && Controllers.shared.poll().toggleFreeCamera { pendingToggle = true }
        defer { pendingToggle = false }
        return pendingToggle
    }
}
