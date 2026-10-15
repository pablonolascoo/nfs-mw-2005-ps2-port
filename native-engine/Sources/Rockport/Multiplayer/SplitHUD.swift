// HUD de un jugador de la pantalla partida: el paquete del juego para su hueco (HUD_Player1 / HUD_Player2, o sus versiones
// de aceleración HUD_Drag_Player1/2; HUD_SingleRace si tiene la pantalla para él solo) con la lógica de FEHud, y la API
// RaceHUD para que la carrera le hable como al HUD de un jugador. Las pantallas completas (resultados, Lista Negra) las sigue
// sacando la interfaz (FEUI), una sola vez para todos.
import Foundation
import Metal
import simd

final class SplitHUD: RaceHUD {
    let assets: FEAssets
    weak var ui: FEUI?
    let slot: SplitSlot
    private(set) var hud: FEHud?
    private var dragHud: FEHud?
    var raceKind: RaceKind?
    /// El HUD que se ve ahora (el de aceleración en las pruebas de drag).
    var current: FEHud? { raceKind == .drag ? (dragHud ?? hud) : hud }

    init(assets: FEAssets, ui: FEUI?, slot: SplitSlot) {
        self.assets = assets; self.ui = ui; self.slot = slot
        hud = FEHud(assets: assets, kind: slot.hud)
        if hud == nil { fputs("Pantalla partida: falta el paquete \(slot.hud.package) (reconvierte el paso «frontend» de tools/)\n", stderr) }
    }

    private var dragKind: FEHud.Kind {
        switch slot.hud { case .split1: .dragSplit1; case .split2: .dragSplit2; default: .drag }
    }

    /// Paquetes a dibujar este fotograma.
    var packages: [FEPackageRT] { [hud, dragHud].compactMap { $0 }.map(\.pkg).filter(\.visible) }

    func update(ms: Int, input: HudInput, visible: Bool, visibleHalfWidth: Float) {
        let drag = raceKind == .drag
        if drag, dragHud == nil { dragHud = FEHud(assets: assets, kind: dragKind); dragHud?.race = hud?.race }
        for h in [hud, dragHud].compactMap({ $0 }) { h.setWidescreen(visibleHalfWidth: visibleHalfWidth) }
        hud?.update(ms: ms, input: input, visible: visible && !drag)
        dragHud?.update(ms: ms, input: input, visible: visible && drag)
    }

    private func each(_ f: (FEHud) -> Void) { for h in [hud, dragHud].compactMap({ $0 }) { f(h) } }

    // MARK: RaceHUD

    func beginRace(_ setup: RaceHUDSetup) {
        raceKind = setup.kind
        var st = FEHud.RaceState(setup: setup)
        if !slot.minimap { st.setup.showMinimap = false }
        hud?.race = st
        dragHud?.race = st
    }
    func endRace() { raceKind = nil; each { $0.race = nil } }
    func showCountdown(_ value: Int) { each { $0.race?.countdown = value } }
    func setPosition(_ position: Int, of total: Int) { each { $0.race?.position = position; $0.race?.racerCount = total } }
    func setLap(_ lap: Int, of total: Int) {
        if let r = current?.race, lap > r.lap, lap == total, total > 1 { current?.queueMessage(.finalLap) }
        each { $0.race?.lap = lap; $0.race?.laps = total }
    }
    func setTimer(raceTime: Double, lapTime: Double?, bestLap: Double?) { each { $0.race?.raceTime = raceTime; $0.race?.lapTime = lapTime; $0.race?.bestLap = bestLap } }
    func setProgress(_ percent: Float) { each { $0.race?.percentComplete = percent } }
    func setRacers(_ racers: [RaceHUDRacer]) { each { $0.race?.racers = racers; if !racers.isEmpty { $0.race?.racerCount = racers.count } } }
    func setNextCheckpoint(_ world: SIMD3<Float>?) { each { $0.race?.nextCheckpoint = world } }
    func setRoute(_ points: [SIMD3<Float>]) { each { $0.race?.route = points } }
    func setRacerBlips(_ positions: [SIMD3<Float>]) { each { $0.race?.blips = positions } }
    func setSpeedtrap(totalMps: Float, passed: Int, of total: Int) {
        each { $0.race?.speedtrapTotal = totalMps; $0.race?.speedtrapPassed = passed; $0.race?.checkpointCount = total }
    }
    func setDrag(shiftQuality: Int, engineTemp: Float) { each { $0.race?.shiftQuality = shiftQuality; $0.race?.engineTemp = engineTemp } }
    func showMessage(_ message: RaceHUDMessage) { current?.queueMessage(message) }
    // Pantallas completas: una sola vez, las de la interfaz
    func showResults(_ results: RaceResults, onContinue: @escaping () -> Void) { if let ui { ui.showResults(results, onContinue: onContinue) } else { onContinue() } }
    func showBlacklist(_ rivals: [BlacklistRival], selected: Int, onChoice: @escaping (Int?) -> Void) { ui?.showBlacklist(rivals, selected: selected, onChoice: onChoice) }
    func showCarWon(carName: String, rivalName: String, onContinue: @escaping () -> Void) { ui?.showCarWon(carName: carName, rivalName: rivalName, onContinue: onContinue) }
    func dismissScreens() { ui?.dismissScreens() }
}

extension HudInput {
    /// Datos del HUD de un coche cualquiera (lo mismo que Engine.ui_hudInput hace con el del jugador).
    static func from(car: Car, english: Bool) -> HudInput {
        var h = HudInput()
        h.kmh = !english
        h.speed = car.speed
        h.rpm = car.rpm
        if let e = car.vehicle?.specs.engine { h.redline = e.RED_LINE; h.maxRpm = e.MAX_RPM }
        h.gear = car.gear
        h.shifting = car.vehicle?.engine.isGearChanging ?? false
        h.nos = car.nosCapacity
        h.nosEngaged = car.isNOSEngaged
        h.playerPos = SIMD2(car.position.x, car.position.y)
        h.playerDir = simd_length(SIMD2(car.forward.x, car.forward.y)) > 0.01 ? simd_normalize(SIMD2(car.forward.x, car.forward.y)) : SIMD2(1, 0)
        return h
    }
}
