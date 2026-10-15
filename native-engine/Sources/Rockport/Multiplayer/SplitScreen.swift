// Pantalla partida: varios jugadores humanos en la misma partida, cada uno con su mando, su coche (Car + física del juego),
// su cámara (camerainfo de pantalla partida), su HUD y su vista. El jugador 1 es el coche del motor (`engine.car`): el motor
// lo simula como siempre pero con la entrada de SU mando (`playerInputOverride`); los demás los simula esta clase en un
// enganche del fotograma, con la misma regla de la carrera (`RaceSession.filterHuman`).
//
//   let ss = SplitScreen(engine: engine, players: [(device, car, nombre)…], displays: 1)
//   ss.begin()                 // vistas, HUD, mandos (luz y LED de jugador), menús solo para los que juegan
//   … RaceSystem.start(…, options: QuickRaceOptions(humans: ss.otherHumans))
//   ss.end()                   // vuelve a un jugador
//
// Mando desenchufado: la partida se para con el aviso del propio juego (ControllerUnplugged.fng: «Se ha extraído el mando…
// pulsa START») hasta que ese jugador (o cualquier mando libre) pulse START [D: FEJoyInput::CheckUnplugged].
// Sonido: `SplitScreen.current?.playerCars` da los coches de los jugadores (el motor de audio pondera los oyentes con ellos).
import Foundation
import Metal
import simd

final class MPPlayer {
    let index: Int
    var device: PlayerDevice
    let car: Car
    let name: String
    let color: SIMD3<Float>
    /// Pantalla (0 = la principal) y hueco dentro de ella.
    var display = 0
    var slot: SplitSlot
    var hud: SplitHUD?
    var disconnected = false
    /// Pruebas: sin mando (el piloto automático de la carrera lo lleva).
    var autopilot = false

    init(index: Int, device: PlayerDevice, car: Car, name: String, color: SIMD3<Float>, slot: SplitSlot) {
        self.index = index; self.device = device; self.car = car; self.name = name; self.color = color; self.slot = slot
    }
}

final class SplitScreen: RenderOverlay {
    /// La partida en pantalla partida en curso (para el sonido y la interfaz).
    static private(set) weak var current: SplitScreen?

    /// Colores de jugador (barra de luz y nombre): azul, rojo, verde y rosa, el orden de los LED de PlayStation [I].
    static let colors: [SIMD3<Float>] = [SIMD3(0.05, 0.35, 1.0), SIMD3(1.0, 0.1, 0.08), SIMD3(0.1, 0.85, 0.2), SIMD3(1.0, 0.35, 0.75)]

    unowned let engine: Engine
    private(set) var players: [MPPlayer] = []
    private(set) var active = false
    /// Pantallas en uso (1 = todo en la principal). Las demás las dibuja MultiDisplay.
    let displays: Int
    /// Pantalla que se está dibujando (la pone quien llama a `views`); el HUD la usa en `encodeScreen`.
    var currentDisplay = 0
    /// Un dibujante de HUD por pantalla (cada uno con su anillo de búferes).
    private var feRenderers: [Int: FERenderer] = [:]
    private var unplugged: (screen: FEScreen, player: MPPlayer)?
    private var hookInstalled = false
    var drawCalls: Int { 0 }

    /// Coches de los jugadores humanos en orden (para el audio: oyentes por jugador).
    var playerCars: [Car] { players.map(\.car) }
    /// Los humanos que no son el jugador 1, para `QuickRaceOptions.humans`.
    var otherHumans: [(car: Car, name: String)] { players.dropFirst().map { ($0.car, $0.name) } }

    init(engine: Engine, players list: [(device: PlayerDevice, car: Car, name: String)], displays: Int = 1) {
        self.engine = engine
        self.displays = max(1, min(displays, list.count))
        let perDisplay = SplitLayout.distribute(players: list.count, displays: self.displays)
        var k = 0
        for (d, n) in perDisplay.enumerated() {
            let slots = SplitLayout.slots(n)
            for s in slots where k < list.count {
                let e = list[k]
                let p = MPPlayer(index: k, device: e.device, car: e.car, name: e.name, color: SplitScreen.colors[k % 4], slot: s)
                p.display = d
                players.append(p)
                k += 1
            }
        }
    }

    // MARK: Empezar y acabar

    func begin() {
        guard !active, let p1 = players.first else { return }
        active = true
        SplitScreen.current = self
        engine.splitScreen = self
        // Jugador 1 = el coche del motor
        engine.car = p1.car
        if engine.mode != .drive { engine.mode = .drive }
        engine.playerInputOverride = { [weak self] in self?.input(0) ?? GameInput.Frame() }
        for p in players {
            p.car.camera.splitScreen = p.slot.hud != .standard
            p.device.setPlayer(p.index, color: p.color)
            if let ui = engine.ui { p.hud = SplitHUD(assets: ui.assets, ui: ui, slot: p.slot) }
        }
        updateAspects(width: 16, height: 10)
        engine.ui?.hudVisible = false
        RaceSystem.shared?.playerHUDs = players.map { p -> RaceHUD in p.hud ?? NullRaceHUD() }
        // Menús de la carrera (pausa): cualquiera de los que juegan [D: cFEngJoyInput::HandleJoy lee los dos puertos]
        MenuOwners.allowed = Set(players.compactMap(\.device.key))
        // El HUD va antes que la interfaz (pausa y resultados por encima)
        if let i = engine.renderer.overlays.firstIndex(where: { $0 === engine.ui }) { engine.renderer.overlays.insert(self, at: i) }
        else { engine.renderer.overlays.append(self) }
        if !hookInstalled {
            hookInstalled = true
            engine.frameHooks.append { [weak self] dt in self?.step(dt: dt) }
        }
        Controllers.shared.onPadsChanged = { [weak self] in self?.checkConnections() }
        Controllers.shared.hid.onPadsChanged = { [weak self] in self?.checkConnections() }
        // Sonido (Audio/SFXWorld.swift): un coche local y un oyente (su cámara) por jugador
        SFXWorld.shared.localCarsProvider = { [weak self] in self?.playerCars ?? [] }
        SFXWorld.shared.listenersProvider = { [weak self] in
            self?.players.map { p in SFXListener(position: p.car.camera.eye, forward: simd_normalize(p.car.camera.target - p.car.camera.eye + 1e-6),
                                                  velocity: p.car.velocity) } ?? []
        }
        if displays > 1 { MultiDisplay.shared.open(extra: displays - 1, engine: engine) }
        print("Pantalla partida: \(players.count) jugadores en \(displays) pantalla(s) · " +
              players.map { "J\($0.index + 1) \($0.device.label(spanish: true)) (\($0.name))" }.joined(separator: " · "))
    }

    func end() {
        guard active else { return }
        active = false
        engine.splitScreen = nil
        engine.playerInputOverride = nil
        engine.cameraAspect = nil
        engine.ui?.hudVisible = true
        engine.renderer.overlays.removeAll { $0 === self }
        RaceSystem.shared?.playerHUDs = nil
        MenuOwners.allowed = nil
        Controllers.shared.onPadsChanged = nil
        Controllers.shared.hid.onPadsChanged = nil
        SFXWorld.shared.localCarsProvider = nil
        SFXWorld.shared.listenersProvider = nil
        hideUnplugged()
        MultiDisplay.shared.close()
        for p in players { p.car.camera.splitScreen = false; p.device.setPlayer(nil, color: nil); p.device.quiet() }
        if SplitScreen.current === self { SplitScreen.current = nil }
    }

    // MARK: Entrada

    /// Entrada del jugador `i` (solo su dispositivo). Desconectado o en piloto automático: nada.
    func input(_ i: Int) -> GameInput.Frame {
        guard i < players.count else { return GameInput.Frame() }
        let p = players[i]
        if p.disconnected || p.autopilot { return GameInput.Frame() }
        return p.device.readDrive(keys: engine.keys)
    }

    // MARK: Fotograma

    /// Enganche del fotograma (tras el jugador 1 y la carrera): los demás coches, sus cámaras, vibración y HUD.
    private func step(dt: Float) {
        guard active else { return }
        // Salir desde la pausa (menú principal): la prueba se abandona y se vuelve a un jugador
        if let st = engine.ui?.state, st == .menu || st == .splash {
            if let s = RaceSystem.shared?.session { s.abandon() }
            if active { end() }
            return
        }
        checkConnections()
        if unplugged != nil { pollReconnect(); return }
        if dt > 0 {
            for p in players.dropFirst() {
                var f = input(p.index)
                if let s = RaceSystem.shared?.session { s.filterHuman(car: p.car, &f.driver, &f.reset, dt) }
                p.car.update(dt: dt, input: Car.Input(driver: f.driver), collision: engine.collision)
                if f.reset && RaceSystem.shared?.session == nil { p.car.reset() }
                if f.nextCamera { p.car.camera.next(1) }
                if f.prevCamera { p.car.camera.next(-1) }
                p.car.camera.update(dt: dt, car: p.car, lookBack: f.driver.lookBack, aspect: aspect(p))
            }
            for p in players where !p.disconnected { p.device.feedback(p.car.padFeedback) }
        }
        updateHUDs(dt: dt)
    }

    private var targetSize = SIMD2<Float>(16, 10)
    private func aspect(_ p: MPPlayer) -> Float { targetSize.x * p.slot.rect.w / max(1, targetSize.y * p.slot.rect.h) }

    /// Tamaño del destino (para el aspecto de cada vista). Lo llama `views`.
    private func updateAspects(width: Int, height: Int) {
        targetSize = SIMD2(Float(width), Float(height))
        if let p1 = players.first { engine.cameraAspect = aspect(p1) }
    }

    private func updateHUDs(dt: Float) {
        let ms = Int((dt * 1000).rounded())
        let english = engine.ui?.assets.language == "english"
        let visible = engine.ui?.state == .game
        for p in players {
            guard let h = p.hud else { continue }
            var input = HudInput.from(car: p.car, english: english)
            if engine.ai != nil, p.index == 0, let ui = engine.ui { input.heat = ui.engine.ui_hudInput().heat }
            // Radar compartido de dos jugadores: el otro coche como segundo icono [D: Minimap::UpdatePlayer2Element]
            let mates = players.filter { $0.display == p.display }
            if p.slot.minimap, mates.count == 2, let o = mates.first(where: { $0 !== p }) {
                let d = SIMD2(o.car.forward.x, o.car.forward.y)
                h.current?.otherPlayer = (SIMD2(o.car.position.x, o.car.position.y), simd_length(d) > 0.01 ? simd_normalize(d) : SIMD2(1, 0))
            }
            let hudW = targetSize.x * p.slot.hudRect.w, hudH = targetSize.y * p.slot.hudRect.h
            let L = FELayout(width: Int(targetSize.x), height: Int(targetSize.y), rect: SIMD4(0, 0, hudW, hudH), canvas: p.slot.canvas)
            h.update(ms: dt > 0 ? ms : 0, input: input, visible: visible, visibleHalfWidth: L.visibleHalfWidth)
        }
    }

    // MARK: Vistas

    /// Puntos para el streaming de casillas: la cámara de cada jugador (y el centro, para la vista aérea).
    func streamingPoints() -> [float3] {
        var pts = players.map { $0.car.camera.eye }
        if needsOverview { pts.append(overviewEye) }
        return pts
    }

    private var needsOverview: Bool { SplitLayout.distribute(players: players.count, displays: displays).contains(3) }

    /// Vistas de la pantalla `currentDisplay` para dibujar en `target`.
    func views(target: MTLTexture) -> [RenderView] {
        if currentDisplay == 0 { updateAspects(width: target.width, height: target.height) }
        let W = Float(target.width), H = Float(target.height)
        var out: [RenderView] = []
        let mine = players.filter { $0.display == currentDisplay }
        for p in mine {
            let cam = p.car.camera
            let a = W * p.slot.rect.w / max(1, H * p.slot.rect.h)
            out.append(RenderView(frame: frame(eye: cam.eye, target: cam.target, up: cam.up, fovY: cam.fovY, aspect: a), rect: p.slot.rect))
        }
        if mine.count == 3 {
            let r = SplitLayout.overviewRect
            let a = W * r.w / max(1, H * r.h)
            out.append(RenderView(frame: frame(eye: overviewEye, target: overviewTarget, up: float3(0, 0, 1), fovY: 50, aspect: a), rect: r))
        }
        return out
    }

    /// Vista aérea del cuarto libre: sobre el centro de los jugadores, mirando hacia abajo [diseño propio].
    private var overviewTarget: float3 {
        let c = players.reduce(float3(0, 0, 0)) { $0 + $1.car.position } / Float(max(1, players.count))
        return c
    }
    private var overviewEye: float3 {
        let c = overviewTarget
        let spread = players.map { simd_distance($0.car.position, c) }.max() ?? 0
        let h = max(90, spread * 1.6 + 60)
        let f = players.first?.car.forward ?? float3(1, 0, 0)
        return c - f * h * 0.55 + float3(0, 0, h)
    }

    private func frame(eye: float3, target: float3, up: float3, fovY: Float, aspect: Float) -> SceneFrame {
        let view = float4x4.lookAt(eye: eye, target: target, up: up)
        let proj = float4x4.perspectiveReversedInfinite(fovY: fovY * .pi / 180, aspect: aspect, near: Config.nearPlane)
        let meshes = engine.streamer.tiles.compactMap { $0.drawMesh } + engine.extraMeshes
        var carDraw: (GPUMesh, [float4x4])? = nil
        if let car = engine.car { carDraw = (car.mesh, car.partMatrices) }
        var f = SceneFrame(view: view, proj: proj, camPos: eye, time: Float(engine.time), meshes: meshes, car: carDraw, carShadow: engine.car?.shadowMatrix)
        f.extraCars = engine.extraCars + players.dropFirst().map { ($0.car.mesh, $0.car.partMatrices, $0.car.shadowMatrix) }
        return f
    }

    // MARK: HUD (RenderOverlay)

    func encodeOpaque(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {}
    func encodeTransparent(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {}
    func encodeScreen(_ cb: MTLCommandBuffer, target: MTLTexture) {
        guard active else { return }
        if feRenderers[currentDisplay] == nil { feRenderers[currentDisplay] = try? FERenderer(device: engine.device, outputFormat: .bgra8Unorm) }
        guard let fr = feRenderers[currentDisplay] else { return }
        let W = Float(target.width), H = Float(target.height)
        var batches: [FEBatch] = []
        for p in players where p.display == currentDisplay {
            guard let h = p.hud else { continue }
            let r = p.slot.hudRect
            let px = SIMD4(r.x * W, r.y * H, r.w * W, r.h * H)
            let L = FELayout(width: target.width, height: target.height, rect: px, canvas: p.slot.canvas)
            let sc = p.slot.clip ? MTLScissorRect(x: Int(px.x), y: Int(px.y), width: max(1, Int(px.z)), height: max(1, Int(px.w))) : nil
            batches.append(FEBatch(packages: h.packages, layout: L, scissor: sc))
        }
        if !batches.isEmpty { fr.encode(cb, target: target, batches: batches) }
    }

    // MARK: Mandos desenchufados

    private func checkConnections() {
        guard active else { return }
        for p in players where !p.disconnected && !p.autopilot && !p.device.connected {
            p.disconnected = true
            print("Pantalla partida: el mando del jugador \(p.index + 1) se ha desconectado")
        }
        if unplugged == nil, let p = players.first(where: \.disconnected) { showUnplugged(p) }
    }

    /// ControllerUnplugged.fng con el número del jugador; la partida queda en pausa (estado modal de la interfaz).
    private func showUnplugged(_ p: MPPlayer) {
        for q in players { q.device.quiet() }
        guard let ui = engine.ui, let s = ui.push("ControllerUnplugged") else { unplugged = nil; return }
        let fmt = ui.assets.string(0x54eefec2) ?? "Se ha extraído el mando. Vuelve a insertar^el mando en el puerto de mando %d,^y pulsa START para continuar."
        s.pkg.printf(s.pkg.find(0xb244cf71), fmt.replacingOccurrences(of: "%d", with: "\(p.index + 1)"))
        ui.state = .modal
        ui.modalAccept = nil; ui.modalBack = nil; ui.modalUpDown = nil
        unplugged = (s, p)
    }

    /// Espera START en un mando libre (o en el mismo, si vuelve) para el jugador desconectado.
    private func pollReconnect() {
        guard let (s, p) = unplugged else { return }
        let bound = Set(players.filter { !$0.disconnected }.compactMap(\.device.key))
        for d in PlayerDeviceList.shared.all {
            if let k = d.key, bound.contains(k) { continue }
            if case .keyboard = d.source, players.contains(where: { !$0.disconnected && $0.device.kind == .keyboard }) { continue }
            let m = d.readMenu(keys: engine.keys, prefix: "mp.reconnect.")
            guard m.start || m.accept else { continue }
            p.device = d
            p.disconnected = false
            d.setPlayer(p.index, color: p.color)
            MenuOwners.allowed = Set(players.compactMap(\.device.key))
            print("Pantalla partida: jugador \(p.index + 1) vuelve con \(d.label(spanish: true))")
            hideUnplugged()
            if engine.ui?.screens.last === s || engine.ui?.screens.contains(where: { $0 === s }) == true {
                engine.ui?.screens.removeAll { $0 === s }
                if engine.ui?.screens.isEmpty == true { engine.ui?.state = .game }
            }
            if let q = players.first(where: \.disconnected) { showUnplugged(q) }
            return
        }
    }

    /// Pruebas sin ventana (--split-test … --unplug-test): simula que el mando del jugador `i` se suelta y vuelve.
    func testUnplug(_ i: Int) { guard i < players.count else { return }; players[i].disconnected = true; showUnplugged(players[i]) }
    func testReconnect() {
        guard let (_, p) = unplugged else { return }
        p.disconnected = false
        hideUnplugged()
    }
    var isWaitingForController: Bool { unplugged != nil }

    private func hideUnplugged() {
        guard let (s, _) = unplugged else { return }
        unplugged = nil
        engine.ui?.screens.removeAll { $0 === s }
        if engine.ui?.state == .modal, engine.ui?.screens.isEmpty == true { engine.ui?.state = .game }
    }
}

/// HUD vacío para un hueco sin interfaz (pruebas sin datos de frontend/).
final class NullRaceHUD: RaceHUD {
    func beginRace(_ setup: RaceHUDSetup) {}
    func endRace() {}
    func showCountdown(_ value: Int) {}
    func setPosition(_ position: Int, of total: Int) {}
    func setLap(_ lap: Int, of total: Int) {}
    func setTimer(raceTime: Double, lapTime: Double?, bestLap: Double?) {}
    func setProgress(_ percent: Float) {}
    func setRacers(_ racers: [RaceHUDRacer]) {}
    func setNextCheckpoint(_ world: SIMD3<Float>?) {}
    func setRoute(_ points: [SIMD3<Float>]) {}
    func setRacerBlips(_ positions: [SIMD3<Float>]) {}
    func setSpeedtrap(totalMps: Float, passed: Int, of total: Int) {}
    func setDrag(shiftQuality: Int, engineTemp: Float) {}
    func showMessage(_ message: RaceHUDMessage) {}
    func showResults(_ results: RaceResults, onContinue: @escaping () -> Void) { onContinue() }
    func showBlacklist(_ rivals: [BlacklistRival], selected: Int, onChoice: @escaping (Int?) -> Void) { onChoice(nil) }
    func showCarWon(carName: String, rivalName: String, onContinue: @escaping () -> Void) { onContinue() }
    func dismissScreens() {}
}
