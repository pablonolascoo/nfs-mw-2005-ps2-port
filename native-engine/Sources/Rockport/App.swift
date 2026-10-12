// La app: una ventana sin bordes que ocupa toda la pantalla, sin barra de menús ni Dock, con una MTKView.
// Resolución de salida = tamaño real de la pantalla (píxeles Retina). La escena se dibuja a una fracción
// variable de esa resolución (resolución dinámica) para mantener 60 fps; vsync activado.
import AppKit
import MetalKit
import QuartzCore

final class GameView: MTKView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}      // el motor lee las teclas con un monitor (evita el pitido)
}

final class AppDelegate: NSObject, NSApplicationDelegate, MTKViewDelegate {
    let options: Options
    var window: NSWindow!
    var view: GameView!
    var engine: Engine!
    var last = CACurrentMediaTime()
    var scale: Float = 1
    var mouseCaptured = false
    // Medidas
    private let statsLock = NSLock()
    private var gpuMs: Double = 0
    private var gpuSamples: [Double] = []
    private var cpuSamples: [Double] = []
    private var frameSamples: [Double] = []
    private var lastLog = CACurrentMediaTime()
    private let start = CACurrentMediaTime()

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else { fatal("Este Mac no tiene GPU compatible con Metal.") }
        let (found, tried) = DataLocator.locate(arg: options.data, disc: options.disc)
        if found == nil, let conv = Bundle.main.url(forResource: "rockport-convert", withExtension: nil) {
            // Primer arranque de la app instalada: pedir la ISO y convertirla (Installer.swift)
            installer = InstallerController(converter: conv, destRoot: DataLocator.appSupport) { [weak self] dest in
                self?.installer = nil
                self?.startGame(device: device, root: dest)
            }
            installer?.show()
            return
        }
        guard let root = found else {
            fatal("No encuentro los datos convertidos de tu disco.\n\nBuscado en:\n" + tried.joined(separator: "\n") +
                  "\n\nGenera map-data con tools/ (bun run build-all <tu ISO>) y arranca con --data <carpeta>.")
        }
        startGame(device: device, root: root)
    }

    var installer: InstallerController?

    func startGame(device: MTLDevice, root: URL) {
        let data: GameData
        do { data = try GameData(root: root) } catch { fatal("No se pudo leer \(root.path)/world.json: \(error)") }
        print("Rockport · datos: \(root.path) · \(data.world.tiles.count) casillas · GPU: \(device.name)")

        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        view = GameView(frame: window.contentLayoutRect, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
        view.preferredFramesPerSecond = screen.maximumFramesPerSecond
        (view.layer as? CAMetalLayer)?.displaySyncEnabled = true      // vsync
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 3
        view.autoResizeDrawable = true
        do { engine = try Engine(device: device, data: data, outputFormat: view.colorPixelFormat) } catch { fatal("Error al crear el motor: \(error)") }
        engine.renderer.gradeStrength = options.grade ?? engine.renderer.gradeStrength
        if let c = options.camera { engine.setCamera(x: c[0], y: c[1], z: c[2], yawDeg: c[3], pitchDeg: c[4]) }
        if options.drive { engine.toggleMode() }
        view.delegate = self
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate(ignoringOtherApps: true)
        captureMouse(true)
        installInput()
        print("Controles: ratón mira · WASD mover · E/Espacio subir · Q/Ctrl bajar · Mayús rápido · C coche/libre · G tono PS2 · Tab soltar ratón · Esc salir")
    }

    func captureMouse(_ on: Bool) {
        mouseCaptured = on
        CGAssociateMouseAndMouseCursorPosition(on ? 0 : 1)
        if on { NSCursor.hide() } else { NSCursor.unhide() }
    }

    func installInput() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown]) { [weak self] e in
            guard let self else { return e }
            switch e.type {
            case .keyDown:
                if e.modifierFlags.contains(.command) && e.charactersIgnoringModifiers == "q" { NSApp.terminate(nil) }
                if e.keyCode == Key.escape.rawValue { NSApp.terminate(nil) }
                if !e.isARepeat {
                    if e.keyCode == Key.c.rawValue { self.engine.toggleMode() }
                    if e.keyCode == Key.g.rawValue { self.engine.renderer.gradeStrength = self.engine.renderer.gradeStrength > 0 ? 0 : (self.options.grade ?? Config.ps2GradeStrength) }
                    if e.keyCode == 48 { self.captureMouse(!self.mouseCaptured) }   // Tab
                }
                self.engine.keys.insert(e.keyCode)
                return nil
            case .keyUp:
                self.engine.keys.remove(e.keyCode)
                return nil
            case .flagsChanged:
                let f = e.modifierFlags
                for (k, on) in [(Key.shift, f.contains(.shift)), (Key.control, f.contains(.control))] {
                    if on { self.engine.keys.insert(k.rawValue) } else { self.engine.keys.remove(k.rawValue); self.engine.keys.remove(Key.rightShift.rawValue) }
                }
                return e
            case .leftMouseDown:
                if !self.mouseCaptured { self.captureMouse(true) }
                return e
            default:
                if self.mouseCaptured { self.engine.mouseDelta += float2(Float(e.deltaX), Float(e.deltaY)) }
                return e
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        engine.aspect = Float(size.width / max(size.height, 1))
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - last))
        last = now
        let t0 = CACurrentMediaTime()
        guard let drawable = view.currentDrawable, let cb = engine.queue.makeCommandBuffer() else { return }
        engine.aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        updateScale()
        engine.frame(cb: cb, target: drawable.texture, dt: dt, scale: scale, now: now)
        cb.addCompletedHandler { [weak self] b in
            guard let self else { return }
            let ms = (b.gpuEndTime - b.gpuStartTime) * 1000
            self.statsLock.lock(); self.gpuMs = ms; self.gpuSamples.append(ms); self.statsLock.unlock()
        }
        cb.present(drawable)
        cb.commit()
        cpuSamples.append((CACurrentMediaTime() - t0) * 1000)
        frameSamples.append(Double(dt) * 1000)
        logStats(now)
        if let q = options.quitAfter, now - start > q { NSApp.terminate(nil) }
    }

    /// Resolución dinámica: ajusta la fracción de píxeles según el tiempo de GPU del último fotograma.
    func updateScale() {
        statsLock.lock(); let g = gpuMs; statsLock.unlock()
        if let fixed = options.scale { scale = fixed; return }
        if g > Config.gpuBudgetMs { scale *= 0.96 } else if g < Config.gpuBudgetMs * 0.7 { scale *= 1.01 }
        scale = max(Config.minRenderScale, min(Config.maxRenderScale, scale))
    }

    func logStats(_ now: Double) {
        guard now - lastLog > 2 else { return }
        lastLog = now
        statsLock.lock(); let g = gpuSamples; gpuSamples.removeAll(); statsLock.unlock()
        let f = frameSamples, c = cpuSamples
        frameSamples.removeAll(); cpuSamples.removeAll()
        let s = engine.streamer.stats
        let size = view.drawableSize
        print(String(format: "fps %.1f · fotograma med %.2f ms p95 %.2f · GPU med %.2f ms p95 %.2f · CPU %.2f ms · escala %.2f (%d×%d de %d×%d) · %d llamadas · %.2f M tri · casillas %d/%d cerca, %d cargando",
                     Double(f.count) / 2.0, median(f), pct(f, 0.95), median(g), pct(g, 0.95), median(c), scale,
                     Int(Float(size.width) * scale), Int(Float(size.height) * scale), Int(size.width), Int(size.height),
                     engine.renderer.lastDrawCalls, Double(engine.renderer.lastTriangles) / 1e6, s.nearReady, s.near, s.loading))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide() }
}

func fatal(_ msg: String) -> Never {
    fputs(msg + "\n", stderr)
    if NSApp != nil && Thread.isMainThread && ProcessInfo.processInfo.environment["ROCKPORT_NO_ALERT"] == nil {
        let a = NSAlert(); a.messageText = "Rockport"; a.informativeText = msg; a.runModal()
    }
    exit(1)
}

func median(_ a: [Double]) -> Double { pct(a, 0.5) }
func pct(_ a: [Double], _ p: Double) -> Double {
    guard !a.isEmpty else { return 0 }
    let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
}
