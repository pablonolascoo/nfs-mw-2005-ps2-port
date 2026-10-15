// Flujo de pantallas con los paquetes originales del juego:
//   MW_LS_Splash («Pulsa START») → MainMenu (Modo carrera, Serie desafío, Carrera rápida, Mis coches, Opciones)
//   → MainMenu_Sub de la carrera (Continuar / Empezar nuevo) → partida (HUD_SingleRace) ⇄ Pause_Main.
// Los logotipos de EA y la película de presentación son vídeos (pendiente): se saltan.
// Los menús de iconos son una copia de IconScroller / IconScrollerMenu [D: feIconScrollerMenu.cpp]; las opciones y sus
// textos e iconos salen de uiMain.cpp, uiCareerManager.cpp y uiPause.cpp [D].
import Foundation
import Metal
import simd

/// Carrusel de iconos de MW (IconScroller [D]).
final class IconScroller {
    struct Option { let tex: UInt32; let name: UInt32; let obj: FEObj; var xPos: Float; let w: Float; let h: Float; let bookEnd: Bool; var grey = false }
    let pkg: FEPackageRT
    private(set) var options: [Option] = []
    private(set) var current = 0
    private let width: Float = 350           // IconScrollerMenu: «ICON_SCROLL_REGION», 350 [D]
    private let spacing: Float = -5
    private var center = SIMD2<Float>(0, 0)
    private var addPos: Float = 0
    private var index = 1
    // AnimateCubic: valor que va hacia −XPos del elegido en 0,2 s [D]
    private var val: Float = 0, from: Float = 0, to: Float = 0, t: Float = 1
    /// IdleColor / FadeColor (ARGB): blanco en los menús; naranja 0xFFFFAE40 en las pantallas dentro del juego [D: uiRepSheetMain].
    var idleColor: UInt32 = 0xFFFFFFFF, fadeColor: UInt32 = 0x00FFFFFF
    var fade: Float = 1                      // fCurFadeTime / fMaxFadeTime (entrada y salida)
    var fadingIn = true, fadingOut = false
    private var fadeTime: Float = 0

    init(pkg: FEPackageRT) {
        self.pkg = pkg
        // El constructor del juego busca el objeto «master» (OPTION_MASTER), toma su centro y lo oculta; la decomp lo
        // llama scroll_region, pero el ensamblador pasa el 2.º argumento (a2 = "OPTION_MASTER", SLUS 0x280360/0x280468) [V].
        // En MainMenu el master está 17 unidades a la derecha de ICON_SCROLL_REGION: justo dentro de los corchetes [V].
        if let m = pkg.find("OPTION_MASTER") { center = SIMD2(m.pos.x, m.pos.y); pkg.setVisible(m, false) }
        else if let r = pkg.find("ICON_SCROLL_REGION") { center = SIMD2(r.pos.x, r.pos.y) }
        // ICON_SCROLL_REGION (BasePoly blanco 340×70) es una guía del editor: no se ve en el juego [I]
        if let r = pkg.find("ICON_SCROLL_REGION") { pkg.setVisible(r, false) }
        for _ in 0..<2 { add(tex: feHash("END_OF_SCROLLER"), name: 0, bookEnd: true) }
    }

    @discardableResult
    func add(tex: UInt32, name: UInt32, bookEnd: Bool = false) -> Bool {
        guard let o = pkg.find("option_\(index)") else { return false }
        index += 1
        o.handle = tex
        options.append(Option(tex: tex, name: name, obj: o, xPos: addPos, w: o.size.x, h: o.size.y, bookEnd: bookEnd))
        addPos += o.size.x + spacing
        if !bookEnd && current == 0 { current = options.count - 1 }
        return true
    }

    /// SetInitialPos: cierra con dos topes y coloca la selección sin animar.
    func finish(select i: Int = 0) {
        for _ in 0..<2 { add(tex: feHash("END_OF_SCROLLER"), name: 0, bookEnd: true) }
        current = 2 + max(0, min(i, options.count - 5))
        val = -options[current].xPos; to = val; from = val; t = 1
        pkg.setCurrentButton(options[current].obj)
        for i in options.indices { position(i) }
    }

    var currentOption: Option { options[current] }
    var currentIndex: Int { current - 2 }
    var atHead: Bool { current == 2 }
    var atTail: Bool { current == options.count - 3 }

    func scroll(_ d: Int) -> Bool {
        var n = current
        repeat { n += d } while n > 1 && n < options.count - 2 && options[n].grey
        guard n >= 2, n <= options.count - 3, n != current else { return false }
        current = n
        pkg.setCurrentButton(options[n].obj)
        from = val; to = -options[n].xPos; t = 0
        return true
    }

    /// IsGreyOut [D]: la opción se ve en gris (alfa 150) y el carrusel la salta.
    func greyOut(_ i: Int) { guard i < options.count else { return }; options[i].grey = true; position(i) }
    /// AnimateCubic.Snap [D]: sin animación hasta la selección.
    func snap() { val = to; from = to; t = 1; for i in options.indices { position(i) } }

    func update(dt: Float) {
        if t < 1 {
            t = min(1, t + dt / 0.2)
            let s = t * t * (3 - 2 * t)
            val = from + (to - from) * s
        }
        if fadingIn { fadeTime = min(9, fadeTime + dt * 60); if fadeTime >= 9 { fadingIn = false } }
        else if fadingOut { fadeTime = max(0, fadeTime - dt * 60) }
        else { fadeTime = 9 }
        fade = fadeTime / 9
        for i in options.indices { position(i) }
    }

    private func scale(_ x: Float) -> Float {
        let pos = center.x + width * 0.5, neg = center.x - width * 0.5
        if x < neg || x > pos { return 0 }
        if x < center.x - 1.5 { return (x - neg) / (width * 0.5) }
        if x > center.x + 1.5 { return (pos - x) / (width * 0.5) }
        return 1
    }

    /// PositionOption + UpdateFade [D].
    private func position(_ i: Int) {
        let op = options[i], o = op.obj
        var x = center.x + val + op.xPos
        var s = scale(x)
        let k = (1 - s) * (1 - s) * (1 - s)
        x += x < center.x ? op.w * k : -op.w * k
        pkg.setVisible(o, !(x < center.x - width * 0.5 || x > center.x + width * 0.5))
        s *= fade
        o.size = SIMD3(op.w * s, op.h * s, o.size.z)
        o.pos = SIMD3(x, center.y, o.pos.z)            // FEngSetCenter; alineación al medio (eSA_MIDDLE)
        // UpdateFade: mezcla IdleColor → FadeColor por canal con la escala; gris = alfa 150 [D]
        func ch(_ c: UInt32, _ sh: UInt32) -> Float { Float((c >> sh) & 0xFF) }
        func mix(_ sh: UInt32) -> UInt32 { UInt32(max(0, min(255, ch(idleColor, sh) * s + ch(fadeColor, sh) * (1 - s)))) }
        let a: UInt32 = op.grey ? 150 : mix(24)
        o.setColor((a << 24) | (mix(16) << 16) | (mix(8) << 8) | mix(0))
    }
}

/// Una pantalla: un paquete y, si es un menú de iconos, su carrusel.
final class FEScreen {
    let pkg: FEPackageRT
    var scroller: IconScroller?
    var actions: [() -> Void] = []
    var leaving = false
    var leaveAge = 0
    var onExit: (() -> Void)?
    var titleObjects: [FEObj] = []
    /// Lógica por fotograma de la pantalla (FEMSG_SCREEN_TICK del juego).
    var tick: (() -> Void)?
    /// Pantallas de los garajes (Garage/GarageMenus.swift): atrás, izquierda/derecha y ✕ propios.
    var onBack: (() -> Void)?
    var onLeftRight: ((Int) -> Void)?
    var onUpDown: ((Int) -> Void)?
    /// Cabecera propia (textos libres en vez de etiquetas del juego): recibe el índice de la opción elegida.
    var customHeader: ((Int) -> Void)?
    init(pkg: FEPackageRT) { self.pkg = pkg }

    /// Salida con las animaciones LEAVE del paquete (LEAVE_SCREEN → __LEAVE_ALL__) y después `then` [D: IconScrollerMenu].
    func leave(then: @escaping () -> Void) {
        guard !leaving else { return }
        leaving = true; leaveAge = 0; onExit = then
        scroller?.fadingOut = true
        pkg.post(FEH.leaveScreen)
        pkg.post(FEH.leaveAll)
    }
    func refreshHeader() {
        guard let sc = scroller else { return }
        if let ch = customHeader { ch(sc.currentIndex) } else { for t in titleObjects { pkg.setLabel(t, sc.currentOption.name) } }
        // IconScrollerMenu::RefreshHeader [D]: en los extremos avisa al paquete (las flechas de ese lado se apagan)
        if sc.atHead { pkg.post(0xD7118934) }
        if sc.atTail { pkg.post(0xB9B17747) }
    }
}

final class FEUI: RenderOverlay {
    /// garage: menús de un garaje del mundo (refugio, concesionario, taller) con la simulación parada.
    enum State { case splash, menu, game, pause, modal, garage }
    let assets: FEAssets
    let renderer: FERenderer
    unowned let engine: Engine
    var state: State = .splash
    var screens: [FEScreen] = []
    /// Paquetes encima del juego que no piden botones (BUSTED_OVERLAY…), con su tiempo restante en ms.
    var overlays: [(screen: FEScreen, ms: Int)] = []
    /// Pantalla modal (resultados, Lista Negra, recompensas…) y qué hacer al pulsar ✕ / ○.
    var modalAccept: (() -> Void)?
    var modalBack: (() -> Void)?
    var modalUpDown: ((Int) -> Void)?
    var hud: FEHud?
    var dragHud: FEHud?
    /// Escenario de prueba del HUD (--ui-test HUD-chase…); nil = datos reales.
    var hudScenario: String?
    var scenarioFrames = 0
    /// Contadores de arrestos/evasiones del fotograma anterior y datos de la última persecución (para las pantallas del final).
    var lastOutcome: (busted: Int, evaded: Int)?
    var lastPursuit: (seconds: Float, bounty: Int) = (0, 0)
    /// Dinero del jugador para la cabecera de la Lista Negra (lo pone la carrera profesional).
    var blacklistCash = 0
    var pendingBust: (ms: Int, seconds: Float)?
    private let keyboard = MenuKeyboard()
    private var orbit: Float = 0
    var drawCalls: Int { 0 }
    /// Pausa: la simulación se congela.
    var paused: Bool { state == .pause || state == .modal || state == .garage }
    /// Menús delante: el juego no recibe teclado ni mando.
    var capturesInput: Bool { state != .game }
    /// En la partida, ¿se ve el HUD? (cámara libre: no)
    var hudVisible = true
    /// Pruebas: HUD con una persecución de ejemplo (calor 3,4, 4 policías, medio camino de escapar).
    var hudDemo: Bool { get { hudScenario != nil } set { hudScenario = newValue ? "HUD-chase" : nil } }

    init?(engine: Engine, outputFormat: MTLPixelFormat) {
        guard let a = FEAssets(dataRoot: engine.data.root, device: engine.device, queue: engine.queue),
              let r = try? FERenderer(device: engine.device, outputFormat: outputFormat) else { return nil }
        assets = a; renderer = r; self.engine = engine
        hud = FEHud(assets: a)
        GarageSystem.attach(engine)   // escenario del frontend y garajes sin carga (Garage/)
    }

    var es: Bool { assets.language == "spanish" }

    // MARK: Pantallas

    func push(_ name: String) -> FEScreen? {
        guard let p = FEPackageRT(name: name, assets: assets) else { return nil }
        let s = FEScreen(pkg: p)
        p.onGameMessage = { [weak self, weak s] msg, obj in
            guard let self, let s else { return }
            self.gameMessage(msg, obj: obj, screen: s)
        }
        screens.append(s)
        // Entrada: todos los objetos que tengan APPEAR lo reproducen (los INIT ya están puestos) [I: MenuScreen]
        // Si el INIT encadena a otro script (p. ej. INIT → HIDE del dinero de la Lista Negra), manda el encadenado [V: datos]
        for o in p.all where o.findScript(FEH.appear) != nil && o.script?.id == FEH.initScript && o.script?.chainTo == nil { p.setScript(o, FEH.appear) }
        return s
    }
    private func popAll() { screens.removeAll() }

    func showSplash() {
        state = .splash
        popAll()
        engine.garages?.stage.enter(.mainFE)
        guard let s = push("MW_LS_Splash") else { showMainMenu(); return }
        let p = s.pkg
        // SplashScreen::SplashScreen [D]: sin grupo HD, sin licencia de Nintendo, «Pulsa START» con el texto del idioma
        p.setVisible(p.find(0x534cc377), false)
        p.setVisible(p.find(0x13cf446d), false); p.setVisible(p.find(0x8c0bd743), false)
        p.setVisible(p.find(0x4b98c4b9), false)
        if let g = p.find(0xc4df3ff2) { p.setVisible(g, true); for c in g.children where c.type == 5 || c.type == 2 { setLabelDeep(p, c, 0x9b580a55) } }
        // El paquete trae objetos de la demo y del PC: fuera
        for h: UInt32 in [0x9cdb8e9a, 0x50da3fd4, 0x9e24c2d8, 0xbde7fa72, 0x9c8fc0ee, 0xe893027f, 0x78da965b, 0xc6cc55a4] { p.setVisible(p.find(h), false) }
    }
    func setLabelDeep(_ p: FEPackageRT, _ o: FEObj, _ label: UInt32) {
        if o.type == 2 { p.setLabel(o, label) }
        for c in o.children { setLabelDeep(p, c, label) }
    }

    func iconMenu(_ name: String, title: UInt32?, options: [(UInt32, UInt32, () -> Void)], select: Int = 0) -> FEScreen? {
        guard let s = push(name) else { return nil }
        let sc = IconScroller(pkg: s.pkg)
        for (tex, nm, act) in options { if sc.add(tex: tex, name: nm) { s.actions.append(act) } }
        sc.finish(select: select)
        s.scroller = sc
        s.titleObjects = [s.pkg.find(0x5E7B09C9), s.pkg.find(0x0DFB7A2E)].compactMap { $0 }
        // Los nombres «__X__» del editor se guardan sin los guiones bajos: hash de «TITLE_GROUP» [V]
        if let title, let tg = s.pkg.find("TITLE_GROUP") { setLabelDeep(s.pkg, tg, title) }
        s.refreshHeader()
        return s
    }

    func showMainMenu() {
        let fromSplash = state == .splash
        state = .menu
        popAll()
        engine.ui_enterFrontend()
        // Fondo: el garaje del frontend (PLATFORMCRIB) con el coche del jugador; cámara de la pantalla «mainmenu» [D]
        if let st = engine.garages?.stage {
            if !st.active || !fromSplash { st.enter(.mainFE, animate: !st.active) }
            st.screenAngle("mainmenu")
        }
        // UIMain::Setup [D] (sin tarjeta de memoria: sin gestor de perfiles)
        _ = iconMenu("MainMenu", title: 0xb24aae58, options: [
            (0x03704f3d, 0x5815a2b5, { [weak self] in self?.leaveTop { self?.showCareerMenu() } }),
            (0x9a962438, 0xcc8cb746, { [weak self] in self?.comingSoon(0xcc8cb746) }),
            (0x4e6fbb02, 0x54020a7a, { [weak self] in self?.leaveTop { if let s = self { QuickRaceFlow.shared.open(s) } } }),   // UI/QuickRaceFlow.swift
            (0xb0c46023, 0x1afd5be6, { [weak self] in self?.comingSoon(0x1afd5be6) }),
            (0x3058fe37, 0x19a8c0af, { [weak self] in self?.comingSoon(0x19a8c0af) }),
        ])
        // Sin perfil cargado (no hay tarjeta de memoria): sin estadísticas ni nombre de jugador [D: UIMain::UpdateProfileData]
        if let p = screens.last?.pkg {
            for h: UInt32 in [0xdabec5f4, 0xe2feb6e2, feHash("GAME STATS GROUP"), feHash("NAME_GROUP"), 0xd6463100] { for o in p.findAll(h) { p.setVisible(o, false) } }
        }
    }

    func showCareerMenu() {
        state = .menu
        popAll()
        if let st = engine.garages?.stage {
            if !st.active { st.enter(.mainFE, animate: false) }
            st.screenAngle("career_manager")
        }
        // uiCareerManager [D]: Continuar / Empezar nuevo
        _ = iconMenu("MainMenu_Sub", title: 0x5815a2b5, options: [
            (0xC1C089CE, 0xE072DB21, { [weak self] in self?.leaveTop { self?.startGame(); Career.shared.start(); self?.careerCar() } }),
            (0xE7353BE7, 0x17E18F87, { [weak self] in self?.leaveTop { self?.startGame(); Career.shared.newGame(); self?.careerCar() } }),
        ])
    }

    /// El coche de la partida (con su tuneo del taller, Garage/CarTuning.swift) en el sitio del de por defecto.
    private func careerCar() {
        let key = Career.shared.save.currentCar
        if key != Config.playerPreset || CarTuning.tune(key) != nil { CarTuning.replacePlayerCar(engine, key: key) }
    }

    /// Carrera rápida: de momento una prueba al azar de las que el juego marca como AvailableQR
    /// (la pantalla de elección de prueba del original está pendiente).
    func startQuickRace() {
        startGame()
        if let e = QuickRace.shared.events.randomElement() { QuickRace.shared.start(eventID: e.eventId) }
    }

    func startGame() {
        popAll()
        state = .game
        engine.garages?.stage.leave()
        engine.ui_startGame()
    }

    /// Solo el HUD, sin tocar el coche ni la cámara (prueba sin ventana --traffic-test).
    func startHUDOnly() { popAll(); state = .game; engine.garages?.stage.leave() }

    func showPause() {
        guard state == .game else { return }
        state = .pause
        // uiPause.cpp, zona libre [D]: Volver a la zona libre, Reiniciar, Opciones, Salir. Título: FEngSetLanguageHash(0x863404B5, …) [D]
        let s = iconMenu("Pause_Main", title: nil, options: [
            (0x12BB5EA2, 0x01BD185C, { [weak self] in self?.leaveTop { self?.resume() } }),
            (0xB295A6B6, 0xF893AFA1, { [weak self] in self?.leaveTop { self?.engine.ui_restart(); self?.resume() } }),
            (0x520DE4E3, 0x2B5A03A8, { [weak self] in self?.comingSoon(0x2B5A03A8) }),
            (0x4C9E34E6, 0x690E9B7C, { [weak self] in self?.leaveTop { self?.showMainMenu() } }),
        ])
        if let p = s?.pkg, let t = p.find(0x863404B5) { setLabelDeep(p, t, 0x6C839FBE) }
    }

    func resume() { popAll(); state = .game }
    func leaveTopScreen(_ then: @escaping () -> Void) { leaveTop(then) }

    private func leaveTop(_ then: @escaping () -> Void) { screens.last?.leave(then: then) }

    /// Cuadro de diálogo del juego (Dialog.fng) con un texto libre y «Aceptar»; `then` al cerrarlo.
    func messageDialog(title: UInt32, text: String, then: (() -> Void)? = nil) {
        guard let s = push("Dialog") else { then?(); return }
        let p = s.pkg
        for o in p.findAll(0x42adb44c) + p.findAll(0xa2fad351) { p.setLabel(o, title) }
        if let m = p.find(0x1e2640fa) { p.printf(m, text) }
        p.post(0x792bc959)
        let b1 = p.find("Button1")
        for b in [p.find("Button2"), p.find("Button3"), p.find(0xfb8b67d1), p.find(0xfde09072)] { p.setVisible(b, false) }
        if let t = p.find(0xf9363f30) { p.setLabel(t, 0x2b65a216) }
        if let b1 { p.setScript(b1, FEH.show); p.setCurrentButton(b1) }
        let close: () -> Void = { [weak self, weak s] in s?.leave { self?.screens.removeAll { $0 === s }; then?() } }
        s.actions = [close]
        s.onBack = close
    }

    /// «Próximamente» con el cuadro de diálogo del propio juego (Dialog.fng) y el nombre de la opción como título.
    private func comingSoon(_ title: UInt32) {
        guard screens.last?.pkg.name.lowercased().hasPrefix("dialog") != true, let s = push("Dialog") else { return }
        let p = s.pkg
        for o in p.findAll(0x42adb44c) + p.findAll(0xa2fad351) { p.setLabel(o, title) }
        if let m = p.find(0x1e2640fa) { p.printf(m, es ? "Próximamente." : "Coming soon.") }
        p.post(0x792bc959)    // tamaño del cuadro para un botón [I]
        let b1 = p.find("Button1")
        for b in [p.find("Button2"), p.find("Button3"), p.find(0xfb8b67d1), p.find(0xfde09072)] { p.setVisible(b, false) }
        if let t = p.find(0xf9363f30) { p.setLabel(t, 0x2b65a216) }   // «Aceptar»
        if let b1 { p.setScript(b1, FEH.show); p.setCurrentButton(b1) }
        s.actions = [{ [weak self, weak s] in s?.leave { self?.screens.removeAll { $0 === s } } }]
    }

    // MARK: Mensajes del paquete al juego

    private func gameMessage(_ msg: UInt32, obj: FEObj?, screen: FEScreen) { }

    // MARK: Fotograma

    func update(dt: Float) {
        let ms = Int((dt * 1000).rounded())
        var m = keyboard.poll(keys: engine.keys)
        m.merge(Controllers.shared.pollMenu())
        switch state {
        case .modal:
            if let s = screens.last, !s.leaving {
                if m.accept, let f = modalAccept { f() }
                else if m.back, let f = modalBack { f() }
                else if m.up { modalUpDown?(-1) } else if m.down { modalUpDown?(1) }
            }
        case .game:
            if m.start { showPause() }
        case .splash:
            if let s = screens.last, s.pkg.age > 600, m.accept || m.start {
                s.leave { [weak self] in self?.showMainMenu() }
            }
        case .menu, .pause, .garage:
            if let s = screens.last, !s.leaving {
                if let f = s.onLeftRight { if m.left { f(-1) } else if m.right { f(1) } }
                if let f = s.onUpDown { if m.up { f(-1) } else if m.down { f(1) } }
                if let sc = s.scroller {
                    if m.left, sc.scroll(-1) { s.refreshHeader() }
                    if m.right, sc.scroll(1) { s.refreshHeader() }
                    if m.accept, !sc.currentOption.grey {
                        s.pkg.post(FEH.buttonPressed, target: sc.currentOption.obj.guid)
                        let i = sc.currentIndex
                        if i >= 0 && i < s.actions.count { s.actions[i]() }
                    }
                } else if m.accept, let a = s.actions.first { a() }
                if m.back || (state == .pause && m.start) {
                    if let b = s.onBack { b() }
                    else if s.scroller == nil { s.actions.first?() }
                    else if state == .pause { s.leave { [weak self] in self?.resume() } }
                    else if s.pkg.name.hasPrefix("MainMenu_Sub") { s.leave { [weak self] in self?.showMainMenu() } }
                    else if s.pkg.name.hasPrefix("MainMenu") { s.leave { [weak self] in self?.showSplash() } }
                }
            }
        }
        // Animaciones y salidas
        for s in screens {
            s.scroller?.update(dt: dt)
            s.pkg.update(ms: ms)
            s.tick?()
            if s.leaving {
                s.leaveAge += ms
                if (s.leaveAge > 250 && !s.pkg.animating) || s.leaveAge > 1500, let done = s.onExit { s.onExit = nil; done() }
            }
        }
        // Modo panorámico del HUD según el aspecto de la pantalla (FEngHud::SetWideScreenMode)
        let hw = 240 * max(4.0 / 3, engine.aspect)
        hud?.setWidescreen(visibleHalfWidth: hw); dragHud?.setWidescreen(visibleHalfWidth: hw)
        tickPendingBust(ms: ms)
        let hudOn = state == .game && hudVisible && overlays.isEmpty && (engine.mode == .drive || AITestDriver.current != nil)
        var input = engine.ui_hudInput()
        if let sc = hudScenario { input = scenarioInput(sc, input) }
        pursuitOutcome(input)
        // HUD_Drag en las pruebas de aceleración; HUD_SingleRace en el resto [D: HudResourceManager::GetHudFengName]
        let drag = hud?.race?.setup.kind == .drag
        if drag, dragHud == nil, let a = Optional(assets) { dragHud = FEHud(assets: a, kind: .drag) }
        if drag, let d = dragHud { d.race = hud?.race }
        hud?.update(ms: ms, input: input, visible: hudOn && !drag)
        dragHud?.update(ms: ms, input: input, visible: hudOn && drag)
        for (k, o) in overlays.enumerated().reversed() {
            overlays[k].ms -= ms
            o.screen.pkg.update(ms: ms)
            if overlays[k].ms <= 0 { overlays.remove(at: k) }
        }
        // Menús del frontend: la cámara del motor se queda sobre el refugio 1 (así la ciudad sigue cargada para empezar sin
        // esperas); lo que se ve es el escenario del garaje (Garage/FEGarage.swift)
        if state == .menu || state == .splash {
            orbit += dt * 0.05
            engine.ui_frontendCamera(angle: orbit)
        }
    }

    var packagesToDraw: [FEPackageRT] {
        var l: [FEPackageRT] = []
        if let h = hud, h.pkg.visible { l.append(h.pkg) }
        if let h = dragHud, h.pkg.visible { l.append(h.pkg) }
        l.append(contentsOf: overlays.map(\.screen.pkg))
        l.append(contentsOf: screens.map(\.pkg))
        return l
    }

    // MARK: RenderOverlay

    func encodeOpaque(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {}
    func encodeTransparent(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {}
    func encodeScreen(_ cb: MTLCommandBuffer, target: MTLTexture) {
        if let path = ProcessInfo.processInfo.environment["ROCKPORT_FE_DUMP"] {
            var all = ""
            for p in packagesToDraw { let tmp = path + ".part"; renderer.dump(p, to: tmp); all += (try? String(contentsOfFile: tmp, encoding: .utf8)) ?? "" }
            try? all.write(toFile: path, atomically: true, encoding: .utf8)
        }
        renderer.encode(cb, target: target, packages: packagesToDraw)
    }

    // MARK: Pruebas (--ui-test)

    /// Muestra una pantalla concreta para capturas: «Splash», «MainMenu», «Career», «Pause», «HUD», «Dialog» o cualquier paquete.
    func showForTest(_ test: String) {
        // «MainMenu@2»: deja elegida la 3.ª opción del carrusel (pruebas del IconScroller)
        let parts = test.split(separator: "@", maxSplits: 1).map(String.init)
        let what = parts[0]
        defer {
            if parts.count > 1, let n = Int(parts[1]), let s = screens.last, let sc = s.scroller {
                for _ in 0..<max(0, n) { _ = sc.scroll(1) }
                sc.snap(); s.refreshHeader()
            }
        }
        switch what.lowercased() {
        case "splash", "mw_ls_splash": showSplash()
        case "mainmenu", "main": showMainMenu()
        case "career", "mainmenu_sub": showCareerMenu()
        case "pause", "pause_main": startGame(); showPause()
        case "hud", "hud_singlerace": startGame()
        case _ where what.lowercased().hasPrefix("hud-") || what.lowercased().hasPrefix("race-")
                    || ["results", "blacklist", "carwon"].contains(what.lowercased()):
            startGame(); startScenario(what)
        case "dialog": showMainMenu(); comingSoon(0x54020a7a)
        default:
            state = .menu; popAll(); _ = push(what)
        }
    }
}
