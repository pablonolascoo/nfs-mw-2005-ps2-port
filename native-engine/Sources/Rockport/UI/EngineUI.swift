// Enlace entre la interfaz original (FEUI) y el motor: modo menú (cámara que gira sobre la ciudad), empezar la partida,
// reiniciar y los datos del HUD (coche + policía, la misma API que usaba HUDPursuit.swift).
import Foundation
import Metal
import simd

extension Engine {
    /// Activa la interfaz del juego (pantallas y HUD originales). La app la activa siempre; las pruebas, con --ui-test.
    @discardableResult
    func enableUI(outputFormat: MTLPixelFormat) -> FEUI? {
        if let ui { return ui }
        guard let u = FEUI(engine: self, outputFormat: outputFormat) else {
            fputs("Interfaz: faltan los datos de frontend/ (reconvierte con tools/: paso «frontend»). Se usa el HUD mínimo.\n", stderr)
            return nil
        }
        ui = u
        renderer.overlays.append(u)
        // El HUD original sustituye al HUD propio de persecución
        aiRenderer?.hud.enabled = u.hud == nil
        return u
    }

    /// Menús: cámara libre sin control del jugador; el coche se queda donde estaba.
    func ui_enterFrontend() {
        if mode == .drive { toggleMode() }
    }

    func ui_startGame() {
        loadCar()
        if mode == .fly { toggleMode() }
    }

    /// «Reiniciar» de la pausa en la zona libre: de vuelta al refugio 1, parado.
    func ui_restart() {
        guard let car, let z = data.zones.first(where: { $0.zoneType == "safehouse" }), let r = z.respawn, r.position.count == 3 else { car?.reset(); return }
        car.place(float3(r.position[0], r.position[1], r.position[2]), yaw: (r.rotation ?? 0) * .pi / 180, collision: collision)
    }

    /// Fondo de los menús: vuelta lenta alrededor del refugio, a 120 m y 60 m de altura.
    func ui_frontendCamera(angle: Float) {
        var c = float3(1700, 2300, 40)
        if let z = data.zones.first(where: { $0.zoneType == "safehouse" }), let r = z.respawn, r.position.count == 3 { c = float3(r.position[0], r.position[1], r.position[2]) }
        let a = angle + 0.6
        camPos = c + float3(cos(a), sin(a), 0) * 140 + float3(0, 0, 55)
        let d = simd_normalize(c + float3(0, 0, 8) - camPos)
        yaw = atan2(d.y, d.x); pitch = asin(max(-1, min(1, d.z)))
    }

    /// Datos del HUD [D: interfaces ITachometer, ISpeedometer, INos, IHeatMeter, IPursuitBoard].
    func ui_hudInput() -> HudInput {
        var h = HudInput()
        h.kmh = ui?.assets.language != "english"
        if let car {
            h.speed = car.speed
            h.rpm = car.rpm
            if let e = car.vehicle?.specs.engine { h.redline = e.RED_LINE; h.maxRpm = e.MAX_RPM }
            h.gear = car.gear
            h.shifting = car.vehicle?.engine.isGearChanging ?? false
            h.nos = car.nosCapacity
            h.nosEngaged = car.isNOSEngaged
        }
        if let pm = ai?.police {
            h.heat = pm.heat
            h.inPursuit = pm.inPursuit
            h.cooldown = pm.state == .cooldown
            if pm.state == .cooldown {
                h.timeUntilBusted = -1
                let lv = pm.level
                h.cooldownRequired = lv?.evadeTimeout ?? 60
                h.cooldownRemaining = (1 - pm.evade) * h.cooldownRequired
            } else {
                // meter: −0,5 (evasión) … +0,5 (arresto); el temporizador de arresto (0…5 s) manda cuando corre
                let bust = pm.bustTimer / PoliceManager.bustedTimeout
                h.timeUntilBusted = bust > 0.01 ? min(0.99, 0.5 + bust * 0.5) : max(-0.99, min(0.99, pm.meter * 2))
            }
            h.pursuitSeconds = pm.pursuitTime
            h.copsEngaged = pm.copsInPursuit
            h.costToState = pm.costToState
        }
        return h
    }
}
