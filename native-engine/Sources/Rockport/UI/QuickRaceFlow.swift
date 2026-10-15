// Carrera rápida con las pantallas del juego (paquetes FEng del disco) y la lógica de la decomp
// (Frontend/MenuScreens/Safehouse/quickrace/*.cpp [D]):
//
//   MainMenu ▸ Carrera rápida (MainMenu_Sub: Partida rápida / Carrera personalizada / Pantalla dividida)   UIQRMainMenu
//     ▸ tipo de prueba (MainMenu_Sub con los iconos de modo)                                                   UIQRModeSelect
//     ▸ Track_Select: prueba con su mapa (TRACK_MAP_<id> de TrackMaps.bin), zona, longitud, mejor tiempo       UIQRTrackSelect
//     ▸ Track_Options: dirección, vueltas, tráfico, rivales, dificultad, alcanzar (+ policía, extensión)       UIQRTrackOptions
//     ▸ PressStart: «Jugador N presiona START» (pantalla partida)                                              uiQRPressStart
//     ▸ Car_Select: lista de serie / carrera / bonificación, logotipo, barras; una por jugador                 UIQRCarSelect
//     ▸ carrera (MultiplayerRace) ▸ resultados ▸ vuelta a este menú
//
// Diferencias con el original (extensiones del port, documentadas en docs/es/19): 3 y 4 jugadores; la pantalla de unirse es
// una sola para todos (en el juego se pasa por PressStart dos veces, una por jugador); en pantalla partida se pueden poner
// rivales de la IA, tráfico y policía (el juego los quita); la prueba de peaje se puede elegir (el juego solo la tenía en
// una versión de demostración). En el juego L1/R1 cambian de zona y de lista; aquí también ▲/▼.
import Foundation
import Metal
import QuartzCore
import simd

final class QuickRaceFlow {
    static let shared = QuickRaceFlow()

    weak var ui: FEUI?
    var engine: Engine? { ui?.engine }
    var settings = QuickRaceData.loadSettings()
    /// 1 = carrera rápida normal; 2…4 = pantalla partida.
    var players = 1
    /// Jugadores unidos en PressStart (el primero es el jugador 1).
    var joined: [PlayerDevice] = []
    /// Coche elegido por cada jugador (QRCar.id).
    var chosen: [String] = []
    private(set) var screen: QRScreen?
    private var hooked = false
    /// Coche del jugador antes de entrar en la selección de coche (la vista previa lo sustituye un momento).
    private var savedCar: Car?
    private var savedMode: Engine.Mode = .fly
    var mode: RaceEvent.Kind { RaceEvent.Kind(rawValue: settings.mode) ?? .circuit }
    var split: Bool { players > 1 }
    /// Pruebas: se avanza solo con las teclas inyectadas.
    var testMode = false

    // MARK: Entrada

    /// Desde el menú principal (UI/FEScreens.swift, opción «Carrera rápida»).
    func open(_ ui: FEUI) {
        self.ui = ui
        if !hooked, let e = ui.engine as Engine? {
            hooked = true
            e.frameHooks.append { [weak self] dt in self?.step(dt: dt) }
            _ = e.enableRaces()
        }
        players = 1; joined = []; chosen = []
        MenuOwners.allowed = nil
        showMainMenu()
    }

    /// UIQRMainMenu [D]: Partida rápida, Carrera personalizada, Pantalla dividida.
    func showMainMenu() {
        guard let ui else { return }
        screen = nil
        ui.state = .menu
        ui.screens.removeAll()
        ui.engine.ui_enterFrontend()
        let s = ui.iconMenu("MainMenu_Sub", title: 0xCDF0CC03, options: [
            (0xE6313967, 0xB5E8F82F, { [weak self] in self?.leave { self?.quickPlay() } }),
            (0x2A49B5E2, 0x25BBD4C3, { [weak self] in self?.players = 1; self?.leave { self?.showModeSelect() } }),
            (0xF365B5F5, 0x841D518A, { [weak self] in self?.players = 2; self?.leave { self?.showModeSelect() } }),
        ], select: 1)
        if let p = s?.pkg { for h: UInt32 in [0x3C458C1, 0xB5C74226] { if let o = p.find(h) { ui.setLabelDeep(p, o, 0xCDF0CC03) } } }
    }

    /// UIQRModeSelect [D]: circuito, sprint, aceleración, eliminación (no en pantalla partida), radar; + peaje (extensión).
    func showModeSelect() {
        guard let ui else { return }
        screen = nil
        ui.state = .menu
        ui.screens.removeAll()
        var modes: [RaceEvent.Kind] = [.circuit, .sprint, .drag]
        if !split { modes.append(.knockout) }
        modes += [.speedtrap, .tollbooth]
        let opts: [(UInt32, UInt32, () -> Void)] = modes.map { k in
            (QuickRaceData.modeIcon(k), QuickRaceData.modeName(k), { [weak self] in
                self?.settings.mode = k.rawValue
                self?.leave { self?.showTrackSelect() }
            })
        }
        _ = ui.iconMenu("MainMenu_Sub", title: split ? 0x43C825ED : 0x1F203817, options: opts, select: modes.firstIndex(of: mode) ?? 0)
    }

    func showTrackSelect() { present(QRTrackSelect(flow: self)) }

    func showTrackOptions() { present(QRTrackOptions(flow: self)) }

    func showJoin() { present(QRJoinScreen(flow: self)) }

    func showCarSelect(player: Int) {
        if savedCar == nil, let e = engine { savedCar = e.car; savedMode = e.mode }
        present(QRCarSelect(flow: self, player: player))
    }

    /// Después de Track_Select: en pantalla partida, el sprint, la aceleración y el radar van directos a PressStart
    /// (UIQRTrackSelect::NotificationMessage [D]); el resto pasa por las opciones.
    func afterTrackSelect() {
        if split && (mode == .drag || mode == .sprint || mode == .speedtrap) { showJoin() } else { showTrackOptions() }
    }
    func afterOptions() { if split { showJoin() } else { joined = []; showCarSelect(player: 0) } }

    /// Pantalla propia en la interfaz (paquete del juego + controlador de esta carpeta).
    private func present(_ s: QRScreen?) {
        guard let ui, let s else { return }
        screen = s
        ui.state = .menu
        ui.screens.removeAll { $0 !== s.fe }
        if !ui.screens.contains(where: { $0 === s.fe }) { ui.screens.append(s.fe) }
    }

    /// Sale de la pantalla de arriba con sus animaciones y luego `then`.
    func leave(_ then: @escaping () -> Void) {
        guard let s = ui?.screens.last else { then(); return }
        s.leave(then: then)
    }

    // MARK: Fotograma

    private var menuState: [ObjectIdentifier: MenuButtons] = [:]

    private func step(dt: Float) {
        guard let ui, let e = engine else { return }
        // Los flancos de todos los dispositivos se leen siempre (así no se cuela una pulsación vieja al cambiar de pantalla)
        var per: [(PlayerDevice, MenuButtons)] = []
        for d in PlayerDeviceList.shared.all { per.append((d, d.readMenu(keys: e.keys, prefix: "qr."))) }
        guard let s = screen, ui.state == .menu, ui.screens.last === s.fe, !s.fe.leaving else { return }
        s.update(dt: dt)
        if s.perDevice { s.handle(devices: per); return }
        // Con jugadores unidos, los menús los lleva el jugador 1 (o el jugador de la selección de coche)
        var m = MenuButtons()
        let owner = s.owner
        for (d, b) in per where owner == nil || owner!.same(d) { m.merge(b) }
        if m.any { s.handle(m) }
    }

    // MARK: Carrera

    /// UIQRMainMenu QuickPlay [D: va a Quick_Race_Brief con una prueba y un coche ya elegidos]: prueba desbloqueada al azar
    /// de cualquier tipo con el último coche elegido.
    func quickPlay() {
        guard let e = engine, let sys = RaceSystem.attach(e) else { return }
        players = 1; joined = []
        let save = Career.shared.save
        let pool = [RaceEvent.Kind.circuit, .sprint, .speedtrap, .knockout, .drag].flatMap {
            QuickRaceData.tracks(db: sys.db, mode: $0, region: 3, save: save).filter { !$0.locked }
        }
        guard let t = pool.randomElement() else { showMainMenu(); return }
        let carId = settings.cars.first ?? "M3GTRCAREERSTART"
        chosen = [carId]
        start(event: t.event)
    }

    /// Todo elegido: monta los coches y empieza.
    func startRace() {
        guard let e = engine, let sys = RaceSystem.attach(e) else { return }
        var ev: RaceEvent?
        if let id = settings.eventByMode[mode.rawValue] { ev = sys.db.event(id) }
        if let base = ev, settings.reverse, let r = QuickRaceData.reversed(base, db: sys.db) { ev = r }
        guard let event = ev else { showTrackSelect(); return }
        start(event: event)
    }

    private func start(event: RaceEvent) {
        guard let e = engine else { return }
        settings.cars = chosen
        QuickRaceData.saveSettings(settings)
        if let c = savedCar { e.car = c }
        e.mode = savedMode
        savedCar = nil
        QRCarPreview.shared.clear()
        var entries: [MPEntry] = []
        let n = split ? joined.count : 1
        for i in 0..<n {
            let id = i < chosen.count ? chosen[i] : "M3GTRCAREERSTART"
            guard let car = MultiplayerRace.makeCar(engine: e, id: id, paint: MultiplayerRace.stockPaints[i % 4]) else { continue }
            let dev = split ? joined[i] : PlayerDeviceList.shared.keyboard
            let name = split ? ((ui?.es ?? true) ? "JUGADOR \(i + 1)" : "PLAYER \(i + 1)") : (RaceSystem.shared?.playerName ?? "TÚ")
            entries.append(MPEntry(device: dev, car: car, name: name))
        }
        guard !entries.isEmpty else { showMainMenu(); return }
        screen = nil
        let displays = split ? MultiplayerSettings.shared.displaysFor(players: entries.count) : 1
        print("Carrera rápida: \(event.eventId) (\(event.kind.rawValue)) · \(entries.count) jugador(es) · \(displays) pantalla(s) · coches \(chosen.prefix(entries.count).joined(separator: ", "))")
        let session = MultiplayerRace.start(engine: e, event: event, entries: entries, settings: settings, displays: displays,
                                            autopilot: testMode) { [weak self] _ in
            DispatchQueue.main.async { self?.afterRace() }
        }
        if session == nil { showMainMenu() }
    }

    /// Tras los resultados: de vuelta al menú de la carrera rápida (como el juego, que vuelve al frontend).
    private func afterRace() {
        MenuOwners.allowed = nil
        for d in joined { d.setPlayer(nil, color: nil) }
        if testMode { return }
        showMainMenu()
    }

    // MARK: Prueba sin ventana

    /// `--quickrace-test [--split N] [--screenshot base.png]`: teclas inyectadas como un jugador; captura de cada pantalla.
    static func runTest(_ o: Options, device: MTLDevice, engine: Engine) {
        guard let ui = engine.enableUI(outputFormat: .bgra8Unorm) else { fputs("Interfaz no disponible\n", stderr); exit(1) }
        _ = engine.enableRaces()
        Career.shared.persist = false
        let flow = QuickRaceFlow.shared
        flow.testMode = true
        flow.settings = QRSettings()
        let splitN = MPTestOptions.value("--split").flatMap(Int.init) ?? 0
        let (W, H) = o.size
        engine.aspect = Float(W) / Float(H)
        let target = makeTarget(device, W, H)
        let base = (o.screenshot.map { ($0 as NSString).deletingPathExtension }) ?? "qr"
        var clock = 0.0
        func frame(_ dt: Float = 1.0 / 60) {
            clock += 1.0 / 60
            let cb = engine.queue.makeCommandBuffer()!
            engine.frame(cb: cb, target: target, dt: dt, scale: 1, now: clock)
            cb.commit(); cb.waitUntilCompleted()
        }
        func run(_ seconds: Double) { for _ in 0..<Int(seconds * 60) { frame() } }
        func press(_ key: UInt16) { engine.keys.insert(key); frame(); frame(); engine.keys.remove(key); run(0.25) }
        func shot(_ name: String) { writePNG(target, device: device, queue: engine.queue, path: "\(base)-\(name).png") }
        func where_() -> String { "\(ui.state) · \(ui.screens.map(\.pkg.name).joined(separator: ">")) · \(flow.screen.map { "\(type(of: $0))" } ?? "-")" }
        let enter: UInt16 = 36, right: UInt16 = 124, left: UInt16 = 123, down: UInt16 = 125, up: UInt16 = 126
        _ = left; _ = up

        ui.showMainMenu()
        waitForStreaming(engine) { frame(0) }
        flow.open(ui)
        run(1.5); shot("1-menu"); print("1 · \(where_())")
        if splitN > 1 { press(right) }                         // Pantalla dividida
        press(enter); run(1.2); shot("2-modo"); print("2 · \(where_())")
        press(enter); run(1.5); shot("3-pista"); print("3 · \(where_())")
        press(right); run(1.2); shot("3b-pista"); print("3b · \(where_())")
        press(down); run(1.2); shot("3c-zona"); print("3c · \(where_())")
        press(enter); run(1.5); shot("4-opciones"); print("4 · \(where_())")
        press(down); press(right); run(0.5); shot("4b-opciones"); print("4b · \(where_())")
        press(enter); run(1.5)
        if splitN > 1 {
            // PressStart: el teclado y mandos de prueba (en la máquina sin mandos, el mismo teclado hace de todos)
            shot("5-unirse-0"); print("5 · \(where_())")
            if let j = flow.screen as? QRJoinScreen {
                for _ in 0..<splitN { j.testJoin(PlayerDeviceList.shared.keyboard); run(0.6) }
                shot("5-unirse"); print("5b · \(where_()) · \(flow.joined.count) unidos")
                j.confirm()
            }
            run(1.5)
        }
        for p in 0..<max(1, splitN) {
            shot("6-coche\(p + 1)"); print("6.\(p + 1) · \(where_())")
            press(right); run(1.5); shot("6-coche\(p + 1)b")
            press(enter); run(1.5)
        }
        run(4); shot("7-carrera"); print("7 · \(where_()) · sesión \(RaceSystem.shared?.session?.event.eventId ?? "ninguna")")
        run(6); shot("8-carrera")
        let ok = RaceSystem.shared?.session != nil
        print(ok ? "Carrera rápida: recorrido completo hasta la salida" : "Carrera rápida: NO llegó a la carrera")
        RaceSystem.shared?.abandon()
        exit(ok ? 0 : 2)
    }
}

/// Controlador de una pantalla propia (un paquete del juego que la interfaz dibuja y anima).
class QRScreen {
    let fe: FEScreen
    unowned let flow: QuickRaceFlow
    var pkg: FEPackageRT { fe.pkg }
    var ui: FEUI { flow.ui! }
    /// Quién maneja la pantalla (nil = cualquiera).
    var owner: PlayerDevice? { flow.joined.first }
    /// La pantalla de unirse lee cada mando por separado.
    var perDevice: Bool { false }

    init?(flow: QuickRaceFlow, package: String) {
        self.flow = flow
        guard let ui = flow.ui else { return nil }
        ui.screens.removeAll()
        guard let s = ui.push(package) else { return nil }
        fe = s
    }

    func handle(_ m: MenuButtons) {}
    func handle(devices: [(PlayerDevice, MenuButtons)]) {}
    func update(dt: Float) {}

    // Ayudas FEng (FEngSetTopLeft, FEngSetVisible…)
    func obj(_ h: UInt32) -> FEObj? { pkg.find(h) }
    func show(_ h: UInt32, _ on: Bool) { for o in pkg.findAll(h) { pkg.setVisible(o, on) } }
    /// FEPrintf: si el objeto es un grupo (texto con su sombra), a todos sus textos.
    func text(_ h: UInt32, _ s: String) { for o in pkg.findAll(h) { printDeep(o, s) } }
    func printDeep(_ o: FEObj, _ s: String) {
        if o.type == 2 { pkg.printf(o, s) }
        for c in o.children { printDeep(c, s) }
    }
    func label(_ h: UInt32, _ l: UInt32) { for o in pkg.findAll(h) { ui.setLabelDeep(pkg, o, l) } }
    func str(_ h: UInt32, _ fallback: String) -> String { ui.assets.string(h) ?? fallback }
    var es: Bool { ui.es }
}
