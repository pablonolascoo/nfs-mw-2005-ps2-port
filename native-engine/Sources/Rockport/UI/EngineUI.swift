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
            fputs("Interfaz: faltan los datos de frontend/ (reconvierte con tools/: paso «frontend»). Sin HUD.\n", stderr)
            return nil
        }
        ui = u
        renderer.overlays.append(u)
        // El HUD original sustituye al HUD propio de persecución (HUDPursuit.swift), que solo queda con --debug-hud
        aiRenderer?.hud.enabled = PursuitHUD.debugEnabled
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

    /// Datos del HUD [D: interfaces ITachometer, ISpeedometer, INos, IHeatMeter, IPursuitBoard, IMinimap].
    /// En la prueba sin ventana `--traffic-test` el «jugador» es el coche de prueba (AITestDriver).
    func ui_hudInput() -> HudInput {
        var h = HudInput()
        h.kmh = ui?.assets.language != "english"
        if let tp = AITestDriver.current {
            // Coche de prueba de la IA: velocidad y posición reales; marcha y vueltas de un cambio de 6 marchas de ejemplo [I]
            let v = tp.v
            h.speed = v.speed
            let kmh = v.speed * 3.6
            let g = min(6, 1 + Int(kmh / 45))
            h.gear = kmh < 1 ? 1 : g + 1
            h.rpm = kmh < 1 ? 1000 : 2500 + (kmh - Float(g - 1) * 45) / 45 * 4500
            h.playerPos = SIMD2(v.pos.x, v.pos.y)
            h.playerDir = SIMD2(v.fwd.x, v.fwd.y)
        } else if let car {
            h.speed = car.speed
            h.rpm = car.rpm
            if let e = car.vehicle?.specs.engine { h.redline = e.RED_LINE; h.maxRpm = e.MAX_RPM }
            h.gear = car.gear
            h.shifting = car.vehicle?.engine.isGearChanging ?? false
            h.nos = car.nosCapacity
            h.nosEngaged = car.isNOSEngaged
            h.playerPos = SIMD2(car.position.x, car.position.y)
            h.playerDir = simd_length(SIMD2(car.forward.x, car.forward.y)) > 0.01 ? simd_normalize(SIMD2(car.forward.x, car.forward.y)) : SIMD2(1, 0)
        }
        if let ai {
            h.bustedCount = ai.stats.busted
            h.evadedCount = ai.stats.evaded
            for c in ai.vehicles where c.kind == .cop && !c.damage.destroyed {
                h.cops.append(HudBlip(pos: SIMD2(c.pos.x, c.pos.y), dir: SIMD2(c.fwd.x, c.fwd.y), inPursuit: c.copRole == .pursuit))
            }
            // Helicóptero en el radar (HELICOPTER_ICON_GROUP) y en la persecución (Crash/Heli.swift)
            if let b = ai.heli?.blip { h.cops.append(b); h.heliInvolved = true }
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
                // medidor: −0,5 (evasión) … +0,5 (arresto); el temporizador de arresto (0…5 s) manda cuando corre
                let bust = pm.bustTimer / PoliceManager.bustedTimeout
                h.timeUntilBusted = bust > 0.01 ? min(0.99, 0.5 + bust * 0.5) : max(-0.99, min(0.99, pm.meter * 2))
            }
            h.pursuitSeconds = pm.pursuitTime
            h.copsEngaged = pm.copsInPursuit + (h.heliInvolved ? 1 : 0)
            // Choques del juego (Crash/): policías dañados y destruidos [D: IPursuit GetNumCopsDamaged/Destroyed]
            h.copsDamaged = pm.copsDamaged
            h.copsDestroyed = pm.copsDestroyed
            h.lastCopDestroyedType = pm.lastCopDestroyedType
            h.lastCopDestroyedRep = pm.lastCopDestroyedRep
            h.costToState = pm.costToState
            h.infractions = pm.infractions.count
        }
        return h
    }
}
