// Mandos: enchufar y jugar, con cable o Bluetooth.
//  · GameController.framework para lo que macOS reconoce de serie: Xbox One/Series, DualShock 4, DualSense, MFi.
//    Extras: barra de luz (color de la pintura; rojo/azul en persecución), gatillos adaptativos del DualSense,
//    vibración con CoreHaptics, panel táctil (deslizar = cámara, pulsar = mirar atrás, toque = vistazo atrás,
//    dos dedos = modo foto).
//  · HIDPads.swift (IOKit) para el resto: DualShock 3 por USB, adaptadores USB de mandos de PS2 y mandos HID genéricos.
// Zonas muertas: stick de dirección 0,1 y stick derecho (gas/freno) 0,2 = mLowerDZ de la colección controller/drive [V];
// gatillos: PAD_DEAD_ZONE 0,05 en InputPlayer [V]. Cómo aplica el juego mLowerDZ no está decompilado: aquí se reescala [I].
import Foundation
import AppKit
import GameController
import CoreHaptics

/// Estado de un mando ya traducido a acciones del juego (InputPlayer: GAMEACTION_*).
struct PadState {
    var gas: Float = 0, brake: Float = 0, steer: Float = 0, handBrake: Float = 0
    var nos = false, lookBack = false, shiftUp = false, shiftDown = false
    var nextCamera = false, prevCamera = false, reset = false, toggleFreeCamera = false
    var active = false
    mutating func merge(_ o: PadState) {
        gas = max(gas, o.gas); brake = max(brake, o.brake); handBrake = max(handBrake, o.handBrake)
        if abs(o.steer) > abs(steer) { steer = o.steer }
        nos = nos || o.nos; lookBack = lookBack || o.lookBack; shiftUp = shiftUp || o.shiftUp; shiftDown = shiftDown || o.shiftDown
        nextCamera = nextCamera || o.nextCamera; prevCamera = prevCamera || o.prevCamera
        reset = reset || o.reset; toggleFreeCamera = toggleFreeCamera || o.toggleFreeCamera; active = active || o.active
    }
}

/// Lo que el coche le cuenta al mando para vibración, gatillos y luz.
struct PadFeedback {
    var speed: Float = 0, rpmRatio: Float = 0, slip: Float = 0, impact: Float = 0
    var brakeLocked = false, onLimiter = false, nos = false, grounded = true
}

enum Deadzone {
    static let steer: Float = 0.1        // GAMEACTION_STEERLEFT/RIGHT mLowerDZ [V]
    static let rightStick: Float = 0.2   // GAMEACTION_GAS/BRAKE (eje) mLowerDZ [V]
    /// |v| < dz → 0; si no, reescala a 0…1 conservando el signo [I].
    static func apply(_ v: Float, _ dz: Float) -> Float {
        let a = abs(v)
        return a < dz ? 0 : (v < 0 ? -1 : 1) * min(1, (a - dz) / (1 - dz))
    }
}

final class Controllers {
    static let shared = Controllers()

    final class Pad {
        let controller: GCController
        var prev = [String: Bool]()
        var hapticEngine: CHHapticEngine?
        var rumble: CHHapticAdvancedPatternPlayer?
        var touchStart: (x: Float, t: Double)? = nil
        var touchLast: (x: Float, t: Double) = (0, 0)
        var twoFinger = false
        var touchEvent: String? = nil            // "izq", "dcha", "toque", "dos"
        var lastTrigger = ""
        init(_ c: GCController) { controller = c }
    }

    private(set) var pads: [Pad] = []
    let hid = HIDPads()
    private var started = false
    private var pursuit = false
    private var paint = Config.playerPaint
    private var clock: Double = 0
    private var glanceBackUntil: Double = 0
    private var xbox360Warned = false
    private var lastUSBCheck: Double = -10

    /// Llamar una vez con la app en marcha (hilo principal).
    func start() {
        // Solo en la app (modo con ventana): las pruebas sin ventana no leen mandos
        guard !started, NSApp?.isRunning == true else { return }
        started = true
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.add(c) }
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            guard let self, let c = n.object as? GCController else { return }
            self.pads.removeAll { $0.controller === c }
            print("Mando desconectado: \(c.vendorName ?? "mando")")
        }
        for c in GCController.controllers() { add(c) }
        hid.start()
    }

    private func add(_ c: GCController) {
        guard c.extendedGamepad != nil, !pads.contains(where: { $0.controller === c }) else { return }
        let p = Pad(c)
        pads.append(p)
        let kind = c.extendedGamepad is GCDualSenseGamepad ? "DualSense" : c.extendedGamepad is GCDualShockGamepad ? "DualShock 4" :
            c.extendedGamepad is GCXboxGamepad ? "Xbox" : (c.productCategory)
        print("Mando conectado: \(c.vendorName ?? "mando") (\(kind)) · GameController")
        // Vibración: un patrón continuo cuya intensidad se cambia en cada fotograma + golpes sueltos
        if let h = c.haptics, let e = h.createEngine(withLocality: .default) {
            do {
                try e.start()
                let ev = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1), CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)],
                    relativeTime: 0, duration: 100)
                let player = try e.makeAdvancedPlayer(with: CHHapticPattern(events: [ev], parameters: []))
                player.loopEnabled = true
                try player.start(atTime: CHHapticTimeImmediate)
                try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)], atTime: CHHapticTimeImmediate)
                p.hapticEngine = e; p.rumble = player
                e.resetHandler = { [weak p] in try? p?.hapticEngine?.start() }
            } catch { print("vibración no disponible en \(c.vendorName ?? "mando"): \(error.localizedDescription)") }
        }
        if let ds = c.extendedGamepad as? GCDualShockGamepad { hookTouchpad(p, ds.touchpadPrimary, ds.touchpadSecondary) }
        if let ds = c.extendedGamepad as? GCDualSenseGamepad { hookTouchpad(p, ds.touchpadPrimary, ds.touchpadSecondary) }
        applyLight(p)
    }

    /// Panel táctil: el juego original no lo tiene (PS2). Gestos propios, documentados en el doc 15.
    private func hookTouchpad(_ p: Pad, _ primary: GCControllerDirectionPad, _ secondary: GCControllerDirectionPad) {
        primary.valueChangedHandler = { [weak p] _, x, y in
            guard let p else { return }
            let now = CACurrentMediaTimeShim.now()
            if x == 0 && y == 0 {                     // dedo fuera: cerrar el gesto ya
                if p.touchStart != nil { p.touchLast.t = now - 1 }
                return
            }
            if p.touchStart == nil { p.touchStart = (x, now); p.twoFinger = false }
            p.touchLast = (x, now)
        }
        secondary.valueChangedHandler = { [weak p] _, _, _ in if let p, p.touchStart != nil { p.twoFinger = true } }
    }

    /// Cierra un gesto si el dedo lleva 120 ms sin moverse (GameController no avisa al levantarlo).
    private func finishTouch(_ p: Pad, pressed: Bool) {
        guard let s = p.touchStart else { return }
        let now = CACurrentMediaTimeShim.now()
        guard now - p.touchLast.t > 0.12, !pressed else { return }
        let dx = p.touchLast.x - s.x, dur = p.touchLast.t - s.t
        if p.twoFinger { p.touchEvent = "dos" }
        else if dx > 0.6 { p.touchEvent = "dcha" }
        else if dx < -0.6 { p.touchEvent = "izq" }
        else if dur < 0.3 && abs(dx) < 0.25 { p.touchEvent = "toque" }
        p.touchStart = nil; p.twoFinger = false
    }

    // MARK: Lectura

    func poll() -> PadState {
        clock = CACurrentMediaTimeShim.now()
        var out = PadState()
        for p in pads { if let s = read(p) { out.merge(s) } }
        out.merge(hid.poll())
        if clock < glanceBackUntil { out.lookBack = true }
        if clock - lastUSBCheck > 3 { lastUSBCheck = clock; checkXbox360() }
        return out
    }

    private func read(_ p: Pad) -> PadState? {
        guard let g = p.controller.extendedGamepad else { return nil }
        var s = PadState()
        func edge(_ k: String, _ v: Bool) -> Bool { let was = p.prev[k] ?? false; p.prev[k] = v; return v && !was }
        s.steer = Deadzone.apply(g.leftThumbstick.xAxis.value, Deadzone.steer)
        let ry = Deadzone.apply(g.rightThumbstick.yAxis.value, Deadzone.rightStick)
        s.gas = max(g.rightTrigger.value, max(ry, 0))
        s.brake = max(g.leftTrigger.value, max(-ry, 0))
        s.handBrake = max(g.buttonA.value, g.rightShoulder.isPressed ? 1 : 0)
        s.nos = g.buttonB.isPressed
        s.lookBack = g.leftShoulder.isPressed || (g.leftThumbstickButton?.isPressed ?? false)
        s.nextCamera = edge("y", g.buttonY.isPressed)
        s.reset = edge("x", g.buttonX.isPressed) || edge("opt", g.buttonOptions?.isPressed ?? false)
        s.toggleFreeCamera = edge("menu", g.buttonMenu.isPressed)
        s.shiftUp = g.dpad.up.isPressed
        s.shiftDown = g.dpad.down.isPressed
        s.prevCamera = edge("dl", g.dpad.left.isPressed)
        if edge("dr", g.dpad.right.isPressed) { s.nextCamera = true }
        // Panel táctil (DualShock 4 / DualSense)
        var tpPressed = false
        if let ds = g as? GCDualShockGamepad { tpPressed = ds.touchpadButton.isPressed }
        if let ds = g as? GCDualSenseGamepad { tpPressed = ds.touchpadButton.isPressed }
        if tpPressed { s.lookBack = true }
        finishTouch(p, pressed: tpPressed)
        if let ev = p.touchEvent {
            p.touchEvent = nil
            switch ev {
            case "dcha": s.nextCamera = true
            case "izq": s.prevCamera = true
            case "toque": glanceBackUntil = clock + 1.0
            case "dos": s.toggleFreeCamera = true
            default: break
            }
        }
        s.active = s.gas > 0 || s.brake > 0 || s.steer != 0 || s.handBrake > 0
        return s
    }

    // MARK: Luz, vibración y gatillos

    /// Para el tráfico/policía: persecución activa → barra de luz roja/azul intermitente.
    func setPursuit(active: Bool) { pursuit = active }
    /// Color normal de la barra de luz (pintura del coche, sRGB 0…1).
    func setPaint(_ rgb: SIMD3<Float>) { paint = rgb; for p in pads { applyLight(p) } }

    private func applyLight(_ p: Pad) {
        guard let light = p.controller.light else { return }
        var c = paint
        if pursuit { c = Int(clock * 4) % 2 == 0 ? SIMD3(1, 0, 0) : SIMD3(0, 0.25, 1) }
        light.color = GCColor(red: c.x, green: c.y, blue: c.z)
    }

    /// Cada fotograma en conducción.
    func update(feedback f: PadFeedback) {
        for p in pads {
            applyLight(p)
            // Vibración continua: deslizamiento, limitador, nitro y golpes [diseño propio; el PS2 usa Rumble.cpp]
            let base = min(1, f.slip * 0.08) * 0.5 + (f.onLimiter ? 0.25 : 0) + (f.nos ? 0.2 : 0) + min(1, f.impact / 15)
            try? p.rumble?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: min(1, base), relativeTime: 0)], atTime: CHHapticTimeImmediate)
            if let ds = p.controller.extendedGamepad as? GCDualSenseGamepad { adaptiveTriggers(p, ds, f) }
        }
        hid.rumble(strong: min(1, f.impact / 15 + (f.onLimiter ? 0.2 : 0)), weak: min(1, f.slip * 0.05 + (f.nos ? 0.3 : 0)))
    }

    /// DualSense: el freno (L2) se endurece; con las ruedas bloqueadas vibra; el gas (R2) tiembla en el limitador.
    private func adaptiveTriggers(_ p: Pad, _ ds: GCDualSenseGamepad, _ f: PadFeedback) {
        let brakeMode = f.brakeLocked ? "lock" : "feel"
        let gasMode = f.onLimiter ? "limit" : (f.nos ? "nos" : "feel")
        let key = brakeMode + gasMode
        guard key != p.lastTrigger else { return }
        p.lastTrigger = key
        if f.brakeLocked { ds.leftTrigger.setModeVibrationWithStartPosition(0.1, amplitude: 0.6, frequency: 0.35) }
        else { ds.leftTrigger.setModeFeedbackWithStartPosition(0.15, resistiveStrength: 0.55) }
        switch gasMode {
        case "limit": ds.rightTrigger.setModeVibrationWithStartPosition(0.5, amplitude: 0.4, frequency: 0.6)
        case "nos": ds.rightTrigger.setModeFeedbackWithStartPosition(0.05, resistiveStrength: 0.1)
        default: ds.rightTrigger.setModeFeedbackWithStartPosition(0.1, resistiveStrength: 0.25)
        }
    }

    // MARK: Xbox 360

    /// El mando de Xbox 360 con cable (045E:028E) y su receptor inalámbrico (045E:0719) no son HID en macOS:
    /// sin un controlador de terceros (360Controller) no llegan ni a GameController ni a IOHIDManager. Se avisa.
    private func checkXbox360() {
        guard !xbox360Warned else { return }
        if USBProbe.present(vendor: 0x045E, products: [0x028E, 0x0719, 0x02A1, 0x0291]) && !hid.hasDevice(vendor: 0x045E)
            && !pads.contains(where: { $0.controller.vendorName?.contains("360") ?? false }) {
            xbox360Warned = true
            print("""
            Mando de Xbox 360 detectado por USB, pero macOS no lo trata como mando (no es HID).
            Instala el controlador libre «360Controller» (github.com/360Controller/360Controller) o usa un mando Xbox One/Series, DualShock 4 o DualSense.
            """)
        }
    }
}

/// Reloj monotónico sin depender de QuartzCore en este archivo.
enum CACurrentMediaTimeShim { static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 } }
