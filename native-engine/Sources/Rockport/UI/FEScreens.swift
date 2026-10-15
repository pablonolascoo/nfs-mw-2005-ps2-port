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
    var fade: Float = 1                      // fCurFadeTime / fMaxFadeTime (entrada y salida)
    var fadingIn = true, fadingOut = false
    private var fadeTime: Float = 0

    init(pkg: FEPackageRT) {
        self.pkg = pkg
        if let r = pkg.find("ICON_SCROLL_REGION") { center = SIMD2(r.pos.x, r.pos.y); pkg.setVisible(r, false) }
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

    func scroll(_ d: Int) -> Bool {
        var n = current
        repeat { n += d } while n > 1 && n < options.count - 2 && options[n].grey
        guard n >= 2, n <= options.count - 3, n != current else { return false }
        current = n
        pkg.setCurrentButton(options[n].obj)
        from = val; to = -options[n].xPos; t = 0
        return true
    }

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
        let a = UInt32(max(0, min(255, 255 * s)))
        o.setColor(op.grey ? (150 << 24) | 0xFFFFFF : (a << 24) | 0xFFFFFF)
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
        for t in titleObjects { pkg.setLabel(t, sc.currentOption.name) }
    }
}

final class FEUI: RenderOverlay {
    enum State { case splash, menu, game, pause }
    let assets: FEAssets
    let renderer: FERenderer
    unowned let engine: Engine
    private(set) var state: State = .splash
    private var screens: [FEScreen] = []
    private(set) var hud: FEHud?
    private let keyboard = MenuKeyboard()
    private var orbit: Float = 0
    var drawCalls: Int { 0 }
    /// Pausa: la simulación se congela.
    var paused: Bool { state == .pause }
    /// Menús delante: el juego no recibe teclado ni mando.
    var capturesInput: Bool { state != .game }
    /// En la partida, ¿se ve el HUD? (cámara libre: no)
    var hudVisible = true
    /// Pruebas: HUD con una persecución de ejemplo (calor 3,4, 4 policías, medio camino de escapar).
    var hudDemo = false

    init?(engine: Engine, outputFormat: MTLPixelFormat) {
        guard let a = FEAssets(dataRoot: engine.data.root, device: engine.device, queue: engine.queue),
              let r = try? FERenderer(device: engine.device, outputFormat: outputFormat) else { return nil }
        assets = a; renderer = r; self.engine = engine
        hud = FEHud(assets: a)
    }

    var es: Bool { assets.language == "spanish" }

    // MARK: Pantallas

    private func push(_ name: String) -> FEScreen? {
        guard let p = FEPackageRT(name: name, assets: assets) else { return nil }
        let s = FEScreen(pkg: p)
        p.onGameMessage = { [weak self, weak s] msg, obj in
            guard let self, let s else { return }
            self.gameMessage(msg, obj: obj, screen: s)
        }
        screens.append(s)
        // Entrada: todos los objetos que tengan APPEAR lo reproducen (los INIT ya están puestos) [I: MenuScreen]
        for o in p.all where o.findScript(FEH.appear) != nil && o.script?.id == FEH.initScript { p.setScript(o, FEH.appear) }
        return s
    }
    private func popAll() { screens.removeAll() }

    func showSplash() {
        state = .splash
        popAll()
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
    private func setLabelDeep(_ p: FEPackageRT, _ o: FEObj, _ label: UInt32) {
        if o.type == 2 { p.setLabel(o, label) }
        for c in o.children { setLabelDeep(p, c, label) }
    }

    private func iconMenu(_ name: String, title: UInt32?, options: [(UInt32, UInt32, () -> Void)], select: Int = 0) -> FEScreen? {
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
        state = .menu
        popAll()
        engine.ui_enterFrontend()
        // UIMain::Setup [D] (sin tarjeta de memoria: sin gestor de perfiles)
        _ = iconMenu("MainMenu", title: 0xb24aae58, options: [
            (0x03704f3d, 0x5815a2b5, { [weak self] in self?.leaveTop { self?.showCareerMenu() } }),
            (0x9a962438, 0xcc8cb746, { [weak self] in self?.comingSoon(0xcc8cb746) }),
            (0x4e6fbb02, 0x54020a7a, { [weak self] in self?.comingSoon(0x54020a7a) }),
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
        // uiCareerManager [D]: Continuar / Empezar nuevo
        _ = iconMenu("MainMenu_Sub", title: 0x5815a2b5, options: [
            (0xC1C089CE, 0xE072DB21, { [weak self] in self?.leaveTop { self?.startGame() } }),
            (0xE7353BE7, 0x17E18F87, { [weak self] in self?.leaveTop { self?.startGame() } }),
        ])
    }

    func startGame() {
        popAll()
        state = .game
        engine.ui_startGame()
    }

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

    private func leaveTop(_ then: @escaping () -> Void) { screens.last?.leave(then: then) }

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
        case .game:
            if m.start { showPause() }
        case .splash:
            if let s = screens.last, s.pkg.age > 600, m.accept || m.start {
                s.leave { [weak self] in self?.showMainMenu() }
            }
        case .menu, .pause:
            if let s = screens.last, !s.leaving {
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
                    if s.scroller == nil { s.actions.first?() }
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
            if s.leaving {
                s.leaveAge += ms
                if (s.leaveAge > 250 && !s.pkg.animating) || s.leaveAge > 1500, let done = s.onExit { s.onExit = nil; done() }
            }
        }
        if let hud {
            let visible = state == .game && hudVisible && engine.mode == .drive
            var input = engine.ui_hudInput()
            if hudDemo {
                input.heat = 3.4; input.inPursuit = true; input.timeUntilBusted = -0.35; input.pursuitSeconds = 83
                input.copsEngaged = 4; input.copsDestroyed = 2; input.copsDamaged = 3; input.costToState = 12_750
                input.rpm = max(input.rpm, 6100); input.speed = max(input.speed, 41.7); input.gear = max(input.gear, 4); input.nos = 0.7
            }
            hud.update(ms: ms, input: input, visible: visible)
        }
        // Fondo de los menús: vuelta lenta sobre la ciudad
        if state == .menu || state == .splash {
            orbit += dt * 0.05
            engine.ui_frontendCamera(angle: orbit)
        }
    }

    var packagesToDraw: [FEPackageRT] {
        var l: [FEPackageRT] = []
        if let h = hud, h.pkg.visible { l.append(h.pkg) }
        l.append(contentsOf: screens.map(\.pkg))
        return l
    }

    // MARK: RenderOverlay

    func encodeOpaque(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {}
    func encodeTransparent(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {}
    func encodeScreen(_ cb: MTLCommandBuffer, target: MTLTexture) {
        renderer.encode(cb, target: target, packages: packagesToDraw)
    }

    // MARK: Pruebas (--ui-test)

    /// Muestra una pantalla concreta para capturas: «Splash», «MainMenu», «Career», «Pause», «HUD», «Dialog» o cualquier paquete.
    func showForTest(_ what: String) {
        switch what.lowercased() {
        case "splash", "mw_ls_splash": showSplash()
        case "mainmenu", "main": showMainMenu()
        case "career", "mainmenu_sub": showCareerMenu()
        case "pause", "pause_main": startGame(); showPause()
        case "hud", "hud_singlerace": startGame()
        case "dialog": showMainMenu(); comingSoon(0x54020a7a)
        default:
            state = .menu; popAll(); _ = push(what)
        }
    }
}
